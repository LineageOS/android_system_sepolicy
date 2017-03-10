LOCAL_PATH:= $(call my-dir)

include $(CLEAR_VARS)

# SELinux policy version.
# Must be <= /sys/fs/selinux/policyvers reported by the Android kernel.
# Must be within the compatibility range reported by checkpolicy -V.
POLICYVERS ?= 30

MLS_SENS=1
MLS_CATS=1024

ifdef BOARD_SEPOLICY_REPLACE
$(error BOARD_SEPOLICY_REPLACE is no longer supported; please remove from your BoardConfig.mk or other .mk file.)
endif

ifdef BOARD_SEPOLICY_IGNORE
$(error BOARD_SEPOLICY_IGNORE is no longer supported; please remove from your BoardConfig.mk or other .mk file.)
endif

ifdef BOARD_SEPOLICY_UNION
$(warning BOARD_SEPOLICY_UNION is no longer required - all files found in BOARD_SEPOLICY_DIRS are implicitly unioned; please remove from your BoardConfig.mk or other .mk file.)
endif

ifdef BOARD_SEPOLICY_M4DEFS
LOCAL_ADDITIONAL_M4DEFS := $(addprefix -D, $(BOARD_SEPOLICY_M4DEFS))
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

# TODO: move to README when doing the README update and finalizing versioning.
# BOARD_SEPOLICY_VERS should contain the platform version identifier
#  corresponding to the platform on which the non-platform policy is to be
#  based.  If unspecified, this will build against the current public platform
#  policy in tree.
# BOARD_SEPOLICY_VERS_DIR should contain the public platform policy which
#  is associated with the given BOARD_SEPOLICY_VERS.  The policy therein will be
#  versioned according to the BOARD_SEPOLICY_VERS identifier and included as
#  part of the non-platform policy to ensure removal of access in future
#  platform policy does not break non-platform policy.
ifndef BOARD_SEPOLICY_VERS
$(warning BOARD_SEPOLICY_VERS not specified, assuming current platform version)
BOARD_SEPOLICY_VERS := current
BOARD_SEPOLICY_VERS_DIR := $(PLAT_PUBLIC_POLICY)
else
ifndef BOARD_SEPOLICY_VERS_DIR
$(error BOARD_SEPOLICY_VERS_DIR not specified for versioned sepolicy.)
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

# Builds paths for all policy files found in BOARD_SEPOLICY_DIRS.
# $(1): the set of policy name paths to build
build_device_policy = $(call build_policy, $(1), $(PLAT_VENDOR_POLICY) $(BOARD_SEPOLICY_DIRS))

# Add a file containing only a newline in-between each policy configuration
# 'contexts' file. This will allow OEM policy configuration files without a
# final newline (0x0A) to be built correctly by the m4(1) macro processor.
# $(1): the set of contexts file names.
# $(2): the file containing only 0x0A.
add_nl = $(foreach entry, $(1), $(subst $(entry), $(entry) $(2), $(entry)))

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

my_target_arch := $(TARGET_ARCH)
ifneq (,$(filter mips mips64,$(TARGET_ARCH)))
  my_target_arch := mips
endif

##################################
# reqd_policy_mask - a policy.conf file which contains only the bare minimum
# policy necessary to use checkpolicy.  This bare-minimum policy needs to be
# present in all policy.conf files, but should not necessarily be exported as
# part of the public policy.  The rules generated by reqd_policy_mask will allow
# the compilation of public policy and subsequent removal of CIL policy that
# should not be exported.

reqd_policy_mask.conf := $(intermediates)/reqd_policy_mask.conf
$(reqd_policy_mask.conf): PRIVATE_MLS_SENS := $(MLS_SENS)
$(reqd_policy_mask.conf): PRIVATE_MLS_CATS := $(MLS_CATS)
$(reqd_policy_mask.conf): PRIVATE_TGT_ARCH := $(my_target_arch)
$(reqd_policy_mask.conf): PRIVATE_ADDITIONAL_M4DEFS := $(LOCAL_ADDITIONAL_M4DEFS)
$(reqd_policy_mask.conf): $(call build_policy, $(sepolicy_build_files), $(REQD_MASK_POLICY))
	@mkdir -p $(dir $@)
	$(hide) m4 $(PRIVATE_ADDITIONAL_M4DEFS) \
		-D mls_num_sens=$(PRIVATE_MLS_SENS) -D mls_num_cats=$(PRIVATE_MLS_CATS) \
		-D target_build_variant=$(TARGET_BUILD_VARIANT) \
		-D target_with_dexpreopt=$(WITH_DEXPREOPT) \
		-D target_arch=$(PRIVATE_TGT_ARCH) \
		-s $^ > $@

reqd_policy_mask.cil := $(intermediates)/reqd_policy_mask.cil
$(reqd_policy_mask.cil): $(reqd_policy_mask.conf) $(HOST_OUT_EXECUTABLES)/checkpolicy
	@mkdir -p $(dir $@)
	$(hide) $(HOST_OUT_EXECUTABLES)/checkpolicy -C -M -c $(POLICYVERS) -o $@ $<

reqd_policy_mask.conf :=

##################################
# plat_pub_policy - policy that will be exported to be a part of non-platform
# policy corresponding to this platform version.  This is a limited subset of
# policy that would not compile in checkpolicy on its own.  To get around this
# limitation, add only the required files from private policy, which will
# generate CIL policy that will then be filtered out by the reqd_policy_mask.
plat_pub_policy.conf := $(intermediates)/plat_pub_policy.conf
$(plat_pub_policy.conf): PRIVATE_MLS_SENS := $(MLS_SENS)
$(plat_pub_policy.conf): PRIVATE_MLS_CATS := $(MLS_CATS)
$(plat_pub_policy.conf): PRIVATE_TGT_ARCH := $(my_target_arch)
$(plat_pub_policy.conf): PRIVATE_ADDITIONAL_M4DEFS := $(LOCAL_ADDITIONAL_M4DEFS)
$(plat_pub_policy.conf): $(call build_policy, $(sepolicy_build_files), \
$(BOARD_SEPOLICY_VERS_DIR) $(REQD_MASK_POLICY))
	@mkdir -p $(dir $@)
	 $(hide) m4 $(PRIVATE_ADDITIONAL_M4DEFS) \
		-D mls_num_sens=$(PRIVATE_MLS_SENS) -D mls_num_cats=$(PRIVATE_MLS_CATS) \
		-D target_build_variant=$(TARGET_BUILD_VARIANT) \
		-D target_with_dexpreopt=$(WITH_DEXPREOPT) \
		-D target_arch=$(PRIVATE_TGT_ARCH) \
		-s $^ > $@

plat_pub_policy.cil := $(intermediates)/plat_pub_policy.cil
$(plat_pub_policy.cil): PRIVATE_POL_CONF := $(plat_pub_policy.conf)
$(plat_pub_policy.cil): PRIVATE_REQD_MASK := $(reqd_policy_mask.cil)
$(plat_pub_policy.cil): $(HOST_OUT_EXECUTABLES)/checkpolicy $(plat_pub_policy.conf) $(reqd_policy_mask.cil)
	@mkdir -p $(dir $@)
	$(hide) $< -C -M -c $(POLICYVERS) -o $@.tmp $(PRIVATE_POL_CONF)
	$(hide) grep -Fxv -f $(PRIVATE_REQD_MASK) $@.tmp > $@

