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
# mapping - TODO.  This contains policy statements which map the attributes
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
build_device_policy = $(call build_policy, $(1), $(BOARD_SEPOLICY_DIRS))

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

LOCAL_MODULE := sepolicy
LOCAL_MODULE_CLASS := ETC
LOCAL_MODULE_TAGS := optional
LOCAL_MODULE_PATH := $(TARGET_ROOT_OUT)
LOCAL_TARGET_ARCH := $(TARGET_ARCH)

# Set LOCAL_TARGET_ARCH to mips for mips and mips64.
ifneq (,$(filter mips mips64,$(TARGET_ARCH)))
  LOCAL_TARGET_ARCH := mips
endif

include $(BUILD_SYSTEM)/base_rules.mk

# reqd_policy_mask - a policy.conf file which contains only the bare minimum
# policy necessary to use checkpolicy.  This bare-minimum policy needs to be
# present in all policy.conf files, but should not necessarily be exported as
# part of the public policy.  The rules generated by reqd_policy_mask will allow
# the compilation of public policy and subsequent removal of CIL policy that
# should not be exported.

reqd_policy_mask.conf := $(intermediates)/reqd_policy_mask.conf
$(reqd_policy_mask.conf): PRIVATE_MLS_SENS := $(MLS_SENS)
$(reqd_policy_mask.conf): PRIVATE_MLS_CATS := $(MLS_CATS)
$(reqd_policy_mask.conf): PRIVATE_ADDITIONAL_M4DEFS := $(LOCAL_ADDITIONAL_M4DEFS)
$(reqd_policy_mask.conf): $(call build_policy, $(sepolicy_build_files), $(REQD_MASK_POLICY))
	@mkdir -p $(dir $@)
	$(hide) m4 $(PRIVATE_ADDITIONAL_M4DEFS) \
		-D mls_num_sens=$(PRIVATE_MLS_SENS) -D mls_num_cats=$(PRIVATE_MLS_CATS) \
		-D target_build_variant=$(TARGET_BUILD_VARIANT) \
		-s $^ > $@

reqd_policy_mask.cil := $(intermediates)/reqd_policy_mask.cil
$(reqd_policy_mask.cil): $(reqd_policy_mask.conf) $(HOST_OUT_EXECUTABLES)/checkpolicy
	@mkdir -p $(dir $@)
	$(hide) $(HOST_OUT_EXECUTABLES)/checkpolicy -C -M -c $(POLICYVERS) -o $@ $<

# plat_pub_policy - policy that will be exported to be a part of non-platform
# policy corresponding to this platform version.  This is a limited subset of
# policy that would not compile in checkpolicy on its own.  To get around this
# limitation, add only the required files from private policy, which will
# generate CIL policy that will then be filtered out by the reqd_policy_mask.
plat_pub_policy.conf := $(intermediates)/plat_pub_policy.conf
$(plat_pub_policy.conf): PRIVATE_MLS_SENS := $(MLS_SENS)
$(plat_pub_policy.conf): PRIVATE_MLS_CATS := $(MLS_CATS)
$(plat_pub_policy.conf): PRIVATE_ADDITIONAL_M4DEFS := $(LOCAL_ADDITIONAL_M4DEFS)
$(plat_pub_policy.conf): $(call build_policy, $(sepolicy_build_files), \
$(BOARD_SEPOLICY_VERS_DIR) $(REQD_MASK_POLICY))
	@mkdir -p $(dir $@)
	 $(hide) m4 $(PRIVATE_ADDITIONAL_M4DEFS) \
		-D mls_num_sens=$(PRIVATE_MLS_SENS) -D mls_num_cats=$(PRIVATE_MLS_CATS) \
		-D target_build_variant=$(TARGET_BUILD_VARIANT) \
		-s $^ > $@

plat_pub_policy.cil := $(intermediates)/plat_pub_policy.cil
$(plat_pub_policy.cil): $(plat_pub_policy.conf) $(HOST_OUT_EXECUTABLES)/checkpolicy
	@mkdir -p $(dir $@)
	$(hide) $(HOST_OUT_EXECUTABLES)/checkpolicy -C -M -c $(POLICYVERS) -o $@ $<

