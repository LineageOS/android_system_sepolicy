# Copyright (C) 2020 The Android Open Source Project
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#      http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

# prebuilt_policy.mk generates policy files from prebuilts of BOARD_SEPOLICY_VERS.
# The policy files will only be used to compile vendor and odm policies.
#
# Specifically, the following prebuilts are used...
# - system/sepolicy/prebuilts/api/{BOARD_SEPOLICY_VERS}
# - BOARD_PLAT_VENDOR_POLICY               (copy of system/sepolicy/vendor from a previous release)
# - BOARD_REQD_MASK_POLICY                 (copy of reqd_mask from a previous release)
# - BOARD_SYSTEM_EXT_PUBLIC_PREBUILT_DIRS  (copy of system_ext public from a previous release)
# - BOARD_SYSTEM_EXT_PRIVATE_PREBUILT_DIRS (copy of system_ext private from a previous release)
# - BOARD_PRODUCT_PUBLIC_PREBUILT_DIRS     (copy of product public from a previous release)
# - BOARD_PRODUCT_PRIVATE_PREBUILT_DIRS    (copy of product private from a previous release)
#
# ... to generate following policy files.
#
# - reqd policy mask
# - plat, system_ext, product public policy
# - plat, system_ext, product policy
# - plat, system_ext, product versioned policy
#
# These generated policy files will be used only when building vendor policies.
# They are not installed to system, system_ext, or product partition.
ver := $(BOARD_SEPOLICY_VERS)
prebuilt_dir := $(LOCAL_PATH)/prebuilts/api/$(ver)
plat_public_policy_$(ver) := $(prebuilt_dir)/public
plat_private_policy_$(ver) := $(prebuilt_dir)/private
system_ext_public_policy_$(ver) := $(BOARD_SYSTEM_EXT_PUBLIC_PREBUILT_DIRS)
system_ext_private_policy_$(ver) := $(BOARD_SYSTEM_EXT_PRIVATE_PREBUILT_DIRS)
product_public_policy_$(ver) := $(BOARD_PRODUCT_PUBLIC_PREBUILT_DIRS)
product_private_policy_$(ver) := $(BOARD_PRODUCT_PRIVATE_PREBUILT_DIRS)

##################################
# policy-to-conf-rule: a helper macro to transform policy files to conf file.
#
# This expands to a set of rules which assign variables for transform-policy-to-conf and then call
# transform-policy-to-conf. Before calling this, policy_files must be set with build_policy macro.
#
# $(1): output path (.conf file)
define policy-to-conf-rule
$(1): PRIVATE_MLS_SENS := $$(MLS_SENS)
$(1): PRIVATE_MLS_CATS := $$(MLS_CATS)
$(1): PRIVATE_TARGET_BUILD_VARIANT := $$(TARGET_BUILD_VARIANT)
$(1): PRIVATE_TGT_ARCH := $$(my_target_arch)
$(1): PRIVATE_TGT_WITH_ASAN := $$(with_asan)
$(1): PRIVATE_TGT_WITH_NATIVE_COVERAGE := $$(with_native_coverage)
$(1): PRIVATE_ADDITIONAL_M4DEFS := $$(LOCAL_ADDITIONAL_M4DEFS)
$(1): PRIVATE_SEPOLICY_SPLIT := $$(PRODUCT_SEPOLICY_SPLIT)
$(1): PRIVATE_COMPATIBLE_PROPERTY := $$(PRODUCT_COMPATIBLE_PROPERTY)
$(1): PRIVATE_TREBLE_SYSPROP_NEVERALLOW := $$(treble_sysprop_neverallow)
$(1): PRIVATE_ENFORCE_SYSPROP_OWNER := $$(enforce_sysprop_owner)
$(1): PRIVATE_POLICY_FILES := $$(policy_files)
$(1): $$(policy_files) $$(M4)
	$$(transform-policy-to-conf)
endef

##################################
# reqd_policy_mask_$(ver).cil
#
policy_files := $(call build_policy, $(sepolicy_build_files), $(BOARD_REQD_MASK_POLICY))
reqd_policy_mask_$(ver).conf := $(intermediates)/reqd_policy_mask_$(ver).conf
$(eval $(call policy-to-conf-rule,$(reqd_policy_mask_$(ver).conf)))

# b/37755687
CHECKPOLICY_ASAN_OPTIONS := ASAN_OPTIONS=detect_leaks=0

