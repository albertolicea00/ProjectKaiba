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

# Pinned, not auto-detected. godot-cpp 4.5 defaults to NDK 28.1.13356709; we build with the
# version actually installed here. Keep this an explicit pin so a future NDK install cannot
# silently change the produced binaries. `make doctor` reports a mismatch.
NDK_VERSION ?= 28.2.13676358

# disable_exceptions=no is mandatory: ocgcore raises Lua errors as C++ exceptions.
SCONS_COMMON  := -C $(NATIVE_DIR) -j$(JOBS) target=$(TARGET) disable_exceptions=no

# Homebrew's android-ndk cask lands here. Picked up automatically so `make android` works
# without exporting anything; an explicit ANDROID_NDK_HOME always wins.
BREW_NDK := /opt/homebrew/share/android-ndk
ifeq ($(ANDROID_NDK_HOME),)
  ifneq ($(wildcard $(BREW_NDK)/toolchains),)
    ANDROID_NDK_HOME := $(BREW_NDK)
  endif
endif

# If ANDROID_NDK_HOME is set (e.g., via Homebrew), we override ANDROID_HOME and omit the
# pinned ndk_version so that godot-cpp picks up the custom NDK installation.
ifneq ($(ANDROID_NDK_HOME),)
  SCONS_ENV := env ANDROID_HOME="" ANDROID_NDK_ROOT="$(ANDROID_NDK_HOME)"
  SCONS_ANDROID := $(SCONS_COMMON) platform=android
else
  SCONS_ENV := env
  SCONS_ANDROID := $(SCONS_COMMON) platform=android ndk_version=$(NDK_VERSION)
endif

.PHONY: help doctor deps host android android-arm64 android-arm32 android-x86_64 selftest verify smoke duel duel-real test-gd test-selectors touch test-ui solo-test data-scripts bootstrap-import run editor clean distclean

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
	@printf "scons         : "; $(SCONS) --version 2>/dev/null | sed -n 's/.*SCons: v\([0-9.]*\).*/\1/p' | head -1 | grep . || echo "NOT INSTALLED - run: make deps"
	@printf "godot         : "; $(GODOT) --version 2>/dev/null || echo "not on PATH"
	@printf "python        : "; python3 --version
	@echo "ANDROID_HOME  : $(ANDROID_HOME)"
	@printf "ndk           : "; if [ -n "$(ANDROID_NDK_HOME)" ]; then \
		echo "$(ANDROID_NDK_HOME) (via ANDROID_NDK_HOME)"; \
	elif [ -d "$(ANDROID_HOME)/ndk/$(NDK_VERSION)/toolchains" ]; then \
		echo "$(NDK_VERSION) (via ANDROID_HOME)"; \
	else \
		echo "NOT USABLE - set ANDROID_NDK_HOME, or install NDK $(NDK_VERSION) under $(ANDROID_HOME)/ndk"; \
	fi
	@printf "card database : "; test -f data/base/cards.cdb \
		&& echo "data/base/cards.cdb ($$(du -h data/base/cards.cdb | cut -f1))" \
		|| echo "MISSING - see docs/DATA.md"
	@printf "export tmpl   : "; test -d "$(TEMPLATE_DIR)" \
		&& echo "$(GODOT_VERSION) (present)" \
		|| echo "MISSING - run: make android-templates (~1.2 GB)"
	@printf "device        : "; adb devices 2>/dev/null | tail -n +2 | grep -q device \
		&& echo "attached" || echo "none attached"
	@printf "card scripts  : "; N=$$(ls data/base/script/official/c*.lua 2>/dev/null | wc -l | tr -d ' '); \
		if [ "$$N" = "0" ]; then echo "MISSING - see docs/DATA.md; card effects will not fire"; \
		else echo "$$N scripts"; fi
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
	$(SCONS_ENV) $(SCONS) $(SCONS_ANDROID) arch=arm64

