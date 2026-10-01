# AGENTS.md — Project Kaiba

Operating rules for any agent or contributor working in this repo.
Full design rationale: **[docs/ARCHITECTURE.md](docs/ARCHITECTURE.md)**. Build steps: **[docs/BUILD.md](docs/BUILD.md)**.

---

## 1. Language

**All code, comments, identifiers, commit messages, documentation and file names are in English.** No exceptions.
Conversation with the maintainer may be in Spanish; the repository is English-only.

---

## 2. What this is

A Godot 4 Yu-Gi-Oh! client that uses `ocgcore` (the EDOPro rules engine) as its rule authority.
Personal, fan-made, **not distributed**. See `DISCLAIMER.md`.

Priorities, in order: Android → PC → VR. Offline-first. No accounts, no backend, no mandatory login.

---

## 3. Scope boundary (current)

| in scope | out of scope |
|---|---|
| Offline / solo play vs local AI | Matchmaking |
| LAN multiplayer over TCP, direct IP | Dedicated servers, WAN |
| LAN host discovery (UDP broadcast) | Friends, ranking, accounts |
| Project-owned wire protocol (KTOS/STOK) | EDOPro/YGOPro server compatibility (CTOS/STOC) |
| Own replay format (`KBRP`) | `.yrp` / `.yrpX` import/export |

Anything in the right column is **Post-MVP**. Do not add it, do not design around it beyond keeping the
duel payload as raw ocgcore bytes (§7 of ARCHITECTURE.md), which is what keeps it cheap later.

---

## 4. Layer map

```
L5 Platform shell   CameraRig, InputSource, HUD shell
L4 Visual Layer     BoardView, CardView, MonsterAvatar, AnimationDirector
L3 Game Adapter     DuelState, EventTranslator, registries, deck, replay
L2 Networking       ITransport, HostService, ClientService
L1 Core (C++)       KaibaCore → ocgapi.h, DuelThread, CardDB, ScriptVFS, MsgParser
```

No layer may know about the layer above it.

---

## 5. Invariants

Violating any of these is a bug, not a style preference. Cite them by id in commits and reviews.

| id | invariant |
|---|---|
| V1 | L4 never imports anything from L1 or L2. |
| V2 | L3 never instantiates `Node3D`, `Texture`, or anything from the scene tree. |
| V3 | All rules logic lives inside `ocgcore`. A Yu-Gi-Oh! rule written in GDScript is a bug. |
| V4 | L1 runs on a dedicated thread. Any `OCG_*` call from the main thread is a bug. |
| V5 | `BoardView` reads only from `DuelState`. Never from `KaibaCore`. |
| V6 | Nothing under `World3D/` uses screen-space coordinates. |
| V7 | Hidden-information filtering happens in `HostService`, before the transport. Never client-side. |
| V8 | An `OCG_Duel` handle is touched only from its `DuelThread`. |
| V9 | Replays store Level-1 `DuelEvent` only. Never Level-2 `VisualIntent`. |
| V10 | Unmounting any pack with `kind != base` must never prevent a duel from being played. |
| V11 | `DuelState` never references `VisualDefinition`, `PackedScene`, or `MonsterSlot`. Only `card_id` and zone coordinates. |
| V12 | Adding or removing a 3D model touches zero lines in L1–L3. |
| V13 | Unimplemented `MSG_*` opcodes log a WARN and continue. They never crash or abort the duel. |
| V14 | Only `Dictionary` / `PackedByteArray` cross the C++↔GDScript boundary. Never raw structs. |

---

## 6. Repository layout

```
native/              C++ only. GDExtension + vendored ocgcore + lua.
  SConstruct         build entry point
  godot-cpp/         submodule, branch 4.5
  vendor/ocgcore/    submodule, edo9300/ygopro-core (pins replay determinism)
  src/               our C++ sources
game/                Godot 4 project
  bin/               built .so/.dll + kaiba.gdextension (binaries untracked)
  core/              L3 — zero scene dependencies
  net/               L2
  view/              L4
  platform/          L5
data/                NOT versioned. cards.cdb, Lua scripts, art, packs.
docs/                ARCHITECTURE.md, BUILD.md
tools/               pack builder, cdb check, replay verifier
```

`../sdk/` sits **outside this repo**. It is upstream source used as reference only
(`edopro`, `ygopro`, `ygopro-core`, `YgoMaster`, `Puzzles`). **Read it, never build against it** —
builds must resolve through `native/vendor/` so the repo stays self-contained and version-pinned.

---

## 7. Build

```bash
make deps        # install scons, init submodules
make host        # build for this machine (editor)
make android     # build all 3 Android ABIs
make selftest    # run the Phase 0 core selftest headless
```

Toolchain verified on this machine (2026-10-01): Godot 4.6.3, Android NDK 28.2.13676358,
`ANDROID_HOME=~/Library/Android/sdk`, Apple clang 17, Python 3.12.

---

## 8. Build gotchas (hard-won — do not "simplify" these away)

1. **Lua must be compiled as C++, not C.** ocgcore propagates Lua errors through C++ exceptions.
   Compiled as C, `longjmp` skips destructors and corrupts memory. `interpreter.cpp` detects this and
   `OCG_CreateDuel` returns `OCG_DUEL_CREATION_INCOMPATIBLE_LUA_API`. The SConstruct forces `-x c++`.
2. **macOS: `processor_visit.cpp` must build with `-fno-exceptions`.** Upstream `premake5.lua` does this
   under `filter { "system:macosx" }`. Dropping it breaks the host build.
3. **Lua excludes 11 source files** (`lua.c`, `luac.c`, `onelua.c`, `linit.c`, `loadlib.c`, `loslib.c`,
   `ldblib.c`, `lbitlib.c`, `lcorolib.c`, `lutf8lib.c`, `ltests.c`). Including them breaks the link or
   exposes unsafe libraries to card scripts.
4. **`-include luaconf-customize.h`** is required; it fixes `lua_getlocaledecpoint()` on Android.
5. **Android arm64 needs `-Wl,-z,max-page-size=16384`** (Android 15+ 16KB page support).
6. **Do not define `OCGCORE_EXPORT_FUNCTIONS`.** ocgcore is linked statically into `libkaiba_core`;
   re-exporting its symbols only widens the ABI surface.
7. **`OCG_CreateDuel` rejects an all-zero `seed[4]`** with `OCG_DUEL_CREATION_NULL_RNG_SEED`.
8. **godot-cpp has no 4.6 branch.** We build against `4.5` and set `compatibility_minimum = "4.5"`.
   GDExtension is forward-compatible, so this runs on Godot 4.6.3. Bump when upstream ships 4.6.

---

## 9. Working rules

- Never reimplement a Yu-Gi-Oh! rule. If behavior looks wrong, the bug is in our adapter or in the
  card's Lua script, not in our code's understanding of the rules. (V3)
- `edopro/gframe/duelclient.cpp` is **reference documentation, not portable code**. It is coupled to
  Irrlicht. `core_utils.cpp` and `bufferio.h` from the same tree *are* portable — port those directly.
- When touching `native/vendor/ocgcore`, record the new pinned SHA in `CHANGELOG.md`. A core bump can
  break replay determinism (ARCHITECTURE.md R5); run `tools/replay_verify.py` before committing it.
- Do not commit anything under `data/`. Card data and art are copyrighted.
- State assumptions explicitly. Prefer saying "I don't know" over inventing engine behavior — the
  authority for ocgcore semantics is the source in `native/vendor/ocgcore/`, not memory.
