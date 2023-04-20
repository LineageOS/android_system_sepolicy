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
import pkgutil
import policy
from policy import MatchPathPrefix
import re
import shutil
import sys
import tempfile

DEBUG=False
SHARED_LIB_EXTENSION = '.dylib' if sys.platform == 'darwin' else '.so'

# TODO(b/266998144): consider rename this file.

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

        # Distinguish between PRODUCT_FULL_TREBLE and PRODUCT_FULL_TREBLE_OVERRIDE
        self.FakeTreble = False

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


#############################################################
# Tests
#############################################################
def TestCoredomainViolations(test_policy):
    # verify that all domains launched from /system have the coredomain
    # attribute
    ret = ""

    for d in test_policy.alldomains:
        domain = test_policy.alldomains[d]
        if domain.fromSystem and domain.fromVendor:
            ret += "The following domain is system and vendor: " + d + "\n"

    for domain in test_policy.alldomains.values():
        ret += domain.error

    violators = []
    for d in test_policy.alldomains:
        domain = test_policy.alldomains[d]
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
    for d in test_policy.alldomains:
        domain = test_policy.alldomains[d]
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
def TestNoUnmappedNewTypes(test_policy):
    newt = test_policy.alltypes - test_policy.oldalltypes
    ret = ""
    violators = []

    for n in newt:
        if n in test_policy.pubtypes and test_policy.compatMapping.rTypeattributesets.get(n) is None:
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
def TestNoUnmappedRmTypes(test_policy):
    rmt = test_policy.oldalltypes - test_policy.alltypes
    ret = ""
    violators = []

    for o in rmt:
        if o in test_policy.compatMapping.pubtypes and not o in test_policy.compatMapping.types:
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

def TestTrebleCompatMapping(test_policy):
    ret = TestNoUnmappedNewTypes(test_policy)
    ret += TestNoUnmappedRmTypes(test_policy)
    return ret

def TestViolatorAttribute(test_policy, attribute):
    ret = ""
    if test_policy.FakeTreble:
        return ret

    violators = test_policy.DomainsWithAttribute(attribute)
    if len(violators) > 0:
        ret += "SELinux: The following domains violate the Treble ban "
        ret += "against use of the " + attribute + " attribute: "
        ret += " ".join(str(x) for x in sorted(violators)) + "\n"
    return ret

def TestViolatorAttributes(test_policy):
    ret = ""
    ret += TestViolatorAttribute(test_policy, "socket_between_core_and_vendor_violators")
    ret += TestViolatorAttribute(test_policy, "vendor_executes_system_violators")
    return ret

# TODO move this to sepolicy_tests
def TestCoreDataTypeViolations(test_policy):
    return test_policy.pol.AssertPathTypesDoNotHaveAttr(["/data/vendor/", "/data/vendor_ce/",
        "/data/vendor_de/"], [], "core_data_file_type")

