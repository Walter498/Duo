ARCHS = arm64e
TARGET = iphone:clang:17.3.1:14.0
INSTALL_TARGET_PROCESSES = SpringBoard
THEOS_PACKAGE_SCHEME = rootless

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = LockLayout
LockLayout_FILES = Tweak.xm
LockLayout_CFLAGS = -fobjc-arc

include $(THEOS_MAKE_PATH)/tweak.mk

SUBPROJECTS += lockprefs
include $(THEOS_MAKE_PATH)/aggregate.mk