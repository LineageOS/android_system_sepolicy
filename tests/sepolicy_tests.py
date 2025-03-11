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

import argparse
import os
import sys
import tempfile
import policy

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
        # adb_keys_file hasn't been a system_file_type
        "/product/etc/security/adb_keys",
        "/system/product/etc/security/adb_keys",
    ]

    return pol.AssertPathTypesHaveAttr(
        partitions, exceptions, "system_file_type"
    )


def TestBpffsTypeViolations(pol):
    return pol.AssertGenfsFilesystemTypesHaveAttr("bpf", "bpffs_type")


def TestProcTypeViolations(pol):
    return pol.AssertGenfsFilesystemTypesHaveAttr("proc", "proc_type")


def TestSysfsTypeViolations(pol):
    ret = pol.AssertGenfsFilesystemTypesHaveAttr("sysfs", "sysfs_type")
    ret += pol.AssertPathTypesHaveAttr(
        ["/sys/"], ["/sys/kernel/debug/", "/sys/kernel/tracing"], "sysfs_type"
    )
    return ret


def TestDebugfsTypeViolations(pol):
    ret = pol.AssertGenfsFilesystemTypesHaveAttr("debugfs", "debugfs_type")
    ret += pol.AssertPathTypesHaveAttr(
        ["/sys/kernel/debug/", "/sys/kernel/tracing"], [], "debugfs_type"
    )
    return ret


def TestTracefsTypeViolations(pol):
    ret = pol.AssertGenfsFilesystemTypesHaveAttr("tracefs", "tracefs_type")
    ret += pol.AssertPathTypesHaveAttr(
        ["/sys/kernel/tracing"], [], "tracefs_type"
    )
    ret += pol.AssertPathTypesDoNotHaveAttr(
        ["/sys/kernel/debug"], ["/sys/kernel/debug/tracing"], "tracefs_type", []
    )
    return ret


def TestVendorTypeViolations(pol):
    partitions = ["/vendor/", "/odm/"]
    exceptions = [
        "/vendor/etc/selinux/",
        "/vendor/odm/etc/selinux/",
        "/odm/etc/selinux/",
    ]
    return pol.AssertPathTypesHaveAttr(
        partitions, exceptions, "vendor_file_type"
    )


def TestCoreDataTypeViolations(pol):
    ret = pol.AssertPathTypesHaveAttr(
        ["/data/"],
        ["/data/vendor", "/data/vendor_ce", "/data/vendor_de"],
        "core_data_file_type",
    )
    ret += pol.AssertPathTypesDoNotHaveAttr(
        ["/data/vendor/", "/data/vendor_ce/", "/data/vendor_de/"],
        [],
        "core_data_file_type",
    )
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
    return pol.AssertPathTypesDoNotHaveAttr(
        partitions, [], "app_data_file_type", exceptions
    )


def TestDmaHeapDevTypeViolations(pol):
    return pol.AssertPathTypesHaveAttr(
        ["/dev/dma_heap/"], [], "dmabuf_heap_device_type"
    )


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
            violators.append(d)
    if len(violators) > 0:
        ret += "The following domain(s) must be associated with the "
        ret += '"coredomain" attribute because they are executed off of '
        ret += "/system:\n"
        ret += " ".join(str(x) for x in sorted(violators)) + "\n"

    # verify that all domains launched from /vendor do not have the coredomain
    # attribute
    violators = []
    for d in test_policy.alldomains:
        domain = test_policy.alldomains[d]
        if domain.fromVendor and "coredomain" in domain.attributes:
            violators.append(d)
    if len(violators) > 0:
        ret += "The following domains must not be associated with the "
        ret += '"coredomain" attribute because they are executed off of '
        ret += "/vendor or /system/vendor:\n"
        ret += " ".join(str(x) for x in sorted(violators)) + "\n"

    return ret


def TestViolatorAttribute(_test_policy, _attribute):
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
    ret += TestViolatorAttribute(
        test_policy, "socket_between_core_and_vendor_violators"
    )
    ret += TestViolatorAttribute(
        test_policy, "vendor_executes_system_violators"
    )
    return ret