plat_pub_policy.conf :=

##################################
include $(CLEAR_VARS)

LOCAL_MODULE := sectxfile_nl
LOCAL_MODULE_CLASS := ETC
LOCAL_MODULE_TAGS := optional

# Create a file containing newline only to add between context config files
include $(BUILD_SYSTEM)/base_rules.mk
$(LOCAL_BUILT_MODULE):
	@mkdir -p $(dir $@)
	$(hide) echo > $@

built_nl := $(LOCAL_BUILT_MODULE)

#################################
include $(CLEAR_VARS)

LOCAL_MODULE := plat_sepolicy.cil
LOCAL_MODULE_CLASS := ETC
LOCAL_MODULE_TAGS := optional
LOCAL_MODULE_PATH := $(TARGET_OUT)/etc/selinux

include $(BUILD_SYSTEM)/base_rules.mk

# plat_policy.conf - A combination of the private and public platform policy
# which will ship with the device.  The platform will always reflect the most
# recent platform version and is not currently being attributized.
plat_policy.conf := $(intermediates)/plat_policy.conf
$(plat_policy.conf): PRIVATE_MLS_SENS := $(MLS_SENS)
$(plat_policy.conf): PRIVATE_MLS_CATS := $(MLS_CATS)
$(plat_policy.conf): PRIVATE_TGT_ARCH := $(my_target_arch)
$(plat_policy.conf): PRIVATE_ADDITIONAL_M4DEFS := $(LOCAL_ADDITIONAL_M4DEFS)
$(plat_policy.conf): $(call build_policy, $(sepolicy_build_files), \
$(PLAT_PUBLIC_POLICY) $(PLAT_PRIVATE_POLICY))
	@mkdir -p $(dir $@)
	$(hide) m4 $(PRIVATE_ADDITIONAL_M4DEFS) \
		-D mls_num_sens=$(PRIVATE_MLS_SENS) -D mls_num_cats=$(PRIVATE_MLS_CATS) \
		-D target_build_variant=$(TARGET_BUILD_VARIANT) \
		-D target_with_dexpreopt=$(WITH_DEXPREOPT) \
		-D target_arch=$(PRIVATE_TGT_ARCH) \
		-s $^ > $@
	$(hide) sed '/dontaudit/d' $@ > $@.dontaudit

plat_policy_nvr := $(intermediates)/plat_policy_nvr.cil
$(plat_policy_nvr): $(plat_policy.conf) $(HOST_OUT_EXECUTABLES)/checkpolicy
	@mkdir -p $(dir $@)
	$(hide) $(HOST_OUT_EXECUTABLES)/checkpolicy -M -C -c $(POLICYVERS) -o $@ $<

$(LOCAL_BUILT_MODULE): PRIVATE_CIL_FILES := $(plat_policy_nvr)
$(LOCAL_BUILT_MODULE): $(HOST_OUT_EXECUTABLES)/secilc $(plat_policy_nvr)
	@mkdir -p $(dir $@)
	# Strip out neverallow statements. They aren't needed on-device and their presence
	# significantly slows down on-device compilation (e.g., from 400 ms to 6,400 ms on
	# sailfish-eng).
	grep -v '^(neverallow' $(PRIVATE_CIL_FILES) > $@
	# Confirm that the resulting policy compiles
	$(hide) $(HOST_OUT_EXECUTABLES)/secilc -M true -c $(POLICYVERS) $@ -o /dev/null -f /dev/null

built_plat_cil := $(LOCAL_BUILT_MODULE)
plat_policy.conf :=

#################################
include $(CLEAR_VARS)

LOCAL_MODULE := plat_sepolicy.cil.sha256
LOCAL_MODULE_CLASS := ETC
LOCAL_MODULE_TAGS := optional
LOCAL_MODULE_PATH = $(TARGET_OUT)/etc/selinux

include $(BUILD_SYSTEM)/base_rules.mk

$(LOCAL_BUILT_MODULE): $(built_plat_cil)
	sha256sum $^ | cut -d' ' -f1 > $@

#################################
include $(CLEAR_VARS)

LOCAL_MODULE := mapping_sepolicy.cil
LOCAL_MODULE_CLASS := ETC
LOCAL_MODULE_TAGS := optional
LOCAL_PROPRIETARY_MODULE := true
LOCAL_MODULE_PATH := $(TARGET_OUT_VENDOR)/etc/selinux

include $(BUILD_SYSTEM)/base_rules.mk

# auto-generate the mapping file for current platform policy, since it needs to
# track platform policy development
current_mapping.cil := $(intermediates)/mapping/current.cil
$(current_mapping.cil) : PRIVATE_VERS := $(BOARD_SEPOLICY_VERS)
$(current_mapping.cil) : $(plat_pub_policy.cil) $(HOST_OUT_EXECUTABLES)/version_policy
	@mkdir -p $(dir $@)
	$(hide) $(HOST_OUT_EXECUTABLES)/version_policy -b $< -m -n $(PRIVATE_VERS) -o $@

ifeq ($(BOARD_SEPOLICY_VERS), current)
mapping_policy_nvr := $(current_mapping.cil)
else
mapping_policy_nvr := $(addsuffix /$(BOARD_SEPOLICY_VERS).cil, $(PLAT_PRIVATE_POLICY)/mapping)
endif

$(LOCAL_BUILT_MODULE): $(mapping_policy_nvr)
	# Strip out neverallow statements. They aren't needed on-device and their presence
	# significantly slows down on-device compilation (e.g., from 400 ms to 6,400 ms on
	# sailfish-eng).
	grep -v '^(neverallow' $< > $@

built_mapping_cil := $(LOCAL_BUILT_MODULE)
current_mapping.cil :=

#################################
include $(CLEAR_VARS)

LOCAL_MODULE := nonplat_sepolicy.cil
LOCAL_MODULE_CLASS := ETC
LOCAL_MODULE_TAGS := optional
LOCAL_PROPRIETARY_MODULE := true
LOCAL_MODULE_PATH := $(TARGET_OUT_VENDOR)/etc/selinux

include $(BUILD_SYSTEM)/base_rules.mk

