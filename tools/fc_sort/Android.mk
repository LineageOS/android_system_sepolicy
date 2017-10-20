LOCAL_PATH:= $(call my-dir)

include $(CLEAR_VARS)

LOCAL_MODULE := fc_sort
LOCAL_MODULE_TAGS := optional
LOCAL_SRC_FILES := fc_sort.c
LOCAL_CFLAGS := -Wall -Werror
LOCAL_CXX_STL := none

include $(BUILD_HOST_EXECUTABLE)

###################################