pruned_plat_pub_policy.cil := $(intermediates)/pruned_plat_pub_policy.cil
$(pruned_plat_pub_policy.cil): $(reqd_policy_mask.cil) $(plat_pub_policy.cil)
	@mkdir -p $(dir $@)
	$(hide) grep -Fxv -f $^ > $@

# plat_policy.conf - A combination of the private and public platform policy
# which will ship with the device.  The platform will always reflect the most
# recent platform version and is not currently being attributized.
plat_policy.conf := $(intermediates)/plat_policy.conf
$(plat_policy.conf): PRIVATE_MLS_SENS := $(MLS_SENS)
$(plat_policy.conf): PRIVATE_MLS_CATS := $(MLS_CATS)
$(plat_policy.conf): PRIVATE_ADDITIONAL_M4DEFS := $(LOCAL_ADDITIONAL_M4DEFS)
$(plat_policy.conf): $(call build_policy, $(sepolicy_build_files), \
$(PLAT_PUBLIC_POLICY) $(PLAT_PRIVATE_POLICY))
	@mkdir -p $(dir $@)
	$(hide) m4 $(PRIVATE_ADDITIONAL_M4DEFS) \
		-D mls_num_sens=$(PRIVATE_MLS_SENS) -D mls_num_cats=$(PRIVATE_MLS_CATS) \
		-D target_build_variant=$(TARGET_BUILD_VARIANT) \
		-D target_build_treble=$(ENABLE_TREBLE) \
		-D target_with_dexpreopt=$(WITH_DEXPREOPT) \
		-D target_with_dexpreopt_pic=$(WITH_DEXPREOPT_PIC) \
		-s $^ > $@
	$(hide) sed '/dontaudit/d' $@ > $@.dontaudit

plat_policy.cil := $(intermediates)/plat_policy.cil
$(plat_policy.cil): $(plat_policy.conf) $(HOST_OUT_EXECUTABLES)/checkpolicy
	@mkdir -p $(dir $@)
	$(hide) $(HOST_OUT_EXECUTABLES)/checkpolicy -M -C -c $(POLICYVERS) -o $@.tmp $<
	$(hide) grep -v neverallow $@.tmp > $@

# nonplat_policy.conf - A combination of the non-platform private and the
# exported platform policy associated with the version the non-platform policy
# targets.  This needs attributization and to be combined with the
# platform-provided policy.  Like plat_pub_policy.conf, this needs to make use
# of the reqd_policy_mask files from private policy in order to use checkpolicy.
nonplat_policy.conf := $(intermediates)/nonplat_policy.conf
$(nonplat_policy.conf): PRIVATE_MLS_SENS := $(MLS_SENS)
$(nonplat_policy.conf): PRIVATE_MLS_CATS := $(MLS_CATS)
$(nonplat_policy.conf): PRIVATE_ADDITIONAL_M4DEFS := $(LOCAL_ADDITIONAL_M4DEFS)
$(nonplat_policy.conf): $(call build_policy, $(sepolicy_build_files), \
$(BOARD_SEPOLICY_VERS_DIR) $(REQD_MASK_POLICY) $(BOARD_SEPOLICY_DIRS))
	@mkdir -p $(dir $@)
	$(hide) m4 $(PRIVATE_ADDITIONAL_M4DEFS) \
		-D mls_num_sens=$(PRIVATE_MLS_SENS) -D mls_num_cats=$(PRIVATE_MLS_CATS) \
		-D target_build_variant=$(TARGET_BUILD_VARIANT) \
		-D target_build_treble=$(ENABLE_TREBLE) \
		-D target_with_dexpreopt=$(WITH_DEXPREOPT) \
		-D target_with_dexpreopt_pic=$(WITH_DEXPREOPT_PIC) \
		-D target_arch=$(LOCAL_TARGET_ARCH) \
		-s $^ > $@
	$(hide) sed '/dontaudit/d' $@ > $@.dontaudit

nonplat_policy.cil := $(intermediates)/nonplat_policy.cil
$(nonplat_policy.cil): $(nonplat_policy.conf) $(HOST_OUT_EXECUTABLES)/checkpolicy
	@mkdir -p $(dir $@)
	$(hide) $(HOST_OUT_EXECUTABLES)/checkpolicy -C -M -c $(POLICYVERS) -o $@ $<

