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

### Known blockers
- No `cards.cdb` and no card scripts are present yet. See `docs/DATA.md`. Until these exist, only
  the toolchain can be exercised, not a duel.
