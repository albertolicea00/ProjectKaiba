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

### Added (interface)
- `game/core/registry/card_art.gd` — runtime loader for `data/base/pics/cards/`. The art lives outside
  `res://` so it is read with `Image.load_from_file()`, which keeps `data/` swappable. Decoding
  happens on a `WorkerThreadPool`; a cache miss returns null and queues, never blocking a frame.
  LRU budget scales with the tier: 64 MB for sd (~200 faces), 256 MB for hd (~90), because a
  face costs roughly nine times more at hd and one number cannot be right for both.
- `game/ui/hud/` — life points, turn, phase and the pending prompt. Life totals roll rather than
  snap, and the previous value lives in the HUD rather than the model.
- `game/ui/main_menu/` and `game/platform/scene_router.gd` — the project boots into a menu after
  its startup self-test instead of straight into a test scene.
- `game/view/fx/` — procedural effects with no binary assets: ground flashes, impact rings and
  shard bursts, capped at 24 live.
- `game/view/anim/card_flight.gd` — a parametric flight with arc, swell, spin and fade, driven by
  tweening one float.
- Summon, attack and battle now read as distinct beats rather than three position tweens. A card
  arriving face-down never receives the mid-flight flip callback, so a set monster cannot show
  its face for a frame.
- `KaibaCore.get_card_info(code)` — card names, effect text and the sixteen per-effect labels,
  which existed in `CardDB` but had no route to GDScript.

### Fixed
- `CardView.art_source` was never assigned, so every card silently fell back to a placeholder
  colour while the whole art pipeline sat unused. `make touch` now asserts that faces decode.
- `skip_all()` killed tweens but left effects playing, so a skip snapped the board to its end
  state while debris from an unwatched battle kept flying.
- An attack returned the card to a remembered transform. It now asks the board to re-seat it, so
  a reconciliation during the lunge cannot strand it.
- `scene_router.gd` lived under `game/core/`, which `AGENTS.md` defines as L3 with no scene
  dependencies, while doing ten scene-tree operations. Moved to the platform layer.

### Verified
- `make smoke` drives a real ocgcore duel on its own thread with synthetic decks and no card
  database. The opening sequence parses correctly: two `MSG_DRAW` of five cards, `MSG_NEW_TURN`,
  three `MSG_NEW_PHASE` (draw, standby, main1), `MSG_HINT`, then `MSG_SELECT_IDLECMD` reporting
  five settable cards. The duel blocks on the selection as designed and the worker thread shuts
  down cleanly from a parked state.
- macOS arm64 host build passes `make verify` end to end: the GDExtension loads inside Godot
  4.6.3, `OCG_CreateDuel` succeeds, a Lua chunk runs inside the duel's own state, and the duel is
  destroyed cleanly. ocgcore reports 11.0.

### Added (decks)
- `game/core/deck/` — `YdkIo`, `DeckModel`, `DeckValidator`, `DeckLibrary`. Decks are **external
  `.ydk` files the player picks**, discovered from `user://decks/` first and `data/base/decks/`
  second, so a player's own copy shadows a bundled one.
- `game/ui/deck_picker/` — lists what the library found with main/extra/side counts read by
  parsing each file, warns about a short or oversized main deck before the engine refuses it, and
  remembers the choice in `user://last_deck.cfg` so it survives a restart.
- The chosen deck is played in Solo.

### Removed
- **The deck editor.** It existed briefly and was replaced by the picker above. An editor would
  have had to reimplement search, filtering, banlists and validation that EDOPro already does
  better, and would have owned a format nobody else could read. `.ydk` is what every other client
  speaks, so a deck built anywhere works here untouched. Reasoning in `ROADMAP.md` section 4.

### Added (input, controls and the card preview)
- A **set-face-down gesture**: a short downward drag on touch, middle click or Shift+click on PC.
  `IDLE_ALT_PRIORITY` reads the idle lists set-before-play, so the player states which reading of
  a tap they meant instead of a priority table guessing.
- `game/ui/controls/` — every gesture, touch and PC, rendered **from the `BINDINGS` table
  itself**, so a verb cannot be added without appearing in the player-facing table.
