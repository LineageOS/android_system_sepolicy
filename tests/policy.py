from ctypes import *
import re
import os
import sys

###
# Check whether the regex will match a file path starting with the provided
# prefix
#
# Compares regex entries in file_contexts with a path prefix. Regex entries
# are often more specific than this file prefix. For example, the regex could
# be /system/bin/foo\.sh and the prefix could be /system. This function
# loops over the regex removing characters from the end until
# 1) there is a match - return True or 2) run out of characters - return
#    False.
#
def MatchPathPrefix(pathregex, prefix):
    for i in range(len(pathregex), 0, -1):
        try:
            pattern = re.compile('^' + pathregex[0:i] + "$")
        except:
            continue
        if pattern.match(prefix):
            return True
    return False

def MatchPathPrefixes(pathregex, Prefixes):
    for Prefix in Prefixes:
        if MatchPathPrefix(pathregex, Prefix):
            return True
    return False

class TERule:
    def __init__(self, rule):
        data = rule.split(',')
        self.flavor = data[0]
        self.sctx = data[1]
        self.tctx = data[2]
        self.tclass = data[3]
        self.perms = set((data[4].strip()).split(' '))
        self.rule = rule

class Policy:
    __Rules = None
    __FcDict = None
    __libsepolwrap = None
    __policydbP = None
    __BUFSIZE = 2048

    # Check that path prefixes that match MatchPrefix, and do not Match
    # DoNotMatchPrefix have the attribute Attr.
    # For example assert that all types in /sys, and not in /sys/kernel/debugfs
    # have the sysfs_type attribute.
    def AssertPathTypesHaveAttr(self, MatchPrefix, DoNotMatchPrefix, Attr):
        # Query policy for the types associated with Attr
        TypesPol = self.QueryTypeAttribute(Attr, True)
        # Search file_contexts to find paths/types that should be associated with
        # Attr.
        TypesFc = self.__GetTypesByFilePathPrefix(MatchPrefix, DoNotMatchPrefix)
        violators = TypesFc.difference(TypesPol)

        ret = ""
        if len(violators) > 0:
            ret += "The following types on "
            ret += " ".join(str(x) for x in sorted(MatchPrefix))
            ret += " must be associated with the "
            ret += "\"" + Attr + "\" attribute: "
            ret += " ".join(str(x) for x in sorted(violators)) + "\n"
        return ret

    # Return all file_contexts entries that map to the input Type.
    def QueryFc(self, Type):
        if Type in self.__FcDict:
            return self.__FcDict[Type]
        else:
            return None

    # Return all attributes associated with a type if IsAttr=False or
    # all types associated with an attribute if IsAttr=True
    def QueryTypeAttribute(self, Type, IsAttr):
        TypeIterP = self.__libsepolwrap.init_type_iter(self.__policydbP,
                        create_string_buffer(Type), IsAttr)
        if (TypeIterP == None):
            sys.exit("Failed to initialize type iterator")
        buf = create_string_buffer(self.__BUFSIZE)
        TypeAttr = set()
        while True:
            ret = self.__libsepolwrap.get_type(buf, self.__BUFSIZE,
                    self.__policydbP, TypeIterP)
            if ret == 0:
                TypeAttr.add(buf.value)
                continue
            if ret == 1:
                break;
            # We should never get here.
            sys.exit("Failed to import policy")
        self.__libsepolwrap.destroy_type_iter(TypeIterP)
        return TypeAttr

    # Return all TERules that match:
    # (any scontext) or (any tcontext) or (any tclass) or (any perms),
    # perms.
    # Any unspecified paramenter will match all.
    #
    # Example: QueryTERule(tcontext=["foo", "bar"], perms=["entrypoint"])
    # Will return any rule with:
    # (tcontext="foo" or tcontext="bar") and ("entrypoint" in perms)
    def QueryTERule(self, **kwargs):
        if self.__Rules is None:
            self.__InitTERules()
        for Rule in self.__Rules:
            # Match source type
            if "scontext" in kwargs and Rule.sctx not in kwargs['scontext']:
                continue
            # Match target type
            if "tcontext" in kwargs and Rule.tctx not in kwargs['tcontext']:
                continue
            # Match target class
            if "tclass" in kwargs and Rule.tclass not in kwargs['tclass']:
                continue
            # Match any perms
            if "perms" in kwargs and not bool(Rule.perms & set(kwargs['perms'])):
                continue
            yield Rule

    def __GetTypesByFilePathPrefix(self, MatchPrefixes, DoNotMatchPrefixes):
        Types = set()
        for Type in self.__FcDict:
            for pathregex in self.__FcDict[Type]:
                if not MatchPathPrefixes(pathregex, MatchPrefixes):
                    continue
                if MatchPathPrefixes(pathregex, DoNotMatchPrefixes):
                    continue
                Types.add(Type)
        return Types


    def __GetTERules(self, policydbP, avtabIterP):
        if self.__Rules is None:
            self.__Rules = set()
        buf = create_string_buffer(self.__BUFSIZE)
        ret = 0
        while True:
            ret = self.__libsepolwrap.get_allow_rule(buf, self.__BUFSIZE,
                        policydbP, avtabIterP)
            if ret == 0:
                Rule = TERule(buf.value)
                self.__Rules.add(Rule)
                continue
            if ret == 1:
                break;
            # We should never get here.
            sys.exit("Failed to import policy")

    def __InitTERules(self):
        avtabIterP = self.__libsepolwrap.init_avtab(self.__policydbP)
        if (avtabIterP == None):
            sys.exit("Failed to initialize avtab")
        self.__GetTERules(self.__policydbP, avtabIterP)
        self.__libsepolwrap.destroy_avtab(avtabIterP)
        avtabIterP = self.__libsepolwrap.init_cond_avtab(self.__policydbP)
        if (avtabIterP == None):
            sys.exit("Failed to initialize conditional avtab")
        self.__GetTERules(self.__policydbP, avtabIterP)
        self.__libsepolwrap.destroy_avtab(avtabIterP)

    # load ctypes-ified libsepol wrapper
    def __InitLibsepolwrap(self, LibPath):
        if "linux" in sys.platform:
            lib = CDLL(LibPath + "/libsepolwrap.so")
        elif "darwin" in sys.platform:
            lib = CDLL(LibPath + "/libsepolwrap.dylib")
        else:
            sys.exit("only Linux and Mac currrently supported")

        # int get_allow_rule(char *out, size_t len, void *policydbp, void *avtab_iterp);
        lib.get_allow_rule.restype = c_int
        lib.get_allow_rule.argtypes = [c_char_p, c_size_t, c_void_p, c_void_p];
        # void *load_policy(const char *policy_path);
        lib.load_policy.restype = c_void_p
        lib.load_policy.argtypes = [c_char_p]
        # void destroy_policy(void *policydbp);
        lib.destroy_policy.argtypes = [c_void_p]
        # void *init_avtab(void *policydbp);
        lib.init_avtab.restype = c_void_p
        lib.init_avtab.argtypes = [c_void_p]
        # void *init_cond_avtab(void *policydbp);
        lib.init_cond_avtab.restype = c_void_p
        lib.init_cond_avtab.argtypes = [c_void_p]
        # void destroy_avtab(void *avtab_iterp);
        lib.destroy_avtab.argtypes = [c_void_p]
        # int get_type(char *out, size_t max_size, void *policydbp, void *type_iterp);
        lib.get_type.restype = c_int
        lib.get_type.argtypes = [c_char_p, c_size_t, c_void_p, c_void_p]
        # void *init_type_iter(void *policydbp, const char *type, bool is_attr);
        lib.init_type_iter.restype = c_void_p
        lib.init_type_iter.argtypes = [c_void_p, c_char_p, c_bool]
        # void destroy_type_iter(void *type_iterp);
        lib.destroy_type_iter.argtypes = [c_void_p]

        self.__libsepolwrap = lib


    # load file_contexts
    def __InitFC(self, FcPaths):
        fc = []
        for path in FcPaths:
            if not os.path.exists(path):
                sys.exit("file_contexts file " + path + " does not exist.")
            fd = open(path, "r")
            fc += fd.readlines()
            fd.close()
        self.__FcDict = {}
        for i in fc:
            rec = i.split()
            try:
                t = rec[-1].split(":")[2]
                if t in self.__FcDict:
                    self.__FcDict[t].append(rec[0])
                else:
                    self.__FcDict[t] = [rec[0]]
            except:
                pass

    # load policy
    def __InitPolicy(self, PolicyPath):
        cPolicyPath = create_string_buffer(PolicyPath)
        self.__policydbP = self.__libsepolwrap.load_policy(cPolicyPath)
        if (self.__policydbP is None):
            sys.exit("Failed to load policy")

    def __init__(self, PolicyPath, FcPaths, LibPath):
        self.__InitLibsepolwrap(LibPath)
        self.__InitFC(FcPaths)
        self.__InitPolicy(PolicyPath)

    def __del__(self):
        if self.__policydbP is not None:
            self.__libsepolwrap.destroy_policy(self.__policydbP)
