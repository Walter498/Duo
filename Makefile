ARCHS = arm64e
TARGET = iphone:clang:17.3.1:14.0
INSTALL_TARGET_PROCESSES = SpringBoard
THEOS_PACKAGE_SCHEME = rootless

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = DuoStatusBar
DuoStatusBar_FILES = Tweak.xm
DuoStatusBar_CFLAGS = -fobjc-arc
DuoStatusBar_LIBRARIES = substrate

include $(THEOS_MAKE_PATH)/tweak.mk

# 零二進制設置頁：PreferenceLoader 直接渲染 plist，無需 bundle 可執行文件（規避 arm64e 限制）
internal-stage::
	$(ECHO_NOTHING)mkdir -p $(THEOS_STAGING_DIR)/Library/PreferenceLoader/Preferences$(ECHO_END)
	$(ECHO_NOTHING)cp prefs.plist $(THEOS_STAGING_DIR)/Library/PreferenceLoader/Preferences/DuoStatus.plist$(ECHO_END)
