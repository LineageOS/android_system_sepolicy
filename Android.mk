LOCAL_PATH:= $(call my-dir)

include $(LOCAL_PATH)/definitions.mk
include $(LOCAL_PATH)/policy_version.mk

include $(CLEAR_VARS)

MLS_SENS=1
MLS_CATS=1024

ifdef BOARD_SEPOLICY_UNION
$(warning BOARD_SEPOLICY_UNION is no longer required - all files found in BOARD_SEPOLICY_DIRS are implicitly unioned; please remove from your BoardConfig.mk or other .mk file.)
endif

ifdef BOARD_SEPOLICY_M4DEFS
LOCAL_ADDITIONAL_M4DEFS := $(addprefix -D, $(BOARD_SEPOLICY_M4DEFS))
else
LOCAL_ADDITIONAL_M4DEFS :=
endif

# sepolicy is now divided into multiple portions:
# public - policy exported on which non-platform policy developers may write
#   additional policy.  types and attributes are versioned and included in
#   delivered non-platform policy, which is to be combined with platform policy.
# private - platform-only policy required for platform functionality but which
#  is not exported to vendor policy developers and as such may not be assumed
#  to exist.
# vendor - vendor-only policy required for vendor functionality. This policy can
#  reference the public policy but cannot reference the private policy. This
#  policy is for components which are produced from the core/non-vendor tree and
#  placed into a vendor partition.
# mapping - This contains policy statements which map the attributes
#  exposed in the public policy of previous versions to the concrete types used
#  in this policy to ensure that policy targeting attributes from public
#  policy from an older platform version continues to work.

# build process for device:
# 1) convert policies to CIL:
#    - private + public platform policy to CIL
#    - mapping file to CIL (should already be in CIL form)
#    - non-platform public policy to CIL
#    - non-platform public + private policy to CIL
# 2) attributize policy
#    - run script which takes non-platform public and non-platform combined
#      private + public policy and produces attributized and versioned
#      non-platform policy
# 3) combine policy files
#    - combine mapping, platform and non-platform policy.
#    - compile output binary policy file

PLAT_PUBLIC_POLICY := $(LOCAL_PATH)/public
PLAT_PRIVATE_POLICY := $(LOCAL_PATH)/private
PLAT_VENDOR_POLICY := $(LOCAL_PATH)/vendor
REQD_MASK_POLICY := $(LOCAL_PATH)/reqd_mask

SYSTEM_EXT_PUBLIC_POLICY := $(SYSTEM_EXT_PUBLIC_SEPOLICY_DIRS)
ifneq (,$(BOARD_PLAT_PUBLIC_SEPOLICY_DIR))
  # TODO: Disallow BOARD_PLAT_*
  SYSTEM_EXT_PUBLIC_POLICY += $(BOARD_PLAT_PUBLIC_SEPOLICY_DIR)
endif
SYSTEM_EXT_PRIVATE_POLICY := $(SYSTEM_EXT_PRIVATE_SEPOLICY_DIRS)
ifneq (,$(BOARD_PLAT_PRIVATE_SEPOLICY_DIR))
  # TODO: Disallow BOARD_PLAT_*
  SYSTEM_EXT_PRIVATE_POLICY += $(BOARD_PLAT_PRIVATE_SEPOLICY_DIR)
endif

PRODUCT_PUBLIC_POLICY := $(PRODUCT_PUBLIC_SEPOLICY_DIRS)
PRODUCT_PRIVATE_POLICY := $(PRODUCT_PRIVATE_SEPOLICY_DIRS)

# Extra sepolicy and prebuilts directories for sepolicy_freeze_test
FREEZE_TEST_EXTRA_DIRS := $(SEPOLICY_FREEZE_TEST_EXTRA_DIRS)
FREEZE_TEST_EXTRA_PREBUILT_DIRS := $(SEPOLICY_FREEZE_TEST_EXTRA_PREBUILT_DIRS)

ifneq (,$(SYSTEM_EXT_PUBLIC_POLICY)$(SYSTEM_EXT_PRIVATE_POLICY))
HAS_SYSTEM_EXT_SEPOLICY_DIR := true
endif

# TODO(b/119305624): Currently if the device doesn't have a product partition,
# we install product sepolicy into /system/product. We do that because bits of
# product sepolicy that's still in /system might depend on bits that have moved
# to /product. Once we finish migrating product sepolicy out of system, change
# it so that if no product partition is present, product sepolicy artifacts are
# not built and installed at all.
ifneq (,$(PRODUCT_PUBLIC_POLICY)$(PRODUCT_PRIVATE_POLICY))
HAS_PRODUCT_SEPOLICY_DIR := true
endif

# TODO: move to README when doing the README update and finalizing versioning.
# BOARD_SEPOLICY_VERS must take the format "NN.m" and contain the sepolicy
# version identifier corresponding to the sepolicy on which the non-platform
# policy is to be based. If unspecified, this will build against the current
# public platform policy in tree
ifndef BOARD_SEPOLICY_VERS
# The default platform policy version.
BOARD_SEPOLICY_VERS := $(PLATFORM_SEPOLICY_VERSION)
endif

# If BOARD_SEPOLICY_VERS is set to a value other than PLATFORM_SEPOLICY_VERSION,
# policy files of platform (system, system_ext, product) can't be mixed with
# policy files of vendor (vendor, odm). If it's the case, platform policies and
# vendor policies are separately built. More specifically,
#
# - Platform policy files needed to build vendor policies, such as plat_policy,
#   plat_mapping_cil, plat_pub_policy, reqd_policy_mask, are built from the
#   prebuilts (copy of platform policy files of version BOARD_SEPOLICY_VERS).
#
# - sepolicy_neverallows only checks platform policies, and a new module
#   sepolicy_neverallows_vendor checks vendor policies.
#
# - neverallow checks are turned off while compiling precompiled_sepolicy module
#   and sepolicy module.
#
# - Vendor policies are not checked on the compat test (compat.mk).
#
# In such scenario, we can grab platform policy files from the prebuilts/api
# directory. But we need more than that: prebuilts of system_ext, product,
# system/sepolicy/reqd_mask, and system/sepolicy/vendor. The following variables
# are introduced to specify such prebuilts.
#
# - BOARD_REQD_MASK_POLICY (prebuilt of system/sepolicy/reqd_mask)
# - BOARD_PLAT_VENDOR_POLICY (prebuilt of system/sepolicy/vendor)
# - BOARD_SYSTEM_EXT_PUBLIC_PREBUILT_DIRS (prebuilt of system_ext public)
# - BOARD_SYSTEM_EXT_PRIVATE_PREBUILT_DIRS (prebuilt of system_ext private)
# - BOARD_PRODUCT_PUBLIC_PREBUILT_DIRS (prebuilt of product public)
# - BOARD_PRODUCT_PRIVATE_PREBUILT_DIRS (prebuilt of product private)
#
# Vendors are responsible for copying policy files from the old version of the
# source tree as prebuilts, and for setting BOARD_*_POLICY variables so they can
# be used to build vendor policies. See prebuilt_policy.mk for more details.
#
# To support both mixed build and normal build, platform policy files are
# indirectly referred by {partition}_{public|private}_policy_$(ver) variables
# when building vendor policies. See vendor_sepolicy.cil and odm_sepolicy.cil
# for more details.
#
# sepolicy.recovery is also compiled from vendor and plat prebuilt policies.
ifneq ($(PLATFORM_SEPOLICY_VERSION),$(BOARD_SEPOLICY_VERS))
mixed_sepolicy_build := true
else
mixed_sepolicy_build :=
endif

NEVERALLOW_ARG :=
ifeq ($(SELINUX_IGNORE_NEVERALLOWS),true)
ifeq ($(TARGET_BUILD_VARIANT),user)
$(error SELINUX_IGNORE_NEVERALLOWS := true cannot be used in user builds)
endif
$(warning Be careful when using the SELINUX_IGNORE_NEVERALLOWS flag. \
          It does not work in user builds and using it will \
          not stop you from failing CTS.)
NEVERALLOW_ARG := -N
endif

# BOARD_SEPOLICY_DIRS was used for vendor/odm sepolicy customization before.
# It has been replaced by BOARD_VENDOR_SEPOLICY_DIRS (mandatory) and
# BOARD_ODM_SEPOLICY_DIRS (optional). BOARD_SEPOLICY_DIRS is still allowed for
# backward compatibility, which will be merged into BOARD_VENDOR_SEPOLICY_DIRS.
ifdef BOARD_SEPOLICY_DIRS
BOARD_VENDOR_SEPOLICY_DIRS += $(BOARD_SEPOLICY_DIRS)
endif

# Set default values for these prebuilt directories
ifeq (,$(BOARD_REQD_MASK_POLICY))
BOARD_REQD_MASK_POLICY := $(REQD_MASK_POLICY)
endif

ifeq (,$(BOARD_PLAT_VENDOR_POLICY))
BOARD_PLAT_VENDOR_POLICY := $(PLAT_VENDOR_POLICY)
endif

$(foreach p,SYSTEM_EXT PRODUCT,$(foreach q,PUBLIC PRIVATE,$(eval \
    $(if $(BOARD_$(p)_$(q)_PREBUILT_DIRS),,\
        BOARD_$(p)_$(q)_PREBUILT_DIRS := $($(p)_$(q)_POLICY) \
    ) \
)))

ifdef BOARD_ODM_SEPOLICY_DIRS
ifneq ($(PRODUCT_SEPOLICY_SPLIT),true)
$(error PRODUCT_SEPOLICY_SPLIT needs to be true when using BOARD_ODM_SEPOLICY_DIRS)
endif
endif

###########################################################
# Compute policy files to be used in policy build.
# $(1): files to include
# $(2): directories in which to find files
###########################################################

define build_policy
$(foreach type, $(1), $(foreach file, $(addsuffix /$(type), $(2)), $(sort $(wildcard $(file)))))
endef

# Builds paths for all policy files found in BOARD_VENDOR_SEPOLICY_DIRS.
# $(1): the set of policy name paths to build
build_vendor_policy = $(call build_policy, $(1), $(PLAT_VENDOR_POLICY) $(BOARD_VENDOR_SEPOLICY_DIRS))

# Builds paths for all policy files found in BOARD_ODM_SEPOLICY_DIRS.
build_odm_policy = $(call build_policy, $(1), $(BOARD_ODM_SEPOLICY_DIRS))

sepolicy_build_files := security_classes \
                        initial_sids \
                        access_vectors \
                        global_macros \
                        neverallow_macros \
                        mls_macros \
                        mls_decl \
                        mls \
                        policy_capabilities \
                        te_macros \
                        attributes \
                        ioctl_defines \
                        ioctl_macros \
                        *.te \
                        roles_decl \
                        roles \
                        users \
                        initial_sid_contexts \
                        fs_use \
                        genfs_contexts \
                        port_contexts

sepolicy_compat_files := $(foreach ver, $(PLATFORM_SEPOLICY_COMPAT_VERSIONS), \
                           $(addprefix compat/$(ver)/, $(addsuffix .cil, $(ver))))

# Security classes and permissions defined outside of system/sepolicy.
security_class_extension_files := $(call build_policy, security_classes access_vectors, \
  $(SYSTEM_EXT_PUBLIC_POLICY) $(SYSTEM_EXT_PRIVATE_POLICY) \
  $(PRODUCT_PUBLIC_POLICY) $(PRODUCT_PRIVATE_POLICY) \
  $(BOARD_VENDOR_SEPOLICY_DIRS) $(BOARD_ODM_SEPOLICY_DIRS))

ifneq (,$(strip $(security_class_extension_files)))
  $(error Only platform SELinux policy may define classes and permissions: $(strip $(security_class_extension_files)))
endif

ifdef HAS_SYSTEM_EXT_SEPOLICY_DIR
  # Checks if there are public system_ext policy files.
  policy_files := $(call build_policy, $(sepolicy_build_files), $(SYSTEM_EXT_PUBLIC_POLICY))
  ifneq (,$(strip $(policy_files)))
    HAS_SYSTEM_EXT_PUBLIC_SEPOLICY := true
  endif
  # Checks if there are public/private system_ext policy files.
  policy_files := $(call build_policy, $(sepolicy_build_files), $(SYSTEM_EXT_PUBLIC_POLICY) $(SYSTEM_EXT_PRIVATE_POLICY))
  ifneq (,$(strip $(policy_files)))
    HAS_SYSTEM_EXT_SEPOLICY := true
  endif
endif # ifdef HAS_SYSTEM_EXT_SEPOLICY_DIR

ifdef HAS_PRODUCT_SEPOLICY_DIR
  # Checks if there are public product policy files.
  policy_files := $(call build_policy, $(sepolicy_build_files), $(PRODUCT_PUBLIC_POLICY))
  ifneq (,$(strip $(policy_files)))
    HAS_PRODUCT_PUBLIC_SEPOLICY := true
  endif
  # Checks if there are public/private product policy files.
  policy_files := $(call build_policy, $(sepolicy_build_files), $(PRODUCT_PUBLIC_POLICY) $(PRODUCT_PRIVATE_POLICY))
  ifneq (,$(strip $(policy_files)))
    HAS_PRODUCT_SEPOLICY := true
  endif