pruned_nonplat_policy.cil := $(intermediates)/pruned_nonplat_policy.cil
$(pruned_nonplat_policy.cil): $(reqd_policy_mask.cil) $(nonplat_policy.cil)
	@mkdir -p $(dir $@)
	$(hide) grep -Fxv -f $^ | grep -v neverallow > $@

vers_nonplat_policy.cil := $(intermediates)/vers_nonplat_policy.cil
$(vers_nonplat_policy.cil) : PRIVATE_VERS := $(BOARD_SEPOLICY_VERS)
$(vers_nonplat_policy.cil) : PRIVATE_TGT_POL := $(pruned_nonplat_policy.cil)
$(vers_nonplat_policy.cil) : $(pruned_plat_pub_policy.cil) $(pruned_nonplat_policy.cil) \
$(HOST_OUT_EXECUTABLES)/version_policy
	@mkdir -p $(dir $@)
	$(HOST_OUT_EXECUTABLES)/version_policy -b $< -t $(PRIVATE_TGT_POL) -n $(PRIVATE_VERS) -o $@

# auto-generate the mapping file for current platform policy, since it needs to
# track platform policy development
current_mapping.cil := $(intermediates)/mapping/current.cil
$(current_mapping.cil) : PRIVATE_VERS := $(BOARD_SEPOLICY_VERS)
$(current_mapping.cil) : $(pruned_plat_pub_policy.cil) $(HOST_OUT_EXECUTABLES)/version_policy
	@mkdir -p $(dir $@)
	$(hide) $(HOST_OUT_EXECUTABLES)/version_policy -b $< -m -n $(PRIVATE_VERS) -o $@

ifeq ($(BOARD_SEPOLICY_VERS), current)
mapping.cil := $(current_mapping.cil)
else
mapping.cil := $(addsuffix /$(BOARD_SEPOLICY_VERS).cil, $(PLAT_PRIVATE_POLICY)/mapping)
endif

all_cil_files := \
    $(plat_policy.cil) \
    $(vers_nonplat_policy.cil) \
    $(mapping.cil)

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
reqd_policy_mask.conf :=
reqd_policy_mask.cil :=
plat_pub_policy.conf :=
plat_pub_policy.cil :=
pruned_plat_pub_policy.cil :=
plat_policy.conf :=
plat_policy.cil :=
nonplat_policy.conf :=
nonplat_policy.cil :=
pruned_nonplat_policy.cil :=
vers_nonplat_policy.cil :=
current_mapping.cil :=
mapping.cil :=
all_cil_files :=
sepolicy_policy.conf :=

##################################
include $(CLEAR_VARS)

LOCAL_MODULE := sepolicy.recovery
LOCAL_MODULE_CLASS := ETC
LOCAL_MODULE_TAGS := eng

include $(BUILD_SYSTEM)/base_rules.mk

sepolicy_policy_recovery.conf := $(intermediates)/policy_recovery.conf
$(sepolicy_policy_recovery.conf): PRIVATE_MLS_SENS := $(MLS_SENS)
$(sepolicy_policy_recovery.conf): PRIVATE_MLS_CATS := $(MLS_CATS)
$(sepolicy_policy_recovery.conf): PRIVATE_ADDITIONAL_M4DEFS := $(LOCAL_ADDITIONAL_M4DEFS)
$(sepolicy_policy_recovery.conf): $(call build_policy, $(sepolicy_build_files), \
$(PLAT_PUBLIC_POLICY) $(PLAT_PRIVATE_POLICY) $(BOARD_SEPOLICY_DIRS))
	@mkdir -p $(dir $@)
	$(hide) m4 $(PRIVATE_ADDITIONAL_M4DEFS) \
		-D mls_num_sens=$(PRIVATE_MLS_SENS) -D mls_num_cats=$(PRIVATE_MLS_CATS) \
		-D target_build_variant=$(TARGET_BUILD_VARIANT) \
		-D target_build_treble=$(ENABLE_TREBLE) \
		-D target_with_dexpreopt=$(WITH_DEXPREOPT) \
		-D target_with_dexpreopt_pic=$(WITH_DEXPREOPT_PIC) \
		-D target_recovery=true \
		-s $^ > $@

