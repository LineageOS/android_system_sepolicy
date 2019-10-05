# Copyright (C) 2019 The Android Open Source Project
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

include $(CLEAR_VARS)

# TODO: move tests into Soong after refactoring sepolicy module (b/130693869)

# Run host-side test with contexts files and the sepolicy file.
# $(1): paths to contexts files
# $(2): path to the host tool
# $(3): additional argument to be passed to the tool
define run_contexts_test
$$(LOCAL_BUILT_MODULE): PRIVATE_CONTEXTS := $(1)
$$(LOCAL_BUILT_MODULE): PRIVATE_SEPOLICY := $$(built_sepolicy)
$$(LOCAL_BUILT_MODULE): $(2) $(1) $$(built_sepolicy)
	$$(hide) $$< $(3) $$(PRIVATE_SEPOLICY) $$(PRIVATE_CONTEXTS)
	$$(hide) mkdir -p $$(dir $$@)
	$$(hide) touch $$@
endef

system_out := $(TARGET_OUT)/etc/selinux
system_ext_out := $(TARGET_OUT_SYSTEM_EXT)/etc/selinux
product_out := $(TARGET_OUT_PRODUCT)/etc/selinux
vendor_out := $(TARGET_OUT_VENDOR)/etc/selinux
odm_out := $(TARGET_OUT_ODM)/etc/selinux

checkfc := $(HOST_OUT_EXECUTABLES)/checkfc
property_info_checker := $(HOST_OUT_EXECUTABLES)/property_info_checker

##################################
LOCAL_MODULE := plat_file_contexts_test
LOCAL_MODULE_CLASS := FAKE
LOCAL_MODULE_TAGS := optional

include $(BUILD_SYSTEM)/base_rules.mk

$(eval $(call run_contexts_test, $(system_out)/plat_file_contexts, $(checkfc),))

##################################
include $(CLEAR_VARS)

LOCAL_MODULE := system_ext_file_contexts_test
LOCAL_MODULE_CLASS := FAKE
LOCAL_MODULE_TAGS := optional

include $(BUILD_SYSTEM)/base_rules.mk

$(eval $(call run_contexts_test, $(system_ext_out)/system_ext_file_contexts, $(checkfc),))

##################################
include $(CLEAR_VARS)

LOCAL_MODULE := product_file_contexts_test
LOCAL_MODULE_CLASS := FAKE
LOCAL_MODULE_TAGS := optional

include $(BUILD_SYSTEM)/base_rules.mk

$(eval $(call run_contexts_test, $(product_out)/product_file_contexts, $(checkfc),))

##################################
include $(CLEAR_VARS)

LOCAL_MODULE := vendor_file_contexts_test
LOCAL_MODULE_CLASS := FAKE
LOCAL_MODULE_TAGS := optional

include $(BUILD_SYSTEM)/base_rules.mk

$(eval $(call run_contexts_test, $(vendor_out)/vendor_file_contexts, $(checkfc),))

##################################
include $(CLEAR_VARS)

LOCAL_MODULE := odm_file_contexts_test
LOCAL_MODULE_CLASS := FAKE
LOCAL_MODULE_TAGS := optional

include $(BUILD_SYSTEM)/base_rules.mk

$(eval $(call run_contexts_test, $(odm_out)/odm_file_contexts, $(checkfc),))

##################################

include $(CLEAR_VARS)

LOCAL_MODULE := plat_hwservice_contexts_test
LOCAL_MODULE_CLASS := FAKE
LOCAL_MODULE_TAGS := optional

include $(BUILD_SYSTEM)/base_rules.mk

$(eval $(call run_contexts_test, $(system_out)/plat_hwservice_contexts, $(checkfc), -e -l))

##################################
include $(CLEAR_VARS)

LOCAL_MODULE := system_ext_hwservice_contexts_test
LOCAL_MODULE_CLASS := FAKE
LOCAL_MODULE_TAGS := optional

include $(BUILD_SYSTEM)/base_rules.mk

$(eval $(call run_contexts_test, $(system_ext_out)/system_ext_hwservice_contexts, $(checkfc), -e -l))

##################################
include $(CLEAR_VARS)

LOCAL_MODULE := product_hwservice_contexts_test
LOCAL_MODULE_CLASS := FAKE
LOCAL_MODULE_TAGS := optional

include $(BUILD_SYSTEM)/base_rules.mk

$(eval $(call run_contexts_test, $(product_out)/product_hwservice_contexts, $(checkfc), -e -l))

##################################
include $(CLEAR_VARS)

LOCAL_MODULE := vendor_hwservice_contexts_test
LOCAL_MODULE_CLASS := FAKE
LOCAL_MODULE_TAGS := optional