endif # ifdef HAS_PRODUCT_SEPOLICY_DIR

# CIL files which contain workarounds for current limitation of human-readable
# module policy language. These files are appended to the CIL files produced
# from module language files.
sepolicy_build_cil_workaround_files := technical_debt.cil

my_target_arch := $(TARGET_ARCH)
ifneq (,$(filter mips mips64,$(TARGET_ARCH)))
  my_target_arch := mips
endif

intermediates := $(TARGET_OUT_INTERMEDIATES)/ETC/sepolicy_intermediates

with_asan := false
ifneq (,$(filter address,$(SANITIZE_TARGET)))
  with_asan := true
endif

with_native_coverage := false
ifeq ($(NATIVE_COVERAGE),true)
  with_native_coverage := true
endif
ifeq ($(CLANG_COVERAGE),true)
  with_native_coverage := true
endif

treble_sysprop_neverallow := true
ifeq ($(BUILD_BROKEN_TREBLE_SYSPROP_NEVERALLOW),true)
  treble_sysprop_neverallow := false
endif

ifeq ($(PRODUCT_SHIPPING_API_LEVEL),)
  #$(warning no product shipping level defined)
else ifneq ($(call math_lt,29,$(PRODUCT_SHIPPING_API_LEVEL)),)
  ifneq ($(BUILD_BROKEN_TREBLE_SYSPROP_NEVERALLOW),)
    $(error BUILD_BROKEN_TREBLE_SYSPROP_NEVERALLOW cannot be set on a device shipping with R or later, and this is tested by CTS.)
  endif
endif

enforce_sysprop_owner := true
ifeq ($(BUILD_BROKEN_ENFORCE_SYSPROP_OWNER),true)
  enforce_sysprop_owner := false
endif

enforce_debugfs_restriction := false
ifeq ($(PRODUCT_SET_DEBUGFS_RESTRICTIONS),true)
  enforce_debugfs_restriction := true
endif

ifeq ($(PRODUCT_SHIPPING_API_LEVEL),)
  #$(warning no product shipping level defined)
else ifneq ($(call math_lt,30,$(PRODUCT_SHIPPING_API_LEVEL)),)
  ifneq ($(BUILD_BROKEN_ENFORCE_SYSPROP_OWNER),)
    $(error BUILD_BROKEN_ENFORCE_SYSPROP_OWNER cannot be set on a device shipping with S or later, and this is tested by CTS.)
  endif
endif

# Library extension for host-side tests
ifeq ($(HOST_OS),darwin)
SHAREDLIB_EXT=dylib
else
SHAREDLIB_EXT=so
endif

# Convert a file_context file for a non-flattened APEX into a file for
# flattened APEX. /system/apex/<apex_name> path is prepended to the original paths
# $(1): path to the input file_contexts file for non-flattened APEX
# $(2): path to the flattened APEX
# $(3): path to the generated file_contexts file for flattened APEX
# $(4): variable where $(3) is added to
define build_flattened_apex_file_contexts
$(4) += $(3)
$(3): PRIVATE_APEX_PATH := $(subst .,\\.,$(2))
$(3): $(1)
	$(hide) awk '/object_r/{printf("$$(PRIVATE_APEX_PATH)%s\n",$$$$0)}' $$< > $$@
endef

#################################

include $(CLEAR_VARS)

LOCAL_MODULE := selinux_policy
LOCAL_LICENSE_KINDS := SPDX-license-identifier-Apache-2.0 legacy_unencumbered
LOCAL_LICENSE_CONDITIONS := notice unencumbered
LOCAL_NOTICE_FILE := $(LOCAL_PATH)/NOTICE
LOCAL_MODULE_TAGS := optional
LOCAL_REQUIRED_MODULES += \
    selinux_policy_nonsystem \
    selinux_policy_system \

include $(BUILD_PHONY_PACKAGE)

# selinux_policy is a main goal and triggers lots of tests.
# Most tests are FAKE modules, so aren'triggered on normal builds. (e.g. 'm')
# By setting as droidcore's dependency, tests will run on normal builds.
droidcore: selinux_policy

include $(CLEAR_VARS)
LOCAL_MODULE := selinux_policy_system
LOCAL_LICENSE_KINDS := SPDX-license-identifier-Apache-2.0 legacy_unencumbered
LOCAL_LICENSE_CONDITIONS := notice unencumbered
LOCAL_NOTICE_FILE := $(LOCAL_PATH)/NOTICE
# These build targets are not used on non-Treble devices. However, we build these to avoid
# divergence between Treble and non-Treble devices.
LOCAL_REQUIRED_MODULES += \
    plat_mapping_file \
    $(addprefix plat_,$(addsuffix .cil,$(PLATFORM_SEPOLICY_COMPAT_VERSIONS))) \
    $(addsuffix .compat.cil,$(PLATFORM_SEPOLICY_COMPAT_VERSIONS)) \
    plat_sepolicy.cil \
    secilc \

ifneq ($(PRODUCT_PRECOMPILED_SEPOLICY),false)
LOCAL_REQUIRED_MODULES += plat_sepolicy_and_mapping.sha256
endif

LOCAL_REQUIRED_MODULES += \
    build_sepolicy \
    plat_file_contexts \
    plat_file_contexts_test \
    plat_keystore2_key_contexts \
    plat_mac_permissions.xml \
    plat_property_contexts \
    plat_property_contexts_test \
    plat_seapp_contexts \
    plat_service_contexts \
    plat_service_contexts_test \
    plat_hwservice_contexts \
    plat_hwservice_contexts_test \
    searchpolicy \

# This conditional inclusion closely mimics the conditional logic
# inside init/init.cpp for loading SELinux policy from files.
ifneq ($(PRODUCT_SEPOLICY_SPLIT),true)
# The following files are only allowed for non-Treble devices.
LOCAL_REQUIRED_MODULES += \
    sepolicy \
    vendor_service_contexts \

endif # ($(PRODUCT_SEPOLICY_SPLIT),true)

ifneq ($(with_asan),true)
ifneq ($(SELINUX_IGNORE_NEVERALLOWS),true)
LOCAL_REQUIRED_MODULES += \
    sepolicy_tests \
    $(addsuffix _compat_test,$(PLATFORM_SEPOLICY_COMPAT_VERSIONS)) \

ifeq ($(PRODUCT_SEPOLICY_SPLIT),true)
LOCAL_REQUIRED_MODULES += \
    $(addprefix treble_sepolicy_tests_,$(PLATFORM_SEPOLICY_COMPAT_VERSIONS)) \

endif  # PRODUCT_SEPOLICY_SPLIT
endif  # SELINUX_IGNORE_NEVERALLOWS
endif  # with_asan

ifneq ($(PLATFORM_SEPOLICY_VERSION),$(TOT_SEPOLICY_VERSION))
LOCAL_REQUIRED_MODULES += \
    sepolicy_freeze_test \

else
ifneq (,$(FREEZE_TEST_EXTRA_DIRS)$(FREEZE_TEST_EXTRA_PREBUILT_DIRS))
$(error SEPOLICY_FREEZE_TEST_EXTRA_DIRS or SEPOLICY_FREEZE_TEST_EXTRA_PREBUILT_DIRS\
cannot be set before system/sepolicy freezes.)
endif #  (,$(FREEZE_TEST_EXTRA_DIRS)$(FREEZE_TEST_EXTRA_PREBUILT_DIRS))
endif # ($(PLATFORM_SEPOLICY_VERSION),$(TOT_SEPOLICY_VERSION))

include $(BUILD_PHONY_PACKAGE)

#################################

include $(CLEAR_VARS)

LOCAL_MODULE := selinux_policy_system_ext
LOCAL_LICENSE_KINDS := SPDX-license-identifier-Apache-2.0 legacy_unencumbered
LOCAL_LICENSE_CONDITIONS := notice unencumbered
LOCAL_NOTICE_FILE := $(LOCAL_PATH)/NOTICE
# Include precompiled policy, unless told otherwise.
ifneq ($(PRODUCT_PRECOMPILED_SEPOLICY),false)
ifdef HAS_SYSTEM_EXT_SEPOLICY
LOCAL_REQUIRED_MODULES += system_ext_sepolicy_and_mapping.sha256
endif
endif

ifdef HAS_SYSTEM_EXT_SEPOLICY
LOCAL_REQUIRED_MODULES += system_ext_sepolicy.cil
endif

ifdef HAS_SYSTEM_EXT_PUBLIC_SEPOLICY
LOCAL_REQUIRED_MODULES += \
    system_ext_mapping_file

system_ext_compat_files := $(call build_policy, $(sepolicy_compat_files), $(SYSTEM_EXT_PRIVATE_POLICY))

LOCAL_REQUIRED_MODULES += $(addprefix system_ext_, $(notdir $(system_ext_compat_files)))

endif

ifdef HAS_SYSTEM_EXT_SEPOLICY_DIR
LOCAL_REQUIRED_MODULES += \
    system_ext_file_contexts \
    system_ext_file_contexts_test \
    system_ext_hwservice_contexts \
    system_ext_hwservice_contexts_test \
    system_ext_property_contexts \
    system_ext_property_contexts_test \
    system_ext_seapp_contexts \
    system_ext_service_contexts \
    system_ext_service_contexts_test \
    system_ext_mac_permissions.xml \
    $(addprefix system_ext_,$(addsuffix .compat.cil,$(PLATFORM_SEPOLICY_COMPAT_VERSIONS))) \

endif

include $(BUILD_PHONY_PACKAGE)

#################################

include $(CLEAR_VARS)

LOCAL_MODULE := selinux_policy_product
LOCAL_LICENSE_KINDS := SPDX-license-identifier-Apache-2.0 legacy_unencumbered
LOCAL_LICENSE_CONDITIONS := notice unencumbered
LOCAL_NOTICE_FILE := $(LOCAL_PATH)/NOTICE
# Include precompiled policy, unless told otherwise.
ifneq ($(PRODUCT_PRECOMPILED_SEPOLICY),false)
ifdef HAS_PRODUCT_SEPOLICY
LOCAL_REQUIRED_MODULES += product_sepolicy_and_mapping.sha256
endif
endif

ifdef HAS_PRODUCT_SEPOLICY
LOCAL_REQUIRED_MODULES += product_sepolicy.cil
endif

ifdef HAS_PRODUCT_PUBLIC_SEPOLICY
LOCAL_REQUIRED_MODULES += \
    product_mapping_file

product_compat_files := $(call build_policy, $(sepolicy_compat_files), $(PRODUCT_PRIVATE_POLICY))

LOCAL_REQUIRED_MODULES += $(addprefix product_, $(notdir $(product_compat_files)))

endif

ifdef HAS_PRODUCT_SEPOLICY_DIR
LOCAL_REQUIRED_MODULES += \
    product_file_contexts \
    product_file_contexts_test \
    product_hwservice_contexts \
    product_hwservice_contexts_test \
    product_property_contexts \
    product_property_contexts_test \
    product_seapp_contexts \
    product_service_contexts \
    product_service_contexts_test \
    product_mac_permissions.xml \

endif

include $(BUILD_PHONY_PACKAGE)

#################################

include $(CLEAR_VARS)

LOCAL_MODULE := selinux_policy_nonsystem
LOCAL_LICENSE_KINDS := SPDX-license-identifier-Apache-2.0 legacy_unencumbered
LOCAL_LICENSE_CONDITIONS := notice unencumbered
LOCAL_NOTICE_FILE := $(LOCAL_PATH)/NOTICE
# Include precompiled policy, unless told otherwise.
ifneq ($(PRODUCT_PRECOMPILED_SEPOLICY),false)
LOCAL_REQUIRED_MODULES += \
    precompiled_sepolicy \
    precompiled_sepolicy.plat_sepolicy_and_mapping.sha256

ifdef HAS_SYSTEM_EXT_SEPOLICY
LOCAL_REQUIRED_MODULES += precompiled_sepolicy.system_ext_sepolicy_and_mapping.sha256
endif

ifdef HAS_PRODUCT_SEPOLICY
LOCAL_REQUIRED_MODULES += precompiled_sepolicy.product_sepolicy_and_mapping.sha256
endif

endif # ($(PRODUCT_PRECOMPILED_SEPOLICY),false)


# These build targets are not used on non-Treble devices. However, we build these to avoid
# divergence between Treble and non-Treble devices.
LOCAL_REQUIRED_MODULES += \
    plat_pub_versioned.cil \
    vendor_sepolicy.cil \
    plat_sepolicy_vers.txt \