$(LOCAL_BUILT_MODULE): $(sepolicy_policy_recovery.conf) $(HOST_OUT_EXECUTABLES)/checkpolicy $(HOST_OUT_EXECUTABLES)/sepolicy-analyze
	@mkdir -p $(dir $@)
	$(hide) $(HOST_OUT_EXECUTABLES)/checkpolicy -M -c $(POLICYVERS) -o $@.tmp $< > /dev/null
	$(hide) $(HOST_OUT_EXECUTABLES)/sepolicy-analyze $@.tmp permissive > $@.permissivedomains
	$(hide) if [ "$(TARGET_BUILD_VARIANT)" = "user" -a -s $@.permissivedomains ]; then \
		echo "==========" 1>&2; \
		echo "ERROR: permissive domains not allowed in user builds" 1>&2; \
		echo "List of invalid domains:" 1>&2; \
		cat $@.permissivedomains 1>&2; \
		exit 1; \
		fi
	$(hide) mv $@.tmp $@

built_sepolicy_recovery := $(LOCAL_BUILT_MODULE)
sepolicy_policy_recovery.conf :=

##################################
include $(CLEAR_VARS)

LOCAL_MODULE := general_sepolicy.conf
LOCAL_MODULE_CLASS := ETC
LOCAL_MODULE_TAGS := tests

include $(BUILD_SYSTEM)/base_rules.mk

$(LOCAL_BUILT_MODULE): PRIVATE_MLS_SENS := $(MLS_SENS)
$(LOCAL_BUILT_MODULE): PRIVATE_MLS_CATS := $(MLS_CATS)
$(LOCAL_BUILT_MODULE): $(call build_policy, $(sepolicy_build_files), \
$(PLAT_PUBLIC_POLICY) $(PLAT_PRIVATE_POLICY))
	mkdir -p $(dir $@)
	$(hide) m4 -D mls_num_sens=$(PRIVATE_MLS_SENS) -D mls_num_cats=$(PRIVATE_MLS_CATS) \
		-D target_build_variant=user \
		-D target_build_treble=$(ENABLE_TREBLE) \
		-D target_with_dexpreopt=$(WITH_DEXPREOPT) \
		-D target_with_dexpreopt_pic=$(WITH_DEXPREOPT_PIC) \
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
	# TODO: fix with attributized types $(hide) $(HOST_OUT_EXECUTABLES)/checkfc -e $(PRIVATE_SEPOLICY) $<
	$(hide) $(HOST_OUT_EXECUTABLES)/fc_sort $< $@

file_contexts.concat.tmp := $(intermediates)/file_contexts.concat.tmp
$(file_contexts.concat.tmp): $(file_contexts.local.tmp) $(file_contexts.device.sorted.tmp)
	@mkdir -p $(dir $@)
	$(hide) m4 -s $^ > $@

$(LOCAL_BUILT_MODULE): PRIVATE_SEPOLICY := $(built_sepolicy)
$(LOCAL_BUILT_MODULE): $(file_contexts.concat.tmp) $(built_sepolicy) $(HOST_OUT_EXECUTABLES)/sefcontext_compile $(HOST_OUT_EXECUTABLES)/checkfc
	@mkdir -p $(dir $@)
	# TODO: fix with attributized types	$(hide) $(HOST_OUT_EXECUTABLES)/checkfc $(PRIVATE_SEPOLICY) $<
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

LOCAL_MODULE := general_file_contexts.bin
LOCAL_MODULE_CLASS := ETC
LOCAL_MODULE_TAGS := tests

include $(BUILD_SYSTEM)/base_rules.mk

general_file_contexts.tmp := $(intermediates)/general_file_contexts.tmp
$(general_file_contexts.tmp): $(addprefix $(PLAT_PRIVATE_POLICY)/, file_contexts)
	@mkdir -p $(dir $@)
	$(hide) m4 -s $< > $@

