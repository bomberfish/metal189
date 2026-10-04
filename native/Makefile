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

clean:
	rm -rf $(BUILD)

.PHONY: all clean