LOCAL_REQUIRED_MODULES += \
    vendor_file_contexts \
    vendor_file_contexts_test \
    vendor_mac_permissions.xml \
    vendor_property_contexts \
    vendor_property_contexts_test \
    vendor_seapp_contexts \
    vendor_service_contexts \
    vendor_hwservice_contexts \
    vendor_hwservice_contexts_test \
    vndservice_contexts \

ifdef BOARD_ODM_SEPOLICY_DIRS
LOCAL_REQUIRED_MODULES += \
    odm_sepolicy.cil \
    odm_file_contexts \
    odm_file_contexts_test \
    odm_seapp_contexts \
    odm_property_contexts \
    odm_property_contexts_test \
    odm_hwservice_contexts \
    odm_hwservice_contexts_test \
    odm_mac_permissions.xml
endif

LOCAL_REQUIRED_MODULES += selinux_policy_system_ext
LOCAL_REQUIRED_MODULES += selinux_policy_product

LOCAL_REQUIRED_MODULES += \
    selinux_denial_metadata \

# Builds an addtional userdebug sepolicy into the debug ramdisk.
LOCAL_REQUIRED_MODULES += \
    userdebug_plat_sepolicy.cil \

include $(BUILD_PHONY_PACKAGE)

#################################

ifeq ($(mixed_sepolicy_build),true)
include $(LOCAL_PATH)/prebuilt_policy.mk
else
reqd_policy_$(PLATFORM_SEPOLICY_VERSION) := $(REQD_MASK_POLICY)
plat_public_policy_$(PLATFORM_SEPOLICY_VERSION) := $(LOCAL_PATH)/public
plat_private_policy_$(PLATFORM_SEPOLICY_VERSION) := $(LOCAL_PATH)/private
system_ext_public_policy_$(PLATFORM_SEPOLICY_VERSION) := $(SYSTEM_EXT_PUBLIC_POLICY)
system_ext_private_policy_$(PLATFORM_SEPOLICY_VERSION) := $(SYSTEM_EXT_PRIVATE_POLICY)
product_public_policy_$(PLATFORM_SEPOLICY_VERSION) := $(PRODUCT_PUBLIC_POLICY)
product_private_policy_$(PLATFORM_SEPOLICY_VERSION) := $(PRODUCT_PRIVATE_POLICY)
endif

#################################
include $(CLEAR_VARS)

LOCAL_MODULE := sepolicy_neverallows
LOCAL_LICENSE_KINDS := SPDX-license-identifier-Apache-2.0 legacy_unencumbered
LOCAL_LICENSE_CONDITIONS := notice unencumbered
LOCAL_NOTICE_FILE := $(LOCAL_PATH)/NOTICE
LOCAL_MODULE_CLASS := FAKE
LOCAL_MODULE_TAGS := optional

include $(BUILD_SYSTEM)/base_rules.mk

# sepolicy_policy.conf - All of the policy for the device.  This is only used to
# check neverallow rules.
# In a mixed build target, vendor policies are checked separately, on the module
# sepolicy_neverallows_vendor.

all_plat_policy := $(PLAT_PUBLIC_POLICY) $(PLAT_PRIVATE_POLICY) $(PLAT_VENDOR_POLICY) \
  $(SYSTEM_EXT_PUBLIC_POLICY) $(SYSTEM_EXT_PRIVATE_POLICY) \
  $(PRODUCT_PUBLIC_POLICY) $(PRODUCT_PRIVATE_POLICY)
ifeq ($(mixed_sepolicy_build),true)
policy_files := $(call build_policy, $(sepolicy_build_files), $(all_plat_policy))
else
policy_files := $(call build_policy, $(sepolicy_build_files), \
  $(all_plat_policy) $(BOARD_VENDOR_SEPOLICY_DIRS) $(BOARD_ODM_SEPOLICY_DIRS))
endif

sepolicy_policy.conf := $(intermediates)/policy.conf
$(sepolicy_policy.conf): PRIVATE_MLS_SENS := $(MLS_SENS)
$(sepolicy_policy.conf): PRIVATE_MLS_CATS := $(MLS_CATS)
$(sepolicy_policy.conf): PRIVATE_TARGET_BUILD_VARIANT := user
$(sepolicy_policy.conf): PRIVATE_TGT_ARCH := $(my_target_arch)
$(sepolicy_policy.conf): PRIVATE_TGT_WITH_ASAN := $(with_asan)
$(sepolicy_policy.conf): PRIVATE_TGT_WITH_NATIVE_COVERAGE := $(with_native_coverage)
$(sepolicy_policy.conf): PRIVATE_ADDITIONAL_M4DEFS := $(LOCAL_ADDITIONAL_M4DEFS)
$(sepolicy_policy.conf): PRIVATE_SEPOLICY_SPLIT := $(PRODUCT_SEPOLICY_SPLIT)
$(sepolicy_policy.conf): PRIVATE_ENFORCE_DEBUGFS_RESTRICTION := $(enforce_debugfs_restriction)
$(sepolicy_policy.conf): PRIVATE_POLICY_FILES := $(policy_files)
$(sepolicy_policy.conf): $(policy_files) $(M4)
	$(transform-policy-to-conf)
	$(hide) sed '/^\s*dontaudit.*;/d' $@ | sed '/^\s*dontaudit/,/;/d' > $@.dontaudit

# sepolicy_policy_2.conf - All of the policy for the device.  This is only used to
# check neverallow rules using sepolicy-analyze, similar to CTS.
sepolicy_policy_2.conf := $(intermediates)/policy_2.conf
$(sepolicy_policy_2.conf): PRIVATE_MLS_SENS := $(MLS_SENS)
$(sepolicy_policy_2.conf): PRIVATE_MLS_CATS := $(MLS_CATS)
$(sepolicy_policy_2.conf): PRIVATE_TARGET_BUILD_VARIANT := user
$(sepolicy_policy_2.conf): PRIVATE_EXCLUDE_BUILD_TEST := true
$(sepolicy_policy_2.conf): PRIVATE_TGT_ARCH := $(my_target_arch)
$(sepolicy_policy_2.conf): PRIVATE_TGT_WITH_ASAN := $(with_asan)
$(sepolicy_policy_2.conf): PRIVATE_TGT_WITH_NATIVE_COVERAGE := $(with_native_coverage)
$(sepolicy_policy_2.conf): PRIVATE_ADDITIONAL_M4DEFS := $(LOCAL_ADDITIONAL_M4DEFS)
$(sepolicy_policy_2.conf): PRIVATE_SEPOLICY_SPLIT := $(PRODUCT_SEPOLICY_SPLIT)
$(sepolicy_policy_2.conf): PRIVATE_ENFORCE_DEBUGFS_RESTRICTION := $(enforce_debugfs_restriction)
$(sepolicy_policy_2.conf): PRIVATE_POLICY_FILES := $(policy_files)
$(sepolicy_policy_2.conf): $(policy_files) $(M4)
	$(transform-policy-to-conf)
	$(hide) sed '/^\s*dontaudit.*;/d' $@ | sed '/^\s*dontaudit/,/;/d' > $@.dontaudit

$(LOCAL_BUILT_MODULE): PRIVATE_SEPOLICY_1 := $(sepolicy_policy.conf)
$(LOCAL_BUILT_MODULE): PRIVATE_SEPOLICY_2 := $(sepolicy_policy_2.conf)
$(LOCAL_BUILT_MODULE): $(sepolicy_policy.conf) $(sepolicy_policy_2.conf) \
  $(HOST_OUT_EXECUTABLES)/checkpolicy $(HOST_OUT_EXECUTABLES)/sepolicy-analyze
ifneq ($(SELINUX_IGNORE_NEVERALLOWS),true)
	$(hide) $(CHECKPOLICY_ASAN_OPTIONS) $(HOST_OUT_EXECUTABLES)/checkpolicy -M -c \
		$(POLICYVERS) -o $@.tmp $(PRIVATE_SEPOLICY_1)
	$(hide) $(HOST_OUT_EXECUTABLES)/sepolicy-analyze $@.tmp neverallow -w -f $(PRIVATE_SEPOLICY_2) || \
	  ( echo "" 1>&2; \
	    echo "sepolicy-analyze failed. This is most likely due to the use" 1>&2; \
	    echo "of an expanded attribute in a neverallow assertion. Please fix" 1>&2; \
	    echo "the policy." 1>&2; \
	    exit 1 )
endif # ($(SELINUX_IGNORE_NEVERALLOWS),true)
	$(hide) touch $@.tmp
	$(hide) mv $@.tmp $@

sepolicy_policy.conf :=
sepolicy_policy_2.conf :=
built_sepolicy_neverallows := $(LOCAL_BUILT_MODULE)

#################################
# sepolicy_neverallows_vendor: neverallow check module for vendors in a mixed build target
ifeq ($(mixed_sepolicy_build),true)
include $(CLEAR_VARS)

LOCAL_MODULE := sepolicy_neverallows_vendor
LOCAL_LICENSE_KINDS := SPDX-license-identifier-Apache-2.0 legacy_unencumbered
LOCAL_LICENSE_CONDITIONS := notice unencumbered
LOCAL_NOTICE_FILE := $(LOCAL_PATH)/NOTICE
LOCAL_MODULE_CLASS := FAKE
LOCAL_MODULE_TAGS := optional

include $(BUILD_SYSTEM)/base_rules.mk

# Check neverallow with prebuilt policy files
policy_files := $(call build_policy, $(sepolicy_build_files), \
  $(plat_public_policy_$(BOARD_SEPOLICY_VERS)) $(plat_private_policy_$(BOARD_SEPOLICY_VERS)) \
  $(system_ext_public_policy_$(BOARD_SEPOLICY_VERS)) $(system_ext_private_policy_$(BOARD_SEPOLICY_VERS)) \
  $(product_public_policy_$(BOARD_SEPOLICY_VERS)) $(product_private_policy_$(BOARD_SEPOLICY_VERS)) \
  $(BOARD_PLAT_VENDOR_POLICY) $(BOARD_VENDOR_SEPOLICY_DIRS) $(BOARD_ODM_SEPOLICY_DIRS))

# sepolicy_policy.conf - All of the policy for the device.  This is only used to
# check neverallow rules.
sepolicy_policy.conf := $(intermediates)/policy_vendor.conf
$(sepolicy_policy.conf): PRIVATE_MLS_SENS := $(MLS_SENS)
$(sepolicy_policy.conf): PRIVATE_MLS_CATS := $(MLS_CATS)
$(sepolicy_policy.conf): PRIVATE_TARGET_BUILD_VARIANT := user
$(sepolicy_policy.conf): PRIVATE_TGT_ARCH := $(my_target_arch)
$(sepolicy_policy.conf): PRIVATE_TGT_WITH_ASAN := $(with_asan)
$(sepolicy_policy.conf): PRIVATE_TGT_WITH_NATIVE_COVERAGE := $(with_native_coverage)
$(sepolicy_policy.conf): PRIVATE_ADDITIONAL_M4DEFS := $(LOCAL_ADDITIONAL_M4DEFS)
$(sepolicy_policy.conf): PRIVATE_SEPOLICY_SPLIT := $(PRODUCT_SEPOLICY_SPLIT)
$(sepolicy_policy.conf): PRIVATE_ENFORCE_DEBUGFS_RESTRICTION := $(enforce_debugfs_restriction)
$(sepolicy_policy.conf): PRIVATE_POLICY_FILES := $(policy_files)
$(sepolicy_policy.conf): $(policy_files) $(M4)
	$(transform-policy-to-conf)
	$(hide) sed '/^\s*dontaudit.*;/d' $@ | sed '/^\s*dontaudit/,/;/d' > $@.dontaudit

# sepolicy_policy_2.conf - All of the policy for the device.  This is only used to
# check neverallow rules using sepolicy-analyze, similar to CTS.
sepolicy_policy_2.conf := $(intermediates)/policy_vendor_2.conf
$(sepolicy_policy_2.conf): PRIVATE_MLS_SENS := $(MLS_SENS)
$(sepolicy_policy_2.conf): PRIVATE_MLS_CATS := $(MLS_CATS)
$(sepolicy_policy_2.conf): PRIVATE_TARGET_BUILD_VARIANT := user
$(sepolicy_policy_2.conf): PRIVATE_EXCLUDE_BUILD_TEST := true
$(sepolicy_policy_2.conf): PRIVATE_TGT_ARCH := $(my_target_arch)
$(sepolicy_policy_2.conf): PRIVATE_TGT_WITH_ASAN := $(with_asan)
$(sepolicy_policy_2.conf): PRIVATE_TGT_WITH_NATIVE_COVERAGE := $(with_native_coverage)
$(sepolicy_policy_2.conf): PRIVATE_ADDITIONAL_M4DEFS := $(LOCAL_ADDITIONAL_M4DEFS)
$(sepolicy_policy_2.conf): PRIVATE_SEPOLICY_SPLIT := $(PRODUCT_SEPOLICY_SPLIT)
$(sepolicy_policy_2.conf): PRIVATE_ENFORCE_DEBUGFS_RESTRICTION := $(enforce_debugfs_restriction)
$(sepolicy_policy_2.conf): PRIVATE_POLICY_FILES := $(policy_files)
$(sepolicy_policy_2.conf): $(policy_files) $(M4)
	$(transform-policy-to-conf)
	$(hide) sed '/^\s*dontaudit.*;/d' $@ | sed '/^\s*dontaudit/,/;/d' > $@.dontaudit