# TODO move this to sepolicy_tests
def TestIsolatedAttributeConsistency(test_policy):
  permissionAllowList = {
      # access given from technical_debt.cil
      "codec2_config_prop" : ["file"],
      "device_config_nnapi_native_prop":["file"],
      "hal_allocator_default":["binder", "fd"],
      "hal_codec2": ["binder", "fd"],
      "hal_codec2_hwservice":["hwservice_manager"],
      "hal_graphics_allocator": ["binder", "fd"],
      "hal_graphics_allocator_service":["service_manager"],
      "hal_graphics_allocator_hwservice":["hwservice_manager"],
      "hal_graphics_allocator_server":["binder", "service_manager"],
      "hal_graphics_mapper_hwservice":["hwservice_manager"],
      "hal_neuralnetworks": ["binder", "fd"],
      "hal_neuralnetworks_service": ["service_manager"],
      "hal_neuralnetworks_hwservice":["hwservice_manager"],
      "hal_omx_hwservice":["hwservice_manager"],
      "hidl_allocator_hwservice":["hwservice_manager"],
      "hidl_manager_hwservice":["hwservice_manager"],
      "hidl_memory_hwservice":["hwservice_manager"],
      "hidl_token_hwservice":["hwservice_manager"],
      "hwservicemanager":["binder"],
      "hwservicemanager_prop":["file"],
      "mediacodec":["binder", "fd"],
      "mediaswcodec":["binder", "fd"],
      "media_variant_prop":["file"],
      "nnapi_ext_deny_product_prop":["file"],
      "servicemanager":["fd"],
      "toolbox_exec": ["file"],
      # extra types being granted to isolated_compute_app
      "isolated_compute_allowed":["service_manager", "chr_file"],
  }

  def resolveHalServerSubtype(target):
   # permission given as a client in technical_debt.cil
    hal_server_attributes = [
       "hal_codec2_server",
       "hal_graphics_allocator_server",
       "hal_neuralnetworks_server"]

    for attr in hal_server_attributes:
      if target in test_policy.pol.QueryTypeAttribute(Type=attr, IsAttr=True):
        return attr.rsplit("_", 1)[0]
    return target

  def checkIsolatedComputeAllowed(tctx, tclass):
    # check if the permission is in isolated_compute_allowed
    allowedMemberTypes = test_policy.pol.QueryTypeAttribute(Type="isolated_compute_allowed_service", IsAttr=True) \
      .union(test_policy.pol.QueryTypeAttribute(Type="isolated_compute_allowed_device", IsAttr=True))
    return tctx in allowedMemberTypes and tclass in permissionAllowList["isolated_compute_allowed"]


  def checkPermissions(permissions):
    violated_permissions = []
    for perm in permissions:
      tctx, tclass, p = perm.split(":")
      tctx = resolveHalServerSubtype(tctx)
      # check unwanted permissions
      if not checkIsolatedComputeAllowed(tctx, tclass) and \
        ( tctx not in permissionAllowList \
          or tclass not in permissionAllowList[tctx] \
          or ( p == "write") \
          or ( p == "rw_file_perms") ):
        violated_permissions += [perm]
    return violated_permissions

  ret = ""

  isolatedMemberTypes = test_policy.pol.QueryTypeAttribute(Type="isolated_app_all", IsAttr=True)
  baseRules = test_policy.pol.QueryExpandedTERule(scontext=["isolated_app"])
  basePermissionSet = set([":".join([rule.tctx, rule.tclass, perm])
                        for rule in baseRules for perm in rule.perms])
  for subType in isolatedMemberTypes:
      if subType == "isolated_app" : continue
      currentTypeRule = test_policy.pol.QueryExpandedTERule(scontext=[subType])
      typePermissionSet = set([":".join([rule.tctx, rule.tclass, perm])
                            for rule in currentTypeRule for perm in rule.perms
                            if not rule.tctx in [subType, subType + "_userfaultfd"]])
      deltaPermissionSet = typePermissionSet.difference(basePermissionSet)
      violated_permissions = checkPermissions(list(deltaPermissionSet))
      for perm in violated_permissions:
        ret += "allow %s %s:%s %s \n" % (subType, *perm.split(":"))

  if ret:
      ret = ("Found prohibited permission granted for isolated like types. " + \
         "Please replace your allow statements that involve \"-isolated_app\" with " + \
         "\"-isolated_app_all\". Violations are shown as the following: \n")  + ret
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
         "CoreDatatypeViolations": TestCoreDataTypeViolations,
         "TrebleCompatMapping": TestTrebleCompatMapping,
         "ViolatorAttributes": TestViolatorAttributes,
         "IsolatedAttributeConsistency": TestIsolatedAttributeConsistency}

def do_main(libpath):
    """
    Args:
        libpath: string, path to libsepolwrap.so
    """
    test_policy = TestPolicy()

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
        test_policy.compatSetup(basepol, oldpol, mapping, pubpol.types)

    if options.faketreble:
        test_policy.FakeTreble = True

    pol = policy.Policy(options.policy, options.file_contexts, libpath)
    test_policy.setup(pol)

    if DEBUG:
        test_policy.PrintScontexts()

    results = ""
    # If an individual test is not specified, run all tests.
    if options.tests is None:
        for t in Tests.values():
            results += t(test_policy)
    else:
        for tn in options.tests:
            t = Tests.get(tn)
            if t:
                results += t(test_policy)
            else:
                err = "Error: unknown test: " + tn + "\n"
                err += "Available tests:\n"
                for tn in Tests.keys():
                    err += tn + "\n"
                sys.exit(err)

    if len(results) > 0:
        sys.exit(results)

if __name__ == '__main__':
    temp_dir = tempfile.mkdtemp()
    try:
        libname = "libsepolwrap" + SHARED_LIB_EXTENSION
        libpath = os.path.join(temp_dir, libname)
        with open(libpath, "wb") as f:
            blob = pkgutil.get_data("treble_sepolicy_tests", libname)
            if not blob:
                sys.exit("Error: libsepolwrap does not exist. Is this binary corrupted?\n")
            f.write(blob)
        do_main(libpath)
    finally:
        shutil.rmtree(temp_dir)
