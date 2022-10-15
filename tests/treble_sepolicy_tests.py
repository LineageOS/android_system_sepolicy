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

from optparse import OptionParser
from optparse import Option, OptionValueError
import os
import mini_parser
import policy
from policy import MatchPathPrefix
import re
import sys

DEBUG=False
SHARED_LIB_EXTENSION = '.dylib' if sys.platform == 'darwin' else '.so'

'''
Use file_contexts and policy to verify Treble requirements
are not violated.
'''
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

def PrintScontexts():
    for d in sorted(alldomains.keys()):
        sctx = alldomains[d]
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

alldomains = {}
coredomains = set()
appdomains = set()
vendordomains = set()
pol = None

# compat vars
alltypes = set()
oldalltypes = set()
compatMapping = None
pubtypes = set()

# Distinguish between PRODUCT_FULL_TREBLE and PRODUCT_FULL_TREBLE_OVERRIDE
FakeTreble = False

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
        domain = alldomains[d]
        # TestCoredomainViolations will verify if coredomain was incorrectly
        # applied.
        if "coredomain" in domain.attributes:
            domain.coredomain = True
            coredomains.add(d)
        # check whether domains are executed off of /system or /vendor
        if d in coredomainAllowlist:
            continue
        # TODO(b/153112003): add checks to prevent app domains from being
        # incorrectly labeled as coredomain. Apps don't have entrypoints as
        # they're always dynamically transitioned to by zygote.
        if d in appdomains:
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
def GetDomainEntrypoints(pol):
    global alldomains
    for x in pol.QueryExpandedTERule(tclass=set(["file"]), perms=set(["entrypoint"])):
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
def compatSetup(pol, oldpol, mapping, types):
    global compatMapping
    global pubtypes

    GetAllTypes(pol, oldpol)
    compatMapping = mapping
    pubtypes = types

def DomainsWithAttribute(attr):
    global alldomains
    domains = []
    for domain in alldomains:
        if attr in alldomains[domain].attributes:
            domains.append(domain)
    return domains

#############################################################
# Tests
#############################################################
def TestCoredomainViolations():
    global alldomains
    # verify that all domains launched from /system have the coredomain
    # attribute
    ret = ""

    for d in alldomains:
        domain = alldomains[d]
        if domain.fromSystem and domain.fromVendor:
            ret += "The following domain is system and vendor: " + d + "\n"

    for domain in alldomains.values():
        ret += domain.error

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
# Make sure that any new public type introduced in the new policy that was not
# present in the old policy has been recorded in the mapping file.
def TestNoUnmappedNewTypes():
    global alltypes
    global oldalltypes
    global compatMapping
    global pubtypes
    newt = alltypes - oldalltypes
    ret = ""
    violators = []

    for n in newt:
        if n in pubtypes and compatMapping.rTypeattributesets.get(n) is None:
            violators.append(n)

    if len(violators) > 0:
        ret += "SELinux: The following public types were found added to the "
        ret += "policy without an entry into the compatibility mapping file(s) "
        ret += "found in private/compat/V.v/V.v[.ignore].cil, where V.v is the "
        ret += "latest API level.\n"
        ret += " ".join(str(x) for x in sorted(violators)) + "\n\n"
        ret += "See examples of how to fix this:\n"
        ret += "https://android-review.googlesource.com/c/platform/system/sepolicy/+/781036\n"
        ret += "https://android-review.googlesource.com/c/platform/system/sepolicy/+/852612\n"
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
        ret += "found in private/compat/V.v/V.v[.ignore].cil, where V.v is the "
        ret += "latest API level.\n"
        ret += " ".join(str(x) for x in sorted(violators)) + "\n\n"
        ret += "See examples of how to fix this:\n"
        ret += "https://android-review.googlesource.com/c/platform/system/sepolicy/+/822743\n"
    return ret

def TestTrebleCompatMapping():
    ret = TestNoUnmappedNewTypes()
    ret += TestNoUnmappedRmTypes()
    return ret

def TestViolatorAttribute(attribute):
    global FakeTreble
    ret = ""
    if FakeTreble:
        return ret

    violators = DomainsWithAttribute(attribute)
    if len(violators) > 0:
        ret += "SELinux: The following domains violate the Treble ban "
        ret += "against use of the " + attribute + " attribute: "
        ret += " ".join(str(x) for x in sorted(violators)) + "\n"
    return ret

def TestViolatorAttributes():
    ret = ""
    ret += TestViolatorAttribute("socket_between_core_and_vendor_violators")
    ret += TestViolatorAttribute("vendor_executes_system_violators")
    return ret

# TODO move this to sepolicy_tests
def TestCoreDataTypeViolations():
    global pol
    return pol.AssertPathTypesDoNotHaveAttr(["/data/vendor/", "/data/vendor_ce/",
        "/data/vendor_de/"], [], "core_data_file_type")

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
         "CoreDatatypeViolations": TestCoreDataTypeViolations,
         "TrebleCompatMapping": TestTrebleCompatMapping,
         "ViolatorAttributes": TestViolatorAttributes}

if __name__ == '__main__':
    usage = "treble_sepolicy_tests "
    usage += "-f nonplat_file_contexts -f plat_file_contexts "
    usage += "-p curr_policy -b base_policy -o old_policy "
    usage +="-m mapping file [--test test] [--help]"
    parser = OptionParser(option_class=MultipleOption, usage=usage)
    parser.add_option("-b", "--basepolicy", dest="basepolicy", metavar="FILE")
    parser.add_option("-u", "--base-pub-policy", dest="base_pub_policy",
                      metavar="FILE")
    parser.add_option("-f", "--file_contexts", dest="file_contexts",
            metavar="FILE", action="extend", type="string")
    parser.add_option("-m", "--mapping", dest="mapping", metavar="FILE")
    parser.add_option("-o", "--oldpolicy", dest="oldpolicy", metavar="FILE")
    parser.add_option("-p", "--policy", dest="policy", metavar="FILE")
    parser.add_option("-t", "--test", dest="tests", action="extend",
            help="Test options include "+str(Tests))
    parser.add_option("--fake-treble", action="store_true", dest="faketreble",
            default=False)

    (options, args) = parser.parse_args()

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

    libpath = os.path.join(os.path.dirname(os.path.realpath(__file__)),
                           "libsepolwrap" + SHARED_LIB_EXTENSION)
    if not os.path.exists(libpath):
        sys.exit("Error: libsepolwrap does not exist. Is this binary corrupted?\n")

    # Mapping files and public platform policy are only necessary for the
    # TrebleCompatMapping test.
    if options.tests is None or options.tests == "TrebleCompatMapping":
        if not options.basepolicy:
            sys.exit("Must specify the current platform-only policy file\n"
                     + parser.usage)
        if not options.mapping:
            sys.exit("Must specify a compatibility mapping file\n"
                     + parser.usage)
        if not options.oldpolicy:
            sys.exit("Must specify the previous monolithic policy file\n"
                     + parser.usage)
        if not options.base_pub_policy:
            sys.exit("Must specify the current platform-only public policy "
                     + ".cil file\n" + parser.usage)
        basepol = policy.Policy(options.basepolicy, None, libpath)
        oldpol = policy.Policy(options.oldpolicy, None, libpath)
        mapping = mini_parser.MiniCilParser(options.mapping)
        pubpol = mini_parser.MiniCilParser(options.base_pub_policy)
        compatSetup(basepol, oldpol, mapping, pubpol.types)

    if options.faketreble:
        FakeTreble = True

    pol = policy.Policy(options.policy, options.file_contexts, libpath)
    setup(pol)

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