- On-screen Yes / No / Confirm on the prompt panel. `CONFIRM` was in the enum with no gesture able
  to emit it; a yes/no question deserves a visible yes rather than an undocumented flick.
- `game/ui/preview/card_preview.gd` — a card shown large with its database text: type line,
  attribute, race, ATK/DEF, link markers and effect text. Reached through `POINT_AT`, which never
  counts as an answer, so looking at a card is always safe.
- Zone markers on the board naming each zone, and the themed card back from `data/base/pics/back`
  for everything face-down. The back is deliberately **outside** the `CardArt` LRU budget: it is
  on screen constantly, so evicting it is the one eviction that always costs.

### Added (solo, the hot seat and the seat in view)
- `game/ai/passive_agent.gd` and `scenes/solo.tscn` — one seat yours, the board never turns.
- `scenes/solo_test.tscn` — the hot seat: both seats yours, the board turns, and face-down cards
  are audited from **both** sides. That audit is the cheapest available stand-in for V7 while
  there is no `HostService`.
- `SeatFocus` and the hot-seat banner: which seat is in view is stated at all times and follows
  the turn, never a prompt.
- `BoardView.view_by_handle()` / `take_view_by_handle()` — following a card across zones by its
  stable handle rather than by position.
- `make solo` and `make solo-test` as separate gates. They assert **opposite things about the
  camera**, so merging them would mean dropping one of the two assertions.

### Added (portrait and the menu dress)
- The board is held upright in portrait and the HUD restyled for it; `Camera3D.KEEP_WIDTH`.
- Battle numbers during an attack (`DuelHud.set_combat()`), so a trade is legible.
- `game/ui/menu_art.gd` — one place that decides the background cut, the stone slab nine-patch,
  the lettering and the dark content panel. Everything in it is `static`, so every decision is
  testable with no window and no rendered frame.
- Menu art and app icon under `game/ui/art/menu/`. The main menu, the deck picker and the controls
  table all wear it. Papyrus is loaded from the macOS system path when present and **never copied
  into the repository or an export**; `menu_font()` returns `null` otherwise and the engine face
  is used (V17).

### Changed
- **`Solo` and `Solo Test` collapsed into one menu entry.** Players could not tell them apart
  while the opponent passes on everything. `scenes/solo.tscn` and `PassiveAgent` stay, gated by
  `make solo`, and earn the entry back when `heuristic_agent` lands.
- `menu_art.gd` moved from `game/ui/main_menu/` to `game/ui/`. Three screens wear it, and a file
  three siblings share is not one sibling's property.
- The deck picker prints `.../folder/deck.ydk` instead of a full path: the pane is 244 px on a
  720-wide phone and the tail is what tells two same-named decks apart.
- The roadmap moved out of `docs/ARCHITECTURE.md` section 12 into `ROADMAP.md`. Two roadmaps
  drift; they had already started to.

### Fixed
- **A duel could freeze after a well-formed but illegal answer.** `respond()` returns ok, the
  scene cleared its pending state, and ocgcore replied `MSG_RETRY` — which does **not** resend the
  selection it rejected. Nothing was left to answer. The selection is now re-armed and the refusal
  is announced on screen; a silent refusal is indistinguishable from a hang.
- **Prompts with nothing to answer.** `Respond with an effect? 0 available` was a question with no
  answers. `SelectionController.auto_answer()` now cancels a **non-forced** `SELECT_CHAIN` whose
  offer list is **empty**, and only that. When there is something to do, the offered cards glow
  instead (`actionable_handles()` → `highlight_cards()`).
- **The deck picker overloaded the navigation verb.** It declared `signal chose(entry: Dictionary)`
  while the menu declares `chose(destination: String)`, and `SceneRouter` connects that signal by
  name — so it handed a Dictionary to a String parameter and the choice died at the signal
  boundary, with the error naming the emitter rather than the disagreement
  (`Cannot convert argument 1 from Dictionary to String`). Back was dead for a related reason:
  `cancelled` had no listener anywhere. Split into `deck_chosen(Dictionary)` and
  `chose(String)`.
- `SceneRouter._takes_a_destination()` now verifies a navigation signal's declared argument before
  connecting it, so the next name collision fails loudly instead of at the boundary. Four cases
  cover it (V15).
