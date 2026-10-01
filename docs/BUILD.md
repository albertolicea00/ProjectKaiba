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

When bumping ocgcore, record the new SHA in `CHANGELOG.md` and run `tools/replay_verify.py` first.
