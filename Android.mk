LOCAL_PATH:= $(call my-dir)
include $(CLEAR_VARS)

# SELinux policy version.
# Must be <= /selinux/policyvers reported by the Android kernel.
# Must be within the compatibility range reported by checkpolicy -V.
POLICYVERS := 24

MLS_SENS=1
MLS_CATS=1024

file := $(TARGET_ROOT_OUT)/policy.$(POLICYVERS)
$(file) : $(LOCAL_PATH)/policy.$(POLICYVERS) | $(ACP)
	$(transform-prebuilt-to-target)
ALL_PREBUILT += $(file)
$(INSTALLED_RAMDISK_TARGET): $(file)

$(LOCAL_PATH)/policy.$(POLICYVERS): $(LOCAL_PATH)/policy.conf
	checkpolicy -M -c $(POLICYVERS) -o $@ $<

$(LOCAL_PATH)/policy.conf: $(wildcard $(addprefix $(LOCAL_PATH)/,security_classes initial_sids access_vectors global_macros mls_macros mls policy_capabilities te_macros attributes *.te roles users ocontexts))
	m4 -D mls_num_sens=$(MLS_SENS) -D mls_num_cats=$(MLS_CATS) -s $^ > $@

file := $(TARGET_ROOT_OUT)/file_contexts
$(file) : $(LOCAL_PATH)/file_contexts | $(ACP)
	$(transform-prebuilt-to-target)
ALL_PREBUILT += $(file)
$(INSTALLED_RAMDISK_TARGET): $(file)

file := $(TARGET_ROOT_OUT)/seapp_contexts
$(file) : $(LOCAL_PATH)/seapp_contexts | $(ACP)
	$(transform-prebuilt-to-target)
ALL_PREBUILT += $(file)
$(INSTALLED_RAMDISK_TARGET): $(file)
