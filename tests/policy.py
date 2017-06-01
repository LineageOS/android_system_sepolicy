from ctypes import *
import re
import os

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
                create_string_buffer(Type), c_bool(IsAttr))
        if (TypeIterP == None):
            sys.exit("Failed to initialize type iterator")
        buf = create_string_buffer(2048)

        while True:
            ret = self.__libsepolwrap.get_type(buf, c_int(2048),
                    self.__policydbP, TypeIterP)
            if ret == 0:
                yield buf.value
                continue
            if ret == 1:
                break;
            # We should never get here.
            sys.exit("Failed to import policy")
        self.__libsepolwrap.destroy_type_iter(TypeIterP)

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


    def __GetTERules(self, policydbP, avtabIterP):
        if self.__Rules is None:
            self.__Rules = set()
        buf = create_string_buffer(2048)
        ret = 0
        while True:
            ret = self.__libsepolwrap.get_allow_rule(buf, c_int(2048), policydbP, avtabIterP)
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
    def __InitLibsepolwrap(self):
        self.__libsepolwrap = CDLL("libsepolwrap.so")

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
        self.__policydbP = self.__libsepolwrap.load_policy(create_string_buffer(PolicyPath))
        if (self.__policydbP is None):
            sys.exit("Failed to load policy")

    def __init__(self, PolicyPath, FcPaths):
        self.__InitLibsepolwrap()
        self.__InitFC(FcPaths)
        self.__InitPolicy(PolicyPath)

    def __del__(self):
        if self.__policydbP is not None:
            self.__libsepolwrap.destroy_policy(self.__policydbP)
