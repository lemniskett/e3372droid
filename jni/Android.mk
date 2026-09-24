LOCAL_PATH := $(call my-dir)

include $(CLEAR_VARS)
LOCAL_MODULE := usb_modeswitch
LOCAL_SRC_FILES := usb_modeswitch.c
LOCAL_CFLAGS := -Wall -Wextra -O2
include $(BUILD_EXECUTABLE)
