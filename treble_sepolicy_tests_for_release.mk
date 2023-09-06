version := $(version_under_treble_tests)

include $(CLEAR_VARS)
# For Treble builds run tests verifying that processes are properly labeled and
# permissions granted do not violate the treble model.  Also ensure that treble
# compatibility guarantees are upheld between SELinux version bumps.
LOCAL_MODULE := treble_sepolicy_tests_$(version)
LOCAL_LICENSE_KINDS := SPDX-license-identifier-Apache-2.0 legacy_unencumbered
LOCAL_LICENSE_CONDITIONS := notice unencumbered
LOCAL_NOTICE_FILE := $(LOCAL_PATH)/NOTICE
LOCAL_MODULE_CLASS := FAKE
LOCAL_MODULE_TAGS := optional

IS_TREBLE_TEST_ENABLED_PARTNER := false
ifeq ($(filter 26.0 27.0 28.0 29.0,$(version)),)
ifneq (,$(BOARD_SYSTEM_EXT_PREBUILT_DIR)$(BOARD_PRODUCT_PREBUILT_DIR))
IS_TREBLE_TEST_ENABLED_PARTNER := true
endif # (,$(SYSTEM_EXT_PREBUILT_POLICY)$(PRODUCT_PREBUILT_POLICY))
endif # ($(filter 26.0 27.0 28.0 29.0,$(version)),)

include $(BUILD_SYSTEM)/base_rules.mk

# $(version)_plat - the platform policy shipped as part of the $(version) release.  This is
# built to enable us to determine the diff between the current policy and the
# $(version) policy, which will be used in tests to make sure that compatibility has
# been maintained by our mapping files.
built_$(version)_plat_sepolicy_cil := $(call intermediates-dir-for,ETC,$(version)_plat_policy.cil)/$(version)_plat_policy.cil

$(version)_mapping.cil := $(call intermediates-dir-for,ETC,plat_$(version).cil)/plat_$(version).cil
$(version)_mapping.ignore.cil := \
    $(call intermediates-dir-for,ETC,$(version).ignore.cil)/$(version).ignore.cil
ifeq ($(IS_TREBLE_TEST_ENABLED_PARTNER),true)
ifneq (,$(SYSTEM_EXT_PREBUILT_POLICY))
$(version)_mapping.cil += \
    $(call intermediates-dir-for,ETC,system_ext_$(version).cil)/system_ext_$(version).cil
$(version)_mapping.ignore.cil += \
    $(call intermediates-dir-for,ETC,system_ext_$(version).ignore.cil)/system_ext_$(version).ignore.cil
endif # (,$(SYSTEM_EXT_PREBUILT_POLICY))
ifneq (,$(PRODUCT_PREBUILT_POLICY))
$(version)_mapping.cil += \
    $(call intermediates-dir-for,ETC,product_$(version).cil)/product_$(version).cil
$(version)_mapping.ignore.cil += \
    $(call intermediates-dir-for,ETC,product_$(version).ignore.cil)/product_$(version).ignore.cil
endif # (,$(PRODUCT_PREBUILT_POLICY))
endif #($(IS_TREBLE_TEST_ENABLED_PARTNER),true)

# $(version)_mapping.combined.cil - a combination of the mapping file used when
# combining the current platform policy with nonplatform policy based on the
# $(version) policy release and also a special ignored file that exists purely for
# these tests.
intermediates := $(TARGET_OUT_INTERMEDIATES)/ETC/$(LOCAL_MODULE)_intermediates
$(version)_mapping.combined.cil := $(intermediates)/$(version)_mapping.combined.cil
$($(version)_mapping.combined.cil): $($(version)_mapping.cil) $($(version)_mapping.ignore.cil)
	mkdir -p $(dir $@)
	cat $^ > $@

ifeq ($(IS_TREBLE_TEST_ENABLED_PARTNER),true)
public_cil_files := $(base_product_pub_policy.cil)
else
public_cil_files := $(base_plat_pub_policy.cil)
endif # ($(IS_TREBLE_TEST_ENABLED_PARTNER),true)
$(LOCAL_BUILT_MODULE): PRIVATE_SEPOLICY_OLD := $(built_$(version)_plat_sepolicy_cil)
$(LOCAL_BUILT_MODULE): PRIVATE_COMBINED_MAPPING := $($(version)_mapping.combined.cil)
$(LOCAL_BUILT_MODULE): PRIVATE_PLAT_PUB_SEPOLICY := $(public_cil_files)
$(LOCAL_BUILT_MODULE): $(HOST_OUT_EXECUTABLES)/treble_sepolicy_tests \
  $(public_cil_files) \
  $(built_$(version)_plat_sepolicy_cil) $($(version)_mapping.combined.cil)
	@mkdir -p $(dir $@)
	$(hide) $(HOST_OUT_EXECUTABLES)/treble_sepolicy_tests \
                -b $(PRIVATE_PLAT_PUB_SEPOLICY) -m $(PRIVATE_COMBINED_MAPPING) \
                -o $(PRIVATE_SEPOLICY_OLD)
	$(hide) touch $@

built_sepolicy_files :=
public_cil_files :=
$(version)_mapping.cil :=
$(version)_mapping.combined.cil :=
$(version)_mapping.ignore.cil :=
built_$(version)_plat_sepolicy :=
version :=
version_under_treble_tests :=
