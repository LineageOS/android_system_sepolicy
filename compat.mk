version := $(version_under_treble_tests)

include $(CLEAR_VARS)
#################################
# build this target to ensure the compat permissions files all build against the current policy
#
LOCAL_MODULE := $(version)_compat_test
LOCAL_REQUIRED_MODULES := $(version).compat.cil
intermediates := $(TARGET_OUT_INTERMEDIATES)/ETC/sepolicy_intermediates

all_cil_files := \
    $(built_plat_cil) \
    $(built_plat_mapping_cil) \
    $(built_pub_vers_cil) \
    $(built_vendor_cil) \
    $(ALL_MODULES.$(version).compat.cil.BUILT) \

ifdef HAS_PRODUCT_SEPOLICY
all_cil_files += \
    $(built_product_cil) \
    $(built_product_mapping_cil) \

endif

ifdef BOARD_ODM_SEPOLICY_DIRS
all_cil_files += $(built_odm_cil)
endif

compat_test := $(intermediates)/$(LOCAL_MODULE)
droidcore: $(compat_test)
$(version)_compat_test: $(compat_test)
.PHONY: $(version)_compat_test
$(compat_test): PRIVATE_CIL_FILES := $(all_cil_files)
$(compat_test): $(HOST_OUT_EXECUTABLES)/secilc $(HOST_OUT_EXECUTABLES)/sepolicy-analyze $(all_cil_files)
	@mkdir -p $(dir $@)
	$(hide) $< -m -N -M true -G -c $(POLICYVERS) $(PRIVATE_CIL_FILES) -o $@ -f /dev/null

compat_test :=
all_cil_files :=
version :=
version_under_treble_tests :=
