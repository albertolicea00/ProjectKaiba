# Changelog

All notable changes to **Project Kaiba** will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added
- `docs/ARCHITECTURE.md` — full technical plan: five-layer architecture, module map, Godot scene
  tree, data flow, ocgcore integration, three-level event format, asset pack system, 3D monster
  system, VR strategy, ranked risks, phased roadmap and solo-developer estimates.
- `docs/BUILD.md` — build requirements, first-build walkthrough, Android targets and
  troubleshooting.
- `docs/DATA.md` — `cards.cdb` schema with the packed-column decoding rules, verified data
  sources, and the `cardReader` memory strategy.
- `AGENTS.md` — working rules, the V1–V14 invariants, repository layout and build gotchas.
- `native/` — GDExtension skeleton built with SCons: `KaibaCore` exposing `get_core_version()`,
  `get_build_info()` and `run_selftest()`.
- `native/src/core_selftest.cpp` — Phase 0 probe. Creates a duel, runs a Lua chunk inside it and
  destroys it, which proves ocgcore links, Lua was compiled as C++, the Lua state executes, and
  C++ exceptions cross the ocgcore boundary.
- `native/tools/selftest_main.cpp` — the same probe as a standalone host executable, so a failure
  can be isolated to either the core build or the Godot binding.
- `game/` — Godot 4 project booting into a Phase 0 scene that reports build identity and selftest
  result.
- `Makefile` — `doctor`, `deps`, `host`, `android`, `selftest`, `run`, `editor`, `clean`.

### Changed
- Multiplayer scope narrowed to **LAN only** for the MVP. EDOPro/YGOPro/YDXPro server
  compatibility and `.yrp` replay interchange moved to Post-MVP; the duel payload stays as raw
  ocgcore bytes so adding them later stays cheap.
- `README.md` roadmap restructured into MVP and Post-MVP sections.
- `.gitignore`: `game/bin/kaiba.gdextension` is now tracked while built libraries stay ignored;
  `data/` and native build artefacts added; `*.import` no longer ignored, since in Godot 4 those
  files carry resource UIDs and regenerating them breaks `uid://` references.

### Pinned dependencies
| dependency | commit | notes |
|---|---|---|
| `native/godot-cpp` | `27d9dd23c83871e0619fca5dc2cddfbfd69e926a` | branch `4.5`; godot-cpp has no 4.6 branch yet |
| `native/vendor/ocgcore` | `efc21aa433b88cd35b7c37db4072a35c58d9d435` | OCG core v11.0. **Bumping this can change duel behaviour and invalidate stored replays** (ARCHITECTURE.md R5) |
| `native/vendor/ocgcore/lua/src` | `6e22fedb74cf0c9b6656e9fce8b7331db847c605` | Lua 5.4, compiled as C++ |

### Added (Phase 1)
- `native/src/core_utils.{h,cpp}` and `buffer_io.h` — port of EDOPro's message/query byte
  parsing layer, stripped of Irrlicht and `ClientField`.
- `native/vendor/sqlite3/` — SQLite 3.53.4 amalgamation, vendored (not a submodule), compiled
  as C with `SQLITE_OMIT_LOAD_EXTENSION` and friends.
- `native/src/card_db.{h,cpp}` — `cards.cdb` reader implementing ocgcore's `cardReader` and
  `cardReaderDone`, with the packed `setcode` / `level` / `def` decoding from docs/DATA.md.
  Loads the whole database into memory at open and closes the SQLite handle.
- `native/src/script_vfs.{h,cpp}` — `scriptReader` over an ordered list of search roots, with
  an in-memory cache.
- `native/src/duel_event.h` — the Level 1 event model. `EV` values mirror the `MSG_*` opcodes
  so replays stay readable across core bumps; `msg_parser.cpp` static_asserts every one.
- `native/src/msg_parser.{h,cpp}` — batch 1 of the opcode decoders (~40 messages), each
  bounds-checked. Unknown opcodes become `EV::UNHANDLED` and truncated ones `EV::MALFORMED`,
  never a crash (invariant V13).