$(LOCAL_BUILT_MODULE): PRIVATE_SEPOLICY := $(built_general_sepolicy)
$(LOCAL_BUILT_MODULE): $(general_file_contexts.tmp) $(built_general_sepolicy) $(HOST_OUT_EXECUTABLES)/sefcontext_compile $(HOST_OUT_EXECUTABLES)/checkfc
	@mkdir -p $(dir $@)
	#  TODO: fix with attributized types $(hide) $(HOST_OUT_EXECUTABLES)/checkfc $(PRIVATE_SEPOLICY) $<
	$(hide) $(HOST_OUT_EXECUTABLES)/sefcontext_compile -o $@ $<

general_file_contexts.tmp :=

##################################
include $(CLEAR_VARS)
LOCAL_MODULE := seapp_contexts
LOCAL_MODULE_CLASS := ETC
LOCAL_MODULE_TAGS := optional
LOCAL_MODULE_PATH := $(TARGET_ROOT_OUT)

include $(BUILD_SYSTEM)/base_rules.mk

all_sc_files := $(call build_policy, seapp_contexts, $(PLAT_PRIVATE_POLICY) $(BOARD_SEPOLICY_DIRS))

$(LOCAL_BUILT_MODULE): PRIVATE_SEPOLICY := $(built_sepolicy)
$(LOCAL_BUILT_MODULE): PRIVATE_SC_FILES := $(all_sc_files)
$(LOCAL_BUILT_MODULE): $(built_sepolicy) $(all_sc_files) $(HOST_OUT_EXECUTABLES)/checkseapp
	@mkdir -p $(dir $@)
	$(hide) $(HOST_OUT_EXECUTABLES)/checkseapp -p $(PRIVATE_SEPOLICY) -o $@ $(PRIVATE_SC_FILES)

built_sc := $(LOCAL_BUILT_MODULE)
all_sc_files :=

##################################
include $(CLEAR_VARS)
LOCAL_MODULE := general_seapp_contexts
LOCAL_MODULE_CLASS := ETC
LOCAL_MODULE_TAGS := tests

include $(BUILD_SYSTEM)/base_rules.mk

all_sc_files := $(addprefix $(PLAT_PRIVATE_POLICY)/, seapp_contexts)

$(LOCAL_BUILT_MODULE): PRIVATE_SEPOLICY := $(built_general_sepolicy)
$(LOCAL_BUILT_MODULE): PRIVATE_SC_FILE := $(all_sc_files)
$(LOCAL_BUILT_MODULE): $(built_general_sepolicy) $(all_sc_files) $(HOST_OUT_EXECUTABLES)/checkseapp
	@mkdir -p $(dir $@)
	$(hide) $(HOST_OUT_EXECUTABLES)/checkseapp -p $(PRIVATE_SEPOLICY) -o $@ $(PRIVATE_SC_FILE)

all_sc_files :=

##################################
include $(CLEAR_VARS)
LOCAL_MODULE := general_seapp_neverallows
LOCAL_MODULE_CLASS := ETC
LOCAL_MODULE_TAGS := tests

include $(BUILD_SYSTEM)/base_rules.mk

$(LOCAL_BUILT_MODULE): $(addprefix $(PLAT_PRIVATE_POLICY)/, seapp_contexts)
	@mkdir -p $(dir $@)
	- $(hide) grep -ie '^neverallow' $< > $@


##################################
include $(CLEAR_VARS)

LOCAL_MODULE := property_contexts
LOCAL_MODULE_CLASS := ETC
LOCAL_MODULE_TAGS := optional
LOCAL_MODULE_PATH := $(TARGET_ROOT_OUT)

include $(BUILD_SYSTEM)/base_rules.mk

all_pc_files := $(call build_policy, property_contexts, $(PLAT_PRIVATE_POLICY) $(BOARD_SEPOLICY_DIRS))
all_pcfiles_with_nl := $(call add_nl, $(all_pc_files), $(built_nl))

property_contexts.tmp := $(intermediates)/property_contexts.tmp
$(property_contexts.tmp): PRIVATE_PC_FILES := $(all_pcfiles_with_nl)
$(property_contexts.tmp): PRIVATE_ADDITIONAL_M4DEFS := $(LOCAL_ADDITIONAL_M4DEFS)
$(property_contexts.tmp): $(all_pcfiles_with_nl)
	@mkdir -p $(dir $@)
	$(hide) m4 -s $(PRIVATE_ADDITIONAL_M4DEFS) $(PRIVATE_PC_FILES) > $@


