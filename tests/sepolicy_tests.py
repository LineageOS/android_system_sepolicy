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
import pkgutil
import policy
import re
import shutil
import sys
import tempfile

SHARED_LIB_EXTENSION = '.dylib' if sys.platform == 'darwin' else '.so'

#############################################################
# Tests
#############################################################
def TestDataTypeViolations(pol):
    return pol.AssertPathTypesHaveAttr(["/data/"], [], "data_file_type")

def TestSystemTypeViolations(pol):
    partitions = ["/system/", "/system_ext/", "/product/"]
    exceptions = [
        # devices before treble don't have a vendor partition
        "/system/vendor/",

        # overlay files are mounted over vendor
        "/product/overlay/",
        "/product/vendor_overlay/",
        "/system/overlay/",
        "/system/product/overlay/",
        "/system/product/vendor_overlay/",
        "/system/system_ext/overlay/",
        "/system_ext/overlay/",
    ]

    return pol.AssertPathTypesHaveAttr(partitions, exceptions, "system_file_type")

def TestBpffsTypeViolations(pol):
    return pol.AssertGenfsFilesystemTypesHaveAttr("bpf", "bpffs_type")

def TestProcTypeViolations(pol):
    return pol.AssertGenfsFilesystemTypesHaveAttr("proc", "proc_type")

def TestSysfsTypeViolations(pol):
    ret = pol.AssertGenfsFilesystemTypesHaveAttr("sysfs", "sysfs_type")
    ret += pol.AssertPathTypesHaveAttr(["/sys/"], ["/sys/kernel/debug/",
                                    "/sys/kernel/tracing"], "sysfs_type")
    return ret

def TestDebugfsTypeViolations(pol):
    ret = pol.AssertGenfsFilesystemTypesHaveAttr("debugfs", "debugfs_type")
    ret += pol.AssertPathTypesHaveAttr(["/sys/kernel/debug/",
                                    "/sys/kernel/tracing"], [], "debugfs_type")
    return ret

def TestTracefsTypeViolations(pol):
    ret = pol.AssertGenfsFilesystemTypesHaveAttr("tracefs", "tracefs_type")
    ret += pol.AssertPathTypesHaveAttr(["/sys/kernel/tracing"], [], "tracefs_type")
    ret += pol.AssertPathTypesDoNotHaveAttr(["/sys/kernel/debug"],
                                            ["/sys/kernel/debug/tracing"], "tracefs_type",
                                            [])
    return ret

def TestVendorTypeViolations(pol):
    partitions = ["/vendor/", "/odm/"]
    exceptions = [
        "/vendor/etc/selinux/",
        "/vendor/odm/etc/selinux/",
        "/odm/etc/selinux/",
    ]
    return pol.AssertPathTypesHaveAttr(partitions, exceptions, "vendor_file_type")

def TestCoreDataTypeViolations(pol):
    ret = pol.AssertPathTypesHaveAttr(["/data/"], ["/data/vendor",
            "/data/vendor_ce", "/data/vendor_de"], "core_data_file_type")
    ret += pol.AssertPathTypesDoNotHaveAttr(["/data/vendor/", "/data/vendor_ce/",
        "/data/vendor_de/"], [], "core_data_file_type")
    return ret

def TestPropertyTypeViolations(pol):
    return pol.AssertPropertyOwnersAreExclusive()

def TestAppDataTypeViolations(pol):
    # Types with the app_data_file_type should only be used for app data files
    # (/data/data/package.name etc) via seapp_contexts, and never applied
    # explicitly to other files.
    partitions = [
        "/data/",
        "/vendor/",
        "/odm/",
        "/product/",
    ]
    exceptions = [
        # These are used for app data files for the corresponding user and
        # assorted other files.
        # TODO(b/172812577): Use different types for the different purposes
        "shell_data_file",
        "bluetooth_data_file",
        "nfc_data_file",
        "radio_data_file",
    ]
    return pol.AssertPathTypesDoNotHaveAttr(partitions, [], "app_data_file_type",
                                            exceptions)
def TestDmaHeapDevTypeViolations(pol):
    return pol.AssertPathTypesHaveAttr(["/dev/dma_heap/"], [],
                                       "dmabuf_heap_device_type")

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

def TestViolatorAttribute(test_policy, attribute):
    # TODO(b/113124961): re-enable once all violator attributes are removed.
    return ""

    # ret = ""
    # return ret

    # violators = test_policy.DomainsWithAttribute(attribute)
    # if len(violators) > 0:
    #    ret += "SELinux: The following domains violate the Treble ban "
    #    ret += "against use of the " + attribute + " attribute: "
    #    ret += " ".join(str(x) for x in sorted(violators)) + "\n"
    # return ret

def TestViolatorAttributes(test_policy):
    ret = ""
    ret += TestViolatorAttribute(test_policy, "socket_between_core_and_vendor_violators")
    ret += TestViolatorAttribute(test_policy, "vendor_executes_system_violators")
    return ret

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
        "hal_graphics_mapper_service":["service_manager"],
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

