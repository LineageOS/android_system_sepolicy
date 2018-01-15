from optparse import OptionParser
from optparse import Option, OptionValueError
import os
import mini_parser
import policy
from policy import MatchPathPrefix
import re
import sys

DEBUG=False

'''
Use file_contexts and policy to verify Treble requirements
are not violated.
'''
###
# Differentiate between domains that are part of the core Android platform and
# domains introduced by vendors
coreAppdomain = {
        'bluetooth',
        'ephemeral_app',
        'isolated_app',
        'nfc',
        'platform_app',
        'priv_app',
        'radio',
        'shared_relro',
        'shell',
        'system_app',
        'untrusted_app',
        'untrusted_app_25',
        'untrusted_v2_app',
        }
coredomainWhitelist = {
        'adbd',
        'kernel',
        'postinstall',
        'postinstall_dexopt',
        'recovery',
        'system_server',
        }
coredomainWhitelist |= coreAppdomain

class scontext:
    def __init__(self):
        self.fromSystem = False
        self.fromVendor = False
        self.coredomain = False
        self.appdomain = False
        self.attributes = set()
        self.entrypoints = []
        self.entrypointpaths = []

def PrintScontexts():
    for d in sorted(alldomains.keys()):
        sctx = alldomains[d]
        print d
        print "\tcoredomain="+str(sctx.coredomain)
        print "\tappdomain="+str(sctx.appdomain)
        print "\tfromSystem="+str(sctx.fromSystem)
        print "\tfromVendor="+str(sctx.fromVendor)
        print "\tattributes="+str(sctx.attributes)
        print "\tentrypoints="+str(sctx.entrypoints)
        print "\tentrypointpaths="
        if sctx.entrypointpaths is not None:
            for path in sctx.entrypointpaths:
                print "\t\t"+str(path)

alldomains = {}
coredomains = set()
appdomains = set()
vendordomains = set()

# compat vars
alltypes = set()
oldalltypes = set()
compatMapping = None

def GetAllDomains(pol):
    global alldomains
    for result in pol.QueryTypeAttribute("domain", True):
        alldomains[result] = scontext()

def GetAppDomains():
    global appdomains
    global alldomains
    for d in alldomains:
        # The application of the "appdomain" attribute is trusted because core
        # selinux policy contains neverallow rules that enforce that only zygote
        # and runas spawned processes may transition to processes that have
        # the appdomain attribute.
        if "appdomain" in alldomains[d].attributes:
            alldomains[d].appdomain = True
            appdomains.add(d)

def GetCoreDomains():
    global alldomains
    global coredomains
    for d in alldomains:
        # TestCoredomainViolations will verify if coredomain was incorrectly
        # applied.
        if "coredomain" in alldomains[d].attributes:
            alldomains[d].coredomain = True
            coredomains.add(d)
        # check whether domains are executed off of /system or /vendor
        if d in coredomainWhitelist:
            continue
        # TODO, add checks to prevent app domains from being incorrectly
        # labeled as coredomain. Apps don't have entrypoints as they're always
        # dynamically transitioned to by zygote.
        if d in appdomains:
            continue
        if not alldomains[d].entrypointpaths:
            continue
        for path in alldomains[d].entrypointpaths:
            # Processes with entrypoint on /system
            if ((MatchPathPrefix(path, "/system") and not
                    MatchPathPrefix(path, "/system/vendor")) or
                    MatchPathPrefix(path, "/init") or
                    MatchPathPrefix(path, "/charger")):
                alldomains[d].fromSystem = True
            # Processes with entrypoint on /vendor or /system/vendor
            if (MatchPathPrefix(path, "/vendor") or
                    MatchPathPrefix(path, "/system/vendor")):
                alldomains[d].fromVendor = True
            # Work around to *not* mark /sbin services as system
            if MatchPathPrefix(path, "/sbin"):
                alldomains[d].fromSystem = False
                alldomains[d].fromVendor = False