$(LOCAL_BUILT_MODULE): PRIVATE_SEPOLICY := $(built_sepolicy)
$(LOCAL_BUILT_MODULE): $(property_contexts.tmp) $(built_sepolicy) $(HOST_OUT_EXECUTABLES)/checkfc
	@mkdir -p $(dir $@)
	$(hide) sed -e 's/#.*$$//' -e '/^$$/d' $< > $@
	# TODO: fix with attributized types $(hide) $(HOST_OUT_EXECUTABLES)/checkfc -p $(PRIVATE_SEPOLICY) $@

built_pc := $(LOCAL_BUILT_MODULE)
all_pc_files :=
all_pcfiles_with_nl :=
property_contexts.tmp :=

##################################
include $(CLEAR_VARS)

LOCAL_MODULE := general_property_contexts
LOCAL_MODULE_CLASS := ETC
LOCAL_MODULE_TAGS := tests

include $(BUILD_SYSTEM)/base_rules.mk

general_property_contexts.tmp := $(intermediates)/general_property_contexts.tmp
$(general_property_contexts.tmp): $(addprefix $(PLAT_PRIVATE_POLICY)/, property_contexts)
	@mkdir -p $(dir $@)
	$(hide) m4 -s $< > $@

$(LOCAL_BUILT_MODULE): PRIVATE_SEPOLICY := $(built_general_sepolicy)
$(LOCAL_BUILT_MODULE): $(general_property_contexts.tmp) $(built_general_sepolicy) $(HOST_OUT_EXECUTABLES)/checkfc $(ACP)
	@mkdir -p $(dir $@)
	$(hide) sed -e 's/#.*$$//' -e '/^$$/d' $< > $@
	# TODO: fix with attributized types $(hide) $(HOST_OUT_EXECUTABLES)/checkfc -p $(PRIVATE_SEPOLICY) $@

general_property_contexts.tmp :=

##################################
include $(CLEAR_VARS)

LOCAL_MODULE := service_contexts
LOCAL_MODULE_CLASS := ETC
LOCAL_MODULE_TAGS := optional
LOCAL_MODULE_PATH := $(TARGET_ROOT_OUT)

include $(BUILD_SYSTEM)/base_rules.mk

all_svc_files := $(call build_policy, service_contexts, $(PLAT_PRIVATE_POLICY) $(BOARD_SEPOLICY_DIRS))
all_svcfiles_with_nl := $(call add_nl, $(all_svc_files), $(built_nl))

service_contexts.tmp := $(intermediates)/service_contexts.tmp
$(service_contexts.tmp): PRIVATE_SVC_FILES := $(all_svcfiles_with_nl)
$(service_contexts.tmp): PRIVATE_ADDITIONAL_M4DEFS := $(LOCAL_ADDITIONAL_M4DEFS)
$(service_contexts.tmp): $(all_svcfiles_with_nl)
	@mkdir -p $(dir $@)
	$(hide) m4 -s $(PRIVATE_ADDITIONAL_M4DEFS) $(PRIVATE_SVC_FILES) > $@

$(LOCAL_BUILT_MODULE): PRIVATE_SEPOLICY := $(built_sepolicy)
$(LOCAL_BUILT_MODULE): $(service_contexts.tmp) $(built_sepolicy) $(HOST_OUT_EXECUTABLES)/checkfc $(ACP)
	@mkdir -p $(dir $@)
	sed -e 's/#.*$$//' -e '/^$$/d' $< > $@
	# TODO: fix with attributized types$(hide) $(HOST_OUT_EXECUTABLES)/checkfc -s $(PRIVATE_SEPOLICY) $@

built_svc := $(LOCAL_BUILT_MODULE)
all_svc_files :=
all_svcfiles_with_nl :=
service_contexts.tmp :=

##################################
include $(CLEAR_VARS)