# nonplat_policy.conf - A combination of the non-platform private, vendor and
# the exported platform policy associated with the version the non-platform
# policy targets.  This needs attributization and to be combined with the
# platform-provided policy.  Like plat_pub_policy.conf, this needs to make use
# of the reqd_policy_mask files from private policy in order to use checkpolicy.
nonplat_policy.conf := $(intermediates)/nonplat_policy.conf
$(nonplat_policy.conf): PRIVATE_MLS_SENS := $(MLS_SENS)
$(nonplat_policy.conf): PRIVATE_MLS_CATS := $(MLS_CATS)
$(nonplat_policy.conf): PRIVATE_TGT_ARCH := $(my_target_arch)
$(nonplat_policy.conf): PRIVATE_ADDITIONAL_M4DEFS := $(LOCAL_ADDITIONAL_M4DEFS)
$(nonplat_policy.conf): $(call build_policy, $(sepolicy_build_files), \
$(BOARD_SEPOLICY_VERS_DIR) $(REQD_MASK_POLICY) $(PLAT_VENDOR_POLICY) $(BOARD_SEPOLICY_DIRS))
	@mkdir -p $(dir $@)
	$(hide) m4 $(PRIVATE_ADDITIONAL_M4DEFS) \
		-D mls_num_sens=$(PRIVATE_MLS_SENS) -D mls_num_cats=$(PRIVATE_MLS_CATS) \
		-D target_build_variant=$(TARGET_BUILD_VARIANT) \
		-D target_with_dexpreopt=$(WITH_DEXPREOPT) \
		-D target_arch=$(PRIVATE_TGT_ARCH) \
		-s $^ > $@
	$(hide) sed '/dontaudit/d' $@ > $@.dontaudit

nonplat_policy_raw := $(intermediates)/nonplat_policy_raw.cil
$(nonplat_policy_raw): PRIVATE_POL_CONF := $(nonplat_policy.conf)
$(nonplat_policy_raw): PRIVATE_REQD_MASK := $(reqd_policy_mask.cil)
$(nonplat_policy_raw): $(HOST_OUT_EXECUTABLES)/checkpolicy $(nonplat_policy.conf) \
$(reqd_policy_mask.cil)
	@mkdir -p $(dir $@)
	$(hide) $< -C -M -c $(POLICYVERS) -o $@.tmp $(PRIVATE_POL_CONF)
	$(hide) grep -Fxv -f $(PRIVATE_REQD_MASK) $@.tmp > $@

nonplat_policy_nvr := $(intermediates)/nonplat_policy_nvr.cil
$(nonplat_policy_nvr) : PRIVATE_VERS := $(BOARD_SEPOLICY_VERS)
$(nonplat_policy_nvr) : PRIVATE_TGT_POL := $(nonplat_policy_raw)
$(nonplat_policy_nvr) : $(plat_pub_policy.cil) $(nonplat_policy_raw) \
$(HOST_OUT_EXECUTABLES)/version_policy
	@mkdir -p $(dir $@)
	$(HOST_OUT_EXECUTABLES)/version_policy -b $< -t $(PRIVATE_TGT_POL) -n $(PRIVATE_VERS) -o $@

$(LOCAL_BUILT_MODULE): PRIVATE_NONPLAT_CIL_FILES := $(nonplat_policy_nvr)
$(LOCAL_BUILT_MODULE): PRIVATE_DEP_CIL_FILES := $(built_plat_cil) $(built_mapping_cil)
$(LOCAL_BUILT_MODULE): $(HOST_OUT_EXECUTABLES)/secilc $(nonplat_policy_nvr) $(built_plat_cil) \
$(built_mapping_cil)
	@mkdir -p $(dir $@)
	# Strip out neverallow statements. They aren't needed on-device and their presence
	# significantly slows down on-device compilation (e.g., from 400 ms to 6,400 ms on
	# sailfish-eng).
	grep -v '^(neverallow' $(PRIVATE_NONPLAT_CIL_FILES) > $@
	# Confirm that the resulting policy compiles combined with platform and mapping policies
	$(hide) $(HOST_OUT_EXECUTABLES)/secilc -M true -c $(POLICYVERS) \
		$(PRIVATE_DEP_CIL_FILES) $@ -o /dev/null -f /dev/null

built_nonplat_cil := $(LOCAL_BUILT_MODULE)
nonplat_policy.conf :=
nonplat_policy_raw :=

#################################
include $(CLEAR_VARS)

LOCAL_MODULE := precompiled_sepolicy
LOCAL_MODULE_CLASS := ETC
LOCAL_MODULE_TAGS := optional
LOCAL_PROPRIETARY_MODULE := true
LOCAL_MODULE_PATH := $(TARGET_OUT_VENDOR)/etc/selinux

include $(BUILD_SYSTEM)/base_rules.mk

$(LOCAL_BUILT_MODULE): PRIVATE_CIL_FILES := \
$(built_plat_cil) $(built_mapping_cil) $(built_nonplat_cil)
$(LOCAL_BUILT_MODULE): $(HOST_OUT_EXECUTABLES)/secilc \
$(built_plat_cil) $(built_mapping_cil) $(built_nonplat_cil)
	$(hide) $(HOST_OUT_EXECUTABLES)/secilc -M true -c $(POLICYVERS) \
		$(PRIVATE_CIL_FILES) -o $@ -f /dev/null

built_precompiled_sepolicy := $(LOCAL_BUILT_MODULE)

#################################
# SHA-256 digest of the plat_sepolicy.cil file against which precompiled_policy was built.
#################################
include $(CLEAR_VARS)
LOCAL_MODULE := precompiled_sepolicy.plat.sha256
LOCAL_MODULE_CLASS := ETC
LOCAL_MODULE_TAGS := optional
LOCAL_PROPRIETARY_MODULE := true
LOCAL_MODULE_PATH := $(TARGET_OUT_VENDOR)/etc/selinux

include $(BUILD_SYSTEM)/base_rules.mk

$(LOCAL_BUILT_MODULE): PRIVATE_CIL_FILE := $(built_plat_cil)
$(LOCAL_BUILT_MODULE): $(built_precompiled_sepolicy) $(built_plat_cil)
	sha256sum $(PRIVATE_CIL_FILE) | cut -d' ' -f1 > $@

#################################
include $(CLEAR_VARS)
# build this target so that we can still perform neverallow checks

LOCAL_MODULE := sepolicy
LOCAL_MODULE_CLASS := ETC
LOCAL_MODULE_TAGS := optional
LOCAL_MODULE_PATH := $(TARGET_ROOT_OUT)

include $(BUILD_SYSTEM)/base_rules.mk

all_cil_files := \
    $(plat_policy_nvr) \
    $(mapping_policy_nvr) \
    $(nonplat_policy_nvr) \

$(LOCAL_BUILT_MODULE): PRIVATE_CIL_FILES := $(all_cil_files)
$(LOCAL_BUILT_MODULE): $(HOST_OUT_EXECUTABLES)/secilc $(HOST_OUT_EXECUTABLES)/sepolicy-analyze $(all_cil_files)
	@mkdir -p $(dir $@)
	$(hide) $< -M true -c $(POLICYVERS) $(PRIVATE_CIL_FILES) -o $@.tmp
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

LOCAL_MODULE := sepolicy.recovery
LOCAL_MODULE_CLASS := ETC
LOCAL_MODULE_TAGS := optional
LOCAL_MODULE_PATH := $(TARGET_ROOT_OUT)

include $(BUILD_SYSTEM)/base_rules.mk

