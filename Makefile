ARCHS = arm64e
TARGET = iphone:clang:17.3.1:14.0
INSTALL_TARGET_PROCESSES = SpringBoard
THEOS_PACKAGE_SCHEME = rootless

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = DuoStatusBar
DuoStatusBar_FILES = src/Tweak.xm
DuoStatusBar_CFLAGS = -fobjc-arc
DuoStatusBar_LIBRARIES = substrate

include $(THEOS_MAKE_PATH)/tweak.mk

SUBPROJECTS += duostatusprefs
include $(THEOS_MAKE_PATH)/aggregate.mk