###
# Add the entrypoint type and path(s) to each domain.
#
def GetDomainEntrypoints(pol):
    global alldomains
    for x in pol.QueryTERule(tclass="file", perms=["entrypoint"]):
        if not x.sctx in alldomains:
            continue
        alldomains[x.sctx].entrypoints.append(str(x.tctx))
        # postinstall_file represents a special case specific to A/B OTAs.
        # Update_engine mounts a partition and relabels it postinstall_file.
        # There is no file_contexts entry associated with postinstall_file
        # so skip the lookup.
        if x.tctx == "postinstall_file":
            continue
        entrypointpath = pol.QueryFc(x.tctx)
        if not entrypointpath:
            continue
        alldomains[x.sctx].entrypointpaths.extend(entrypointpath)
###
# Get attributes associated with each domain
#
def GetAttributes(pol):
    global alldomains
    for domain in alldomains:
        for result in pol.QueryTypeAttribute(domain, False):
            alldomains[domain].attributes.add(result)

def GetAllTypes(pol, oldpol):
    global alltypes
    global oldalltypes
    alltypes = pol.GetAllTypes(False)
    oldalltypes = oldpol.GetAllTypes(False)

def setup(pol):
    GetAllDomains(pol)
    GetAttributes(pol)
    GetDomainEntrypoints(pol)
    GetAppDomains()
    GetCoreDomains()

# setup for the policy compatibility tests
def compatSetup(pol, oldpol, mapping):
    global compatMapping

    GetAllTypes(pol, oldpol)
    compatMapping = mapping

#############################################################
# Tests
#############################################################
def TestCoredomainViolations():
    global alldomains
    # verify that all domains launched from /system have the coredomain
    # attribute
    ret = ""
    violators = []
    for d in alldomains:
        domain = alldomains[d]
        if domain.fromSystem and "coredomain" not in domain.attributes:
                violators.append(d);
    if len(violators) > 0:
        ret += "The following domain(s) must be associated with the "
        ret += "\"coredomain\" attribute because they are executed off of "
        ret += "/system:\n"
        ret += " ".join(str(x) for x in sorted(violators)) + "\n"

    # verify that all domains launched form /vendor do not have the coredomain
    # attribute
    violators = []
    for d in alldomains:
        domain = alldomains[d]
        if domain.fromVendor and "coredomain" in domain.attributes:
            violators.append(d)
    if len(violators) > 0:
        ret += "The following domains must not be associated with the "
        ret += "\"coredomain\" attribute because they are executed off of "
        ret += "/vendor or /system/vendor:\n"
        ret += " ".join(str(x) for x in sorted(violators)) + "\n"

    return ret

###
# Make sure that any new type introduced in the new policy that was not present
# in the old policy has been recorded in the mapping file.
def TestNoUnmappedNewTypes():
    global alltypes
    global oldalltypes
    global compatMapping
    newt = alltypes - oldalltypes
    ret = ""
    violators = []

    for n in newt:
        if compatMapping.rTypeattributesets.get(n) is None:
            violators.append(n)

    if len(violators) > 0:
        ret += "SELinux: The following types were found added to the policy "
        ret += "without an entry into the compatibility mapping file(s) found "
        ret += "in private/compat/" + compatMapping.apiLevel + "/"
        ret +=  compatMapping.apiLevel + "[.ignore].cil/n"
        ret += " ".join(str(x) for x in sorted(violators)) + "\n"
    return ret

###
# Make sure that any public type removed in the current policy has its
# declaration added to the mapping file for use in non-platform policy
def TestNoUnmappedRmTypes():
    global alltypes
    global oldalltypes
    global compatMapping
    rmt = oldalltypes - alltypes
    ret = ""
    violators = []

    for o in rmt:
        if o in compatMapping.pubtypes and not o in compatMapping.types:
            violators.append(o)

    if len(violators) > 0:
        ret += "SELinux: The following formerly public types were removed from "
        ret += "policy without a declaration in the compatibility mapping "
        ret += "file(s) found in prebuilts/api/" + compatMapping.apiLevel + "/\n"
        ret += " ".join(str(x) for x in sorted(violators)) + "\n"
    return ret

