ifeq ($(HAVE_SELINUX),true)

LOCAL_PATH:= $(call my-dir)
include $(CLEAR_VARS)

# SELinux policy version.
# Must be <= /selinux/policyvers reported by the Android kernel.
# Must be within the compatibility range reported by checkpolicy -V.
POLICYVERS := 24

MLS_SENS=1
MLS_CATS=1024

LOCAL_POLICY_DIRS := $(SRC_TARGET_DIR)/board/$(TARGET_DEVICE)/ device/*/$(TARGET_DEVICE)/ vendor/*/$(TARGET_DEVICE)/

LOCAL_POLICY_FC := $(wildcard $(addsuffix sepolicy.fc, $(LOCAL_POLICY_DIRS)))
LOCAL_POLICY_TE := $(wildcard $(addsuffix sepolicy.te, $(LOCAL_POLICY_DIRS)))
LOCAL_POLICY_PC := $(wildcard $(addsuffix sepolicy.pc, $(LOCAL_POLICY_DIRS)))

##################################
include $(CLEAR_VARS)

LOCAL_MODULE := sepolicy
LOCAL_MODULE_CLASS := ETC
LOCAL_MODULE_TAGS := optional
LOCAL_MODULE_SUFFIX := .$(POLICYVERS)
LOCAL_MODULE_PATH := $(TARGET_ROOT_OUT)

include $(BUILD_SYSTEM)/base_rules.mk

sepolicy_policy.conf := $(intermediates)/policy.conf
$(sepolicy_policy.conf): PRIVATE_MLS_SENS := $(MLS_SENS)
$(sepolicy_policy.conf): PRIVATE_MLS_CATS := $(MLS_CATS)
$(sepolicy_policy.conf) : $(wildcard $(addprefix $(LOCAL_PATH)/,security_classes initial_sids access_vectors global_macros mls_macros mls policy_capabilities te_macros attributes *.te) $(LOCAL_POLICY_TE) $(addprefix $(LOCAL_PATH)/, roles users ocontexts))
	@mkdir -p $(dir $@)
	$(hide) m4 -D mls_num_sens=$(PRIVATE_MLS_SENS) -D mls_num_cats=$(PRIVATE_MLS_CATS) -s $^ > $@

$(LOCAL_BUILT_MODULE) : $(sepolicy_policy.conf) $(HOST_OUT_EXECUTABLES)/checkpolicy
	@mkdir -p $(dir $@)
	$(hide) $(HOST_OUT_EXECUTABLES)/checkpolicy -M -c $(POLICYVERS) -o $@ $<

sepolicy_policy.conf :=
##################################
include $(CLEAR_VARS)

LOCAL_MODULE := file_contexts
LOCAL_MODULE_CLASS := ETC
LOCAL_MODULE_TAGS := optional
LOCAL_MODULE_PATH := $(TARGET_ROOT_OUT)

include $(BUILD_SYSTEM)/base_rules.mk

file_contexts := $(intermediates)/file_contexts
$(file_contexts): $(LOCAL_PATH)/file_contexts $(LOCAL_POLICY_FC)
	@mkdir -p $(dir $@)
	$(hide) cat $^ > $@

file_contexts :=
##################################
include $(CLEAR_VARS)

LOCAL_MODULE := seapp_contexts
LOCAL_SRC_FILES := $(LOCAL_MODULE)
LOCAL_MODULE_CLASS := ETC
LOCAL_MODULE_TAGS := optional
LOCAL_MODULE_PATH := $(TARGET_ROOT_OUT)

include $(BUILD_PREBUILT)

##################################
include $(CLEAR_VARS)

LOCAL_MODULE := property_contexts
LOCAL_MODULE_CLASS := ETC
LOCAL_MODULE_TAGS := optional
LOCAL_MODULE_PATH := $(TARGET_ROOT_OUT)

include $(BUILD_SYSTEM)/base_rules.mk

property_contexts := $(intermediates)/property_contexts
$(property_contexts): $(LOCAL_PATH)/property_contexts $(LOCAL_POLICY_PC)
	@mkdir -p $(dir $@)
	$(hide) cat $^ > $@

property_contexts :=
##################################

endif #ifeq ($(HAVE_SELINUX),true)