plat_pub_policy.recovery.conf := $(intermediates)/plat_pub_policy.recovery.conf
$(plat_pub_policy.recovery.conf): PRIVATE_MLS_SENS := $(MLS_SENS)
$(plat_pub_policy.recovery.conf): PRIVATE_MLS_CATS := $(MLS_CATS)
$(plat_pub_policy.recovery.conf): PRIVATE_TGT_ARCH := $(my_target_arch)
$(plat_pub_policy.recovery.conf): PRIVATE_ADDITIONAL_M4DEFS := $(LOCAL_ADDITIONAL_M4DEFS)
$(plat_pub_policy.recovery.conf): $(call build_policy, $(sepolicy_build_files), \
$(BOARD_SEPOLICY_VERS_DIR) $(REQD_MASK_POLICY))
	@mkdir -p $(dir $@)
	$(hide) m4 $(PRIVATE_ADDITIONAL_M4DEFS) \
		-D mls_num_sens=$(PRIVATE_MLS_SENS) -D mls_num_cats=$(PRIVATE_MLS_CATS) \
		-D target_build_variant=$(TARGET_BUILD_VARIANT) \
		-D target_with_dexpreopt=$(WITH_DEXPREOPT) \
		-D target_arch=$(PRIVATE_TGT_ARCH) \
		-D target_recovery=true \
		-s $^ > $@

plat_pub_policy.recovery.cil := $(intermediates)/plat_pub_policy.recovery.cil
$(plat_pub_policy.recovery.cil): PRIVATE_POL_CONF := $(plat_pub_policy.recovery.conf)
$(plat_pub_policy.recovery.cil): PRIVATE_REQD_MASK := $(reqd_policy_mask.cil)
$(plat_pub_policy.recovery.cil): $(HOST_OUT_EXECUTABLES)/checkpolicy \
$(plat_pub_policy.recovery.conf) $(reqd_policy_mask.cil)
	@mkdir -p $(dir $@)
	$(hide) $< -C -M -c $(POLICYVERS) -o $@.tmp $(PRIVATE_POL_CONF)
	$(hide) grep -Fxv -f $(PRIVATE_REQD_MASK) $@.tmp > $@

plat_pub_policy.recovery.conf :=

plat_policy.recovery.conf := $(intermediates)/plat_policy.recovery.conf
$(plat_policy.recovery.conf): PRIVATE_MLS_SENS := $(MLS_SENS)
$(plat_policy.recovery.conf): PRIVATE_MLS_CATS := $(MLS_CATS)
$(plat_policy.recovery.conf): PRIVATE_TGT_ARCH := $(my_target_arch)
$(plat_policy.recovery.conf): PRIVATE_ADDITIONAL_M4DEFS := $(LOCAL_ADDITIONAL_M4DEFS)
$(plat_policy.recovery.conf): $(call build_policy, $(sepolicy_build_files), \
$(PLAT_PUBLIC_POLICY) $(PLAT_PRIVATE_POLICY))
	@mkdir -p $(dir $@)
	$(hide) m4 $(PRIVATE_ADDITIONAL_M4DEFS) \
		-D mls_num_sens=$(PRIVATE_MLS_SENS) -D mls_num_cats=$(PRIVATE_MLS_CATS) \
		-D target_build_variant=$(TARGET_BUILD_VARIANT) \
		-D target_with_dexpreopt=$(WITH_DEXPREOPT) \
		-D target_arch=$(PRIVATE_TGT_ARCH) \
		-D target_recovery=true \
		-s $^ > $@
	$(hide) sed '/dontaudit/d' $@ > $@.dontaudit

plat_policy_nvr.recovery := $(intermediates)/plat_policy_nvr.recovery.cil
$(plat_policy_nvr.recovery): $(plat_policy.recovery.conf) $(HOST_OUT_EXECUTABLES)/checkpolicy
	@mkdir -p $(dir $@)
	$(hide) $(HOST_OUT_EXECUTABLES)/checkpolicy -M -C -c $(POLICYVERS) -o $@ $<

plat_policy.recovery.conf :=

# auto-generate the mapping file for current platform policy, since it needs to
# track platform policy development
current_mapping.recovery.cil := $(intermediates)/mapping/current.recovery.cil
$(current_mapping.recovery.cil) : PRIVATE_VERS := $(BOARD_SEPOLICY_VERS)
$(current_mapping.recovery.cil) : $(plat_pub_policy.recovery.cil) $(HOST_OUT_EXECUTABLES)/version_policy
	@mkdir -p $(dir $@)
	$(hide) $(HOST_OUT_EXECUTABLES)/version_policy -b $< -m -n $(PRIVATE_VERS) -o $@

ifeq ($(BOARD_SEPOLICY_VERS), current)
mapping_policy_nvr.recovery := $(current_mapping.recovery.cil)
else
mapping_policy_nvr.recovery := $(addsuffix /$(BOARD_SEPOLICY_VERS).recovery.cil, \
$(PLAT_PRIVATE_POLICY)/mapping)
endif

current_mapping.recovery.cil :=

# nonplat_policy.recovery.conf - A combination of the non-platform private,
# vendor and the exported platform policy associated with the version the
# non-platform policy targets.  This needs attributization and to be combined
# with the platform-provided policy.  Like plat_pub_policy.recovery.conf, this
# needs to make use of the reqd_policy_mask files from private policy in order
# to use checkpolicy.
nonplat_policy.recovery.conf := $(intermediates)/nonplat_policy.recovery.conf
$(nonplat_policy.recovery.conf): PRIVATE_MLS_SENS := $(MLS_SENS)
$(nonplat_policy.recovery.conf): PRIVATE_MLS_CATS := $(MLS_CATS)
$(nonplat_policy.recovery.conf): PRIVATE_TGT_ARCH := $(my_target_arch)
$(nonplat_policy.recovery.conf): PRIVATE_ADDITIONAL_M4DEFS := $(LOCAL_ADDITIONAL_M4DEFS)
$(nonplat_policy.recovery.conf): $(call build_policy, $(sepolicy_build_files), \
$(BOARD_SEPOLICY_VERS_DIR) $(REQD_MASK_POLICY) $(PLAT_VENDOR_POLICY) $(BOARD_SEPOLICY_DIRS))
	@mkdir -p $(dir $@)
	$(hide) m4 $(PRIVATE_ADDITIONAL_M4DEFS) \
		-D mls_num_sens=$(PRIVATE_MLS_SENS) -D mls_num_cats=$(PRIVATE_MLS_CATS) \
		-D target_build_variant=$(TARGET_BUILD_VARIANT) \
		-D target_with_dexpreopt=$(WITH_DEXPREOPT) \
		-D target_arch=$(PRIVATE_TGT_ARCH) \
		-D target_recovery=true \
		-s $^ > $@
	$(hide) sed '/dontaudit/d' $@ > $@.dontaudit

nonplat_policy_raw.recovery := $(intermediates)/nonplat_policy_raw.recovery.cil
$(nonplat_policy_raw.recovery): PRIVATE_POL_CONF := $(nonplat_policy.recovery.conf)
$(nonplat_policy_raw.recovery): PRIVATE_REQD_MASK := $(reqd_policy_mask.cil)
$(nonplat_policy_raw.recovery): $(HOST_OUT_EXECUTABLES)/checkpolicy $(nonplat_policy.recovery.conf) \
$(reqd_policy_mask.cil)
	@mkdir -p $(dir $@)
	$(hide) $< -C -M -c $(POLICYVERS) -o $@.tmp $(PRIVATE_POL_CONF)
	$(hide) grep -Fxv -f $(PRIVATE_REQD_MASK) $@.tmp > $@