android-arm32:
	$(SCONS_ENV) $(SCONS) $(SCONS_ANDROID) arch=arm32

android-x86_64:
	$(SCONS_ENV) $(SCONS) $(SCONS_ANDROID) arch=x86_64

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

# Headless end-to-end check: boots the Godot project, runs the native selftest and fails the
# build unless it reports PASS. This is the Phase 0 exit criterion.
verify:
	$(MAKE) selftest
	@test -f $(GAME_DIR)/.godot/extension_list.cfg || $(MAKE) bootstrap-import
	@$(GODOT) --headless --path $(GAME_DIR) --quit-after 5 2>&1 | tee /tmp/kaiba_verify.log
	@grep -q "selftest : PASS" /tmp/kaiba_verify.log || (echo "FAIL: Godot did not report selftest PASS"; exit 1)
	@echo "Phase 0 verified: GDExtension loads and ocgcore runs inside Godot."

# Godot 4.6.3 segfaults in EditorHelp::_gen_extensions_docs() at shutdown the first time it
# scans a project that declares a GDExtension. The import itself completes and writes
# .godot/extension_list.cfg correctly, so the exit code is deliberately ignored.
# Only the first import crashes; later ones are clean. See docs/BUILD.md.
bootstrap-import:
	@$(GODOT) --headless --path $(GAME_DIR) --import >/dev/null 2>&1 || true
	@test -f $(GAME_DIR)/.godot/extension_list.cfg \
		&& echo "Godot project imported; extension registered." \
		|| (echo "FAIL: import did not register the extension"; exit 1)

# Phase 1 end-to-end check: runs a real ocgcore duel through DuelThread + MsgParser and
# asserts the opening sequence parses. Needs no cards.cdb (docs/DATA.md): the point is the
# message pump, not the card pool.
smoke: host
	@test -f $(GAME_DIR)/.godot/extension_list.cfg || $(MAKE) bootstrap-import
	@$(GODOT) --headless --path $(GAME_DIR) --script res://scenes/duel_smoke.gd 2>&1 | tee /tmp/kaiba_smoke.log
	@grep -q "reached a blocking selection (t=11)" /tmp/kaiba_smoke.log \
		|| (echo "FAIL: duel did not reach MSG_SELECT_IDLECMD"; exit 1)
	@grep -q "duel ended cleanly" /tmp/kaiba_smoke.log \
		|| (echo "FAIL: duel thread did not shut down"; exit 1)
	@echo "Phase 1 verified: ocgcore duel runs on its own thread and parses into DuelEvents."

# Phase 1 console driver: runs a real duel and prints the board after every event, so the
# L1 -> L3 pipeline can be read rather than inferred from a packet dump. It is a scene, not a
# --script: it needs _process to pump poll_event().
duel: host
	@test -f $(GAME_DIR)/.godot/extension_list.cfg || $(MAKE) bootstrap-import
	@$(GODOT) --headless --path $(GAME_DIR) res://scenes/headless_duel.tscn 2>&1 | tee /tmp/kaiba_duel.log
	@grep -q "final board" /tmp/kaiba_duel.log || (echo "FAIL: driver did not reach a final board"; exit 1)

# GDScript test suite for the L3 model and the event translator.
test-gd:
	@test -f $(GAME_DIR)/.godot/extension_list.cfg || $(MAKE) bootstrap-import
	@$(GODOT) --headless --path $(GAME_DIR) --script res://core/duel/duel_state_test.gd

# Integration check against the real card database. Plays a scripted opening: normal summon,
# choose a zone, enter battle, attack directly. Needs data/base/cards.cdb (docs/DATA.md).
duel-real:
	@test -f data/base/cards.cdb || (echo "SKIP: data/base/cards.cdb is missing, see docs/DATA.md"; exit 1)
	@test -f $(GAME_DIR)/.godot/extension_list.cfg || $(MAKE) bootstrap-import
	@$(GODOT) --headless --path $(GAME_DIR) --script res://scenes/duel_real.gd 2>&1 | tee /tmp/kaiba_real.log
	@grep -q "all checks passed" /tmp/kaiba_real.log \
		|| (echo "FAIL: real-data duel did not complete"; exit 1)

