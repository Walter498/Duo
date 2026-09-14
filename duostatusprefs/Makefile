ARCHS = arm64e
TARGET = iphone:clang:17.3.1:14.0

include $(THEOS)/makefiles/common.mk

BUNDLE_NAME = DuoStatusPrefs
DuoStatusPrefs_FILES = DuoStatusRootListController.m
DuoStatusPrefs_INSTALL_PATH = /Library/PreferenceBundles
DuoStatusPrefs_FRAMEWORKS = UIKit
DuoStatusPrefs_PRIVATE_FRAMEWORKS = Preferences
DuoStatusPrefs_CFLAGS = -fobjc-arc

include $(THEOS_MAKE_PATH)/bundle.mk

internal-stage::
	$(ECHO_NOTHING)mkdir -p $(THEOS_STAGING_DIR)/Library/PreferenceLoader/Preferences$(ECHO_END)
	$(ECHO_NOTHING)cp entry.plist $(THEOS_STAGING_DIR)/Library/PreferenceLoader/Preferences/DuoStatusPrefs.plist$(ECHO_END)