nonplat_policy_nvr.recovery := $(intermediates)/nonplat_policy_nvr.recovery.cil
$(nonplat_policy_nvr.recovery) : PRIVATE_VERS := $(BOARD_SEPOLICY_VERS)
$(nonplat_policy_nvr.recovery) : PRIVATE_TGT_POL := $(nonplat_policy_raw.recovery)
$(nonplat_policy_nvr.recovery) : $(plat_pub_policy.recovery.cil) $(nonplat_policy_raw.recovery) \
$(HOST_OUT_EXECUTABLES)/version_policy
	@mkdir -p $(dir $@)
	$(HOST_OUT_EXECUTABLES)/version_policy -b $< -t $(PRIVATE_TGT_POL) -n $(PRIVATE_VERS) -o $@

nonplat_policy.recovery.conf :=
nonplat_policy_raw.recovery :=

all_cil_files.recovery := \
    $(plat_policy_nvr.recovery) \
    $(mapping_policy_nvr.recovery) \
    $(nonplat_policy_nvr.recovery) \

$(LOCAL_BUILT_MODULE): PRIVATE_CIL_FILES := $(all_cil_files.recovery)
$(LOCAL_BUILT_MODULE): $(HOST_OUT_EXECUTABLES)/secilc $(HOST_OUT_EXECUTABLES)/sepolicy-analyze $(all_cil_files.recovery)
	@mkdir -p $(dir $@)
	$(hide) $< -M true -c $(POLICYVERS) $(PRIVATE_CIL_FILES) -o $@.tmp
	$(hide) $(HOST_OUT_EXECUTABLES)/sepolicy-analyze $@.tmp permissive > $@.permissivedomains
	$(hide) if [ "$(TARGET_BUILD_VARIANT)" = "user" -a -s $@.permissivedomains ]; then \
		echo "==========" 1>&2; \
		echo "ERROR: permissive domains not allowed in user builds" 1>&2; \
		echo "List of invalid domains:" 1>&2; \
		cat $@.permissivedomains 1>&2; \
		exit 1; \
		fi
	$(hide) mv $@.tmp $@

all_cil_files.recovery :=
plat_pub_policy.recovery.cil :=
plat_policy_nvr.recovery :=
mapping_policy_nvr.recovery :=
nonplat_policy_nvr.recovery :=

##################################
include $(CLEAR_VARS)

LOCAL_MODULE := general_sepolicy.conf
LOCAL_MODULE_CLASS := ETC
LOCAL_MODULE_TAGS := tests

include $(BUILD_SYSTEM)/base_rules.mk

$(LOCAL_BUILT_MODULE): PRIVATE_MLS_SENS := $(MLS_SENS)
$(LOCAL_BUILT_MODULE): PRIVATE_MLS_CATS := $(MLS_CATS)
$(LOCAL_BUILT_MODULE): PRIVATE_TGT_ARCH := $(my_target_arch)
$(LOCAL_BUILT_MODULE): $(call build_policy, $(sepolicy_build_files), \
$(PLAT_PUBLIC_POLICY) $(PLAT_PRIVATE_POLICY))
	mkdir -p $(dir $@)
	$(hide) m4 -D mls_num_sens=$(PRIVATE_MLS_SENS) -D mls_num_cats=$(PRIVATE_MLS_CATS) \
		-D target_build_variant=user \
		-D target_with_dexpreopt=$(WITH_DEXPREOPT) \
		-D target_arch=$(PRIVATE_TGT_ARCH) \
		-s $^ > $@
	$(hide) sed '/dontaudit/d' $@ > $@.dontaudit

built_general_sepolicy.conf := $(LOCAL_BUILT_MODULE)
exp_sepolicy_build_files :=

##################################
include $(CLEAR_VARS)

LOCAL_MODULE := sepolicy.general
LOCAL_MODULE_CLASS := ETC
LOCAL_MODULE_TAGS := tests

include $(BUILD_SYSTEM)/base_rules.mk

$(LOCAL_BUILT_MODULE): PRIVATE_BUILT_SEPOLICY.CONF := $(built_general_sepolicy.conf)
$(LOCAL_BUILT_MODULE): $(built_general_sepolicy.conf) $(HOST_OUT_EXECUTABLES)/checkpolicy
	@mkdir -p $(dir $@)
	$(hide) $(HOST_OUT_EXECUTABLES)/checkpolicy -M -c $(POLICYVERS) -o $@ $(PRIVATE_BUILT_SEPOLICY.CONF) > /dev/null

built_general_sepolicy := $(LOCAL_BUILT_MODULE)

##################################
# TODO - remove this.   Keep around until we get the filesystem creation stuff taken care of.
#
include $(CLEAR_VARS)

LOCAL_MODULE := file_contexts.bin
LOCAL_MODULE_CLASS := ETC
LOCAL_MODULE_TAGS := optional
LOCAL_MODULE_PATH := $(TARGET_ROOT_OUT)

include $(BUILD_SYSTEM)/base_rules.mk

# The file_contexts.bin is built in the following way:
# 1. Collect all file_contexts files in THIS repository and process them with
#    m4 into a tmp file called file_contexts.local.tmp.
# 2. Collect all device specific file_contexts files and process them with m4
#    into a tmp file called file_contexts.device.tmp.
# 3. Run checkfc -e (allow no device fc entries ie empty) and fc_sort on
#    file_contexts.device.tmp and output to file_contexts.device.sorted.tmp.
# 4. Concatenate file_contexts.local.tmp and file_contexts.device.tmp into
#    file_contexts.concat.tmp.
# 5. Run checkfc and sefcontext_compile on file_contexts.concat.tmp to produce
#    file_contexts.bin.
#
#  Note: That a newline file is placed between each file_context file found to
#        ensure a proper build when an fc file is missing an ending newline.

local_fc_files := $(PLAT_PRIVATE_POLICY)/file_contexts
ifneq ($(filter address,$(SANITIZE_TARGET)),)
  local_fc_files := $(local_fc_files) $(PLAT_PRIVATE_POLICY)/file_contexts_asan
endif
local_fcfiles_with_nl := $(call add_nl, $(local_fc_files), $(built_nl))

file_contexts.local.tmp := $(intermediates)/file_contexts.local.tmp
$(file_contexts.local.tmp): $(local_fcfiles_with_nl)
	@mkdir -p $(dir $@)
	$(hide) m4 -s $^ > $@

device_fc_files := $(call build_device_policy, file_contexts)
device_fcfiles_with_nl := $(call add_nl, $(device_fc_files), $(built_nl))

file_contexts.device.tmp := $(intermediates)/file_contexts.device.tmp
$(file_contexts.device.tmp): PRIVATE_ADDITIONAL_M4DEFS := $(LOCAL_ADDITIONAL_M4DEFS)
$(file_contexts.device.tmp): $(device_fcfiles_with_nl)
	@mkdir -p $(dir $@)
	$(hide) m4 -s $(PRIVATE_ADDITIONAL_M4DEFS) $^ > $@