reqd_policy_mask_$(ver).cil := $(intermediates)/reqd_policy_mask_$(ver).cil
$(reqd_policy_mask_$(ver).cil): $(reqd_policy_mask_$(ver).conf) $(HOST_OUT_EXECUTABLES)/checkpolicy
	@mkdir -p $(dir $@)
	$(hide) $(CHECKPOLICY_ASAN_OPTIONS) $(HOST_OUT_EXECUTABLES)/checkpolicy -C -M -c \
		$(POLICYVERS) -o $@ $<

reqd_policy_mask_$(ver).conf :=

reqd_policy_$(ver) := $(BOARD_REQD_MASK_POLICY)

##################################
# plat_pub_policy_$(ver).cil: exported plat policies
#
policy_files := $(call build_policy, $(sepolicy_build_files), \
  $(plat_public_policy_$(ver)) $(reqd_policy_$(ver)))
plat_pub_policy_$(ver).conf := $(intermediates)/plat_pub_policy_$(ver).conf
$(eval $(call policy-to-conf-rule,$(plat_pub_policy_$(ver).conf)))

plat_pub_policy_$(ver).cil := $(intermediates)/plat_pub_policy_$(ver).cil
$(plat_pub_policy_$(ver).cil): PRIVATE_POL_CONF := $(plat_pub_policy_$(ver).conf)
$(plat_pub_policy_$(ver).cil): PRIVATE_REQD_MASK := $(reqd_policy_mask_$(ver).cil)
$(plat_pub_policy_$(ver).cil): $(HOST_OUT_EXECUTABLES)/checkpolicy \
$(HOST_OUT_EXECUTABLES)/build_sepolicy $(plat_pub_policy_$(ver).conf) $(reqd_policy_mask_$(ver).cil)
	@mkdir -p $(dir $@)
	$(hide) $(CHECKPOLICY_ASAN_OPTIONS) $< -C -M -c $(POLICYVERS) -o $@ $(PRIVATE_POL_CONF)
	$(hide) $(HOST_OUT_EXECUTABLES)/build_sepolicy -a $(HOST_OUT_EXECUTABLES) filter_out \
		-f $(PRIVATE_REQD_MASK) -t $@

plat_pub_policy_$(ver).conf :=

##################################
# plat_mapping_cil_$(ver).cil: versioned exported system policy
#
plat_mapping_cil_$(ver) := $(intermediates)/plat_mapping_$(ver).cil
$(plat_mapping_cil_$(ver)) : PRIVATE_VERS := $(ver)
$(plat_mapping_cil_$(ver)) : $(plat_pub_policy_$(ver).cil) $(HOST_OUT_EXECUTABLES)/version_policy
	@mkdir -p $(dir $@)
	$(hide) $(HOST_OUT_EXECUTABLES)/version_policy -b $< -m -n $(PRIVATE_VERS) -o $@
built_plat_mapping_cil_$(ver) := $(plat_mapping_cil_$(ver))

##################################
# plat_policy_$(ver).cil: system policy
#
policy_files := $(call build_policy, $(sepolicy_build_files), \
  $(plat_public_policy_$(ver)) $(plat_private_policy_$(ver)) )
plat_policy_$(ver).conf := $(intermediates)/plat_policy_$(ver).conf
$(eval $(call policy-to-conf-rule,$(plat_policy_$(ver).conf)))

plat_policy_$(ver).cil := $(intermediates)/plat_policy_$(ver).cil
$(plat_policy_$(ver).cil): PRIVATE_ADDITIONAL_CIL_FILES := \
  $(call build_policy, $(sepolicy_build_cil_workaround_files), $(plat_private_policy_$(ver)))
$(plat_policy_$(ver).cil): PRIVATE_NEVERALLOW_ARG := $(NEVERALLOW_ARG)
$(plat_policy_$(ver).cil): $(plat_policy_$(ver).conf) $(HOST_OUT_EXECUTABLES)/checkpolicy \
  $(HOST_OUT_EXECUTABLES)/secilc \
  $(call build_policy, $(sepolicy_build_cil_workaround_files), $(plat_private_policy_$(ver)))
	@mkdir -p $(dir $@)
	$(hide) $(CHECKPOLICY_ASAN_OPTIONS) $(HOST_OUT_EXECUTABLES)/checkpolicy -M -C -c \
		$(POLICYVERS) -o $@.tmp $<
	$(hide) cat $(PRIVATE_ADDITIONAL_CIL_FILES) >> $@.tmp
	$(hide) $(HOST_OUT_EXECUTABLES)/secilc -m -M true -G -c $(POLICYVERS) $(PRIVATE_NEVERALLOW_ARG) $@.tmp -o /dev/null -f /dev/null
	$(hide) mv $@.tmp $@

plat_policy_$(ver).conf :=