# Fetches the ProjectIgnis card script collection into data/base/script as a git working copy,
# so refreshing it later is a plain `git -C data/base/script pull`. Roughly 115 MB.
# Must be ProjectIgnis, not Fluorohydride: those target the older core and use a different
# Lua API (docs/DATA.md).
CARDSCRIPTS_URL := https://github.com/ProjectIgnis/CardScripts.git

data-scripts:
	@test ! -d data/base/script/.git || (echo "already present; updating"; git -C data/base/script pull --ff-only; exit 0)
	@test ! -e data/base/script || (echo "data/base/script exists but is not a git clone; move it aside first"; exit 1)
	@mkdir -p data/base
	git clone --depth 1 $(CARDSCRIPTS_URL) data/base/script
	@$(MAKE) doctor | grep "card scripts"

# Selector coverage: forces the prompts a vanilla duel never produces (tribute summon, deck
# search, ritual sum). Needs both cards.cdb and the script collection (docs/DATA.md).
test-selectors:
	@test -f data/base/cards.cdb || (echo "SKIP: data/base/cards.cdb missing, see docs/DATA.md"; exit 1)
	@test -d data/base/script/official || (echo "SKIP: card scripts missing, run make data-scripts"; exit 1)
	@test -f $(GAME_DIR)/.godot/extension_list.cfg || $(MAKE) bootstrap-import
	@$(GODOT) --headless --path $(GAME_DIR) --script res://scenes/duel_selectors.gd 2>&1 | tee /tmp/kaiba_sel.log
	@grep -q "all checks passed" /tmp/kaiba_sel.log || (echo "FAIL: selector coverage"; exit 1)

# ----------------------------------------------------------------------------------------------
# Android packaging
#
# Everything needed is already on this machine except Godot's export templates, which are a
# ~1.2 GB download pinned to the exact engine version. `make android-templates` fetches them.
# ----------------------------------------------------------------------------------------------

GODOT_VERSION  := 4.6.3.stable
TEMPLATE_DIR   := $(HOME)/Library/Application Support/Godot/export_templates/$(GODOT_VERSION)
TEMPLATE_URL   := https://github.com/godotengine/godot/releases/download/4.6.3-stable/Godot_v4.6.3-stable_export_templates.tpz
APK            := build/project-kaiba.apk

.PHONY: android-templates export-preset apk install-apk