file_contexts.device.sorted.tmp := $(intermediates)/file_contexts.device.sorted.tmp
$(file_contexts.device.sorted.tmp): PRIVATE_SEPOLICY := $(built_sepolicy)
$(file_contexts.device.sorted.tmp): $(file_contexts.device.tmp) $(built_sepolicy) $(HOST_OUT_EXECUTABLES)/fc_sort $(HOST_OUT_EXECUTABLES)/checkfc
	@mkdir -p $(dir $@)
	$(hide) $(HOST_OUT_EXECUTABLES)/checkfc -e $(PRIVATE_SEPOLICY) $<
	$(hide) $(HOST_OUT_EXECUTABLES)/fc_sort $< $@

file_contexts.concat.tmp := $(intermediates)/file_contexts.concat.tmp
$(file_contexts.concat.tmp): $(file_contexts.local.tmp) $(file_contexts.device.sorted.tmp)
	@mkdir -p $(dir $@)
	$(hide) m4 -s $^ > $@

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

##################################
include $(CLEAR_VARS)

LOCAL_MODULE := plat_file_contexts
LOCAL_MODULE_CLASS := ETC
LOCAL_MODULE_TAGS := optional
LOCAL_MODULE_PATH := $(TARGET_ROOT_OUT)

include $(BUILD_SYSTEM)/base_rules.mk

local_fc_files := $(PLAT_PRIVATE_POLICY)/file_contexts
ifneq ($(filter address,$(SANITIZE_TARGET)),)
  local_fc_files += $(PLAT_PRIVATE_POLICY)/file_contexts_asan
endif
local_fcfiles_with_nl := $(call add_nl, $(local_fc_files), $(built_nl))

$(LOCAL_BUILT_MODULE): PRIVATE_FC_FILES := $(local_fcfiles_with_nl)
$(LOCAL_BUILT_MODULE): PRIVATE_SEPOLICY := $(built_sepolicy)
$(LOCAL_BUILT_MODULE): PRIVATE_FC_SORT := $(HOST_OUT_EXECUTABLES)/fc_sort
$(LOCAL_BUILT_MODULE): $(HOST_OUT_EXECUTABLES)/checkfc $(HOST_OUT_EXECUTABLES)/fc_sort \
$(local_fcfiles_with_nl) $(built_sepolicy)
	@mkdir -p $(dir $@)
	$(hide) m4 -s $(PRIVATE_FC_FILES) > $@.tmp
	$(hide) $< $(PRIVATE_SEPOLICY) $@.tmp
	$(hide) $(PRIVATE_FC_SORT) $@.tmp $@

built_plat_fc := $(LOCAL_BUILT_MODULE)
local_fc_files :=
local_fcfiles_with_nl :=

##################################
include $(CLEAR_VARS)

LOCAL_MODULE := nonplat_file_contexts
LOCAL_MODULE_CLASS := ETC
LOCAL_MODULE_TAGS := optional
LOCAL_MODULE_PATH := $(TARGET_ROOT_OUT)

include $(BUILD_SYSTEM)/base_rules.mk

nonplat_fc_files := $(call build_device_policy, file_contexts)
nonplat_fcfiles_with_nl := $(call add_nl, $(nonplat_fc_files), $(built_nl))

$(LOCAL_BUILT_MODULE): PRIVATE_FC_FILES := $(nonplat_fcfiles_with_nl)
$(LOCAL_BUILT_MODULE): PRIVATE_SEPOLICY := $(built_sepolicy)
$(LOCAL_BUILT_MODULE): PRIVATE_FC_SORT := $(HOST_OUT_EXECUTABLES)/fc_sort
$(LOCAL_BUILT_MODULE): $(HOST_OUT_EXECUTABLES)/checkfc $(HOST_OUT_EXECUTABLES)/fc_sort \
$(nonplat_fcfiles_with_nl) $(built_sepolicy)
	@mkdir -p $(dir $@)
	$(hide) m4 -s $(PRIVATE_ADDITIONAL_M4DEFS) $(PRIVATE_FC_FILES) > $@.tmp
	$(hide) $< $(PRIVATE_SEPOLICY) $@.tmp
	$(hide) $(PRIVATE_FC_SORT) $@.tmp $@

built_nonplat_fc := $(LOCAL_BUILT_MODULE)
nonplat_fc_files :=
nonplat_fcfiles_with_nl :=

##################################
include $(CLEAR_VARS)
LOCAL_MODULE := plat_seapp_contexts
LOCAL_MODULE_CLASS := ETC
LOCAL_MODULE_TAGS := optional
ifeq ($(PRODUCT_FULL_TREBLE),true)
LOCAL_MODULE_PATH := $(TARGET_OUT)/etc/selinux
else
LOCAL_MODULE_PATH := $(TARGET_ROOT_OUT)
endif

include $(BUILD_SYSTEM)/base_rules.mk

plat_sc_files := $(call build_policy, seapp_contexts, $(PLAT_PRIVATE_POLICY))

$(LOCAL_BUILT_MODULE): PRIVATE_SEPOLICY := $(built_sepolicy)
$(LOCAL_BUILT_MODULE): PRIVATE_SC_FILES := $(plat_sc_files)
$(LOCAL_BUILT_MODULE): $(built_sepolicy) $(plat_sc_files) $(HOST_OUT_EXECUTABLES)/checkseapp
	@mkdir -p $(dir $@)
	$(hide) $(HOST_OUT_EXECUTABLES)/checkseapp -p $(PRIVATE_SEPOLICY) -o $@ $(PRIVATE_SC_FILES)

built_plat_sc := $(LOCAL_BUILT_MODULE)
plat_sc_files :=

##################################
include $(CLEAR_VARS)
LOCAL_MODULE := nonplat_seapp_contexts
LOCAL_MODULE_CLASS := ETC
LOCAL_MODULE_TAGS := optional
ifeq ($(PRODUCT_FULL_TREBLE),true)
LOCAL_MODULE_PATH := $(TARGET_OUT_VENDOR)/etc/selinux
else
LOCAL_MODULE_PATH := $(TARGET_ROOT_OUT)
endif

include $(BUILD_SYSTEM)/base_rules.mk

nonplat_sc_files := $(call build_policy, seapp_contexts, $(PLAT_VENDOR_POLICY) $(BOARD_SEPOLICY_DIRS) $(REQD_MASK_POLICY))
plat_sc_neverallow_files := $(addprefix $(PLAT_PRIVATE_POLICY)/, seapp_contexts)

$(LOCAL_BUILT_MODULE): PRIVATE_SEPOLICY := $(built_sepolicy)
$(LOCAL_BUILT_MODULE): PRIVATE_SC_FILES := $(nonplat_sc_files)
$(LOCAL_BUILT_MODULE): PRIVATE_SC_NEVERALLOW_FILES := $(plat_sc_neverallow_files)
$(LOCAL_BUILT_MODULE): $(built_sepolicy) $(nonplat_sc_files) $(HOST_OUT_EXECUTABLES)/checkseapp $(plat_sc_neverallow_files)
	@mkdir -p $(dir $@)
	$(hide) grep -ie '^neverallow' $(PRIVATE_SC_NEVERALLOW_FILES) > plat_seapp_neverallows.tmp
	$(hide) $(HOST_OUT_EXECUTABLES)/checkseapp -p $(PRIVATE_SEPOLICY) -o $@ $(PRIVATE_SC_FILES) plat_seapp_neverallows.tmp