include $(BUILD_SYSTEM)/base_rules.mk

$(eval $(call run_contexts_test, $(vendor_out)/vendor_hwservice_contexts, $(checkfc), -e -l))

##################################
include $(CLEAR_VARS)

LOCAL_MODULE := odm_hwservice_contexts_test
LOCAL_MODULE_CLASS := FAKE
LOCAL_MODULE_TAGS := optional

include $(BUILD_SYSTEM)/base_rules.mk

$(eval $(call run_contexts_test, $(odm_out)/odm_hwservice_contexts, $(checkfc), -e -l))

##################################

pc_files := $(system_out)/plat_property_contexts

include $(CLEAR_VARS)

LOCAL_MODULE := plat_property_contexts_test
LOCAL_MODULE_CLASS := FAKE
LOCAL_MODULE_TAGS := optional

include $(BUILD_SYSTEM)/base_rules.mk

$(eval $(call run_contexts_test, $(pc_files), $(property_info_checker),))

##################################

ifdef HAS_SYSTEM_EXT_SEPOLICY_DIR

pc_files += $(system_ext_out)/system_ext_property_contexts

include $(CLEAR_VARS)

LOCAL_MODULE := system_ext_property_contexts_test
LOCAL_MODULE_CLASS := FAKE
LOCAL_MODULE_TAGS := optional

include $(BUILD_SYSTEM)/base_rules.mk

$(eval $(call run_contexts_test, $(pc_files), $(property_info_checker),))

endif

##################################

pc_files += $(vendor_out)/vendor_property_contexts

include $(CLEAR_VARS)

LOCAL_MODULE := vendor_property_contexts_test
LOCAL_MODULE_CLASS := FAKE
LOCAL_MODULE_TAGS := optional

include $(BUILD_SYSTEM)/base_rules.mk

$(eval $(call run_contexts_test, $(pc_files), $(property_info_checker),))

##################################

ifdef BOARD_ODM_SEPOLICY_DIRS

pc_files += $(odm_out)/odm_property_contexts

include $(CLEAR_VARS)

LOCAL_MODULE := odm_property_contexts_test
LOCAL_MODULE_CLASS := FAKE
LOCAL_MODULE_TAGS := optional

include $(BUILD_SYSTEM)/base_rules.mk

$(eval $(call run_contexts_test, $(pc_files), $(property_info_checker),))

endif

##################################

ifdef HAS_PRODUCT_SEPOLICY_DIR

pc_files += $(product_out)/product_property_contexts

include $(CLEAR_VARS)

LOCAL_MODULE := product_property_contexts_test
LOCAL_MODULE_CLASS := FAKE
LOCAL_MODULE_TAGS := optional

include $(BUILD_SYSTEM)/base_rules.mk

$(eval $(call run_contexts_test, $(pc_files), $(property_info_checker),))

endif

pc_files :=

##################################
include $(CLEAR_VARS)

LOCAL_MODULE := plat_service_contexts_test
LOCAL_MODULE_CLASS := FAKE
LOCAL_MODULE_TAGS := optional

include $(BUILD_SYSTEM)/base_rules.mk

$(eval $(call run_contexts_test, $(system_out)/plat_service_contexts, $(checkfc), -s))

##################################
include $(CLEAR_VARS)

LOCAL_MODULE := system_ext_service_contexts_test
LOCAL_MODULE_CLASS := FAKE
LOCAL_MODULE_TAGS := optional

include $(BUILD_SYSTEM)/base_rules.mk

$(eval $(call run_contexts_test, $(system_ext_out)/system_ext_service_contexts, $(checkfc), -s))

##################################
include $(CLEAR_VARS)

LOCAL_MODULE := product_service_contexts_test
LOCAL_MODULE_CLASS := FAKE
LOCAL_MODULE_TAGS := optional

include $(BUILD_SYSTEM)/base_rules.mk

$(eval $(call run_contexts_test, $(product_out)/product_service_contexts, $(checkfc), -s))

##################################
# nonplat_service_contexts is only allowed on non-full-treble devices
ifneq ($(PRODUCT_SEPOLICY_SPLIT),true)

include $(CLEAR_VARS)

LOCAL_MODULE := vendor_service_contexts_test
LOCAL_MODULE_CLASS := FAKE
LOCAL_MODULE_TAGS := optional

include $(BUILD_SYSTEM)/base_rules.mk

$(eval $(call run_contexts_test, $(vendor_out)/vendor_service_contexts, $(checkfc), -s))

endif

system_out :=
product_out :=
vendor_out :=
odm_out :=
checkfc :=
property_info_checker :=
run_contexts_test :=