$(LOCAL_BUILT_MODULE): PRIVATE_SEPOLICY_1 := $(sepolicy_policy.conf)
$(LOCAL_BUILT_MODULE): PRIVATE_SEPOLICY_2 := $(sepolicy_policy_2.conf)
$(LOCAL_BUILT_MODULE): $(sepolicy_policy.conf) $(sepolicy_policy_2.conf) \
  $(HOST_OUT_EXECUTABLES)/checkpolicy $(HOST_OUT_EXECUTABLES)/sepolicy-analyze
ifneq ($(SELINUX_IGNORE_NEVERALLOWS),true)
	$(hide) $(CHECKPOLICY_ASAN_OPTIONS) $(HOST_OUT_EXECUTABLES)/checkpolicy -M -c \
		$(POLICYVERS) -o $@.tmp $(PRIVATE_SEPOLICY_1)
	$(hide) $(HOST_OUT_EXECUTABLES)/sepolicy-analyze $@.tmp neverallow -w -f $(PRIVATE_SEPOLICY_2) || \
	  ( echo "" 1>&2; \
	    echo "sepolicy-analyze failed. This is most likely due to the use" 1>&2; \
	    echo "of an expanded attribute in a neverallow assertion. Please fix" 1>&2; \
	    echo "the policy." 1>&2; \
	    exit 1 )
endif # ($(SELINUX_IGNORE_NEVERALLOWS),true)
	$(hide) touch $@.tmp
	$(hide) mv $@.tmp $@

sepolicy_policy.conf :=
sepolicy_policy_2.conf :=
built_sepolicy_neverallows += $(LOCAL_BUILT_MODULE)

endif # ifeq ($(mixed_sepolicy_build),true)

##################################
# plat policy files are now built with Android.bp. Grab them from intermediate.
# See Android.bp for details of plat policy files.
#
reqd_policy_mask.cil := $(call intermediates-dir-for,ETC,reqd_policy_mask.cil)/reqd_policy_mask.cil
reqd_policy_mask_$(PLATFORM_SEPOLICY_VERSION).cil := $(reqd_policy_mask.cil)

pub_policy.cil := $(call intermediates-dir-for,ETC,pub_policy.cil)/pub_policy.cil
pub_policy_$(PLATFORM_SEPOLICY_VERSION).cil := $(pub_policy.cil)

system_ext_pub_policy.cil := $(call intermediates-dir-for,ETC,system_ext_pub_policy.cil)/system_ext_pub_policy.cil
system_ext_pub_policy_$(PLATFORM_SEPOLICY_VERSION).cil := $(system_ext_pub_policy.cil)

plat_pub_policy.cil := $(call intermediates-dir-for,ETC,plat_pub_policy.cil)/plat_pub_policy.cil
plat_pub_policy_$(PLATFORM_SEPOLICY_VERSION).cil := $(plat_pub_policy.cil)

built_plat_cil := $(call intermediates-dir-for,ETC,plat_sepolicy.cil)/plat_sepolicy.cil
built_plat_cil_$(PLATFORM_SEPOLICY_VERSION) := $(built_plat_cil)
built_plat_mapping_cil := $(call intermediates-dir-for,ETC,plat_mapping_file)/plat_mapping_file
built_plat_mapping_cil_$(PLATFORM_SEPOLICY_VERSION) := $(built_plat_mapping_cil)

ifdef HAS_SYSTEM_EXT_SEPOLICY
built_system_ext_cil := $(call intermediates-dir-for,ETC,system_ext_sepolicy.cil)/system_ext_sepolicy.cil
built_system_ext_cil_$(PLATFORM_SEPOLICY_VERSION) := $(built_system_ext_cil)
built_system_ext_mapping_cil := $(call intermediates-dir-for,ETC,system_ext_mapping_file)/system_ext_mapping_file
built_system_ext_mapping_cil_$(PLATFORM_SEPOLICY_VERSION) := $(built_system_ext_mapping_cil)
endif # ifdef HAS_SYSTEM_EXT_SEPOLICY

ifdef HAS_PRODUCT_SEPOLICY
built_product_cil := $(call intermediates-dir-for,ETC,product_sepolicy.cil)/product_sepolicy.cil
built_product_cil_$(PLATFORM_SEPOLICY_VERSION) := $(built_product_cil)
built_product_mapping_cil := $(call intermediates-dir-for,ETC,product_mapping_file)/product_mapping_file
built_product_mapping_cil_$(PLATFORM_SEPOLICY_VERSION) := $(built_product_mapping_cil)
endif # ifdef HAS_PRODUCT_SEPOLICY

built_pub_vers_cil := $(call intermediates-dir-for,ETC,plat_pub_versioned.cil)/plat_pub_versioned.cil
built_pub_vers_cil_$(PLATFORM_SEPOLICY_VERSION) := $(built_pub_vers_cil)

# b/37755687
CHECKPOLICY_ASAN_OPTIONS := ASAN_OPTIONS=detect_leaks=0

#################################
include $(CLEAR_VARS)

# vendor_policy.cil - the vendor sepolicy. This needs attributization and to be combined
# with the platform-provided policy.  It makes use of the reqd_policy_mask files from private
# policy and the platform public policy files in order to use checkpolicy.
LOCAL_MODULE := vendor_sepolicy.cil
LOCAL_LICENSE_KINDS := SPDX-license-identifier-Apache-2.0 legacy_unencumbered
LOCAL_LICENSE_CONDITIONS := notice unencumbered
LOCAL_NOTICE_FILE := $(LOCAL_PATH)/NOTICE
LOCAL_MODULE_CLASS := ETC
LOCAL_MODULE_TAGS := optional
LOCAL_PROPRIETARY_MODULE := true
LOCAL_MODULE_PATH := $(TARGET_OUT_VENDOR)/etc/selinux

include $(BUILD_SYSTEM)/base_rules.mk

# Use either prebuilt policy files or current policy files, depending on BOARD_SEPOLICY_VERS
policy_files := $(call build_policy, $(sepolicy_build_files), \
  $(plat_public_policy_$(BOARD_SEPOLICY_VERS)) $(system_ext_public_policy_$(BOARD_SEPOLICY_VERS)) \
  $(product_public_policy_$(BOARD_SEPOLICY_VERS)) $(reqd_policy_$(BOARD_SEPOLICY_VERS)) \
  $(BOARD_PLAT_VENDOR_POLICY) $(BOARD_VENDOR_SEPOLICY_DIRS))
vendor_policy.conf := $(intermediates)/vendor_policy.conf
$(vendor_policy.conf): PRIVATE_MLS_SENS := $(MLS_SENS)
$(vendor_policy.conf): PRIVATE_MLS_CATS := $(MLS_CATS)
$(vendor_policy.conf): PRIVATE_TARGET_BUILD_VARIANT := $(TARGET_BUILD_VARIANT)
$(vendor_policy.conf): PRIVATE_TGT_ARCH := $(my_target_arch)
$(vendor_policy.conf): PRIVATE_TGT_WITH_ASAN := $(with_asan)
$(vendor_policy.conf): PRIVATE_TGT_WITH_NATIVE_COVERAGE := $(with_native_coverage)
$(vendor_policy.conf): PRIVATE_ADDITIONAL_M4DEFS := $(LOCAL_ADDITIONAL_M4DEFS)
$(vendor_policy.conf): PRIVATE_SEPOLICY_SPLIT := $(PRODUCT_SEPOLICY_SPLIT)
$(vendor_policy.conf): PRIVATE_COMPATIBLE_PROPERTY := $(PRODUCT_COMPATIBLE_PROPERTY)
$(vendor_policy.conf): PRIVATE_TREBLE_SYSPROP_NEVERALLOW := $(treble_sysprop_neverallow)
$(vendor_policy.conf): PRIVATE_ENFORCE_SYSPROP_OWNER := $(enforce_sysprop_owner)
$(vendor_policy.conf): PRIVATE_ENFORCE_DEBUGFS_RESTRICTION := $(enforce_debugfs_restriction)
$(vendor_policy.conf): PRIVATE_POLICY_FILES := $(policy_files)
$(vendor_policy.conf): $(policy_files) $(M4)
	$(transform-policy-to-conf)
	$(hide) sed '/^\s*dontaudit.*;/d' $@ | sed '/^\s*dontaudit/,/;/d' > $@.dontaudit

$(LOCAL_BUILT_MODULE): PRIVATE_POL_CONF := $(vendor_policy.conf)
$(LOCAL_BUILT_MODULE): PRIVATE_REQD_MASK := $(reqd_policy_mask_$(BOARD_SEPOLICY_VERS).cil)
$(LOCAL_BUILT_MODULE): PRIVATE_BASE_CIL := $(pub_policy_$(BOARD_SEPOLICY_VERS).cil)
$(LOCAL_BUILT_MODULE): PRIVATE_VERS := $(BOARD_SEPOLICY_VERS)
$(LOCAL_BUILT_MODULE): PRIVATE_DEP_CIL_FILES := $(built_plat_cil_$(BOARD_SEPOLICY_VERS)) \
$(built_system_ext_cil_$(BOARD_SEPOLICY_VERS)) $(built_product_cil_$(BOARD_SEPOLICY_VERS)) \
$(built_pub_vers_cil_$(BOARD_SEPOLICY_VERS)) $(built_plat_mapping_cil_$(BOARD_SEPOLICY_VERS)) \
$(built_system_ext_mapping_cil_$(BOARD_SEPOLICY_VERS)) $(built_product_mapping_cil_$(BOARD_SEPOLICY_VERS))
$(LOCAL_BUILT_MODULE): PRIVATE_FILTER_CIL := $(built_pub_vers_cil_$(BOARD_SEPOLICY_VERS))
$(LOCAL_BUILT_MODULE): $(HOST_OUT_EXECUTABLES)/build_sepolicy \
  $(vendor_policy.conf) $(reqd_policy_mask_$(BOARD_SEPOLICY_VERS).cil) \
  $(pub_policy_$(BOARD_SEPOLICY_VERS).cil) $(built_plat_cil_$(BOARD_SEPOLICY_VERS)) \
  $(built_system_ext_cil_$(BOARD_SEPOLICY_VERS)) $(built_product_cil_$(BOARD_SEPOLICY_VERS)) \
  $(built_pub_vers_cil_$(BOARD_SEPOLICY_VERS)) $(built_plat_mapping_cil_$(BOARD_SEPOLICY_VERS)) \
  $(built_system_ext_mapping_cil_$(BOARD_SEPOLICY_VERS)) $(built_product_mapping_cil_$(BOARD_SEPOLICY_VERS))
	@mkdir -p $(dir $@)
	$(hide) $(HOST_OUT_EXECUTABLES)/build_sepolicy -a $(HOST_OUT_EXECUTABLES) build_cil \
		-i $(PRIVATE_POL_CONF) -m $(PRIVATE_REQD_MASK) -c $(CHECKPOLICY_ASAN_OPTIONS) \
		-b $(PRIVATE_BASE_CIL) -d $(PRIVATE_DEP_CIL_FILES) -f $(PRIVATE_FILTER_CIL) \
		-t $(PRIVATE_VERS) -p $(POLICYVERS) -o $@

built_vendor_cil := $(LOCAL_BUILT_MODULE)
vendor_policy.conf :=

#################################
include $(CLEAR_VARS)

ifdef BOARD_ODM_SEPOLICY_DIRS
# odm_policy.cil - the odm sepolicy. This needs attributization and to be combined
# with the platform-provided policy.  It makes use of the reqd_policy_mask files from private
# policy and the platform public policy files in order to use checkpolicy.
LOCAL_MODULE := odm_sepolicy.cil
LOCAL_LICENSE_KINDS := SPDX-license-identifier-Apache-2.0 legacy_unencumbered
LOCAL_LICENSE_CONDITIONS := notice unencumbered
LOCAL_NOTICE_FILE := $(LOCAL_PATH)/NOTICE
LOCAL_MODULE_CLASS := ETC
LOCAL_MODULE_TAGS := optional
LOCAL_PROPRIETARY_MODULE := true
LOCAL_MODULE_PATH := $(TARGET_OUT_ODM)/etc/selinux

include $(BUILD_SYSTEM)/base_rules.mk

# Use either prebuilt policy files or current policy files, depending on BOARD_SEPOLICY_VERS
policy_files := $(call build_policy, $(sepolicy_build_files), \
  $(plat_public_policy_$(BOARD_SEPOLICY_VERS)) $(system_ext_public_policy_$(BOARD_SEPOLICY_VERS)) \
  $(product_public_policy_$(BOARD_SEPOLICY_VERS)) $(reqd_policy_$(BOARD_SEPOLICY_VERS)) \
  $(BOARD_PLAT_VENDOR_POLICY) $(BOARD_VENDOR_SEPOLICY_DIRS) $(BOARD_ODM_SEPOLICY_DIRS))
