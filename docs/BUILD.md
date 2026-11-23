# Building Project Kaiba

Phase 0 goal: a GDExtension that statically links `ocgcore` and Lua 5.4, loads inside Godot, and
passes a selftest proving the rules engine actually runs.

Compiler flags are load-bearing. **Read [AGENTS.md](../AGENTS.md) section 8 before changing any of
them.** Several exist to work around real miscompiles and would look like dead weight otherwise.

---

## Requirements

| tool | version used | notes |
|---|---|---|
| Godot | 4.6.3 stable | extension is built against godot-cpp 4.5; GDExtension is forward compatible |
| SCons | 4.11+ | `python3 -m pip install --user scons` |
| Python | 3.12 | godot-cpp's build scripts |
| Clang | Apple clang 17 / NDK clang | C++17 with exceptions |
| Android NDK | 28.2.13676358 | needs `ANDROID_HOME` set |

Verify everything at once:

```bash
make doctor
```

---

## First build

```bash
make deps     # installs SCons if missing, then initialises submodules recursively
make host     # builds for this machine
make run      # launches Godot; look for the [kaiba] lines
```

Expected output from `make run`:

```
[kaiba] platform : macos arm64
[kaiba] compiler : clang 17.0.0 ...
[kaiba] built    : ...
[kaiba] ocgcore  : 11.0 (headers expect 11.0)
[kaiba] selftest : PASS
```

`selftest : PASS` is the Phase 0 exit criterion. It is far stronger than printing a version
number — see "What the selftest proves" below.

---

## Android

```bash
make android              # all three ABIs
make android-arm64        # just one
```

Requires `ANDROID_HOME` and an installed NDK. godot-cpp locates the NDK itself.

Release builds:

```bash
make android TARGET=template_release
```

### Packaging an APK

Only a **debug** APK can be built today. There is no release export target and no release
signing wired into this repo (see "Release APK" below).

Prerequisites, all checked by `make doctor`:

- The Android NDK above (`ANDROID_HOME`, or `ANDROID_NDK_HOME`), for the native library.
- Godot's export templates for the exact engine version, 4.6.3.stable: `make android-templates`
  (~1.2 GB, one time).
- A first import of the project; `make apk` runs `make bootstrap-import` itself if needed.

```bash
make apk           # builds libkaiba_core for arm64, then exports the debug APK
make install-apk   # the same, then installs it on the one attached device and launches it
make apk-name      # prints the path the debug APK will get, without building anything
```

`make apk` builds the native library with `make android-arm64` (default `TARGET=template_debug`),
writes `game/export_presets.cfg` if it does not exist yet (`make export-preset`), and runs
`godot --headless --export-debug "Android"`. Only arm64 is exported.

The APK lands in `build/` as:

```
build/project-kaiba-v<version>-<versionCode>-<debug|release>.apk
e.g. build/project-kaiba-v0.1.0-1-debug.apk
```

`<version>` and `<versionCode>` are the values Godot writes into the Android manifest. Both are
versioned in the repository:

| value | where |
|---|---|
| version | `config/version` under `[application]` in `game/project.godot` |
| version code | `VERSION_CODE` in the `Makefile` |

There is no fallback: without `config/version`, `make` stops with an error. To release a new
build, bump both together (`version code` must increase for Android to install an update over an
older build) and run `make apk-name` to confirm the name.

`export_presets.cfg` is gitignored because it can hold a keystore path and password, so it is
generated, never committed. `make export-preset` (run by `make apk`) writes it when missing and
always resets its `version/name` and `version/code` to the values above; no other line is touched.
An existing file is never otherwise overwritten, so a preset written before this naming scheme
keeps its old `export_path`. That field only matters for exports started from the editor;
`make apk` always passes the path explicitly.

The project also needs `textures/vram_compression/import_etc2_astc=true` (in `project.godot`):
without it Godot refuses the Android export with an empty "configuration errors" message.

Debug signing uses the debug keystore configured in Godot's editor settings
(`export/android/debug_keystore`), not anything in this repo.

### Release APK