LOCAL_MODULE := general_service_contexts
LOCAL_MODULE_CLASS := ETC
LOCAL_MODULE_TAGS := tests

include $(BUILD_SYSTEM)/base_rules.mk

general_service_contexts.tmp := $(intermediates)/general_service_contexts.tmp
$(general_service_contexts.tmp): $(addprefix $(PLAT_PRIVATE_POLICY)/, service_contexts)
	@mkdir -p $(dir $@)
	$(hide) m4 -s $< > $@

$(LOCAL_BUILT_MODULE): PRIVATE_SEPOLICY := $(built_general_sepolicy)
$(LOCAL_BUILT_MODULE): $(general_service_contexts.tmp) $(built_general_sepolicy) $(HOST_OUT_EXECUTABLES)/checkfc $(ACP)
	@mkdir -p $(dir $@)
	sed -e 's/#.*$$//' -e '/^$$/d' $< > $@
	# TODO: fix with attributized types $(hide) $(HOST_OUT_EXECUTABLES)/checkfc -s $(PRIVATE_SEPOLICY) $@

general_service_contexts.tmp :=

##################################
include $(CLEAR_VARS)

LOCAL_MODULE := mac_permissions.xml
LOCAL_MODULE_CLASS := ETC
LOCAL_MODULE_TAGS := optional
LOCAL_MODULE_PATH := $(TARGET_OUT_ETC)/security

include $(BUILD_SYSTEM)/base_rules.mk

# Build keys.conf
mac_perms_keys.tmp := $(intermediates)/keys.tmp
$(mac_perms_keys.tmp): PRIVATE_ADDITIONAL_M4DEFS := $(LOCAL_ADDITIONAL_M4DEFS)
$(mac_perms_keys.tmp): $(call build_policy, keys.conf, $(PLAT_PRIVATE_POLICY) $(BOARD_SEPOLICY_DIRS))
	@mkdir -p $(dir $@)
	$(hide) m4 -s $(PRIVATE_ADDITIONAL_M4DEFS) $^ > $@

all_mac_perms_files := $(call build_policy, $(LOCAL_MODULE), $(PLAT_PRIVATE_POLICY) $(BOARD_SEPOLICY_DIRS))

# Should be synced with keys.conf.
all_keys := platform media shared testkey
all_keys := $(all_keys:%=$(dir $(DEFAULT_SYSTEM_DEV_CERTIFICATE))/%.x509.pem)

$(LOCAL_BUILT_MODULE): PRIVATE_MAC_PERMS_FILES := $(all_mac_perms_files)
$(LOCAL_BUILT_MODULE): $(mac_perms_keys.tmp) $(HOST_OUT_EXECUTABLES)/insertkeys.py $(all_mac_perms_files) $(all_keys)
	@mkdir -p $(dir $@)
	$(hide) DEFAULT_SYSTEM_DEV_CERTIFICATE="$(dir $(DEFAULT_SYSTEM_DEV_CERTIFICATE))" \
		$(HOST_OUT_EXECUTABLES)/insertkeys.py -t $(TARGET_BUILD_VARIANT) -c $(TOP) $< -o $@ $(PRIVATE_MAC_PERMS_FILES)

mac_perms_keys.tmp :=
all_mac_perms_files :=

##################################
include $(CLEAR_VARS)

LOCAL_MODULE := selinux_version
LOCAL_MODULE_CLASS := ETC
LOCAL_MODULE_TAGS := optional
LOCAL_MODULE_PATH := $(TARGET_ROOT_OUT)

include $(BUILD_SYSTEM)/base_rules.mk
$(LOCAL_BUILT_MODULE): $(built_sepolicy) $(built_pc) $(built_fc) $(built_sc) $(built_svc)
	@mkdir -p $(dir $@)
	$(hide) echo -n $(BUILD_FINGERPRINT_FROM_FILE) > $@

##################################

build_policy :=
build_device_policy :=
sepolicy_build_files :=
built_sepolicy :=
built_sepolicy_recovery :=
built_sc :=
built_fc :=
built_pc :=
built_svc :=
built_general_sepolicy :=
built_general_sepolicy.conf :=
built_nl :=
add_nl :=

include $(call all-makefiles-under,$(LOCAL_PATH))