odm_policy.conf := $(intermediates)/odm_policy.conf
$(odm_policy.conf): PRIVATE_MLS_SENS := $(MLS_SENS)
$(odm_policy.conf): PRIVATE_MLS_CATS := $(MLS_CATS)
$(odm_policy.conf): PRIVATE_TARGET_BUILD_VARIANT := $(TARGET_BUILD_VARIANT)
$(odm_policy.conf): PRIVATE_TGT_ARCH := $(my_target_arch)
$(odm_policy.conf): PRIVATE_TGT_WITH_ASAN := $(with_asan)
$(odm_policy.conf): PRIVATE_TGT_WITH_NATIVE_COVERAGE := $(with_native_coverage)
$(odm_policy.conf): PRIVATE_ADDITIONAL_M4DEFS := $(LOCAL_ADDITIONAL_M4DEFS)
$(odm_policy.conf): PRIVATE_SEPOLICY_SPLIT := $(PRODUCT_SEPOLICY_SPLIT)
$(odm_policy.conf): PRIVATE_COMPATIBLE_PROPERTY := $(PRODUCT_COMPATIBLE_PROPERTY)
$(odm_policy.conf): PRIVATE_TREBLE_SYSPROP_NEVERALLOW := $(treble_sysprop_neverallow)
$(odm_policy.conf): PRIVATE_ENFORCE_DEBUGFS_RESTRICTION := $(enforce_debugfs_restriction)
$(odm_policy.conf): PRIVATE_ENFORCE_SYSPROP_OWNER := $(enforce_sysprop_owner)
$(odm_policy.conf): PRIVATE_POLICY_FILES := $(policy_files)
$(odm_policy.conf): $(policy_files) $(M4)
	$(transform-policy-to-conf)
	$(hide) sed '/^\s*dontaudit.*;/d' $@ | sed '/^\s*dontaudit/,/;/d' > $@.dontaudit

$(LOCAL_BUILT_MODULE): PRIVATE_POL_CONF := $(odm_policy.conf)
$(LOCAL_BUILT_MODULE): PRIVATE_REQD_MASK := $(reqd_policy_mask_$(BOARD_SEPOLICY_VERS).cil)
$(LOCAL_BUILT_MODULE): PRIVATE_BASE_CIL := $(pub_policy_$(BOARD_SEPOLICY_VERS).cil)
$(LOCAL_BUILT_MODULE): PRIVATE_VERS := $(BOARD_SEPOLICY_VERS)
$(LOCAL_BUILT_MODULE): PRIVATE_DEP_CIL_FILES := $(built_plat_cil_$(BOARD_SEPOLICY_VERS)) \
$(built_system_ext_cil_$(BOARD_SEPOLICY_VERS)) $(built_product_cil_$(BOARD_SEPOLICY_VERS)) \
$(built_pub_vers_cil_$(BOARD_SEPOLICY_VERS)) $(built_plat_mapping_cil_$(BOARD_SEPOLICY_VERS)) \
$(built_system_ext_mapping_cil_$(BOARD_SEPOLICY_VERS)) $(built_product_mapping_cil_$(BOARD_SEPOLICY_VERS)) \
$(built_vendor_cil)
$(LOCAL_BUILT_MODULE) : PRIVATE_FILTER_CIL_FILES := $(built_pub_vers_cil_$(BOARD_SEPOLICY_VERS)) $(built_vendor_cil)
$(LOCAL_BUILT_MODULE): $(HOST_OUT_EXECUTABLES)/build_sepolicy \
  $(odm_policy.conf) $(reqd_policy_mask_$(BOARD_SEPOLICY_VERS).cil) \
  $(pub_policy_$(BOARD_SEPOLICY_VERS).cil) $(built_plat_cil_$(BOARD_SEPOLICY_VERS)) \
  $(built_system_ext_cil_$(BOARD_SEPOLICY_VERS)) $(built_product_cil_$(BOARD_SEPOLICY_VERS)) \
  $(built_pub_vers_cil_$(BOARD_SEPOLICY_VERS)) $(built_plat_mapping_cil_$(BOARD_SEPOLICY_VERS)) \
  $(built_system_ext_mapping_cil_$(BOARD_SEPOLICY_VERS)) $(built_product_mapping_cil_$(BOARD_SEPOLICY_VERS)) \
  $(built_vendor_cil)
	@mkdir -p $(dir $@)
	$(hide) $(HOST_OUT_EXECUTABLES)/build_sepolicy -a $(HOST_OUT_EXECUTABLES) build_cil \
		-i $(PRIVATE_POL_CONF) -m $(PRIVATE_REQD_MASK) -c $(CHECKPOLICY_ASAN_OPTIONS) \
		-b $(PRIVATE_BASE_CIL) -d $(PRIVATE_DEP_CIL_FILES) -f $(PRIVATE_FILTER_CIL_FILES) \
		-t $(PRIVATE_VERS) -p $(POLICYVERS) -o $@

built_odm_cil := $(LOCAL_BUILT_MODULE)
odm_policy.conf :=
odm_policy_raw :=
endif

#################################
include $(CLEAR_VARS)

LOCAL_MODULE := precompiled_sepolicy
LOCAL_LICENSE_KINDS := SPDX-license-identifier-Apache-2.0 legacy_unencumbered
LOCAL_LICENSE_CONDITIONS := notice unencumbered
LOCAL_NOTICE_FILE := $(LOCAL_PATH)/NOTICE
LOCAL_MODULE_CLASS := ETC
LOCAL_MODULE_TAGS := optional
LOCAL_PROPRIETARY_MODULE := true

ifeq ($(BOARD_USES_ODMIMAGE),true)
LOCAL_MODULE_PATH := $(TARGET_OUT_ODM)/etc/selinux
else
LOCAL_MODULE_PATH := $(TARGET_OUT_VENDOR)/etc/selinux
endif

include $(BUILD_SYSTEM)/base_rules.mk

all_cil_files := \
    $(built_plat_cil) \
    $(TARGET_OUT)/etc/selinux/mapping/$(BOARD_SEPOLICY_VERS).cil \
    $(built_pub_vers_cil_$(BOARD_SEPOLICY_VERS)) \
    $(built_vendor_cil)

ifdef HAS_SYSTEM_EXT_SEPOLICY
all_cil_files += $(built_system_ext_cil)
endif

ifdef HAS_SYSTEM_EXT_PUBLIC_SEPOLICY
all_cil_files += $(TARGET_OUT_SYSTEM_EXT)/etc/selinux/mapping/$(BOARD_SEPOLICY_VERS).cil
endif

ifdef HAS_PRODUCT_SEPOLICY
all_cil_files += $(built_product_cil)
endif

ifdef HAS_PRODUCT_PUBLIC_SEPOLICY
all_cil_files += $(TARGET_OUT_PRODUCT)/etc/selinux/mapping/$(BOARD_SEPOLICY_VERS).cil
endif

ifdef BOARD_ODM_SEPOLICY_DIRS
all_cil_files += $(built_odm_cil)
endif

$(LOCAL_BUILT_MODULE): PRIVATE_CIL_FILES := $(all_cil_files)
# Neverallow checks are skipped in a mixed build target.
$(LOCAL_BUILT_MODULE): PRIVATE_NEVERALLOW_ARG := $(if $(filter $(PLATFORM_SEPOLICY_VERSION),$(BOARD_SEPOLICY_VERS)),$(NEVERALLOW_ARG),-N)
$(LOCAL_BUILT_MODULE): $(HOST_OUT_EXECUTABLES)/secilc $(all_cil_files) $(built_sepolicy_neverallows)
	$(hide) $(HOST_OUT_EXECUTABLES)/secilc -m -M true -G -c $(POLICYVERS) $(PRIVATE_NEVERALLOW_ARG) \
		$(PRIVATE_CIL_FILES) -o $@ -f /dev/null

built_precompiled_sepolicy := $(LOCAL_BUILT_MODULE)
all_cil_files :=

#################################
# Precompiled sepolicy is loaded if and only if:
# - plat_sepolicy_and_mapping.sha256 equals
#   precompiled_sepolicy.plat_sepolicy_and_mapping.sha256
# AND
# - system_ext_sepolicy_and_mapping.sha256 equals
#   precompiled_sepolicy.system_ext_sepolicy_and_mapping.sha256
# AND
# - product_sepolicy_and_mapping.sha256 equals
#   precompiled_sepolicy.product_sepolicy_and_mapping.sha256
# See system/core/init/selinux.cpp for details.
#################################

#################################
include $(CLEAR_VARS)
# build this target so that we can still perform neverallow checks

LOCAL_MODULE := sepolicy
LOCAL_LICENSE_KINDS := SPDX-license-identifier-Apache-2.0 legacy_unencumbered
LOCAL_LICENSE_CONDITIONS := notice unencumbered
LOCAL_NOTICE_FILE := $(LOCAL_PATH)/NOTICE
LOCAL_MODULE_CLASS := ETC
LOCAL_MODULE_TAGS := optional
LOCAL_MODULE_PATH := $(TARGET_ROOT_OUT)

include $(BUILD_SYSTEM)/base_rules.mk

all_cil_files := \
    $(built_plat_cil) \
    $(TARGET_OUT)/etc/selinux/mapping/$(BOARD_SEPOLICY_VERS).cil \
    $(built_pub_vers_cil_$(BOARD_SEPOLICY_VERS)) \
    $(built_vendor_cil)

ifdef HAS_SYSTEM_EXT_SEPOLICY
all_cil_files += $(built_system_ext_cil)
endif

ifdef HAS_SYSTEM_EXT_PUBLIC_SEPOLICY
all_cil_files += $(TARGET_OUT_SYSTEM_EXT)/etc/selinux/mapping/$(BOARD_SEPOLICY_VERS).cil
endif

ifdef HAS_PRODUCT_SEPOLICY
all_cil_files += $(built_product_cil)
endif

ifdef HAS_PRODUCT_PUBLIC_SEPOLICY
all_cil_files += $(TARGET_OUT_PRODUCT)/etc/selinux/mapping/$(BOARD_SEPOLICY_VERS).cil
endif

ifdef BOARD_ODM_SEPOLICY_DIRS
all_cil_files += $(built_odm_cil)
endif

$(LOCAL_BUILT_MODULE): PRIVATE_CIL_FILES := $(all_cil_files)
# Neverallow checks are skipped in a mixed build target.
$(LOCAL_BUILT_MODULE): PRIVATE_NEVERALLOW_ARG := $(if $(filter $(PLATFORM_SEPOLICY_VERSION),$(BOARD_SEPOLICY_VERS)),$(NEVERALLOW_ARG),-N)
$(LOCAL_BUILT_MODULE): $(HOST_OUT_EXECUTABLES)/secilc $(HOST_OUT_EXECUTABLES)/sepolicy-analyze $(all_cil_files) \
$(built_sepolicy_neverallows)
	@mkdir -p $(dir $@)
	$(hide) $< -m -M true -G -c $(POLICYVERS) $(PRIVATE_NEVERALLOW_ARG) $(PRIVATE_CIL_FILES) -o $@.tmp -f /dev/null
	$(hide) $(HOST_OUT_EXECUTABLES)/sepolicy-analyze $@.tmp permissive > $@.permissivedomains
	$(hide) if [ "$(TARGET_BUILD_VARIANT)" = "user" -a -s $@.permissivedomains ]; then \
		echo "==========" 1>&2; \
		echo "ERROR: permissive domains not allowed in user builds" 1>&2; \
		echo "List of invalid domains:" 1>&2; \
		cat $@.permissivedomains 1>&2; \
		exit 1; \
		fi
	$(hide) mv $@.tmp $@

built_sepolicy := $(LOCAL_BUILT_MODULE)
all_cil_files :=

#################################
include $(CLEAR_VARS)

# keep concrete sepolicy for neverallow checks
# If SELINUX_IGNORE_NEVERALLOWS is set, we use sed to remove the neverallow lines before compiling.

LOCAL_MODULE := sepolicy.recovery
LOCAL_LICENSE_KINDS := SPDX-license-identifier-Apache-2.0 legacy_unencumbered
LOCAL_LICENSE_CONDITIONS := notice unencumbered
LOCAL_NOTICE_FILE := $(LOCAL_PATH)/NOTICE
LOCAL_MODULE_STEM := sepolicy
LOCAL_MODULE_CLASS := ETC
LOCAL_MODULE_TAGS := optional
LOCAL_MODULE_PATH := $(TARGET_RECOVERY_ROOT_OUT)

include $(BUILD_SYSTEM)/base_rules.mk