built_plat_cil_$(ver) := $(plat_policy_$(ver).cil)

ifdef HAS_SYSTEM_EXT_SEPOLICY_DIR

##################################
# system_ext_pub_policy_$(ver).cil: exported system and system_ext policy
#
policy_files := $(call build_policy, $(sepolicy_build_files), \
  $(plat_public_policy_$(ver)) $(system_ext_public_policy_$(ver)) $(reqd_policy_$(ver)))
system_ext_pub_policy_$(ver).conf := $(intermediates)/system_ext_pub_policy_$(ver).conf
$(eval $(call policy-to-conf-rule,$(system_ext_pub_policy_$(ver).conf)))

system_ext_pub_policy_$(ver).cil := $(intermediates)/system_ext_pub_policy_$(ver).cil
$(system_ext_pub_policy_$(ver).cil): PRIVATE_POL_CONF := $(system_ext_pub_policy_$(ver).conf)
$(system_ext_pub_policy_$(ver).cil): PRIVATE_REQD_MASK := $(reqd_policy_mask_$(ver).cil)
$(system_ext_pub_policy_$(ver).cil): $(HOST_OUT_EXECUTABLES)/checkpolicy \
$(HOST_OUT_EXECUTABLES)/build_sepolicy $(system_ext_pub_policy_$(ver).conf) $(reqd_policy_mask_$(ver).cil)
	@mkdir -p $(dir $@)
	$(hide) $(CHECKPOLICY_ASAN_OPTIONS) $< -C -M -c $(POLICYVERS) -o $@ $(PRIVATE_POL_CONF)
	$(hide) $(HOST_OUT_EXECUTABLES)/build_sepolicy -a $(HOST_OUT_EXECUTABLES) filter_out \
		-f $(PRIVATE_REQD_MASK) -t $@

system_ext_pub_policy_$(ver).conf :=

##################################
# system_ext_policy_$(ver).cil: system_ext policy
#
policy_files := $(call build_policy, $(sepolicy_build_files), \
  $(plat_public_policy_$(ver)) $(plat_private_policy_$(ver)) \
  $(system_ext_public_policy_$(ver)) $(system_ext_private_policy_$(ver)) )
system_ext_policy_$(ver).conf := $(intermediates)/system_ext_policy_$(ver).conf
$(eval $(call policy-to-conf-rule,$(system_ext_policy_$(ver).conf)))

system_ext_policy_$(ver).cil := $(intermediates)/system_ext_policy_$(ver).cil
$(system_ext_policy_$(ver).cil): PRIVATE_NEVERALLOW_ARG := $(NEVERALLOW_ARG)
$(system_ext_policy_$(ver).cil): PRIVATE_PLAT_CIL := $(built_plat_cil_$(ver))
$(system_ext_policy_$(ver).cil): $(system_ext_policy_$(ver).conf) $(HOST_OUT_EXECUTABLES)/checkpolicy \
$(HOST_OUT_EXECUTABLES)/build_sepolicy $(HOST_OUT_EXECUTABLES)/secilc $(built_plat_cil_$(ver))
	@mkdir -p $(dir $@)
	$(hide) $(CHECKPOLICY_ASAN_OPTIONS) $(HOST_OUT_EXECUTABLES)/checkpolicy -M -C -c \
	$(POLICYVERS) -o $@ $<
	$(hide) $(HOST_OUT_EXECUTABLES)/build_sepolicy -a $(HOST_OUT_EXECUTABLES) filter_out \
		-f $(PRIVATE_PLAT_CIL) -t $@
	# Line markers (denoted by ;;) are malformed after above cmd. They are only
	# used for debugging, so we remove them.
	$(hide) grep -v ';;' $@ > $@.tmp
	$(hide) mv $@.tmp $@
	# Combine plat_sepolicy.cil and system_ext_sepolicy.cil to make sure that the
	# latter doesn't accidentally depend on vendor/odm policies.
	$(hide) $(HOST_OUT_EXECUTABLES)/secilc -m -M true -G -c $(POLICYVERS) \
		$(PRIVATE_NEVERALLOW_ARG) $(PRIVATE_PLAT_CIL) $@ -o /dev/null -f /dev/null

system_ext_policy_$(ver).conf :=

built_system_ext_cil_$(ver) := $(system_ext_policy_$(ver).cil)

