# Project Kaiba - developer entry points.
#
# All native code lives under native/ and is built by SCons. These targets exist so the common
# flows are one word long and the flag combinations stay correct.
#
# Read AGENTS.md section 8 before changing any build flag.

SCONS       ?= scons
GODOT       ?= godot
NATIVE_DIR  := native
GAME_DIR    := game
TARGET      ?= template_debug
JOBS        ?= $(shell sysctl -n hw.ncpu 2>/dev/null || nproc 2>/dev/null || echo 4)

HOST_OS   := $(shell uname -s)
HOST_ARCH := $(shell uname -m)

ifeq ($(HOST_OS),Darwin)
  HOST_PLATFORM := macos
else ifeq ($(HOST_OS),Linux)
  HOST_PLATFORM := linux
else
  HOST_PLATFORM := windows
endif

ifeq ($(HOST_ARCH),aarch64)
  HOST_ARCH := arm64
endif

# disable_exceptions=no is mandatory: ocgcore raises Lua errors as C++ exceptions.
SCONS_COMMON := -C $(NATIVE_DIR) -j$(JOBS) target=$(TARGET) disable_exceptions=no

.PHONY: help doctor deps host android android-arm64 android-arm32 android-x86_64 selftest run editor clean distclean

help:
	@echo "Project Kaiba"
	@echo ""
	@echo "  make doctor     Show the detected toolchain and submodule state"
	@echo "  make deps       Install SCons and initialise submodules"
	@echo "  make host       Build the GDExtension for this machine ($(HOST_PLATFORM) $(HOST_ARCH))"
	@echo "  make android    Build all three Android ABIs"
	@echo "  make selftest   Build and run the headless ocgcore probe"
	@echo "  make run        Launch the Godot project"
	@echo "  make editor     Open the Godot editor on the project"
	@echo "  make clean      Remove build artefacts"
	@echo "  make distclean  Also remove built libraries from $(GAME_DIR)/bin"
	@echo ""
	@echo "  Override TARGET=template_release for optimised builds."

doctor:
	@echo "host platform : $(HOST_PLATFORM) $(HOST_ARCH)"
	@printf "scons         : "; $(SCONS) --version 2>/dev/null | sed -n 's/.*engine: v\([0-9.]*\).*/\1/p' | head -1 || echo "NOT INSTALLED - run: make deps"
	@printf "godot         : "; $(GODOT) --version 2>/dev/null || echo "not on PATH"
	@printf "python        : "; python3 --version
	@echo "ANDROID_HOME  : $(ANDROID_HOME)"
	@printf "ndk           : "; ls $(ANDROID_HOME)/ndk 2>/dev/null | tail -1 || echo "NOT FOUND"
	@echo "submodules    :"
	@git submodule status | sed 's/^/                /'

deps:
	@command -v $(SCONS) >/dev/null 2>&1 || python3 -m pip install --user scons
	git submodule update --init --recursive
	@echo "Dependencies ready. Next: make host"

host:
	$(SCONS) $(SCONS_COMMON) platform=$(HOST_PLATFORM) arch=$(HOST_ARCH)

android: android-arm64 android-arm32 android-x86_64

android-arm64:
	$(SCONS) $(SCONS_COMMON) platform=android arch=arm64

android-arm32:
	$(SCONS) $(SCONS_COMMON) platform=android arch=arm32

android-x86_64:
	$(SCONS) $(SCONS_COMMON) platform=android arch=x86_64

# Builds and runs the standalone probe. A failure here points at the ocgcore build itself;
# a pass here plus a failure in Godot points at the GDExtension binding.
selftest:
	$(SCONS) $(SCONS_COMMON) platform=$(HOST_PLATFORM) arch=$(HOST_ARCH) selftest=yes
	$(NATIVE_DIR)/build/$(HOST_PLATFORM).$(TARGET).$(HOST_ARCH)/kaiba_selftest

run:
	$(GODOT) --path $(GAME_DIR)

editor:
	$(GODOT) --editor --path $(GAME_DIR)

clean:
	rm -rf $(NATIVE_DIR)/build
	rm -f $(NATIVE_DIR)/.sconsign.dblite

distclean: clean
	rm -f $(GAME_DIR)/bin/libkaiba_core.*
	rm -rf $(NATIVE_DIR)/godot-cpp/bin