def TestTrebleCompatMapping():
    ret = TestNoUnmappedNewTypes()
    ret += TestNoUnmappedRmTypes()
    return ret
###
# extend OptionParser to allow the same option flag to be used multiple times.
# This is used to allow multiple file_contexts files and tests to be
# specified.
#
class MultipleOption(Option):
    ACTIONS = Option.ACTIONS + ("extend",)
    STORE_ACTIONS = Option.STORE_ACTIONS + ("extend",)
    TYPED_ACTIONS = Option.TYPED_ACTIONS + ("extend",)
    ALWAYS_TYPED_ACTIONS = Option.ALWAYS_TYPED_ACTIONS + ("extend",)

    def take_action(self, action, dest, opt, value, values, parser):
        if action == "extend":
            values.ensure_value(dest, []).append(value)
        else:
            Option.take_action(self, action, dest, opt, value, values, parser)

Tests = {"CoredomainViolations": TestCoredomainViolations,
         "TrebleCompatMapping": TestTrebleCompatMapping }

if __name__ == '__main__':
    usage = "treble_sepolicy_tests.py -f nonplat_file_contexts -f "
    usage +="plat_file_contexts -p curr_policy -b base_policy -o old_policy "
    usage +="-m mapping file [--test test] [--help]"
    parser = OptionParser(option_class=MultipleOption, usage=usage)
    parser.add_option("-b", "--basepolicy", dest="basepolicy", metavar="FILE")
    parser.add_option("-f", "--file_contexts", dest="file_contexts",
            metavar="FILE", action="extend", type="string")
    parser.add_option("-l", "--library-path", dest="libpath", metavar="FILE")
    parser.add_option("-m", "--mapping", dest="mapping", metavar="FILE")
    parser.add_option("-o", "--oldpolicy", dest="oldpolicy", metavar="FILE")
    parser.add_option("-p", "--policy", dest="policy", metavar="FILE")
    parser.add_option("-t", "--test", dest="tests", action="extend",

            help="Test options include "+str(Tests))

    (options, args) = parser.parse_args()

    if not options.libpath:
        sys.exit("Must specify path to host libraries\n" + parser.usage)
    if not os.path.exists(options.libpath):
        sys.exit("Error: library-path " + options.libpath + " does not exist\n"
                + parser.usage)
    if not options.basepolicy:
        sys.exit("Must specify the current platform-only policy file\n" + parser.usage)
    if not options.mapping:
        sys.exit("Must specify a compatibility mapping file\n" + parser.usage)
    if not options.oldpolicy:
        sys.exit("Must specify the previous monolithic policy file\n" + parser.usage)
    if not options.policy:
        sys.exit("Must specify current monolithic policy file\n" + parser.usage)
    if not os.path.exists(options.policy):
        sys.exit("Error: policy file " + options.policy + " does not exist\n"
                + parser.usage)

    if not options.file_contexts:
        sys.exit("Error: Must specify file_contexts file(s)\n" + parser.usage)
    for f in options.file_contexts:
        if not os.path.exists(f):
            sys.exit("Error: File_contexts file " + f + " does not exist\n" +
                    parser.usage)

    pol = policy.Policy(options.policy, options.file_contexts, options.libpath)
    setup(pol)
    basepol = policy.Policy(options.basepolicy, None, options.libpath)
    oldpol = policy.Policy(options.oldpolicy, None, options.libpath)
    mapping = mini_parser.MiniCilParser(options.mapping)
    compatSetup(basepol, oldpol, mapping)

    if DEBUG:
        PrintScontexts()

    results = ""
    # If an individual test is not specified, run all tests.
    if options.tests is None:
        for t in Tests.values():
            results += t()
    else:
        for tn in options.tests:
            t = Tests.get(tn)
            if t:
                results += t()
            else:
                err = "Error: unknown test: " + tn + "\n"
                err += "Available tests:\n"
                for tn in Tests.keys():
                    err += tn + "\n"
                sys.exit(err)

    if len(results) > 0:
        sys.exit(results)