##################################
# system_ext_mapping_cil_$(ver).cil: versioned exported system_ext policy
#
system_ext_mapping_cil_$(ver) := $(intermediates)/system_ext_mapping_$(ver).cil
$(system_ext_mapping_cil_$(ver)) : PRIVATE_VERS := $(ver)
$(system_ext_mapping_cil_$(ver)) : PRIVATE_PLAT_MAPPING_CIL := $(built_plat_mapping_cil_$(ver))
$(system_ext_mapping_cil_$(ver)) : $(HOST_OUT_EXECUTABLES)/version_policy
$(system_ext_mapping_cil_$(ver)) : $(HOST_OUT_EXECUTABLES)/build_sepolicy
$(system_ext_mapping_cil_$(ver)) : $(built_plat_mapping_cil_$(ver))
$(system_ext_mapping_cil_$(ver)) : $(system_ext_pub_policy_$(ver).cil)
	@mkdir -p $(dir $@)
	# Generate system_ext mapping file as mapping file of 'system' (plat) and 'system_ext'
	# sepolicy minus plat_mapping_file.
	$(hide) $(HOST_OUT_EXECUTABLES)/version_policy -b $< -m -n $(PRIVATE_VERS) -o $@
	$(hide) $(HOST_OUT_EXECUTABLES)/build_sepolicy -a $(HOST_OUT_EXECUTABLES) filter_out \
		-f $(PRIVATE_PLAT_MAPPING_CIL) -t $@

built_system_ext_mapping_cil_$(ver) := $(system_ext_mapping_cil_$(ver))

endif # ifdef HAS_SYSTEM_EXT_SEPOLICY_DIR

ifdef HAS_PRODUCT_SEPOLICY_DIR

##################################
# product_policy_$(ver).cil: product policy
#
policy_files := $(call build_policy, $(sepolicy_build_files), \
  $(plat_public_policy_$(ver)) $(plat_private_policy_$(ver)) \
  $(system_ext_public_policy_$(ver)) $(system_ext_private_policy_$(ver)) \
  $(product_public_policy_$(ver)) $(product_private_policy_$(ver)) )
product_policy_$(ver).conf := $(intermediates)/product_policy_$(ver).conf
$(eval $(call policy-to-conf-rule,$(product_policy_$(ver).conf)))

product_policy_$(ver).cil := $(intermediates)/product_policy_$(ver).cil
$(product_policy_$(ver).cil): PRIVATE_NEVERALLOW_ARG := $(NEVERALLOW_ARG)
$(product_policy_$(ver).cil): PRIVATE_PLAT_CIL_FILES := $(built_plat_cil_$(ver)) $(built_system_ext_cil_$(ver))
$(product_policy_$(ver).cil): $(product_policy_$(ver).conf) $(HOST_OUT_EXECUTABLES)/checkpolicy \
$(HOST_OUT_EXECUTABLES)/build_sepolicy $(HOST_OUT_EXECUTABLES)/secilc \
$(built_plat_cil_$(ver)) $(built_system_ext_cil_$(ver))
	@mkdir -p $(dir $@)
	$(hide) $(CHECKPOLICY_ASAN_OPTIONS) $(HOST_OUT_EXECUTABLES)/checkpolicy -M -C -c \
	$(POLICYVERS) -o $@ $<
	$(hide) $(HOST_OUT_EXECUTABLES)/build_sepolicy -a $(HOST_OUT_EXECUTABLES) filter_out \
		-f $(PRIVATE_PLAT_CIL) -t $@
	# Line markers (denoted by ;;) are malformed after above cmd. They are only
	# used for debugging, so we remove them.
	$(hide) grep -v ';;' $@ > $@.tmp
	$(hide) mv $@.tmp $@
	# Combine plat_sepolicy.cil, system_ext_sepolicy.cil and product_sepolicy.cil to
	# make sure that the latter doesn't accidentally depend on vendor/odm policies.
	$(hide) $(HOST_OUT_EXECUTABLES)/secilc -m -M true -G -c $(POLICYVERS) \
		$(PRIVATE_NEVERALLOW_ARG) $(PRIVATE_PLAT_CIL_FILES) $@ -o /dev/null -f /dev/null

product_policy_$(ver).conf :=

built_product_cil_$(ver) := $(product_policy_$(ver).cil)

endif # ifdef HAS_PRODUCT_SEPOLICY_DIR

##################################
# pub_policy_$(ver).cil: exported plat, system_ext, and product policies
#
policy_files := $(call build_policy, $(sepolicy_build_files), \
  $(plat_public_policy_$(ver)) $(system_ext_public_policy_$(ver)) \
  $(product_public_policy_$(ver)) $(reqd_policy_$(ver)) )
pub_policy_$(ver).conf := $(intermediates)/pub_policy_$(ver).conf
$(eval $(call policy-to-conf-rule,$(pub_policy_$(ver).conf)))

