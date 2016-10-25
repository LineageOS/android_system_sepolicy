# Command to turn collection of policy files into a policy.conf file to be
# processed by checkpolicy
define transform-policy-to-conf
@mkdir -p $(dir $@)
$(hide) m4 $(PRIVATE_ADDITIONAL_M4DEFS) \
	-D mls_num_sens=$(PRIVATE_MLS_SENS) -D mls_num_cats=$(PRIVATE_MLS_CATS) \
	-D target_build_variant=$(PRIVATE_TARGET_BUILD_VARIANT) \
	-D target_with_dexpreopt=$(WITH_DEXPREOPT) \
	-D target_arch=$(PRIVATE_TGT_ARCH) \
	-D target_with_asan=$(PRIVATE_TGT_WITH_ASAN) \
	-D target_full_treble=$(PRIVATE_SEPOLICY_SPLIT) \
	-D target_compatible_property=$(PRIVATE_COMPATIBLE_PROPERTY) \
	-D target_has_legacy_camera_hal1=$(TARGET_HAS_LEGACY_CAMERA_HAL1) \
	-D target_needs_platform_text_relocations=$(TARGET_NEEDS_PLATFORM_TEXT_RELOCATIONS) \
	$(PRIVATE_TGT_RECOVERY) \
	-s $^ > $@
endef
.KATI_READONLY := transform-policy-to-conf