- `native/src/spsc_queue.h` and `duel_thread.{h,cpp}` — the duel worker thread. One
  `OCG_Duel` per thread, created and destroyed on it (V8); events leave through a lock-free
  SPSC queue, responses arrive through a condition variable that also serves as the shutdown
  wakeup.
- `KaibaCore` duel API: `load_card_database`, `add_script_root`, `start_duel`, `poll_event`,
  `send_response`, `end_duel`, `is_duel_running`.
- `game/core/duel/` — `duel_enums.gd`, `duel_card.gd`, `duel_state.gd`.
- `game/scenes/duel_smoke.gd` and `make smoke` — Phase 1 regression test.

### Added (Phase 2 — visual layer)
- `game/view/board/` — `BoardView`, `CardView`, `CardPool`. The table is 1.20 m x 0.75 m and
  cards 8.6 x 5.9 cm in Godot units, so the later VR port is not an art redo (ARCHITECTURE.md
  section 10 rule 1). Player 1's half is derived by a 180 degree rotation about the table
  centre rather than written twice.
- `game/view/anim/animation_director.gd` — consumes Level-2 `VisualIntent` with a single
  barrier: a blocking intent stops the queue until its own tween finishes, non-blocking ones
  overlap. A five-card draw therefore plays as one beat.
- `game/platform/camera/` — `CameraRig` plus `RigMobile`. `duel_3d.tscn` holds no direct
  `Camera3D`; the rig is a swappable child.
- `game/scenes/duel_3d.{gd,tscn}` — a real duel rendered on the 3D board, with 21 self-checks.
- `make test-selectors` — forces the prompts a vanilla duel never produces.

### Fixed
- `MSG_SELECT_TRIBUTE` decoded as `MALFORMED`. It shares a five-field prefix with
  `MSG_SELECT_CARD` but not a card entry: `SELECT_CARD` writes a packed `loc_info`,
  `SELECT_TRIBUTE` writes a loose controller/location/sequence triple plus a `release_param`
  byte. Reading it as a `loc_info` overran by four bytes per card.
- `MSG_SELECT_SUM` implemented. Reached in practice only through ritual summons:
  `proc_ritual.lua` is the sole caller of `Group.SelectWithSumEqual` in the whole collection.
- `make duel` could not start a duel once the script collection was installed: the driver
  neither registered script roots nor opted out of the library preload. The target now asserts
  that it reaches a final board, so it cannot rot unnoticed again.
- Intents with nothing to animate (`TURN_START`, `LP_CHANGE`, `PHASE_CHANGE`) had no tween and
  settled in their starting frame, so a blocking one released the barrier instantly.

### Verified
- `make smoke` drives a real ocgcore duel on its own thread with synthetic decks and no card
  database. The opening sequence parses correctly: two `MSG_DRAW` of five cards, `MSG_NEW_TURN`,
  three `MSG_NEW_PHASE` (draw, standby, main1), `MSG_HINT`, then `MSG_SELECT_IDLECMD` reporting
  five settable cards. The duel blocks on the selection as designed and the worker thread shuts
  down cleanly from a parked state.
- macOS arm64 host build passes `make verify` end to end: the GDExtension loads inside Godot
  4.6.3, `OCG_CreateDuel` succeeds, a Lua chunk runs inside the duel's own state, and the duel is
  destroyed cleanly. ocgcore reports 11.0.

### Known blockers
- No `cards.cdb` and no card scripts are present yet. See `docs/DATA.md`. Until these exist, only
  the toolchain can be exercised, not a duel.
- **Android does not build yet.** `$ANDROID_HOME/ndk/28.2.13676358/` exists but is empty: the NDK
  was never fully installed. The Makefile pins `NDK_VERSION` (godot-cpp 4.5 defaults to
  `28.1.13356709`, which is also absent). `make doctor` reports the mismatch.

### Upstream bugs worked around
- Godot 4.6.3 segfaults in `EditorHelp::_gen_extensions_docs()` during `Main::cleanup` on the
  first `--import` of a project declaring a GDExtension. The import completes correctly and later
  imports are clean. `make bootstrap-import` absorbs it.