def TestDevTypeViolations(pol):
    exceptions = [
        "/dev/socket",
    ]
    exceptionTypes = [
        "boringssl_self_test_marker",  # /dev/boringssl/selftest
        "cgroup_rc_file",              # /dev/cgroup.rc
        "dev_cpu_variant",             # /dev/cpu_variant:{arch}
        "fscklogs",                    # /dev/fscklogs
        "properties_serial",           # /dev/__properties__/properties_serial
        "property_info",               # /dev/__properties__/property_info
        "runtime_event_log_tags_file", # /dev/event-log-tags
    ]
    return pol.AssertPathTypesHaveAttr(["/dev"], exceptions,
                                       "dev_type", exceptionTypes)

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

Tests = [
    "TestBpffsTypeViolations",
    "TestDataTypeViolators",
    "TestProcTypeViolations",
    "TestSysfsTypeViolations",
    "TestSystemTypeViolators",
    "TestDebugfsTypeViolations",
    "TestTracefsTypeViolations",
    "TestVendorTypeViolations",
    "TestCoreDataTypeViolations",
    "TestPropertyTypeViolations",
    "TestAppDataTypeViolations",
    "TestDmaHeapDevTypeViolations",
    "TestCoredomainViolations",
    "TestViolatorAttributes",
    "TestIsolatedAttributeConsistency",
    "TestDevTypeViolations",
]

def do_main(libpath):
    """
    Args:
        libpath: string, path to libsepolwrap.so
    """
    usage = "sepolicy_tests -f vendor_file_contexts -f "
    usage +="plat_file_contexts -p policy [--test test] [--help]"
    parser = OptionParser(option_class=MultipleOption, usage=usage)
    parser.add_option("-f", "--file_contexts", dest="file_contexts",
            metavar="FILE", action="extend", type="string")
    parser.add_option("-p", "--policy", dest="policy", metavar="FILE")
    parser.add_option("-t", "--test", dest="test", action="extend",
            help="Test options include "+str(Tests))

    (options, args) = parser.parse_args()

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

    pol = policy.Policy(options.policy, options.file_contexts, libpath)
    test_policy = policy.TestPolicy()
    test_policy.setup(pol)

    results = ""
    # If an individual test is not specified, run all tests.
    if options.test is None or "TestBpffsTypeViolations" in options.test:
        results += TestBpffsTypeViolations(pol)
    if options.test is None or "TestDataTypeViolations" in options.test:
        results += TestDataTypeViolations(pol)
    if options.test is None or "TestProcTypeViolations" in options.test:
        results += TestProcTypeViolations(pol)
    if options.test is None or "TestSysfsTypeViolations" in options.test:
        results += TestSysfsTypeViolations(pol)
    if options.test is None or "TestSystemTypeViolations" in options.test:
        results += TestSystemTypeViolations(pol)
    if options.test is None or "TestDebugfsTypeViolations" in options.test:
        results += TestDebugfsTypeViolations(pol)
    if options.test is None or "TestTracefsTypeViolations" in options.test:
        results += TestTracefsTypeViolations(pol)
    if options.test is None or "TestVendorTypeViolations" in options.test:
        results += TestVendorTypeViolations(pol)
    if options.test is None or "TestCoreDataTypeViolations" in options.test:
        results += TestCoreDataTypeViolations(pol)
    if options.test is None or "TestPropertyTypeViolations" in options.test:
        results += TestPropertyTypeViolations(pol)
    if options.test is None or "TestAppDataTypeViolations" in options.test:
        results += TestAppDataTypeViolations(pol)
    if options.test is None or "TestDmaHeapDevTypeViolations" in options.test:
        results += TestDmaHeapDevTypeViolations(pol)
    if options.test is None or "TestCoredomainViolations" in options.test:
        results += TestCoredomainViolations(test_policy)
    if options.test is None or "TestViolatorAttributes" in options.test:
        results += TestViolatorAttributes(test_policy)
    if options.test is None or "TestIsolatedAttributeConsistency" in options.test:
        results += TestIsolatedAttributeConsistency(test_policy)

    # dev type test won't be run as default
    if options.test and "TestDevTypeViolations" in options.test:
        results += TestDevTypeViolations(pol)

    if len(results) > 0:
        sys.exit(results)

if __name__ == '__main__':
    temp_dir = tempfile.mkdtemp()
    try:
        libname = "libsepolwrap" + SHARED_LIB_EXTENSION
        libpath = os.path.join(temp_dir, libname)
        with open(libpath, "wb") as f:
            blob = pkgutil.get_data("sepolicy_tests", libname)
            if not blob:
                sys.exit("Error: libsepolwrap does not exist. Is this binary corrupted?\n")
            f.write(blob)
        do_main(libpath)
    finally:
        shutil.rmtree(temp_dir)