built_nonplat_sc := $(LOCAL_BUILT_MODULE)
nonplat_sc_files :=

##################################
include $(CLEAR_VARS)
LOCAL_MODULE := plat_seapp_neverallows
LOCAL_MODULE_CLASS := ETC
LOCAL_MODULE_TAGS := tests

include $(BUILD_SYSTEM)/base_rules.mk

$(LOCAL_BUILT_MODULE): $(plat_sc_neverallow_files)
	@mkdir -p $(dir $@)
	- $(hide) grep -ie '^neverallow' $< > $@

plat_sc_neverallow_files :=

##################################
include $(CLEAR_VARS)

LOCAL_MODULE := plat_property_contexts
LOCAL_MODULE_CLASS := ETC
LOCAL_MODULE_TAGS := optional
# TODO: Change module path to TARGET_SYSTEM_OUT after b/27805372
LOCAL_MODULE_PATH := $(TARGET_ROOT_OUT)

include $(BUILD_SYSTEM)/base_rules.mk

plat_pcfiles := $(call build_policy, property_contexts, $(PLAT_PRIVATE_POLICY))

plat_property_contexts.tmp := $(intermediates)/plat_property_contexts.tmp
$(plat_property_contexts.tmp): PRIVATE_PC_FILES := $(plat_pcfiles)
$(plat_property_contexts.tmp): PRIVATE_ADDITIONAL_M4DEFS := $(LOCAL_ADDITIONAL_M4DEFS)
$(plat_property_contexts.tmp): $(plat_pcfiles)
	@mkdir -p $(dir $@)
	$(hide) m4 -s $(PRIVATE_ADDITIONAL_M4DEFS) $(PRIVATE_PC_FILES) > $@


$(LOCAL_BUILT_MODULE): PRIVATE_SEPOLICY := $(built_sepolicy)
$(LOCAL_BUILT_MODULE): $(plat_property_contexts.tmp) $(built_sepolicy) $(HOST_OUT_EXECUTABLES)/checkfc
	@mkdir -p $(dir $@)
	$(hide) sed -e 's/#.*$$//' -e '/^$$/d' $< | sort -u -o $@
	$(hide) $(HOST_OUT_EXECUTABLES)/checkfc -p $(PRIVATE_SEPOLICY) $@

built_plat_pc := $(LOCAL_BUILT_MODULE)
plat_pcfiles :=
plat_property_contexts.tmp :=

##################################
include $(CLEAR_VARS)

LOCAL_MODULE := nonplat_property_contexts
LOCAL_MODULE_CLASS := ETC
LOCAL_MODULE_TAGS := optional
# TODO: Change module path to TARGET_SYSTEM_OUT after b/27805372
LOCAL_MODULE_PATH := $(TARGET_ROOT_OUT)

include $(BUILD_SYSTEM)/base_rules.mk

nonplat_pcfiles := $(call build_policy, property_contexts, $(PLAT_VENDOR_POLICY) $(BOARD_SEPOLICY_DIRS) $(REQD_MASK_POLICY))

nonplat_property_contexts.tmp := $(intermediates)/nonplat_property_contexts.tmp
$(nonplat_property_contexts.tmp): PRIVATE_PC_FILES := $(nonplat_pcfiles)
$(nonplat_property_contexts.tmp): PRIVATE_ADDITIONAL_M4DEFS := $(LOCAL_ADDITIONAL_M4DEFS)
$(nonplat_property_contexts.tmp): $(nonplat_pcfiles)
	@mkdir -p $(dir $@)
	$(hide) m4 -s $(PRIVATE_ADDITIONAL_M4DEFS) $(PRIVATE_PC_FILES) > $@


$(LOCAL_BUILT_MODULE): PRIVATE_SEPOLICY := $(built_sepolicy)
$(LOCAL_BUILT_MODULE): $(nonplat_property_contexts.tmp) $(built_sepolicy) $(HOST_OUT_EXECUTABLES)/checkfc
	@mkdir -p $(dir $@)
	$(hide) sed -e 's/#.*$$//' -e '/^$$/d' $< | sort -u -o $@
	$(hide) $(HOST_OUT_EXECUTABLES)/checkfc -p $(PRIVATE_SEPOLICY) $@

built_nonplat_pc := $(LOCAL_BUILT_MODULE)
nonplat_pcfiles :=
nonplat_property_contexts.tmp :=

##################################
include $(CLEAR_VARS)

LOCAL_MODULE := plat_service_contexts
LOCAL_MODULE_CLASS := ETC
LOCAL_MODULE_TAGS := optional
ifeq ($(PRODUCT_FULL_TREBLE),true)
LOCAL_MODULE_PATH := $(TARGET_OUT)/etc/selinux
else
LOCAL_MODULE_PATH := $(TARGET_ROOT_OUT)
endif

include $(BUILD_SYSTEM)/base_rules.mk

plat_svcfiles := $(call build_policy, service_contexts, $(PLAT_PRIVATE_POLICY))

plat_service_contexts.tmp := $(intermediates)/plat_service_contexts.tmp
$(plat_service_contexts.tmp): PRIVATE_SVC_FILES := $(plat_svcfiles)
$(plat_service_contexts.tmp): PRIVATE_ADDITIONAL_M4DEFS := $(LOCAL_ADDITIONAL_M4DEFS)
$(plat_service_contexts.tmp): $(plat_svcfiles)
	@mkdir -p $(dir $@)
	$(hide) m4 -s $(PRIVATE_ADDITIONAL_M4DEFS) $(PRIVATE_SVC_FILES) > $@

$(LOCAL_BUILT_MODULE): PRIVATE_SEPOLICY := $(built_sepolicy)
$(LOCAL_BUILT_MODULE): $(plat_service_contexts.tmp) $(built_sepolicy) $(HOST_OUT_EXECUTABLES)/checkfc $(ACP)
	@mkdir -p $(dir $@)
	sed -e 's/#.*$$//' -e '/^$$/d' $< > $@
	$(HOST_OUT_EXECUTABLES)/checkfc -s $(PRIVATE_SEPOLICY) $@

built_plat_svc := $(LOCAL_BUILT_MODULE)
plat_svcfiles :=
plat_service_contexts.tmp :=

##################################
include $(CLEAR_VARS)

LOCAL_MODULE := nonplat_service_contexts
LOCAL_MODULE_CLASS := ETC
LOCAL_MODULE_TAGS := optional
ifeq ($(PRODUCT_FULL_TREBLE),true)
LOCAL_MODULE_PATH := $(TARGET_OUT_VENDOR)/etc/selinux
else
LOCAL_MODULE_PATH := $(TARGET_ROOT_OUT)
endif

include $(BUILD_SYSTEM)/base_rules.mk

