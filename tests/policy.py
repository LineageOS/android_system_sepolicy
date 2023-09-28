# Copyright 2021 The Android Open Source Project
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

from ctypes import *
import re
import os
import sys
import platform
import fc_sort

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
COMMON_PREFIXES = {
    "/(vendor|system/vendor)": ["/vendor", "/system/vendor"],
    "/(odm|vendor/odm)": ["/odm", "/vendor/odm"],
    "/(product|system/product)": ["/product", "/system/product"],
    "/(system_ext|system/system_ext)": ["/system_ext", "/system/system_ext"],
}

def MatchPathPrefix(pathregex, prefix):
    # Before running regex compile loop, try two heuristics, because compiling
    # regex is too expensive. These two can handle more than 90% out of all
    # MatchPathPrefix calls.

    # Heuristic 1: handle common prefixes for partitions
    for c in COMMON_PREFIXES:
        if not pathregex.startswith(c):
            continue
        found = False
        for p in COMMON_PREFIXES[c]:
            if prefix.startswith(p):
                found = True
                prefix = prefix[len(p):]
                pathregex = pathregex[len(c):]
                break
        if not found:
            return False

    # Heuristic 2: compare normal characters as long as possible
    idx = 0
    while idx < len(prefix):
        if idx == len(pathregex):
            return False
        if pathregex[idx] in fc_sort.META_CHARS or pathregex[idx] == '\\':
            break
        if pathregex[idx] != prefix[idx]:
            return False
        idx += 1
    if idx == len(prefix):
        return True

    # Fall back to regex compile loop.
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
    __ExpandedRules = set()
    __Rules = set()
    __FcDict = None
    __FcSorted = None
    __GenfsDict = None
    __libsepolwrap = None
    __policydbP = None
    __BUFSIZE = 2048

    def AssertPathTypesDoNotHaveAttr(self, MatchPrefix, DoNotMatchPrefix, Attr, ExcludedTypes = []):
        # Query policy for the types associated with Attr
        TypesPol = self.QueryTypeAttribute(Attr, True) - set(ExcludedTypes)
        # Search file_contexts to find types associated with input paths.
        TypesFc, Files = self.__GetTypesAndFilesByFilePathPrefix(MatchPrefix, DoNotMatchPrefix)
        violators = TypesFc.intersection(TypesPol)
        ret = ""
        if len(violators) > 0:
            ret += "The following types on "
            ret += " ".join(str(x) for x in sorted(MatchPrefix))
            ret += " must not be associated with the "
            ret += "\"" + Attr + "\" attribute: "
            ret += " ".join(str(x) for x in sorted(violators)) + "\n"
            ret += " corresponding to files: "
            ret += " ".join(str(x) for x in sorted(Files)) + "\n"
        return ret

    # Check that all types for "filesystem" have "attribute" associated with them
    # for types labeled in genfs_contexts.
    def AssertGenfsFilesystemTypesHaveAttr(self, Filesystem, Attr):
        TypesPol = self.QueryTypeAttribute(Attr, True)
        TypesGenfs = self.__GenfsDict[Filesystem]
        violators = TypesGenfs.difference(TypesPol)

        ret = ""
        if len(violators) > 0:
            ret += "The following types in " + Filesystem
            ret += " must be associated with the "
            ret += "\"" + Attr + "\" attribute: "
            ret += " ".join(str(x) for x in sorted(violators)) + "\n"
        return ret

    # Check that path prefixes that match MatchPrefix, and do not Match
    # DoNotMatchPrefix have the attribute Attr.
    # For example assert that all types in /sys, and not in /sys/kernel/debugfs
    # have the sysfs_type attribute.
    def AssertPathTypesHaveAttr(self, MatchPrefix, DoNotMatchPrefix, Attr):
        # Query policy for the types associated with Attr
        TypesPol = self.QueryTypeAttribute(Attr, True)
        # Search file_contexts to find paths/types that should be associated with
        # Attr.
        TypesFc, Files = self.__GetTypesAndFilesByFilePathPrefix(MatchPrefix, DoNotMatchPrefix)
        violators = TypesFc.difference(TypesPol)

        ret = ""
        if len(violators) > 0:
            ret += "The following types on "
            ret += " ".join(str(x) for x in sorted(MatchPrefix))
            ret += " must be associated with the "
            ret += "\"" + Attr + "\" attribute: "
            ret += " ".join(str(x) for x in sorted(violators)) + "\n"
            ret += " corresponding to files: "
            ret += " ".join(str(x) for x in sorted(Files)) + "\n"
        return ret

    def AssertPropertyOwnersAreExclusive(self):
        systemProps = self.QueryTypeAttribute('system_property_type', True)
        vendorProps = self.QueryTypeAttribute('vendor_property_type', True)
        violators = systemProps.intersection(vendorProps)
        ret = ""
        if len(violators) > 0:
            ret += "The following types have both system_property_type "
            ret += "and vendor_property_type: "
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
                        create_string_buffer(Type.encode("ascii")), IsAttr)
        if (TypeIterP == None):
            sys.exit("Failed to initialize type iterator")
        buf = create_string_buffer(self.__BUFSIZE)
        TypeAttr = set()
        while True:
            ret = self.__libsepolwrap.get_type(buf, self.__BUFSIZE,
                    self.__policydbP, TypeIterP)
            if ret == 0:
                TypeAttr.add(buf.value.decode("ascii"))
                continue
            if ret == 1:
                break;
            # We should never get here.
            sys.exit("Failed to import policy")
        self.__libsepolwrap.destroy_type_iter(TypeIterP)
        return TypeAttr

    def __TERuleMatch(self, Rule, **kwargs):
        # Match source type
        if ("scontext" in kwargs and
                len(kwargs['scontext']) > 0 and
                Rule.sctx not in kwargs['scontext']):
            return False
        # Match target type
        if ("tcontext" in kwargs and
                len(kwargs['tcontext']) > 0 and
                Rule.tctx not in kwargs['tcontext']):
            return False
        # Match target class
        if ("tclass" in kwargs and
                len(kwargs['tclass']) > 0 and
                not bool(set([Rule.tclass]) & kwargs['tclass'])):
            return False
        # Match any perms
        if ("perms" in kwargs and
                len(kwargs['perms']) > 0 and
                not bool(Rule.perms & kwargs['perms'])):
            return False
        return True

    # resolve a type to its attributes or
    # resolve an attribute to its types and attributes
    # For example if scontext is the domain attribute, then we need to
    # include all types with the domain attribute such as untrusted_app and
    # priv_app and all the attributes of those types such as appdomain.
    def ResolveTypeAttribute(self, Type):
        types = self.GetAllTypes(False)
        attributes = self.GetAllTypes(True)

        if Type in types:
            return self.QueryTypeAttribute(Type, False)
        elif Type in attributes:
            TypesAndAttributes = set()
            Types = self.QueryTypeAttribute(Type, True)
            TypesAndAttributes |= Types
            for T in Types:
                TypesAndAttributes |= self.QueryTypeAttribute(T, False)
            return TypesAndAttributes
        else:
            return set()

    # Return all TERules that match:
    # (any scontext) or (any tcontext) or (any tclass) or (any perms),
    # perms.
    # Any unspecified paramenter will match all.
    #
    # Example: QueryTERule(tcontext=["foo", "bar"], perms=["entrypoint"])
    # Will return any rule with:
    # (tcontext="foo" or tcontext="bar") and ("entrypoint" in perms)
    def QueryTERule(self, **kwargs):
        if len(self.__Rules) == 0:
            self.__InitTERules()

        # add any matching types and attributes for scontext and tcontext
        if ("scontext" in kwargs and len(kwargs['scontext']) > 0):
            scontext = set()
            for sctx in kwargs['scontext']:
                scontext |= self.ResolveTypeAttribute(sctx)
            if (len(scontext) == 0):
                return []
            kwargs['scontext'] = scontext
        if ("tcontext" in kwargs and len(kwargs['tcontext']) > 0):
            tcontext = set()
            for tctx in kwargs['tcontext']:
                tcontext |= self.ResolveTypeAttribute(tctx)
            if (len(tcontext) == 0):
                return []
            kwargs['tcontext'] = tcontext
        for Rule in self.__Rules:
            if self.__TERuleMatch(Rule, **kwargs):
                yield Rule

    # Same as QueryTERule but only using the expanded ruleset.
    # i.e. all attributes have been expanded to their various types.
    def QueryExpandedTERule(self, **kwargs):
        if len(self.__ExpandedRules) == 0:
            self.__InitExpandedTERules()
        for Rule in self.__ExpandedRules:
            if self.__TERuleMatch(Rule, **kwargs):
                yield Rule

    def GetAllTypes(self, isAttr):
        TypeIterP = self.__libsepolwrap.init_type_iter(self.__policydbP, None, isAttr)
        if (TypeIterP == None):
            sys.exit("Failed to initialize type iterator")
        buf = create_string_buffer(self.__BUFSIZE)
        AllTypes = set()
        while True:
            ret = self.__libsepolwrap.get_type(buf, self.__BUFSIZE,
                    self.__policydbP, TypeIterP)
            if ret == 0:
                AllTypes.add(buf.value.decode("ascii"))
                continue
            if ret == 1:
                break;
            # We should never get here.
            sys.exit("Failed to import policy")
        self.__libsepolwrap.destroy_type_iter(TypeIterP)
        return AllTypes

    def __ExactMatchPathPrefix(self, pathregex, prefix):
        pattern = re.compile('^' + pathregex + "$")
        if pattern.match(prefix):
            return True
        return False

    # Return a tuple (prefix, i) where i is the index of the most specific
    # match of prefix in the sorted file_contexts. This is useful for limiting a
    # file_contexts search to matches that are more specific and omitting less
    # specific matches. For example, finding all matches to prefix /data/vendor
    # should not include /data(/.*)? if /data/vendor(/.*)? is also specified.
    def __FcSortedIndex(self, prefix):
        index = 0
        for i in range(0, len(self.__FcSorted)):
            if self.__ExactMatchPathPrefix(self.__FcSorted[i].path, prefix):
                index = i
        return prefix, index

    # Return a tuple of (path, Type) for all matching paths. Use the sorted
    # file_contexts and index returned from __FcSortedIndex() to limit results
    # to results that are more specific than the prefix.
    def __MatchPathPrefixTypes(self, prefix, index):
        PathType = []
        for i in range(index, len(self.__FcSorted)):
            if MatchPathPrefix(self.__FcSorted[i].path, prefix):
                PathType.append((self.__FcSorted[i].path, self.__FcSorted[i].type))
        return PathType

    # Return types that match MatchPrefixes but do not match
    # DoNotMatchPrefixes
    def __GetTypesAndFilesByFilePathPrefix(self, MatchPrefixes, DoNotMatchPrefixes):
        Types = set()
        Files = set()

        MatchPrefixesWithIndex = []
        for MatchPrefix in MatchPrefixes:
            MatchPrefixesWithIndex.append(self.__FcSortedIndex(MatchPrefix))

        for MatchPrefixWithIndex in MatchPrefixesWithIndex:
            PathTypes = self.__MatchPathPrefixTypes(*MatchPrefixWithIndex)
            for PathType in PathTypes:
                if MatchPathPrefixes(PathType[0], DoNotMatchPrefixes):
                    continue
                Types.add(PathType[1])
                Files.add(PathType[0])
        return Types, Files

    def __GetTERules(self, policydbP, avtabIterP, Rules):
        if Rules is None:
            Rules = set()
        buf = create_string_buffer(self.__BUFSIZE)
        ret = 0
        while True:
            ret = self.__libsepolwrap.get_allow_rule(buf, self.__BUFSIZE,
                        policydbP, avtabIterP)
            if ret == 0:
                Rule = TERule(buf.value.decode("ascii"))
                Rules.add(Rule)
                continue
            if ret == 1:
                break;
            # We should never get here.
            sys.exit("Failed to import policy")

    def __InitTERules(self):
        avtabIterP = self.__libsepolwrap.init_avtab(self.__policydbP)
        if (avtabIterP == None):
            sys.exit("Failed to initialize avtab")
        self.__GetTERules(self.__policydbP, avtabIterP, self.__Rules)
        self.__libsepolwrap.destroy_avtab(avtabIterP)
        avtabIterP = self.__libsepolwrap.init_cond_avtab(self.__policydbP)
        if (avtabIterP == None):
            sys.exit("Failed to initialize conditional avtab")
        self.__GetTERules(self.__policydbP, avtabIterP, self.__Rules)
        self.__libsepolwrap.destroy_avtab(avtabIterP)

    def __InitExpandedTERules(self):
        avtabIterP = self.__libsepolwrap.init_expanded_avtab(self.__policydbP)
        if (avtabIterP == None):
            sys.exit("Failed to initialize avtab")
        self.__GetTERules(self.__policydbP, avtabIterP, self.__ExpandedRules)
        self.__libsepolwrap.destroy_expanded_avtab(avtabIterP)
        avtabIterP = self.__libsepolwrap.init_expanded_cond_avtab(self.__policydbP)
        if (avtabIterP == None):
            sys.exit("Failed to initialize conditional avtab")
        self.__GetTERules(self.__policydbP, avtabIterP, self.__ExpandedRules)
        self.__libsepolwrap.destroy_expanded_avtab(avtabIterP)

    # load ctypes-ified libsepol wrapper
    def __InitLibsepolwrap(self, LibPath):
        lib = CDLL(LibPath)

        # int get_allow_rule(char *out, size_t len, void *policydbp, void *avtab_iterp);
        lib.get_allow_rule.restype = c_int
        lib.get_allow_rule.argtypes = [c_char_p, c_size_t, c_void_p, c_void_p];
        # void *load_policy(const char *policy_path);
        lib.load_policy.restype = c_void_p
        lib.load_policy.argtypes = [c_char_p]
        # void destroy_policy(void *policydbp);
        lib.destroy_policy.argtypes = [c_void_p]
        # void *init_expanded_avtab(void *policydbp);
        lib.init_expanded_avtab.restype = c_void_p
        lib.init_expanded_avtab.argtypes = [c_void_p]
        # void *init_expanded_cond_avtab(void *policydbp);
        lib.init_expanded_cond_avtab.restype = c_void_p
        lib.init_expanded_cond_avtab.argtypes = [c_void_p]
        # void destroy_expanded_avtab(void *avtab_iterp);
        lib.destroy_expanded_avtab.argtypes = [c_void_p]
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
        # void *init_genfs_iter(void *policydbp)
        lib.init_genfs_iter.restype = c_void_p
        lib.init_genfs_iter.argtypes = [c_void_p]
        # int get_genfs(char *out, size_t max_size, void *genfs_iterp);
        lib.get_genfs.restype = c_int
        lib.get_genfs.argtypes = [c_char_p, c_size_t, c_void_p, c_void_p]
        # void destroy_genfs_iter(void *genfs_iterp)
        lib.destroy_genfs_iter.argtypes = [c_void_p]

        self.__libsepolwrap = lib

    def __GenfsDictAdd(self, Dict, buf):
        fs, buf = buf.split(' ', 1)
        path, context = buf.rsplit(' ', 1)
        Type = context.split(":")[2]
        if not fs in Dict:
            Dict[fs] = {Type}
        else:
            Dict[fs].add(Type)

    def __InitGenfsCon(self):
        self.__GenfsDict = {}
        GenfsIterP = self.__libsepolwrap.init_genfs_iter(self.__policydbP)
        if (GenfsIterP == None):
            sys.exit("Failed to retreive genfs entries")
        buf = create_string_buffer(self.__BUFSIZE)
        while True:
            ret = self.__libsepolwrap.get_genfs(buf, self.__BUFSIZE,
                        self.__policydbP, GenfsIterP)
            if ret == 0:
                self.__GenfsDictAdd(self.__GenfsDict, buf.value.decode("ascii"))
                continue
            if ret == 1:
                self.__GenfsDictAdd(self.__GenfsDict, buf.value.decode("ascii"))
                break;
            # We should never get here.
            sys.exit("Failed to get genfs entries")
        self.__libsepolwrap.destroy_genfs_iter(GenfsIterP)

    # load file_contexts
    def __InitFC(self, FcPaths):
        self.__FcDict = {}
        if FcPaths is None:
            return
        fc = []
        for path in FcPaths:
            if not os.path.exists(path):
                sys.exit("file_contexts file " + path + " does not exist.")
            fd = open(path, "r")
            fc += fd.readlines()
            fd.close()
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
        self.__FcSorted = fc_sort.sort(FcPaths)

    # load policy
    def __InitPolicy(self, PolicyPath):
        cPolicyPath = create_string_buffer(PolicyPath.encode("ascii"))
        self.__policydbP = self.__libsepolwrap.load_policy(cPolicyPath)
        if (self.__policydbP is None):
            sys.exit("Failed to load policy")

    def __init__(self, PolicyPath, FcPaths, LibPath):
        self.__InitLibsepolwrap(LibPath)
        self.__InitFC(FcPaths)
        self.__InitPolicy(PolicyPath)
        self.__InitGenfsCon()

    def __del__(self):
        if self.__policydbP is not None:
            self.__libsepolwrap.destroy_policy(self.__policydbP)