pub_policy_$(ver).cil := $(intermediates)/pub_policy_$(ver).cil
$(pub_policy_$(ver).cil): PRIVATE_POL_CONF := $(pub_policy_$(ver).conf)
$(pub_policy_$(ver).cil): PRIVATE_REQD_MASK := $(reqd_policy_mask_$(ver).cil)
$(pub_policy_$(ver).cil): $(HOST_OUT_EXECUTABLES)/checkpolicy \
$(HOST_OUT_EXECUTABLES)/build_sepolicy $(pub_policy_$(ver).conf) $(reqd_policy_mask_$(ver).cil)
	@mkdir -p $(dir $@)
	$(hide) $(CHECKPOLICY_ASAN_OPTIONS) $< -C -M -c $(POLICYVERS) -o $@ $(PRIVATE_POL_CONF)
	$(hide) $(HOST_OUT_EXECUTABLES)/build_sepolicy -a $(HOST_OUT_EXECUTABLES) filter_out \
		-f $(PRIVATE_REQD_MASK) -t $@

pub_policy_$(ver).conf :=

ifdef HAS_PRODUCT_SEPOLICY_DIR

##################################
# product_mapping_cil_$(ver).cil: versioned exported product policy
#
product_mapping_cil_$(ver) := $(intermediates)/product_mapping_cil_$(ver).cil
$(product_mapping_cil_$(ver)) : PRIVATE_VERS := $(ver)
$(product_mapping_cil_$(ver)) : PRIVATE_FILTER_CIL_FILES := $(built_plat_mapping_cil_$(ver)) $(built_system_ext_mapping_cil_$(ver))
$(product_mapping_cil_$(ver)) : $(pub_policy_$(ver).cil)
$(product_mapping_cil_$(ver)) : $(HOST_OUT_EXECUTABLES)/build_sepolicy
$(product_mapping_cil_$(ver)) : $(HOST_OUT_EXECUTABLES)/version_policy
$(product_mapping_cil_$(ver)) : $(built_plat_mapping_cil_$(ver))
$(product_mapping_cil_$(ver)) : $(built_system_ext_mapping_cil_$(ver))
	@mkdir -p $(dir $@)
	# Generate product mapping file as mapping file of all public sepolicy minus
	# plat_mapping_file and system_ext_mapping_file.
	$(hide) $(HOST_OUT_EXECUTABLES)/version_policy -b $< -m -n $(PRIVATE_VERS) -o $@
	$(hide) $(HOST_OUT_EXECUTABLES)/build_sepolicy -a $(HOST_OUT_EXECUTABLES) filter_out \
		-f $(PRIVATE_FILTER_CIL_FILES) -t $@

built_product_mapping_cil_$(ver) := $(product_mapping_cil_$(ver))

endif # ifdef HAS_PRODUCT_SEPOLICY_DIR

##################################
# plat_pub_versioned_$(ver).cil - the exported platform policy
#
plat_pub_versioned_$(ver).cil := $(intermediates)/plat_pub_versioned_$(ver).cil
$(plat_pub_versioned_$(ver).cil) : PRIVATE_VERS := $(ver)
$(plat_pub_versioned_$(ver).cil) : PRIVATE_TGT_POL := $(pub_policy_$(ver).cil)
$(plat_pub_versioned_$(ver).cil) : PRIVATE_DEP_CIL_FILES := $(built_plat_cil_$(ver)) $(built_system_ext_cil_$(ver)) \
$(built_product_cil_$(ver)) $(built_plat_mapping_cil_$(ver)) $(built_system_ext_mapping_cil_$(ver)) \
$(built_product_mapping_cil_$(ver))
$(plat_pub_versioned_$(ver).cil) : $(pub_policy_$(ver).cil) $(HOST_OUT_EXECUTABLES)/version_policy \
  $(HOST_OUT_EXECUTABLES)/secilc $(built_plat_cil_$(ver)) $(built_system_ext_cil_$(ver)) $(built_product_cil_$(ver)) \
  $(built_plat_mapping_cil_$(ver)) $(built_system_ext_mapping_cil_$(ver)) $(built_product_mapping_cil_$(ver))
	@mkdir -p $(dir $@)
	$(HOST_OUT_EXECUTABLES)/version_policy -b $< -t $(PRIVATE_TGT_POL) -n $(PRIVATE_VERS) -o $@
	$(hide) $(HOST_OUT_EXECUTABLES)/secilc -m -M true -G -N -c $(POLICYVERS) \
		$(PRIVATE_DEP_CIL_FILES) $@ -o /dev/null -f /dev/null

built_pub_vers_cil_$(ver) := $(plat_pub_versioned_$(ver).cil)
