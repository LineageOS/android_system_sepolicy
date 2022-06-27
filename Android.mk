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
SYSTEM_EXT_PRIVATE_POLICY := $(SYSTEM_EXT_PRIVATE_SEPOLICY_DIRS)

PRODUCT_PUBLIC_POLICY := $(PRODUCT_PUBLIC_SEPOLICY_DIRS)
PRODUCT_PRIVATE_POLICY := $(PRODUCT_PRIVATE_SEPOLICY_DIRS)

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
$(strip $(foreach type, $(1), $(foreach file, $(addsuffix /$(type), $(2)), $(sort $(wildcard $(file))))))
endef

# Builds paths for all policy files found in BOARD_VENDOR_SEPOLICY_DIRS.
# $(1): the set of policy name paths to build
build_vendor_policy = $(call build_policy, $(1), $(BOARD_PLAT_VENDOR_POLICY) $(BOARD_VENDOR_SEPOLICY_DIRS))

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
    plat_bug_map \
    searchpolicy \

# This conditional inclusion closely mimics the conditional logic
# inside init/init.cpp for loading SELinux policy from files.
ifneq ($(PRODUCT_SEPOLICY_SPLIT),true)
# The following files are only allowed for non-Treble devices.
LOCAL_REQUIRED_MODULES += \
    sepolicy \

endif # ($(PRODUCT_SEPOLICY_SPLIT),true)

ifneq ($(with_asan),true)
ifneq ($(SELINUX_IGNORE_NEVERALLOWS),true)
LOCAL_REQUIRED_MODULES += \
    sepolicy_compat_test \

# HACK: sepolicy_test is implemented as genrule
# genrule modules aren't installable, so LOCAL_REQUIRED_MODULES doesn't work.
# Instead, use LOCAL_ADDITIONAL_DEPENDENCIES with intermediate output
LOCAL_ADDITIONAL_DEPENDENCIES += $(call intermediates-dir-for,ETC,sepolicy_test)/sepolicy_test

ifeq ($(PRODUCT_SEPOLICY_SPLIT),true)
LOCAL_REQUIRED_MODULES += \
    $(addprefix treble_sepolicy_tests_,$(PLATFORM_SEPOLICY_COMPAT_VERSIONS)) \

endif  # PRODUCT_SEPOLICY_SPLIT
endif  # SELINUX_IGNORE_NEVERALLOWS
endif  # with_asan

ifneq ($(PLATFORM_SEPOLICY_VERSION),$(TOT_SEPOLICY_VERSION))
LOCAL_REQUIRED_MODULES += \
    sepolicy_freeze_test
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
    system_ext_bug_map \
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
    vendor_service_contexts_test \
    vendor_hwservice_contexts \
    vendor_hwservice_contexts_test \
    vendor_bug_map \
    vndservice_contexts \
    vndservice_contexts_test \

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

# Builds an addtional userdebug sepolicy into the debug ramdisk.
LOCAL_REQUIRED_MODULES += \
    userdebug_plat_sepolicy.cil \

include $(BUILD_PHONY_PACKAGE)

##################################
# Policy files are now built with Android.bp. Grab them from intermediate.
# See Android.bp for details of policy files.
#
built_plat_cil := $(call intermediates-dir-for,ETC,plat_sepolicy.cil)/plat_sepolicy.cil

ifdef HAS_SYSTEM_EXT_SEPOLICY
built_system_ext_cil := $(call intermediates-dir-for,ETC,system_ext_sepolicy.cil)/system_ext_sepolicy.cil
endif # ifdef HAS_SYSTEM_EXT_SEPOLICY

ifdef HAS_PRODUCT_SEPOLICY
built_product_cil := $(call intermediates-dir-for,ETC,product_sepolicy.cil)/product_sepolicy.cil
endif # ifdef HAS_PRODUCT_SEPOLICY

built_sepolicy := $(call intermediates-dir-for,ETC,precompiled_sepolicy)/precompiled_sepolicy
built_sepolicy_neverallows := $(call intermediates-dir-for,ETC,sepolicy_neverallows)/sepolicy_neverallows
built_sepolicy_neverallows += $(call intermediates-dir-for,ETC,sepolicy_neverallows_vendor)/sepolicy_neverallows_vendor

#################################
# sepolicy is also built with Android.bp.
# This module is to keep compatibility with monolithic sepolicy devices.
include $(CLEAR_VARS)

LOCAL_MODULE := sepolicy
LOCAL_LICENSE_KINDS := SPDX-license-identifier-Apache-2.0 legacy_unencumbered
LOCAL_LICENSE_CONDITIONS := notice unencumbered
LOCAL_NOTICE_FILE := $(LOCAL_PATH)/NOTICE
LOCAL_MODULE_CLASS := ETC
LOCAL_MODULE_TAGS := optional
LOCAL_MODULE_PATH := $(TARGET_ROOT_OUT)

include $(BUILD_SYSTEM)/base_rules.mk

$(LOCAL_BUILT_MODULE): $(built_sepolicy)
	$(copy-file-to-target)

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
include $(LOCAL_PATH)/mac_permissions.mk

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

##################################
# Tests for Treble compatibility of current platform policy and vendor policy of
# given release version.
ifeq ($(PRODUCT_SEPOLICY_SPLIT),true)

built_plat_sepolicy       := $(call intermediates-dir-for,ETC,base_plat_sepolicy)/base_plat_sepolicy
built_system_ext_sepolicy := $(call intermediates-dir-for,ETC,base_system_ext_sepolicy)/base_system_ext_sepolicy
built_product_sepolicy    := $(call intermediates-dir-for,ETC,base_product_sepolicy)/base_product_sepolicy

base_plat_pub_policy.cil      := $(call intermediates-dir-for,ETC,base_plat_pub_policy.cil)/base_plat_pub_policy.cil
base_system_ext_pub_polcy.cil := $(call intermediates-dir-for,ETC,base_system_ext_pub_polcy.cil)/base_system_ext_pub_polcy.cil
base_product_pub_policy.cil   := $(call intermediates-dir-for,ETC,base_product_pub_policy.cil)/base_product_pub_policy.cil

$(foreach v,$(PLATFORM_SEPOLICY_COMPAT_VERSIONS), \
  $(eval version_under_treble_tests := $(v)) \
  $(eval include $(LOCAL_PATH)/treble_sepolicy_tests_for_release.mk) \
)
endif  # PRODUCT_SEPOLICY_SPLIT

built_plat_sepolicy :=
built_system_ext_sepolicy :=
built_product_sepolicy :=
base_plat_pub_policy.cil :=
base_system_ext_pub_polcy.cil :=
base_product_pub_policy.cil :=
all_fc_files :=
all_fc_args :=

#################################


build_vendor_policy :=
build_odm_policy :=
build_policy :=
built_plat_cil :=
built_system_ext_cil :=
built_product_cil :=
built_sepolicy :=
built_sepolicy_neverallows :=
built_plat_svc :=
built_vendor_svc :=
treble_sysprop_neverallow :=
enforce_sysprop_owner :=
enforce_debugfs_restriction :=
my_target_arch :=
sepolicy_build_files :=
sepolicy_build_cil_workaround_files :=
with_asan :=

include $(call all-makefiles-under,$(LOCAL_PATH))
