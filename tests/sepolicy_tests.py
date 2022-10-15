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
import policy
import re
import sys

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
    return pol.AssertPathTypesHaveAttr(["/data/"], ["/data/vendor",
            "/data/vendor_ce", "/data/vendor_de"], "core_data_file_type")

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
]

if __name__ == '__main__':
    usage = "sepolicy_tests -f vendor_file_contexts -f "
    usage +="plat_file_contexts -p policy [--test test] [--help]"
    parser = OptionParser(option_class=MultipleOption, usage=usage)
    parser.add_option("-f", "--file_contexts", dest="file_contexts",
            metavar="FILE", action="extend", type="string")
    parser.add_option("-p", "--policy", dest="policy", metavar="FILE")
    parser.add_option("-t", "--test", dest="test", action="extend",
            help="Test options include "+str(Tests))

    (options, args) = parser.parse_args()

    libpath = os.path.join(os.path.dirname(os.path.realpath(__file__)),
                           "libsepolwrap" + SHARED_LIB_EXTENSION)
    if not os.path.exists(libpath):
        sys.exit("Error: libsepolwrap does not exist. Is this binary corrupted?\n")

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

    if len(results) > 0:
        sys.exit(results)
