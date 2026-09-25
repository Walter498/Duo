ARCHS = arm64e
TARGET = iphone:clang:17.3.1:14.0

include $(THEOS)/makefiles/common.mk

BUNDLE_NAME = LockLayoutPrefs
LockLayoutPrefs_FILES = LockLayoutRootListController.m
LockLayoutPrefs_INSTALL_PATH = /Library/PreferenceBundles
LockLayoutPrefs_FRAMEWORKS = UIKit
LockLayoutPrefs_CFLAGS = -fobjc-arc
LockLayoutPrefs_LDFLAGS = -undefined dynamic_lookup

include $(THEOS_MAKE_PATH)/bundle.mk

internal-stage::
	$(ECHO_NOTHING)mkdir -p $(THEOS_STAGING_DIR)/Library/PreferenceLoader/Preferences$(ECHO_END)
	$(ECHO_NOTHING)cp entry.plist $(THEOS_STAGING_DIR)/Library/PreferenceLoader/Preferences/LockLayoutPrefs.plist$(ECHO_END)