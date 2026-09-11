ARCHS = arm64 arm64e
TARGET = iphone:clang:latest:14.0
INSTALL_TARGET_PROCESSES = LiveProcess LiveContainer

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = Cytus2120FPS
Cytus2120FPS_FILES = Tweak.mm
Cytus2120FPS_CFLAGS = -fobjc-arc -Wno-unused-function -Wno-unused-variable
Cytus2120FPS_FRAMEWORKS = Foundation UIKit QuartzCore

include $(THEOS_MAKE_PATH)/tweak.mk