# We use vendor version's policy files because recovery partition is vendor-owned.
policy_files := $(call build_policy, $(sepolicy_build_files), \
  $(plat_public_policy_$(BOARD_SEPOLICY_VERS)) $(plat_private_policy_$(BOARD_SEPOLICY_VERS)) \
  $(system_ext_public_policy_$(BOARD_SEPOLICY_VERS)) $(system_ext_private_policy_$(BOARD_SEPOLICY_VERS)) \
  $(product_public_policy_$(BOARD_SEPOLICY_VERS)) $(product_private_policy_$(BOARD_SEPOLICY_VERS)) \
  $(BOARD_PLAT_VENDOR_POLICY) $(BOARD_VENDOR_SEPOLICY_DIRS) $(BOARD_ODM_SEPOLICY_DIRS))
sepolicy.recovery.conf := $(intermediates)/sepolicy.recovery.conf
$(sepolicy.recovery.conf): PRIVATE_MLS_SENS := $(MLS_SENS)
$(sepolicy.recovery.conf): PRIVATE_MLS_CATS := $(MLS_CATS)
$(sepolicy.recovery.conf): PRIVATE_TARGET_BUILD_VARIANT := $(TARGET_BUILD_VARIANT)
$(sepolicy.recovery.conf): PRIVATE_TGT_ARCH := $(my_target_arch)
$(sepolicy.recovery.conf): PRIVATE_TGT_WITH_ASAN := $(with_asan)
$(sepolicy.recovery.conf): PRIVATE_TGT_WITH_NATIVE_COVERAGE := $(with_native_coverage)
$(sepolicy.recovery.conf): PRIVATE_ADDITIONAL_M4DEFS := $(LOCAL_ADDITIONAL_M4DEFS)
$(sepolicy.recovery.conf): PRIVATE_TGT_RECOVERY := -D target_recovery=true
$(sepolicy.recovery.conf): PRIVATE_ENFORCE_DEBUGFS_RESTRICTION := $(enforce_debugfs_restriction)
$(sepolicy.recovery.conf): PRIVATE_POLICY_FILES := $(policy_files)
$(sepolicy.recovery.conf): $(policy_files) $(M4)
	$(transform-policy-to-conf)
	$(hide) sed '/^\s*dontaudit.*;/d' $@ | sed '/^\s*dontaudit/,/;/d' > $@.dontaudit

ifeq ($(SELINUX_IGNORE_NEVERALLOWS),true)
	$(hide) sed -z 's/\n\s*neverallow[^;]*;/\n/g' $@ > $@.neverallow
	$(hide) mv $@.neverallow $@
endif

$(LOCAL_BUILT_MODULE): $(sepolicy.recovery.conf) $(HOST_OUT_EXECUTABLES)/checkpolicy \
                       $(HOST_OUT_EXECUTABLES)/sepolicy-analyze
	@mkdir -p $(dir $@)
	$(hide) $(CHECKPOLICY_ASAN_OPTIONS) $(HOST_OUT_EXECUTABLES)/checkpolicy -M -c \
		$(POLICYVERS) -o $@.tmp $<
	$(hide) $(HOST_OUT_EXECUTABLES)/sepolicy-analyze $@.tmp permissive > $@.permissivedomains
	$(hide) if [ "$(TARGET_BUILD_VARIANT)" = "user" -a -s $@.permissivedomains ]; then \
		echo "==========" 1>&2; \
		echo "ERROR: permissive domains not allowed in user builds" 1>&2; \
		echo "List of invalid domains:" 1>&2; \
		cat $@.permissivedomains 1>&2; \
		exit 1; \
		fi
	$(hide) mv $@.tmp $@

sepolicy.recovery.conf :=

##################################
# TODO - remove this.   Keep around until we get the filesystem creation stuff taken care of.
#
include $(CLEAR_VARS)

LOCAL_MODULE := file_contexts.bin
LOCAL_LICENSE_KINDS := SPDX-license-identifier-Apache-2.0 legacy_unencumbered
LOCAL_LICENSE_CONDITIONS := notice unencumbered
LOCAL_NOTICE_FILE := $(LOCAL_PATH)/NOTICE
LOCAL_MODULE_CLASS := ETC
LOCAL_MODULE_TAGS := optional
LOCAL_MODULE_PATH := $(TARGET_ROOT_OUT)

include $(BUILD_SYSTEM)/base_rules.mk

# The file_contexts.bin is built in the following way:
# 1. Collect all file_contexts files in THIS repository and process them with
#    m4 into a tmp file called file_contexts.local.tmp.
# 2. Collect all file_contexts files from LOCAL_FILE_CONTEXTS of installed
#    modules with m4 with a tmp file called file_contexts.modules.tmp.
# 3. Collect all device specific file_contexts files and process them with m4
#    into a tmp file called file_contexts.device.tmp.
# 4. Run checkfc -e (allow no device fc entries ie empty) and fc_sort on
#    file_contexts.device.tmp and output to file_contexts.device.sorted.tmp.
# 5. Concatenate file_contexts.local.tmp, file_contexts.modules.tmp and
#    file_contexts.device.sorted.tmp into file_contexts.concat.tmp.
# 6. Run checkfc and sefcontext_compile on file_contexts.concat.tmp to produce
#    file_contexts.bin.
#
#  Note: That a newline file is placed between each file_context file found to
#        ensure a proper build when an fc file is missing an ending newline.

local_fc_files := $(call build_policy, file_contexts, $(PLAT_PRIVATE_POLICY))

ifdef HAS_SYSTEM_EXT_SEPOLICY_DIR
local_fc_files += $(call build_policy, file_contexts, $(SYSTEM_EXT_PRIVATE_POLICY))
endif

ifdef HAS_PRODUCT_SEPOLICY_DIR
local_fc_files += $(call build_policy, file_contexts, $(PRODUCT_PRIVATE_POLICY))
endif

ifneq ($(filter address,$(SANITIZE_TARGET)),)
  local_fc_files += $(wildcard $(addsuffix /file_contexts_asan, $(PLAT_PRIVATE_POLICY)))
endif
ifneq (,$(filter userdebug eng,$(TARGET_BUILD_VARIANT)))
  local_fc_files += $(wildcard $(addsuffix /file_contexts_overlayfs, $(PLAT_PRIVATE_POLICY)))
endif

file_contexts.local.tmp := $(intermediates)/file_contexts.local.tmp
$(call merge-fc-files,$(local_fc_files),$(file_contexts.local.tmp))

# The rule for file_contexts.modules.tmp is defined in build/make/core/Makefile.
# it gathers LOCAL_FILE_CONTEXTS from product_MODULES
file_contexts.modules.tmp := $(intermediates)/file_contexts.modules.tmp

device_fc_files := $(call build_vendor_policy, file_contexts)

ifdef BOARD_ODM_SEPOLICY_DIRS
device_fc_files += $(call build_odm_policy, file_contexts)
endif

file_contexts.device.tmp := $(intermediates)/file_contexts.device.tmp
$(file_contexts.device.tmp): PRIVATE_ADDITIONAL_M4DEFS := $(LOCAL_ADDITIONAL_M4DEFS)
$(file_contexts.device.tmp): PRIVATE_DEVICE_FC_FILES := $(device_fc_files)
$(file_contexts.device.tmp): $(device_fc_files) $(M4)
	@mkdir -p $(dir $@)
	$(hide) $(M4) --fatal-warnings -s $(PRIVATE_ADDITIONAL_M4DEFS) $(PRIVATE_DEVICE_FC_FILES) > $@

file_contexts.device.sorted.tmp := $(intermediates)/file_contexts.device.sorted.tmp
$(file_contexts.device.sorted.tmp): PRIVATE_SEPOLICY := $(built_sepolicy)
$(file_contexts.device.sorted.tmp): $(file_contexts.device.tmp) $(built_sepolicy) \
  $(HOST_OUT_EXECUTABLES)/fc_sort $(HOST_OUT_EXECUTABLES)/checkfc
	@mkdir -p $(dir $@)
	$(hide) $(HOST_OUT_EXECUTABLES)/checkfc -e $(PRIVATE_SEPOLICY) $<
	$(hide) $(HOST_OUT_EXECUTABLES)/fc_sort -i $< -o $@

file_contexts.concat.tmp := $(intermediates)/file_contexts.concat.tmp
$(call merge-fc-files,\
  $(file_contexts.local.tmp) $(file_contexts.modules.tmp) $(file_contexts.device.sorted.tmp),\
  $(file_contexts.concat.tmp))

$(LOCAL_BUILT_MODULE): PRIVATE_SEPOLICY := $(built_sepolicy)
$(LOCAL_BUILT_MODULE): $(file_contexts.concat.tmp) $(built_sepolicy) $(HOST_OUT_EXECUTABLES)/sefcontext_compile $(HOST_OUT_EXECUTABLES)/checkfc
	@mkdir -p $(dir $@)
	$(hide) $(HOST_OUT_EXECUTABLES)/checkfc $(PRIVATE_SEPOLICY) $<
	$(hide) $(HOST_OUT_EXECUTABLES)/sefcontext_compile -o $@ $<

built_fc := $(LOCAL_BUILT_MODULE)
local_fc_files :=
local_fcfiles_with_nl :=
device_fc_files :=
device_fcfiles_with_nl :=
file_contexts.concat.tmp :=
file_contexts.device.sorted.tmp :=
file_contexts.device.tmp :=
file_contexts.local.tmp :=
file_contexts.modules.tmp :=

##################################
include $(CLEAR_VARS)

LOCAL_MODULE := selinux_denial_metadata
LOCAL_LICENSE_KINDS := SPDX-license-identifier-Apache-2.0 legacy_unencumbered
LOCAL_LICENSE_CONDITIONS := notice unencumbered
LOCAL_NOTICE_FILE := $(LOCAL_PATH)/NOTICE
LOCAL_MODULE_CLASS := ETC
LOCAL_MODULE_PATH := $(TARGET_OUT_VENDOR)/etc/selinux

include $(BUILD_SYSTEM)/base_rules.mk

bug_files := $(call build_policy, bug_map, $(LOCAL_PATH) $(PLAT_PRIVATE_POLICY) $(PLAT_VENDOR_POLICY) $(BOARD_VENDOR_SEPOLICY_DIRS) $(PLAT_PUBLIC_POLICY))

$(LOCAL_BUILT_MODULE) : $(bug_files)
	@mkdir -p $(dir $@)
	cat $^ > $@

bug_files :=

##################################
include $(LOCAL_PATH)/seapp_contexts.mk

##################################
include $(LOCAL_PATH)/contexts_tests.mk

##################################
include $(CLEAR_VARS)

LOCAL_MODULE := vndservice_contexts
LOCAL_LICENSE_KINDS := SPDX-license-identifier-Apache-2.0 legacy_unencumbered
LOCAL_LICENSE_CONDITIONS := notice unencumbered
LOCAL_NOTICE_FILE := $(LOCAL_PATH)/NOTICE
LOCAL_MODULE_CLASS := ETC
LOCAL_MODULE_TAGS := optional
LOCAL_MODULE_PATH := $(TARGET_OUT_VENDOR)/etc/selinux

include $(BUILD_SYSTEM)/base_rules.mk

vnd_svcfiles := $(call build_policy, vndservice_contexts, $(PLAT_VENDOR_POLICY) $(BOARD_VENDOR_SEPOLICY_DIRS) $(REQD_MASK_POLICY))

vndservice_contexts.tmp := $(intermediates)/vndservice_contexts.tmp
$(vndservice_contexts.tmp): PRIVATE_SVC_FILES := $(vnd_svcfiles)
$(vndservice_contexts.tmp): PRIVATE_ADDITIONAL_M4DEFS := $(LOCAL_ADDITIONAL_M4DEFS)
$(vndservice_contexts.tmp): $(vnd_svcfiles) $(M4)
	@mkdir -p $(dir $@)
	$(hide) $(M4) --fatal-warnings -s $(PRIVATE_ADDITIONAL_M4DEFS) $(PRIVATE_SVC_FILES) > $@

$(LOCAL_BUILT_MODULE): PRIVATE_SEPOLICY := $(built_sepolicy)
$(LOCAL_BUILT_MODULE): $(vndservice_contexts.tmp) $(built_sepolicy) $(HOST_OUT_EXECUTABLES)/checkfc $(ACP)
	@mkdir -p $(dir $@)
	sed -e 's/#.*$$//' -e '/^$$/d' $< > $@
	$(hide) $(HOST_OUT_EXECUTABLES)/checkfc -e -v $(PRIVATE_SEPOLICY) $@

vnd_svcfiles :=
vndservice_contexts.tmp :=

##################################
include $(LOCAL_PATH)/mac_permissions.mk

#################################
include $(CLEAR_VARS)
LOCAL_MODULE := sepolicy_tests
LOCAL_LICENSE_KINDS := SPDX-license-identifier-Apache-2.0 legacy_unencumbered
LOCAL_LICENSE_CONDITIONS := notice unencumbered
LOCAL_NOTICE_FILE := $(LOCAL_PATH)/NOTICE
LOCAL_MODULE_CLASS := FAKE
LOCAL_MODULE_TAGS := optional