nonplat_svcfiles := $(call build_policy, service_contexts, $(PLAT_VENDOR_POLICY) $(BOARD_SEPOLICY_DIRS) $(REQD_MASK_POLICY))

nonplat_service_contexts.tmp := $(intermediates)/nonplat_service_contexts.tmp
$(nonplat_service_contexts.tmp): PRIVATE_SVC_FILES := $(nonplat_svcfiles)
$(nonplat_service_contexts.tmp): PRIVATE_ADDITIONAL_M4DEFS := $(LOCAL_ADDITIONAL_M4DEFS)
$(nonplat_service_contexts.tmp): $(nonplat_svcfiles)
	@mkdir -p $(dir $@)
	$(hide) m4 -s $(PRIVATE_ADDITIONAL_M4DEFS) $(PRIVATE_SVC_FILES) > $@

$(LOCAL_BUILT_MODULE): PRIVATE_SEPOLICY := $(built_sepolicy)
$(LOCAL_BUILT_MODULE): $(nonplat_service_contexts.tmp) $(built_sepolicy) $(HOST_OUT_EXECUTABLES)/checkfc $(ACP)
	@mkdir -p $(dir $@)
	sed -e 's/#.*$$//' -e '/^$$/d' $< > $@
	$(hide) $(HOST_OUT_EXECUTABLES)/checkfc -s $(PRIVATE_SEPOLICY) $@

built_nonplat_svc := $(LOCAL_BUILT_MODULE)
nonplat_svcfiles :=
nonplat_service_contexts.tmp :=

##################################
include $(CLEAR_VARS)

LOCAL_MODULE := plat_mac_permissions.xml
LOCAL_MODULE_CLASS := ETC
LOCAL_MODULE_TAGS := optional
LOCAL_MODULE_PATH := $(TARGET_OUT_ETC)/security

include $(BUILD_SYSTEM)/base_rules.mk

# Build keys.conf
plat_mac_perms_keys.tmp := $(intermediates)/plat_keys.tmp
$(plat_mac_perms_keys.tmp): PRIVATE_ADDITIONAL_M4DEFS := $(LOCAL_ADDITIONAL_M4DEFS)
$(plat_mac_perms_keys.tmp): $(call build_policy, keys.conf, $(PLAT_PRIVATE_POLICY))
	@mkdir -p $(dir $@)
	$(hide) m4 -s $(PRIVATE_ADDITIONAL_M4DEFS) $^ > $@

all_plat_mac_perms_files := $(call build_policy, mac_permissions.xml, $(PLAT_PRIVATE_POLICY))

# Should be synced with keys.conf.
all_plat_keys := platform media shared testkey
all_plat_keys := $(all_keys:%=$(dir $(DEFAULT_SYSTEM_DEV_CERTIFICATE))/%.x509.pem)

$(LOCAL_BUILT_MODULE): PRIVATE_MAC_PERMS_FILES := $(all_plat_mac_perms_files)
$(LOCAL_BUILT_MODULE): $(plat_mac_perms_keys.tmp) $(HOST_OUT_EXECUTABLES)/insertkeys.py \
$(all_plat_mac_perms_files) $(all_plat_keys)
	@mkdir -p $(dir $@)
	$(hide) DEFAULT_SYSTEM_DEV_CERTIFICATE="$(dir $(DEFAULT_SYSTEM_DEV_CERTIFICATE))" \
		$(HOST_OUT_EXECUTABLES)/insertkeys.py -t $(TARGET_BUILD_VARIANT) -c $(TOP) $< -o $@ $(PRIVATE_MAC_PERMS_FILES)

all_mac_perms_files :=
all_plat_keys :=
plat_mac_perms_keys.tmp :=

##################################
include $(CLEAR_VARS)

LOCAL_MODULE := nonplat_mac_permissions.xml
LOCAL_MODULE_CLASS := ETC
LOCAL_MODULE_TAGS := optional
LOCAL_MODULE_PATH := $(TARGET_OUT_ETC)/security

include $(BUILD_SYSTEM)/base_rules.mk

# Build keys.conf
nonplat_mac_perms_keys.tmp := $(intermediates)/nonplat_keys.tmp
$(nonplat_mac_perms_keys.tmp): PRIVATE_ADDITIONAL_M4DEFS := $(LOCAL_ADDITIONAL_M4DEFS)
$(nonplat_mac_perms_keys.tmp): $(call build_policy, keys.conf, $(PLAT_VENDOR_POLICY) $(BOARD_SEPOLICY_DIRS) $(REQD_MASK_POLICY))
	@mkdir -p $(dir $@)
	$(hide) m4 -s $(PRIVATE_ADDITIONAL_M4DEFS) $^ > $@

all_nonplat_mac_perms_files := $(call build_policy, mac_permissions.xml, $(PLAT_VENDOR_POLICY) $(BOARD_SEPOLICY_DIRS) $(REQD_MASK_POLICY))

$(LOCAL_BUILT_MODULE): PRIVATE_MAC_PERMS_FILES := $(all_nonplat_mac_perms_files)
$(LOCAL_BUILT_MODULE): $(nonplat_mac_perms_keys.tmp) $(HOST_OUT_EXECUTABLES)/insertkeys.py \
$(all_nonplat_mac_perms_files)
	@mkdir -p $(dir $@)
	$(hide) $(HOST_OUT_EXECUTABLES)/insertkeys.py -t $(TARGET_BUILD_VARIANT) -c $(TOP) $< -o $@ $(PRIVATE_MAC_PERMS_FILES)

nonplat_mac_perms_keys.tmp :=
all_nonplat_mac_perms_files :=

##################################
include $(CLEAR_VARS)

LOCAL_MODULE := selinux_version
LOCAL_MODULE_CLASS := ETC
LOCAL_MODULE_TAGS := optional
LOCAL_MODULE_PATH := $(TARGET_ROOT_OUT)

include $(BUILD_SYSTEM)/base_rules.mk
$(LOCAL_BUILT_MODULE): $(built_sepolicy) $(built_plat_pc) $(built_nonplat_pc) $(built_plat_fc) \
$(buit_nonplat_fc) $(built_plat_sc) $(built_nonplat_sc) $(built_plat_svc) $(built_nonplat_svc)
	@mkdir -p $(dir $@)
	$(hide) echo -n $(BUILD_FINGERPRINT_FROM_FILE) > $@

##################################

add_nl :=
build_device_policy :=
build_policy :=
built_plat_fc :=
built_nonplat_fc :=
built_general_sepolicy :=
built_general_sepolicy.conf :=
built_nl :=
built_plat_cil :=
built_mapping_cil :=
built_plat_pc :=
built_nonplat_cil :=
built_nonplat_pc :=
built_nonplat_sc :=
built_plat_sc :=
built_precompiled_sepolicy :=
built_sepolicy :=
built_plat_svc :=
built_nonplat_svc :=
mapping_policy_nvr :=
my_target_arch :=
nonplat_policy_nvr :=
plat_policy_nvr :=
plat_pub_policy.cil :=
reqd_policy_mask.cil :=
sepolicy_build_files :=

include $(call all-makefiles-under,$(LOCAL_PATH))