coredomainAllowlist = {
        # TODO: how do we make sure vendor_init doesn't have bad coupling with
        # /vendor? It is the only system process which is not coredomain.
        'vendor_init',
        # TODO(b/152813275): need to avoid allowlist for rootdir
        "modprobe",
        "slideshow",
        }

class scontext:
    def __init__(self):
        self.fromSystem = False
        self.fromVendor = False
        self.coredomain = False
        self.appdomain = False
        self.attributes = set()
        self.entrypoints = []
        self.entrypointpaths = []
        self.error = ""

class TestPolicy:
    """A policy loaded in memory with its domains easily accessible."""

    def __init__(self):
        self.alldomains = {}
        self.coredomains = set()
        self.appdomains = set()
        self.vendordomains = set()
        self.pol = None

        # compat vars
        self.alltypes = set()
        self.oldalltypes = set()
        self.compatMapping = None
        self.pubtypes = set()

    def GetAllDomains(self):
        for result in self.pol.QueryTypeAttribute("domain", True):
            self.alldomains[result] = scontext()

    def GetAppDomains(self):
        for d in self.alldomains:
            # The application of the "appdomain" attribute is trusted because core
            # selinux policy contains neverallow rules that enforce that only zygote
            # and runas spawned processes may transition to processes that have
            # the appdomain attribute.
            if "appdomain" in self.alldomains[d].attributes:
                self.alldomains[d].appdomain = True
                self.appdomains.add(d)

    def GetCoreDomains(self):
        for d in self.alldomains:
            domain = self.alldomains[d]
            # TestCoredomainViolations will verify if coredomain was incorrectly
            # applied.
            if "coredomain" in domain.attributes:
                domain.coredomain = True
                self.coredomains.add(d)
            # check whether domains are executed off of /system or /vendor
            if d in coredomainAllowlist:
                continue
            # TODO(b/153112003): add checks to prevent app domains from being
            # incorrectly labeled as coredomain. Apps don't have entrypoints as
            # they're always dynamically transitioned to by zygote.
            if d in self.appdomains:
                continue
            # TODO(b/153112747): need to handle cases where there is a dynamic
            # transition OR there happens to be no context in AOSP files.
            if not domain.entrypointpaths:
                continue

            for path in domain.entrypointpaths:
                vendor = any(MatchPathPrefix(path, prefix) for prefix in
                             ["/vendor", "/odm"])
                system = any(MatchPathPrefix(path, prefix) for prefix in
                             ["/init", "/system_ext", "/product" ])

                # only mark entrypoint as system if it is not in legacy /system/vendor
                if MatchPathPrefix(path, "/system/vendor"):
                    vendor = True
                elif MatchPathPrefix(path, "/system"):
                    system = True

                if not vendor and not system:
                    domain.error += "Unrecognized entrypoint for " + d + " at " + path + "\n"

                domain.fromSystem = domain.fromSystem or system
                domain.fromVendor = domain.fromVendor or vendor

    ###
    # Add the entrypoint type and path(s) to each domain.
    #
    def GetDomainEntrypoints(self):
        for x in self.pol.QueryExpandedTERule(tclass=set(["file"]), perms=set(["entrypoint"])):
            if not x.sctx in self.alldomains:
                continue
            self.alldomains[x.sctx].entrypoints.append(str(x.tctx))
            # postinstall_file represents a special case specific to A/B OTAs.
            # Update_engine mounts a partition and relabels it postinstall_file.
            # There is no file_contexts entry associated with postinstall_file
            # so skip the lookup.
            if x.tctx == "postinstall_file":
                continue
            entrypointpath = self.pol.QueryFc(x.tctx)
            if not entrypointpath:
                continue
            self.alldomains[x.sctx].entrypointpaths.extend(entrypointpath)

    ###
    # Get attributes associated with each domain
    #
    def GetAttributes(self):
        for domain in self.alldomains:
            for result in self.pol.QueryTypeAttribute(domain, False):
                self.alldomains[domain].attributes.add(result)

    def setup(self, pol):
        self.pol = pol
        self.GetAllDomains()
        self.GetAttributes()
        self.GetDomainEntrypoints()
        self.GetAppDomains()
        self.GetCoreDomains()

    def GetAllTypes(self, basepol, oldpol):
        self.alltypes = basepol.GetAllTypes(False)
        self.oldalltypes = oldpol.GetAllTypes(False)

    # setup for the policy compatibility tests
    def compatSetup(self, basepol, oldpol, mapping, types):
        self.GetAllTypes(basepol, oldpol)
        self.compatMapping = mapping
        self.pubtypes = types

    def DomainsWithAttribute(self, attr):
        domains = []
        for domain in self.alldomains:
            if attr in self.alldomains[domain].attributes:
                domains.append(domain)
        return domains

    def PrintScontexts(self):
        for d in sorted(self.alldomains.keys()):
            sctx = self.alldomains[d]
            print(d)
            print("\tcoredomain="+str(sctx.coredomain))
            print("\tappdomain="+str(sctx.appdomain))
            print("\tfromSystem="+str(sctx.fromSystem))
            print("\tfromVendor="+str(sctx.fromVendor))
            print("\tattributes="+str(sctx.attributes))
            print("\tentrypoints="+str(sctx.entrypoints))
            print("\tentrypointpaths=")
            if sctx.entrypointpaths is not None:
                for path in sctx.entrypointpaths:
                    print("\t\t"+str(path))