- A scene kept taking input after the duel closed: `set_process(false)` does not stop
  signal-driven input.
- `make solo-test` asserted with `grep -qv "FAIL"`, which succeeds whenever *any* line lacks the
  word, and printed PASS above three real failures. Fixed to `! grep -qE "^  FAIL"` and proved to
  fail by injecting a failure. The same run had emitted its summary line **before** teardown.
- `game/ui/art/menu` paths and `CardArt.DEFAULT_PICS_PATH` were inverted (`base/cards/pics`
  instead of `base/pics/cards`), so the art tests skipped every case and printed `0 cases,
  0 failed`. A suite reporting zero cases is now treated as a failure.
- Set spells and traps were drawn sideways: ocgcore encodes a set spell as `FACEDOWN_DEFENSE`, the
  same position value that lays a monster on its side. `BoardView.zone_turns()` consults the zone
  as well as the position.

### Documentation
- `ROADMAP.md` — the single roadmap: real state per phase against the gate that proves it, the
  ordered next actions, the settled decisions, and the ranked risks. `docs/ARCHITECTURE.md`
  section 12 now points here.
- `docs/DUEL.md` — the duel loop as it runs in code: the three event levels, the `KaibaCore`
  surface, how each selection type is answered, why handles and not passcodes, and the failure
  mode that defines the layer (a wrong answer is reported as a hang, not an error).
- `docs/UI.md` — screens, the navigation contract and the bug that produced it, `MenuArt`, the
  input verb table, the board, the HUD and the preview.
- `docs/TESTING.md` — the ten gates and what each proves, plus a section listing every way they
  have passed while proving nothing.
- `AGENTS.md` — a documentation index, L2 marked absent in the layer map, invariants **V15**
  (the navigation verb), **V16** (nothing measures the screen) and **V17** (system fonts are never
  bundled), the ten gates, five new working rules, and a settled-decisions section.

### Verified (2026-10-05)
- All ten gates green on macOS arm64 with Godot 4.6.3:
  `verify smoke duel test-gd duel-real test-selectors touch test-ui solo solo-test`.
  The UI suite reports **52 cases, 0 failed**.
- `make duel-real` and `make test-selectors` run against the real `cards.cdb` and the ProjectIgnis
  script collection, not synthetic decks.
- Layouts measured headlessly at 720x1280, 1080x2340 and 1920x1080: frame containment, no sibling
  overlap, a 48 px touch floor, and every panel enclosing the text under it.
- Pinned submodules unchanged since the table above: `godot-cpp` at `27d9dd2`,
  `ocgcore` at `efc21aa` (v11.0-96). No core bump, so no replay-determinism risk taken.

### Known blockers
*Updated 2026-10-05. The two blockers recorded here previously — missing card data and a
broken Android build — are both resolved: `data/base/cards.cdb` and the ProjectIgnis script
collection are installed (`make data-scripts`), and all three Android ABIs build, with arm64
carrying the 16 KB page flag.*

- **Nothing has ever run on a real phone.** `make android-templates` is a 1.17 GB download that
  has not been run, so there is no APK. Touch is proven headlessly, which proves verb routing and
  nothing about ergonomics, latency, thermals or battery.
- **There is no L2.** `game/net/` does not exist — no `ITransport`, no `HostService`, no
  `ClientService`. Every duel scene reaches `KaibaCore` directly, so invariant V7 has nowhere to
  live and LAN cannot start. This is the next structural task (`ROADMAP.md` section 3, N1).
- **35 of 97 `MSG_*` opcodes are unimplemented.** They degrade to `EV::UNHANDLED` and the duel
  continues (V13) — safe, and also silent.
- **`SELECT_OPTION`, `SORT_CARD` and `SORT_CHAIN` have no gesture.** They are answered with their
  least-destructive default and flagged by `can_answer()`, so a card offering two effects to
  choose between leaves the player stuck.
- **The only opponent is `PassiveAgent`**, which passes on everything.

### Upstream bugs worked around
- Godot 4.6.3 segfaults in `EditorHelp::_gen_extensions_docs()` during `Main::cleanup` on the
  first `--import` of a project declaring a GDExtension. The import completes correctly and later
  imports are clean. `make bootstrap-import` absorbs it.