def TestIsolatedComputeAllowedPropertySubset(test_policy):
    # Properties granted for isolated_compute_allowed should also be readable
    # by `untrusted_app`
    ret = ""

    # Check if the attribute exists in the policy (it might be empty/unused)
    allAttributes = test_policy.pol.GetAllTypes(isAttr=True)
    if "isolated_compute_allowed_property_type" not in allAttributes:
        return ret

    # Permission granted for `get_prop`
    allowedPerms = {"getattr", "open", "read", "map"}

    violatingTypes = []
    for typeName in test_policy.pol.QueryTypeAttribute(
            Type="isolated_compute_allowed_property_type", IsAttr=True):

        grantedPerms = set()
        for rule in test_policy.pol.QueryExpandedTERule(
            scontext={"untrusted_app"},
            tcontext={typeName},
            tclass={"file"},
        ):
            grantedPerms.update(rule.perms)

        missingPerms = allowedPerms.difference(grantedPerms)
        if missingPerms:
            violatingTypes.append(
                f"{typeName} (missing: {', '.join(missingPerms)})")

    if violatingTypes:
        ret += "The following property types are in "
        ret += "'isolated_compute_allowed_property_type' but are NOT readable "
        ret += "by 'untrusted_app'.\n"
        ret += "To ensure safety, only properties accessible to untrusted "
        ret += "apps should be exposed to isolated_compute_app.\n"
        ret += "Violators:\n"
        ret += "\n".join(violatingTypes) + "\n"

    return ret


def TestIsolatedAttributeConsistency(test_policy):
    permissionAllowList = {
        # access given from technical_debt.cil
        "codec2_config_prop": ["file"],
        "device_config_nnapi_native_prop": ["file"],
        "gpu_device": ["dir"],
        "hal_allocator_default": ["binder", "fd", "memfd_file"],
        "hal_codec2": ["binder", "fd", "memfd_file"],
        "hal_codec2_hwservice": ["hwservice_manager"],
        "hal_graphics_allocator": ["binder", "fd"],
        "hal_graphics_allocator_service": ["service_manager"],
        "hal_graphics_allocator_hwservice": ["hwservice_manager"],
        "hal_graphics_allocator_server": ["binder", "service_manager"],
        "hal_graphics_mapper_hwservice": ["hwservice_manager"],
        "hal_graphics_mapper_service": ["service_manager"],
        "hal_neuralnetworks": ["binder", "fd"],
        "hal_neuralnetworks_service": ["service_manager"],
        "hal_neuralnetworks_hwservice": ["hwservice_manager"],
        "hal_omx_hwservice": ["hwservice_manager"],
        "hidl_allocator_hwservice": ["hwservice_manager"],
        "hidl_manager_hwservice": ["hwservice_manager"],
        "hidl_memory_hwservice": ["hwservice_manager"],
        "hidl_token_hwservice": ["hwservice_manager"],
        "hwservicemanager": ["binder"],
        "hwservicemanager_prop": ["file"],
        "mediacodec": ["binder", "fd"],
        "mediaswcodec": ["binder", "fd"],
        "media_variant_prop": ["file"],
        "nnapi_ext_deny_product_prop": ["file"],
        "servicemanager": ["fd"],
        "sysfs_gpu": ["dir", "file", "lnk_file"],
        "toolbox_exec": ["file"],
        "vendor_sysfs_public": ["file", "dir", "lnk_file"],
        "vendor_sysfs_soc": ["dir"],
        "vendor_hal_dspmanager": ["binder", "fd"],
        "vendor_dspservice": ["binder", "fd"],
        "isolated_compute_allowed": ["service_manager", "chr_file", "file", "dir", "lnk_file", "fd", "binder"],
    }

    def resolveHalServerSubtype(target):
        # permission given as a client in technical_debt.cil
        hal_server_attributes = [
            "hal_codec2_server",
            "hal_graphics_allocator_server",
            "hal_neuralnetworks_server",
        ]

        for attr in hal_server_attributes:
            if target in test_policy.pol.QueryTypeAttribute(
                Type=attr, IsAttr=True
            ):
                return attr.rsplit("_", 1)[0]
        return target

    def checkIsolatedComputeAllowed(tctx, tclass):
        # check if the permission is in isolated_compute_allowed
        allowedAttributes = [
            "isolated_compute_allowed_service",
            "isolated_compute_allowed_device",
            "isolated_compute_allowed_property_type",
        ]

        allowedMemberTypes = set()
        for attribute in allowedAttributes:
            allowedMemberTypes.update(
                test_policy.pol.QueryTypeAttribute(
                    Type=attribute, IsAttr=True,
                    IgnoreMissing=True,
                )
            )
        return (
            tctx in allowedMemberTypes
            and tclass in permissionAllowList["isolated_compute_allowed"]
        )

    def checkPermissions(permissions):
        violated_permissions = []
        for perm in permissions:
            tctx, tclass, p = perm.split(":")
            tctx = resolveHalServerSubtype(tctx)
            # check unwanted permissions
            if not checkIsolatedComputeAllowed(tctx, tclass) and (
                tctx not in permissionAllowList
                or tclass not in permissionAllowList[tctx]
                or (p == "write" and tclass != "memfd_file")
                or (p == "rw_file_perms")
            ):
                violated_permissions += [perm]
        return violated_permissions

    ret = ""

    isolatedMemberTypes = test_policy.pol.QueryTypeAttribute(
        Type="isolated_app_all", IsAttr=True
    )
    baseRules = test_policy.pol.QueryExpandedTERule(scontext=["isolated_app"])
    basePermissionSet = {
        ":".join([rule.tctx, rule.tclass, perm])
        for rule in baseRules
        for perm in rule.perms
    }
    for subType in isolatedMemberTypes:
        if subType == "isolated_app":
            continue
        currentTypeRule = test_policy.pol.QueryExpandedTERule(
            scontext=[subType]
        )
        typePermissionSet = {
            ":".join([rule.tctx, rule.tclass, perm])
            for rule in currentTypeRule
            for perm in rule.perms
            if rule.tctx not in [subType, subType + "_userfaultfd"]
        }
        deltaPermissionSet = typePermissionSet.difference(basePermissionSet)
        violated_permissions = checkPermissions(list(deltaPermissionSet))
        for perm in violated_permissions:
            tctx, tclass, p = perm.split(":")
            ret += f"allow {subType} {tctx}:{tclass} {p} \n"

    if ret:
        ret = (
            "Found prohibited permission granted for isolated like types. "
            + "Please replace your allow statements that involve"
            ' "-isolated_app"'
            " with "
            + '"-isolated_app_all". Violations are shown as the following: \n'
        ) + ret
    return ret


