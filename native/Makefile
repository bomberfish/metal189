# metal189 native library + shader library
JAVA_HOME ?= /Library/Java/JavaVirtualMachines/zulu-8.jdk/Contents/Home
BUILD     := build
SRC       := $(wildcard src/*.mm)
OBJ       := $(patsubst src/%.mm,$(BUILD)/obj/%.o,$(SRC))
HDR       := $(wildcard src/*.h) $(wildcard shaders/*.h)
SHADERS   := $(wildcard shaders/*.metal)
AIR       := $(patsubst shaders/%.metal,$(BUILD)/air/%.air,$(SHADERS))

CXXFLAGS  := -std=c++20 -O2 -g -fobjc-arc -fvisibility=hidden -Wall -Wextra -Wno-unused-parameter \
             -mmacosx-version-min=14.0 -arch arm64 -arch x86_64 \
             -I$(JAVA_HOME)/include -I$(JAVA_HOME)/include/darwin -Isrc -Ishaders
LDFLAGS   := -dynamiclib -arch arm64 -arch x86_64 -mmacosx-version-min=14.0 \
             -framework Cocoa -framework Metal -framework MetalFX -framework QuartzCore -framework CoreVideo \
             -framework IOKit -framework CoreGraphics -framework ImageIO -framework UniformTypeIdentifiers -install_name @rpath/libmetal189.dylib
MTLFLAGS  := -std=metal3.1 -O3 -ffast-math -Ishaders -Wall

all: $(BUILD)/libmetal189.dylib $(BUILD)/metal189.metallib

$(BUILD)/obj/%.o: src/%.mm $(HDR)
	@mkdir -p $(dir $@)
	clang++ $(CXXFLAGS) -c $< -o $@

$(BUILD)/libmetal189.dylib: $(OBJ)
	clang++ $(LDFLAGS) $(OBJ) -o $@

$(BUILD)/air/%.air: shaders/%.metal $(wildcard shaders/*.h)
	@mkdir -p $(dir $@)
	xcrun -sdk macosx metal $(MTLFLAGS) -c $< -o $@

$(BUILD)/metal189.metallib: $(AIR)
	xcrun -sdk macosx metallib $(AIR) -o $@

# ---- iOS (experimental, for launchers such as PojavLauncher): arm64, iOS 17 (Metal 3.1) ----
IOS_BUILD    := build-ios
IOS_SDK      := $(shell xcrun --sdk iphoneos --show-sdk-path)
IOS_OBJ      := $(patsubst src/%.mm,$(IOS_BUILD)/obj/%.o,$(SRC))
IOS_AIR      := $(patsubst shaders/%.metal,$(IOS_BUILD)/air/%.air,$(SHADERS))
IOS_CXXFLAGS := -std=c++20 -O2 -g -fobjc-arc -fvisibility=hidden -Wall -Wextra -Wno-unused-parameter \
                -isysroot $(IOS_SDK) -miphoneos-version-min=17.0 -arch arm64 \
                -I$(JAVA_HOME)/include -I$(JAVA_HOME)/include/darwin -Isrc -Ishaders
IOS_LDFLAGS  := -dynamiclib -isysroot $(IOS_SDK) -miphoneos-version-min=17.0 -arch arm64 \
                -framework Foundation -framework UIKit -framework Metal -framework MetalFX -framework QuartzCore \
                -framework CoreGraphics -framework ImageIO -framework UniformTypeIdentifiers \
                -install_name @rpath/libmetal189.dylib

ios: $(IOS_BUILD)/libmetal189.dylib $(IOS_BUILD)/metal189.metallib

$(IOS_BUILD)/obj/%.o: src/%.mm $(HDR)
	@mkdir -p $(dir $@)
	clang++ $(IOS_CXXFLAGS) -c $< -o $@

# ad-hoc signed: iOS loads only signed code (a launcher may re-sign it with its own identity)
$(IOS_BUILD)/libmetal189.dylib: $(IOS_OBJ)
	clang++ $(IOS_LDFLAGS) $(IOS_OBJ) -o $@
	codesign --force --sign - $@

$(IOS_BUILD)/air/%.air: shaders/%.metal $(wildcard shaders/*.h)
	@mkdir -p $(dir $@)
	xcrun -sdk iphoneos metal $(MTLFLAGS) -c $< -o $@

$(IOS_BUILD)/metal189.metallib: $(IOS_AIR)
	xcrun -sdk iphoneos metallib $(IOS_AIR) -o $@

clean:
	rm -rf $(BUILD) $(IOS_BUILD)

.PHONY: all ios clean