android-templates:
	@if [ -d "$(TEMPLATE_DIR)" ]; then \
		echo "already installed: $(TEMPLATE_DIR)"; \
	else \
		echo "Downloading Godot $(GODOT_VERSION) export templates (~1.2 GB)..."; \
		mkdir -p /tmp/kaiba-templates "$(TEMPLATE_DIR)" && \
		curl -L --progress-bar -o /tmp/kaiba-templates/templates.tpz "$(TEMPLATE_URL)" && \
		(cd /tmp/kaiba-templates && unzip -qo templates.tpz) && \
		cp /tmp/kaiba-templates/templates/* "$(TEMPLATE_DIR)/" && \
		rm -rf /tmp/kaiba-templates && \
		echo "Installed into $(TEMPLATE_DIR)"; \
	fi

# export_presets.cfg is gitignored because it can hold a keystore path and password, so it is
# generated locally rather than versioned. Editing it by hand or in the editor is fine; this
# only writes it when it is missing.
export-preset:
	@if [ -f $(GAME_DIR)/export_presets.cfg ]; then \
		echo "export_presets.cfg already exists; leaving it alone"; \
	else \
		printf '%s\n' \
		  '[preset.0]' '' \
		  'name="Android"' \
		  'platform="Android"' \
		  'runnable=true' \
		  'advanced_options=false' \
		  'dedicated_server=false' \
		  'custom_features=""' \
		  'export_filter="all_resources"' \
		  'include_filter=""' \
		  'exclude_filter=""' \
		  'export_path="../build/project-kaiba.apk"' \
		  'encryption_include_filters=""' \
		  'encryption_exclude_filters=""' \
		  'seed=0' \
		  'encrypt_pck=false' \
		  'encrypt_directory=false' \
		  'script_export_mode=2' \
		  '' '[preset.0.options]' '' \
		  'gradle_build/use_gradle_build=false' \
		  'architectures/armeabi-v7a=false' \
		  'architectures/arm64-v8a=true' \
		  'architectures/x86=false' \
		  'architectures/x86_64=false' \
		  'package/unique_name="com.example.projectkaiba"' \
		  'package/name="Project Kaiba"' \
		  'package/signed=true' \
		  'screen/immersive_mode=true' \
		  'screen/orientation=0' \
		  'screen/support_small=true' \
		  'screen/support_normal=true' \
		  'screen/support_large=true' \
		  'screen/support_xlarge=true' \
		  > $(GAME_DIR)/export_presets.cfg; \
		echo "wrote $(GAME_DIR)/export_presets.cfg (arm64 only, debug signing)"; \
	fi

# Builds the native library for arm64 and packages a debug APK.
apk: android-arm64 export-preset
	@test -d "$(TEMPLATE_DIR)" || (echo "export templates missing - run: make android-templates"; exit 1)
	@mkdir -p build
	@test -f $(GAME_DIR)/.godot/extension_list.cfg || $(MAKE) bootstrap-import
	$(GODOT) --headless --path $(GAME_DIR) --export-debug "Android" ../$(APK)
	@ls -lh $(APK)

# Installs onto the one attached device and launches it.
install-apk: apk
	@adb devices | tail -n +2 | grep -q device || (echo "no device attached - enable USB debugging"; exit 1)
	adb install -r $(APK)
	adb shell monkey -p com.example.projectkaiba -c android.intent.category.LAUNCHER 1

# The touch-driven duel. Headless it drives itself with synthesised InputIntents and probes the
# raycast against a real card, so the picking path is covered without a finger.
touch:
	@test -f data/base/cards.cdb || (echo "SKIP: data/base/cards.cdb missing, see docs/DATA.md"; exit 1)
	@test -f $(GAME_DIR)/.godot/extension_list.cfg || $(MAKE) bootstrap-import
	@$(GODOT) --headless --path $(GAME_DIR) res://scenes/duel_touch.tscn 2>&1 | tee /tmp/kaiba_touch.log
	@grep -q "all checks passed" /tmp/kaiba_touch.log || (echo "FAIL: touch duel"; exit 1)

# The UI suite. Was not in any gate until now, which is how `make duel` quietly rotted once.
test-ui:
	@test -f $(GAME_DIR)/.godot/extension_list.cfg || $(MAKE) bootstrap-import
	@$(GODOT) --headless --path $(GAME_DIR) --script res://ui/ui_test.gd 2>&1 | tee /tmp/kaiba_ui.log
	@grep -q ", 0 failed" /tmp/kaiba_ui.log || (echo "FAIL: ui suite"; exit 1)

# Solo Test: the hot-seat mode. Headless it drives both seats and audits the seat policy.
solo-test:
	@test -f data/base/cards.cdb || (echo "SKIP: data/base/cards.cdb missing, see docs/DATA.md"; exit 1)
	@test -f $(GAME_DIR)/.godot/extension_list.cfg || $(MAKE) bootstrap-import
	@$(GODOT) --headless --path $(GAME_DIR) res://scenes/solo_test.tscn 2>&1 | tee /tmp/kaiba_solo.log
	@grep -q "no face-down card revealed itself" /tmp/kaiba_solo.log || (echo "FAIL: solo test"; exit 1)
	@grep -qv "FAIL" /tmp/kaiba_solo.log || (echo "FAIL: solo test reported a failure"; exit 1)
