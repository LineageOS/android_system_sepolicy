from optparse import OptionParser
from optparse import Option, OptionValueError
import os
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
        # TestCoredomainViolators will verify if coredomain was incorrectly
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

def setup(pol):
    GetAllDomains(pol)
    GetAttributes(pol)
    GetDomainEntrypoints(pol)
    GetAppDomains()
    GetCoreDomains()

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

Tests = ["CoredomainViolators"]

if __name__ == '__main__':
    usage = "treble_sepolicy_tests.py -f nonplat_file_contexts -f "
    usage +="plat_file_contexts -p policy [--test test] [--help]"
    parser = OptionParser(option_class=MultipleOption, usage=usage)
    parser.add_option("-f", "--file_contexts", dest="file_contexts",
            metavar="FILE", action="extend", type="string")
    parser.add_option("-p", "--policy", dest="policy", metavar="FILE")
    parser.add_option("-l", "--library-path", dest="libpath", metavar="FILE")
    parser.add_option("-t", "--test", dest="test", action="extend",
            help="Test options include "+str(Tests))

    (options, args) = parser.parse_args()

    if not options.libpath:
        sys.exit("Must specify path to host libraries\n" + parser.usage)
    if not os.path.exists(options.libpath):
        sys.exit("Error: library-path " + options.libpath + " does not exist\n"
                + parser.usage)

    if not options.policy:
        sys.exit("Must specify monolithic policy file\n" + parser.usage)
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

    if DEBUG:
        PrintScontexts()

    results = ""
    # If an individual test is not specified, run all tests.
    if options.test is None or "CoredomainViolations" in options.tests:
        results += TestCoredomainViolations()

    if len(results) > 0:
        sys.exit(results)