include $(BUILD_SYSTEM)/base_rules.mk

all_fc_files := $(TARGET_OUT)/etc/selinux/plat_file_contexts
all_fc_files += $(TARGET_OUT_VENDOR)/etc/selinux/vendor_file_contexts
ifdef HAS_SYSTEM_EXT_SEPOLICY_DIR
all_fc_files += $(TARGET_OUT_SYSTEM_EXT)/etc/selinux/system_ext_file_contexts
endif
ifdef HAS_PRODUCT_SEPOLICY_DIR
all_fc_files += $(TARGET_OUT_PRODUCT)/etc/selinux/product_file_contexts
endif
ifdef BOARD_ODM_SEPOLICY_DIRS
all_fc_files += $(TARGET_OUT_ODM)/etc/selinux/odm_file_contexts
endif
all_fc_args := $(foreach file, $(all_fc_files), -f $(file))

$(LOCAL_BUILT_MODULE): ALL_FC_ARGS := $(all_fc_args)
$(LOCAL_BUILT_MODULE): PRIVATE_SEPOLICY := $(built_sepolicy)
$(LOCAL_BUILT_MODULE): $(HOST_OUT_EXECUTABLES)/sepolicy_tests $(all_fc_files) $(built_sepolicy)
	@mkdir -p $(dir $@)
	$(hide) $(HOST_OUT_EXECUTABLES)/sepolicy_tests -l $(HOST_OUT)/lib64/libsepolwrap.$(SHAREDLIB_EXT) \
		$(ALL_FC_ARGS)  -p $(PRIVATE_SEPOLICY)
	$(hide) touch $@

##################################
intermediates := $(call intermediates-dir-for,ETC,built_plat_sepolicy,,,,)

# plat_sepolicy - the current platform policy only, built into a policy binary.
# TODO - this currently excludes partner extensions, but support should be added
# to enable partners to add their own compatibility mapping
policy_files := $(call build_policy, $(sepolicy_build_files), \
  $(PLAT_PUBLIC_POLICY) $(PLAT_PRIVATE_POLICY))
base_plat_policy.conf := $(intermediates)/base_plat_policy.conf
$(base_plat_policy.conf): PRIVATE_MLS_SENS := $(MLS_SENS)
$(base_plat_policy.conf): PRIVATE_MLS_CATS := $(MLS_CATS)
$(base_plat_policy.conf): PRIVATE_TARGET_BUILD_VARIANT := user
$(base_plat_policy.conf): PRIVATE_TGT_ARCH := $(my_target_arch)
$(base_plat_policy.conf): PRIVATE_TGT_WITH_ASAN := $(with_asan)
$(base_plat_policy.conf): PRIVATE_ADDITIONAL_M4DEFS := $(LOCAL_ADDITIONAL_M4DEFS)
$(base_plat_policy.conf): PRIVATE_SEPOLICY_SPLIT := true
$(base_plat_policy.conf): PRIVATE_COMPATIBLE_PROPERTY := $(PRODUCT_COMPATIBLE_PROPERTY)
$(base_plat_policy.conf): PRIVATE_TREBLE_SYSPROP_NEVERALLOW := $(treble_sysprop_neverallow)
$(base_plat_policy.conf): PRIVATE_ENFORCE_SYSPROP_OWNER := $(enforce_sysprop_owner)
$(base_plat_policy.conf): PRIVATE_ENFORCE_DEBUGFS_RESTRICTION := $(enforce_debugfs_restriction)
$(base_plat_policy.conf): PRIVATE_POLICY_FILES := $(policy_files)
$(base_plat_policy.conf): $(policy_files) $(M4)
	$(transform-policy-to-conf)
	$(hide) sed '/^\s*dontaudit.*;/d' $@ | sed '/^\s*dontaudit/,/;/d' > $@.dontaudit

built_plat_sepolicy := $(intermediates)/built_plat_sepolicy
$(built_plat_sepolicy): PRIVATE_ADDITIONAL_CIL_FILES := \
  $(call build_policy, $(sepolicy_build_cil_workaround_files), $(PLAT_PRIVATE_POLICY))
$(built_plat_sepolicy): PRIVATE_NEVERALLOW_ARG := $(NEVERALLOW_ARG)
$(built_plat_sepolicy): $(base_plat_policy.conf) $(HOST_OUT_EXECUTABLES)/checkpolicy \
$(HOST_OUT_EXECUTABLES)/secilc \
$(call build_policy, $(sepolicy_build_cil_workaround_files), $(PLAT_PRIVATE_POLICY)) \
$(built_sepolicy_neverallows)
	@mkdir -p $(dir $@)
	$(hide) $(CHECKPOLICY_ASAN_OPTIONS) $(HOST_OUT_EXECUTABLES)/checkpolicy -M -C -c \
		$(POLICYVERS) -o $@ $<
	$(hide) cat $(PRIVATE_ADDITIONAL_CIL_FILES) >> $@
	$(hide) $(HOST_OUT_EXECUTABLES)/secilc -m -M true -G -c $(POLICYVERS) $(PRIVATE_NEVERALLOW_ARG) $@ -o $@ -f /dev/null

policy_files := $(call build_policy, $(sepolicy_build_files), \
  $(PLAT_PUBLIC_POLICY) $(REQD_MASK_POLICY))
base_plat_pub_policy.conf := $(intermediates)/base_plat_pub_policy.conf
$(base_plat_pub_policy.conf): PRIVATE_MLS_SENS := $(MLS_SENS)
$(base_plat_pub_policy.conf): PRIVATE_MLS_CATS := $(MLS_CATS)
$(base_plat_pub_policy.conf): PRIVATE_TARGET_BUILD_VARIANT := user
$(base_plat_pub_policy.conf): PRIVATE_TGT_ARCH := $(my_target_arch)
$(base_plat_pub_policy.conf): PRIVATE_TGT_WITH_ASAN := $(with_asan)
$(base_plat_pub_policy.conf): PRIVATE_ADDITIONAL_M4DEFS := $(LOCAL_ADDITIONAL_M4DEFS)
$(base_plat_pub_policy.conf): PRIVATE_SEPOLICY_SPLIT := true
$(base_plat_pub_policy.conf): PRIVATE_COMPATIBLE_PROPERTY := $(PRODUCT_COMPATIBLE_PROPERTY)
$(base_plat_pub_policy.conf): PRIVATE_TREBLE_SYSPROP_NEVERALLOW := $(treble_sysprop_neverallow)
$(base_plat_pub_policy.conf): PRIVATE_ENFORCE_SYSPROP_OWNER := $(enforce_sysprop_owner)
$(base_plat_pub_policy.conf): PRIVATE_ENFORCE_DEBUGFS_RESTRICTION := $(enforce_debugfs_restriction)
$(base_plat_pub_policy.conf): PRIVATE_POLICY_FILES := $(policy_files)
$(base_plat_pub_policy.conf): $(policy_files) $(M4)
	$(transform-policy-to-conf)

base_plat_pub_policy.cil := $(intermediates)/base_plat_pub_policy.cil
$(base_plat_pub_policy.cil): PRIVATE_POL_CONF := $(base_plat_pub_policy.conf)
$(base_plat_pub_policy.cil): PRIVATE_REQD_MASK := $(reqd_policy_mask.cil)
$(base_plat_pub_policy.cil): $(HOST_OUT_EXECUTABLES)/checkpolicy \
$(HOST_OUT_EXECUTABLES)/build_sepolicy $(base_plat_pub_policy.conf) $(reqd_policy_mask.cil)
	@mkdir -p $(dir $@)
	$(hide) $(CHECKPOLICY_ASAN_OPTIONS) $< -C -M -c $(POLICYVERS) -o $@ $(PRIVATE_POL_CONF)
	$(hide) $(HOST_OUT_EXECUTABLES)/build_sepolicy -a $(HOST_OUT_EXECUTABLES) filter_out \
		-f $(PRIVATE_REQD_MASK) -t $@


#####################################################
intermediates := $(call intermediates-dir-for,ETC,built_system_ext_sepolicy,,,,)

policy_files := $(call build_policy, $(sepolicy_build_files), \
  $(PLAT_PUBLIC_POLICY) $(PLAT_PRIVATE_POLICY) $(SYSTEM_EXT_PUBLIC_POLICY) $(SYSTEM_EXT_PRIVATE_POLICY))
base_system_ext_policy.conf := $(intermediates)/base_system_ext_policy.conf
$(base_system_ext_policy.conf): PRIVATE_MLS_SENS := $(MLS_SENS)
$(base_system_ext_policy.conf): PRIVATE_MLS_CATS := $(MLS_CATS)
$(base_system_ext_policy.conf): PRIVATE_TARGET_BUILD_VARIANT := user
$(base_system_ext_policy.conf): PRIVATE_TGT_ARCH := $(my_target_arch)
$(base_system_ext_policy.conf): PRIVATE_TGT_WITH_ASAN := $(with_asan)
$(base_system_ext_policy.conf): PRIVATE_ADDITIONAL_M4DEFS := $(LOCAL_ADDITIONAL_M4DEFS)
$(base_system_ext_policy.conf): PRIVATE_SEPOLICY_SPLIT := true
$(base_system_ext_policy.conf): PRIVATE_COMPATIBLE_PROPERTY := $(PRODUCT_COMPATIBLE_PROPERTY)
$(base_system_ext_policy.conf): PRIVATE_TREBLE_SYSPROP_NEVERALLOW := $(treble_sysprop_neverallow)
$(base_system_ext_policy.conf): PRIVATE_POLICY_FILES := $(policy_files)
$(base_system_ext_policy.conf): $(policy_files) $(M4)
	$(transform-policy-to-conf)
	$(hide) sed '/^\s*dontaudit.*;/d' $@ | sed '/^\s*dontaudit/,/;/d' > $@.dontaudit

built_system_ext_sepolicy := $(intermediates)/built_system_ext_sepolicy
$(built_system_ext_sepolicy): PRIVATE_ADDITIONAL_CIL_FILES := \
  $(call build_policy, $(sepolicy_build_cil_workaround_files), $(PLAT_PRIVATE_POLICY))
$(built_system_ext_sepolicy): PRIVATE_NEVERALLOW_ARG := $(NEVERALLOW_ARG)
$(built_system_ext_sepolicy): $(base_system_ext_policy.conf) $(HOST_OUT_EXECUTABLES)/checkpolicy \
$(HOST_OUT_EXECUTABLES)/secilc \
$(call build_policy, $(sepolicy_build_cil_workaround_files), $(PLAT_PRIVATE_POLICY)) \
$(built_sepolicy_neverallows)
	@mkdir -p $(dir $@)
	$(hide) $(CHECKPOLICY_ASAN_OPTIONS) $(HOST_OUT_EXECUTABLES)/checkpolicy -M -C -c \
                $(POLICYVERS) -o $@ $<
	$(hide) cat $(PRIVATE_ADDITIONAL_CIL_FILES) >> $@
	$(hide) $(HOST_OUT_EXECUTABLES)/secilc -m -M true -G -c $(POLICYVERS) $(PRIVATE_NEVERALLOW_ARG) $@ -o $@ -f /dev/null

policy_files := $(call build_policy, $(sepolicy_build_files), \
$(PLAT_PUBLIC_POLICY) $(SYSTEM_EXT_PUBLIC_POLICY) $(REQD_MASK_POLICY))
base_system_ext_pub_policy.conf := $(intermediates)/base_system_ext_pub_policy.conf
$(base_system_ext_pub_policy.conf): PRIVATE_MLS_SENS := $(MLS_SENS)
$(base_system_ext_pub_policy.conf): PRIVATE_MLS_CATS := $(MLS_CATS)
$(base_system_ext_pub_policy.conf): PRIVATE_TARGET_BUILD_VARIANT := user
$(base_system_ext_pub_policy.conf): PRIVATE_TGT_ARCH := $(my_target_arch)
$(base_system_ext_pub_policy.conf): PRIVATE_TGT_WITH_ASAN := $(with_asan)
$(base_system_ext_pub_policy.conf): PRIVATE_ADDITIONAL_M4DEFS := $(LOCAL_ADDITIONAL_M4DEFS)
$(base_system_ext_pub_policy.conf): PRIVATE_SEPOLICY_SPLIT := true
$(base_system_ext_pub_policy.conf): PRIVATE_COMPATIBLE_PROPERTY := $(PRODUCT_COMPATIBLE_PROPERTY)
$(base_system_ext_pub_policy.conf): PRIVATE_TREBLE_SYSPROP_NEVERALLOW := $(treble_sysprop_neverallow)
$(base_system_ext_pub_policy.conf): PRIVATE_POLICY_FILES := $(policy_files)
$(base_system_ext_pub_policy.conf): $(policy_files) $(M4)
	$(transform-policy-to-conf)