Not wired. There is no `make` target that runs `--export-release`, and nothing in the Makefile
reads `keys/` or any properties file to put a keystore into the preset. `keys/release.properties`
is listed in `.gitignore` but no script consumes it.

What a release export would need, from Godot's side: the Android preset's
`keystore/release`, `keystore/release_user` and `keystore/release_password` options (or the
`GODOT_ANDROID_KEYSTORE_RELEASE_PATH`, `_USER` and `_PASSWORD` environment variables, which Godot
reads at export time), native libraries built with `TARGET=template_release`, and a
`godot --headless --export-release "Android" ../build/project-kaiba-v<version>-<versionCode>-release.apk`
call. If you put those values in `export_presets.cfg` by hand, remember it is a Godot
`ConfigFile`: string values are double-quoted and a backslash or quote inside them is written
`\\` or `\"`. On macOS and Linux keystore paths normally contain neither.

---

## The standalone probe

```bash
make selftest
```

Builds `native/build/<config>/kaiba_selftest`, a host executable that links ocgcore and Lua
**without Godot**, and runs the same probe.

Use it to split a failure in half:

| selftest binary | Godot | diagnosis |
|---|---|---|
| PASS | PASS | everything is fine |
| PASS | FAIL | the GDExtension binding or `kaiba.gdextension` is wrong |
| FAIL | FAIL | the ocgcore or Lua build is wrong; ignore Godot entirely |

---

## What the selftest proves

`OCG_GetVersion()` only proves the library was found. The selftest in
`native/src/core_selftest.cpp` goes further. It creates a real duel, runs a Lua chunk in it and
destroys it, which validates:

1. **ocgcore links** and its symbols resolve on this ABI.
2. **Lua was compiled as C++.** ocgcore raises Lua errors through C++ exceptions; compiled as C,
   `lua_error()` longjmps past ocgcore's destructors and corrupts the heap. `interpreter.cpp`
   checks this at startup and `OCG_CreateDuel` returns `OCG_DUEL_CREATION_INCOMPATIBLE_LUA_API`.
3. **The Lua state initialises** and executes bytecode (`luaL_loadbuffer` + `lua_pcall`).
4. **C++ exceptions survive** the ocgcore boundary.

Point 2 is the one that silently destroys a build. It is why the SConstruct forces `-x c++` onto
every Lua translation unit.

---

## Troubleshooting

**`KaibaCore is not registered`**
The extension did not load. Check that `game/bin/` holds a library whose name matches the entry in
`game/bin/kaiba.gdextension` for your platform, target and arch. Run `make host` and compare the
produced filename against the manifest.

**`OCG_DUEL_CREATION_INCOMPATIBLE_LUA_API`**
Lua was compiled as C. Something stripped `-x c++` from `lua_env` in `native/SConstruct`.

**`ocgcore submodule is missing or empty`**
Run `make deps`.

**Build fails with exception-related errors**
Something passed `disable_exceptions=yes`, or built SCons directly without the flag. Always build
through `make`, or pass `disable_exceptions=no` by hand.

**Godot segfaults on the very first `--import`**
Known Godot 4.6.3 bug, not a project defect. `EditorHelp::_gen_extensions_docs()` crashes during
`Main::cleanup` the first time Godot scans a project that declares a GDExtension. The import has
already finished by then: `.godot/extension_list.cfg` is written correctly, the second import is
clean, and the runtime is unaffected. `make bootstrap-import` absorbs it.

**macOS: crashes or miscompiles inside the process dispatcher**
`processor_visit.cpp` must be compiled with `-fno-exceptions` on macOS only. The SConstruct does
this; upstream `premake5.lua` does the same.

---

## Pinned versions

Both submodules are pinned by commit, not by branch tip. `ocgcore` in particular must be pinned:
bumping it can change duel behaviour and invalidate stored replays
(see [ARCHITECTURE.md](ARCHITECTURE.md) R5).

```bash
git submodule status
```

When bumping ocgcore, record the new SHA in `CHANGELOG.md`. Once replays exist (Phase 3),
`tools/replay_verify.py` must re-simulate the stored replay library before the bump is accepted.
That tool is not written yet.