def TestDevTypeViolations(pol):
    exceptions = [
        "/dev/socket",
    ]
    exceptionTypes = [
        "boringssl_self_test_marker",  # /dev/boringssl/selftest
        "cgroup_rc_file",  # /dev/cgroup.rc
        "dev_cpu_variant",  # /dev/cpu_variant:{arch}
        "fscklogs",  # /dev/fscklogs
        "properties_serial",  # /dev/__properties__/properties_serial
        "property_info",  # /dev/__properties__/property_info
        "runtime_event_log_tags_file",  # /dev/event-log-tags
    ]
    return pol.AssertPathTypesHaveAttr(
        ["/dev"], exceptions, "dev_type", exceptionTypes
    )


TEST_NAMES = [name for name in dir() if name.startswith("Test")]


def do_main(libpath):
    """Args:

    libpath: string, path to libsepolwrap.so
    """
    parser = argparse.ArgumentParser(description="Run sepolicy tests.")
    parser.add_argument(
        "-f",
        "--file_contexts",
        dest="file_contexts",
        metavar="FILE",
        action="append",
        help="file_contexts file",
    )
    parser.add_argument(
        "-p",
        "--policy",
        dest="policy",
        metavar="FILE",
        help="monolithic policy file",
    )
    parser.add_argument(
        "-t",
        "--test",
        dest="test",
        action="append",
        help="Test options include " + str(TEST_NAMES),
    )

    options = parser.parse_args()

    if not options.policy:
        sys.exit("Must specify monolithic policy file\n" + parser.format_help())
    if not os.path.exists(options.policy):
        sys.exit(
            "Error: policy file "
            + options.policy
            + " does not exist\n"
            + parser.format_help()
        )

    if not options.file_contexts:
        sys.exit(
            "Error: Must specify file_contexts file(s)\n" + parser.format_help()
        )
    for file_contexts in options.file_contexts:
        if not os.path.exists(file_contexts):
            sys.exit(
                "Error: File_contexts file "
                + file_contexts
                + " does not exist\n"
                + parser.format_help()
            )

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
    if (
        options.test is None
        or "TestIsolatedAttributeConsistency" in options.test
    ):
        results += TestIsolatedAttributeConsistency(test_policy)
    if (
        options.test is None
        or "TestIsolatedComputeAllowedPropertySubset" in options.test
    ):
        results += TestIsolatedComputeAllowedPropertySubset(test_policy)

    # dev type test won't be run as default
    if options.test and "TestDevTypeViolations" in options.test:
        results += TestDevTypeViolations(pol)

    if len(results) > 0:
        sys.exit(results)


if __name__ == "__main__":
    with tempfile.TemporaryDirectory(ignore_cleanup_errors=True) as temp_dir:
        lib_path = policy.ReadLibsepolwrap(temp_dir)
        do_main(lib_path)