base_system_ext_pub_policy.cil := $(intermediates)/base_system_ext_pub_policy.cil
$(base_system_ext_pub_policy.cil): PRIVATE_POL_CONF := $(base_system_ext_pub_policy.conf)
$(base_system_ext_pub_policy.cil): PRIVATE_REQD_MASK := $(reqd_policy_mask.cil)
$(base_system_ext_pub_policy.cil): $(HOST_OUT_EXECUTABLES)/checkpolicy \
$(HOST_OUT_EXECUTABLES)/build_sepolicy $(base_system_ext_pub_policy.conf) $(reqd_policy_mask.cil)
	@mkdir -p $(dir $@)
	$(hide) $(CHECKPOLICY_ASAN_OPTIONS) $< -C -M -c $(POLICYVERS) -o $@ $(PRIVATE_POL_CONF)
	$(hide) $(HOST_OUT_EXECUTABLES)/build_sepolicy -a $(HOST_OUT_EXECUTABLES) filter_out \
		-f $(PRIVATE_REQD_MASK) -t $@


################################################################################
intermediates := $(call intermediates-dir-for,ETC,built_product_sepolicy,,,,)

policy_files := $(call build_policy, $(sepolicy_build_files), \
  $(PLAT_PUBLIC_POLICY) $(PLAT_PRIVATE_POLICY) $(SYSTEM_EXT_PUBLIC_POLICY) $(SYSTEM_EXT_PRIVATE_POLICY) \
  $(PRODUCT_PUBLIC_POLICY) $(PRODUCT_PRIVATE_POLICY))
base_product_policy.conf := $(intermediates)/base_product_policy.conf
$(base_product_policy.conf): PRIVATE_MLS_SENS := $(MLS_SENS)
$(base_product_policy.conf): PRIVATE_MLS_CATS := $(MLS_CATS)
$(base_product_policy.conf): PRIVATE_TARGET_BUILD_VARIANT := user
$(base_product_policy.conf): PRIVATE_TGT_ARCH := $(my_target_arch)
$(base_product_policy.conf): PRIVATE_TGT_WITH_ASAN := $(with_asan)
$(base_product_policy.conf): PRIVATE_ADDITIONAL_M4DEFS := $(LOCAL_ADDITIONAL_M4DEFS)
$(base_product_policy.conf): PRIVATE_SEPOLICY_SPLIT := true
$(base_product_policy.conf): PRIVATE_COMPATIBLE_PROPERTY := $(PRODUCT_COMPATIBLE_PROPERTY)
$(base_product_policy.conf): PRIVATE_TREBLE_SYSPROP_NEVERALLOW := $(treble_sysprop_neverallow)
$(base_product_policy.conf): PRIVATE_POLICY_FILES := $(policy_files)
$(base_product_policy.conf): $(policy_files) $(M4)
	$(transform-policy-to-conf)
	$(hide) sed '/^\s*dontaudit.*;/d' $@ | sed '/^\s*dontaudit/,/;/d' > $@.dontaudit

built_product_sepolicy := $(intermediates)/built_product_sepolicy
$(built_product_sepolicy): PRIVATE_ADDITIONAL_CIL_FILES := \
  $(call build_policy, $(sepolicy_build_cil_workaround_files), $(PLAT_PRIVATE_POLICY))
$(built_product_sepolicy): PRIVATE_NEVERALLOW_ARG := $(NEVERALLOW_ARG)
$(built_product_sepolicy): $(base_product_policy.conf) $(HOST_OUT_EXECUTABLES)/checkpolicy \
$(HOST_OUT_EXECUTABLES)/secilc \
$(call build_policy, $(sepolicy_build_cil_workaround_files), $(PLAT_PRIVATE_POLICY)) \
$(built_sepolicy_neverallows)
	@mkdir -p $(dir $@)
	$(hide) $(CHECKPOLICY_ASAN_OPTIONS) $(HOST_OUT_EXECUTABLES)/checkpolicy -M -C -c \
                $(POLICYVERS) -o $@ $<
	$(hide) cat $(PRIVATE_ADDITIONAL_CIL_FILES) >> $@
	$(hide) $(HOST_OUT_EXECUTABLES)/secilc -m -M true -G -c $(POLICYVERS) $(PRIVATE_NEVERALLOW_ARG) $@ -o $@ -f /dev/null


policy_files := $(call build_policy, $(sepolicy_build_files), \
$(PLAT_PUBLIC_POLICY) $(SYSTEM_EXT_PUBLIC_POLICY) $(PRODUCT_PUBLIC_POLICY) $(REQD_MASK_POLICY))
base_product_pub_policy.conf := $(intermediates)/base_product_pub_policy.conf
$(base_product_pub_policy.conf): PRIVATE_MLS_SENS := $(MLS_SENS)
$(base_product_pub_policy.conf): PRIVATE_MLS_CATS := $(MLS_CATS)
$(base_product_pub_policy.conf): PRIVATE_TARGET_BUILD_VARIANT := user
$(base_product_pub_policy.conf): PRIVATE_TGT_ARCH := $(my_target_arch)
$(base_product_pub_policy.conf): PRIVATE_TGT_WITH_ASAN := $(with_asan)
$(base_product_pub_policy.conf): PRIVATE_ADDITIONAL_M4DEFS := $(LOCAL_ADDITIONAL_M4DEFS)
$(base_product_pub_policy.conf): PRIVATE_SEPOLICY_SPLIT := true
$(base_product_pub_policy.conf): PRIVATE_COMPATIBLE_PROPERTY := $(PRODUCT_COMPATIBLE_PROPERTY)
$(base_product_pub_policy.conf): PRIVATE_TREBLE_SYSPROP_NEVERALLOW := $(treble_sysprop_neverallow)
$(base_product_pub_policy.conf): PRIVATE_POLICY_FILES := $(policy_files)
$(base_product_pub_policy.conf): $(policy_files) $(M4)
	$(transform-policy-to-conf)

base_product_pub_policy.cil := $(intermediates)/base_product_pub_policy.cil
$(base_product_pub_policy.cil): PRIVATE_POL_CONF := $(base_product_pub_policy.conf)
$(base_product_pub_policy.cil): PRIVATE_REQD_MASK := $(reqd_policy_mask.cil)
$(base_product_pub_policy.cil): $(HOST_OUT_EXECUTABLES)/checkpolicy \
$(HOST_OUT_EXECUTABLES)/build_sepolicy $(base_product_pub_policy.conf) $(reqd_policy_mask.cil)
	@mkdir -p $(dir $@)
	$(hide) $(CHECKPOLICY_ASAN_OPTIONS) $< -C -M -c $(POLICYVERS) -o $@ $(PRIVATE_POL_CONF)
	$(hide) $(HOST_OUT_EXECUTABLES)/build_sepolicy -a $(HOST_OUT_EXECUTABLES) filter_out \
                -f $(PRIVATE_REQD_MASK) -t $@

ifeq ($(PRODUCT_SEPOLICY_SPLIT),true)
# Tests for Treble compatibility of current platform policy and vendor policy of
# given release version.
version_under_treble_tests := 26.0
include $(LOCAL_PATH)/treble_sepolicy_tests_for_release.mk
version_under_treble_tests := 27.0
include $(LOCAL_PATH)/treble_sepolicy_tests_for_release.mk
version_under_treble_tests := 28.0
include $(LOCAL_PATH)/treble_sepolicy_tests_for_release.mk
version_under_treble_tests := 29.0
include $(LOCAL_PATH)/treble_sepolicy_tests_for_release.mk
version_under_treble_tests := 30.0
include $(LOCAL_PATH)/treble_sepolicy_tests_for_release.mk
version_under_treble_tests := 31.0
include $(LOCAL_PATH)/treble_sepolicy_tests_for_release.mk
endif  # PRODUCT_SEPOLICY_SPLIT

version_under_treble_tests := 26.0
include $(LOCAL_PATH)/compat.mk
version_under_treble_tests := 27.0
include $(LOCAL_PATH)/compat.mk
version_under_treble_tests := 28.0
include $(LOCAL_PATH)/compat.mk
version_under_treble_tests := 29.0
include $(LOCAL_PATH)/compat.mk
version_under_treble_tests := 30.0
include $(LOCAL_PATH)/compat.mk
version_under_treble_tests := 31.0
include $(LOCAL_PATH)/compat.mk

base_plat_policy.conf :=
base_plat_pub_policy.conf :=
plat_sepolicy :=
all_fc_files :=
all_fc_args :=

#################################
include $(CLEAR_VARS)
LOCAL_MODULE := sepolicy_freeze_test
LOCAL_LICENSE_KINDS := SPDX-license-identifier-Apache-2.0 legacy_unencumbered
LOCAL_LICENSE_CONDITIONS := notice unencumbered
LOCAL_NOTICE_FILE := $(LOCAL_PATH)/NOTICE
LOCAL_MODULE_CLASS := FAKE
LOCAL_MODULE_TAGS := optional

include $(BUILD_SYSTEM)/base_rules.mk

define ziplist
$(if $(and $1,$2), "$(firstword $1) $(firstword $2)"\
  $(call ziplist,$(wordlist 2,$(words $1),$1),$(wordlist 2,$(words $2),$2)))
endef

base_plat_public := $(LOCAL_PATH)/public
base_plat_private := $(LOCAL_PATH)/private
base_plat_public_prebuilt := \
  $(LOCAL_PATH)/prebuilts/api/$(PLATFORM_SEPOLICY_VERSION)/public
base_plat_private_prebuilt := \
  $(LOCAL_PATH)/prebuilts/api/$(PLATFORM_SEPOLICY_VERSION)/private

all_frozen_files := $(call build_policy,$(sepolicy_build_files), \
$(base_plat_public) $(base_plat_private) $(base_plat_public_prebuilt) $(base_plat_private_prebuilt))

$(LOCAL_BUILT_MODULE): PRIVATE_BASE_PLAT_PUBLIC := $(base_plat_public)
$(LOCAL_BUILT_MODULE): PRIVATE_BASE_PLAT_PRIVATE := $(base_plat_private)
$(LOCAL_BUILT_MODULE): PRIVATE_BASE_PLAT_PUBLIC_PREBUILT := $(base_plat_public_prebuilt)
$(LOCAL_BUILT_MODULE): PRIVATE_BASE_PLAT_PRIVATE_PREBUILT := $(base_plat_private_prebuilt)
$(LOCAL_BUILT_MODULE): PRIVATE_EXTRA := $(sort $(FREEZE_TEST_EXTRA_DIRS))
$(LOCAL_BUILT_MODULE): PRIVATE_EXTRA_PREBUILT := $(sort $(FREEZE_TEST_EXTRA_PREBUILT_DIRS))
$(LOCAL_BUILT_MODULE): $(all_frozen_files)
ifneq ($(PLATFORM_SEPOLICY_VERSION),$(TOT_SEPOLICY_VERSION))
	@diff -rq -x bug_map $(PRIVATE_BASE_PLAT_PUBLIC_PREBUILT) $(PRIVATE_BASE_PLAT_PUBLIC)
	@diff -rq -x bug_map $(PRIVATE_BASE_PLAT_PRIVATE_PREBUILT) $(PRIVATE_BASE_PLAT_PRIVATE)
ifneq (,$(FREEZE_TEST_EXTRA_DIRS)$(FREEZE_TEST_EXTRA_PREBUILT_DIRS))
	@for pair in $(call ziplist, $(PRIVATE_EXTRA_PREBUILT), $(PRIVATE_EXTRA)); \
		do diff -rq -x bug_map $$pair; done
endif # (,$(FREEZE_TEST_EXTRA_DIRS)$(FREEZE_TEST_EXTRA_PREBUILT_DIRS))
endif # ($(PLATFORM_SEPOLICY_VERSION),$(TOT_SEPOLICY_VERSION))
	$(hide) touch $@

base_plat_public :=
base_plat_private :=
base_plat_public_prebuilt :=
base_plat_private_prebuilt :=
all_frozen_files :=

#################################


build_vendor_policy :=
build_odm_policy :=
build_policy :=
built_plat_cil :=
built_system_ext_cil :=
built_product_cil :=
built_pub_vers_cil :=
built_plat_mapping_cil :=
built_system_ext_mapping_cil :=
built_product_mapping_cil :=
built_vendor_cil :=
built_odm_cil :=
built_precompiled_sepolicy :=
built_sepolicy :=
built_sepolicy_neverallows :=
built_plat_svc :=
built_vendor_svc :=
built_plat_sepolicy :=
treble_sysprop_neverallow :=
enforce_sysprop_owner :=
enforce_debugfs_restriction :=
mapping_policy :=
my_target_arch :=
pub_policy.cil :=
system_ext_pub_policy.cil :=
plat_pub_policy.cil :=
reqd_policy_mask.cil :=
sepolicy_build_files :=
sepolicy_build_cil_workaround_files :=
with_asan :=

include $(call all-makefiles-under,$(LOCAL_PATH))
