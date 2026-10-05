# Testing — the gates, and how they have lied

> Last reviewed: 2026-10-05. All ten gates green; the UI suite reports 52 cases, 0 failed.

This project has no CI. The ten `make` targets below *are* the test suite, and they are the only
thing standing between a refactor and a silently broken duel.

Section 3 is the important one. Several of these gates have passed while proving nothing, and
each way they did it is written down so the same hour is not spent twice.

---

## 1. The ten gates

Run them all after a pull, before a commit that touches more than one layer, and after any
`class_name` move:

```bash
make verify smoke duel test-gd duel-real test-selectors touch test-ui solo solo-test
```

| gate | needs | what it actually proves |
|---|---|---|
| `verify` | — | the GDExtension loads **inside Godot** and ocgcore answers. Phase 0's exit condition |
| `smoke` | — | a real duel runs on its own thread, parses into `DuelEvent`s, reaches `MSG_SELECT_IDLECMD` and shuts the thread down cleanly |
| `duel` | — | the console driver prints a board after every event and reaches a final board. This is the readable L1→L3 pipeline |
| `test-gd` | — | the `DuelState` model and `EventTranslator` unit suite |
| `duel-real` | `cards.cdb` | a scripted opening against **real card data**: normal summon, pick a zone, enter battle, attack directly |
| `test-selectors` | `cards.cdb` + scripts | each selection type the controller claims to handle is actually reached and answered in a real duel |
| `touch` | `cards.cdb` | every input verb resolves to a board action through `TouchSource` |
| `test-ui` | — | the 52-case UI suite: HUD, preview, router, menu, controls, deck picker, board markers, layout at three screen shapes |
| `solo` | `cards.cdb` | one seat yours, `PassiveAgent` on the other, **the board never turns** |
| `solo-test` | `cards.cdb` | the hot seat: both seats yours, the board *does* turn, and the face-down audit runs from both sides |

`solo` and `solo-test` are separate gates because they assert **opposite things about the
camera**. Merging them would mean one of the two assertions had to go.

Gates that need `data/` print `SKIP` and exit non-zero when the data is missing — see
`docs/DATA.md`. A skip is not a pass.

---

## 2. Where the tests live

| file | layer |
|---|---|
| `game/core/duel/duel_state_test.gd` | L3 model |
| `game/core/deck/deck_test.gd` | `.ydk` I/O, validator |
| `game/core/registry/card_art_test.gd` | art resolution and the LRU budget |
| `game/view/audio/audio_director_test.gd` | sound mapping coverage |
| `game/ui/ui_test.gd` | everything L4/L5 — the big one |
| `game/scenes/duel_*.gd`, `solo*.tscn` | end-to-end scenes that double as gates |

---

## 3. How these gates have lied

Every entry here actually happened, cost real time, and is now defended by something.

### 3.1 A feature with no caller

`CardView.art_source` was a static that **nothing ever assigned**. The entire card-art pipeline
was dead and every gate was green. `set_combat()` shipped complete, correct, and uncalled. The
`CONFIRM` input verb existed with no gesture bound to it.

**Defence adopted: self-policing tables.** The audio kind mapping, the input `BINDINGS` table and
the `EV` enum all fail the build or the suite when a new entry appears without its counterpart.
A table that lists what must exist is worth more than a test that checks what does.

**Rule:** when you add a capability, add the thing that *proves it is reached*, not just the
thing that proves it is correct.

### 3.2 A grep that could not fail

`make solo-test` asserted with `grep -qv "FAIL"` — which succeeds if **any single line** lacks
the word FAIL. It printed `PASS` above three real failures.

Fixed to `! grep -qE "^  FAIL"`, and then **proved to fail by injecting a failure**. The fix was
not trusted until it had gone red.

**Rule:** a new assertion is not finished until you have made it fail on purpose once.

### 3.3 A loop over zero items

`get_script_constant_map()` returns empty on Godot 4.6.3. The audio coverage test looped over
zero kinds and passed vacuously. The art test printed `0 cases, 0 failed` because
`DEFAULT_PICS_PATH` was inverted (`base/cards/pics` instead of `base/pics/cards`), so every case
was skipped.

**Rule:** a suite must print a case count, and a count of **zero is a failure**. Read the number,
not the colour.

### 3.4 Cases that never ran

Test cases called `_begin()` but never `_end()`, so they executed and counted for nothing. A
probe used `_check()` in a scene whose harness exposes `_expect()`, produced a 339-byte log, and
ran zero assertions.

**Rule:** after writing a case, check the total went up by the number you added.

### 3.5 A pass printed before the work finished

`[solo] all checks passed` appeared above five `FAIL ... no duel is running` lines, because
`_check_results()` ran before `end_duel()` and because `set_process(false)` **does not stop
signal-driven input** — the scene kept taking taps after it had torn itself down.

**Rule:** the summary line is emitted last, after teardown, or it is lying about what it covers.

### 3.6 A tree that did not compile

Commit `403faeb` was committed without the `touch` gate finishing — it timed out and was waved
through. The tree did not compile.

**Rule:** a timed-out gate is a failed gate.

### 3.7 A suite nobody ran

`test-ui` existed for a while without being in any gate list, which is how `make duel` quietly
rotted once.

**Rule:** a suite that is not in §1 of this file does not exist.

---

## 4. Patterns worth copying

- **Grep for the thing you forbid.** `ui_test.gd` greps all of `game/ui/` for screen measurement
  (`get_viewport_rect`, `DisplayServer.*size`) and for anything naming the core, because those
  are architecture rules no unit test can reach. Two cases, both cheap, both have caught drift.
- **Measure rects headlessly.** The layout cases instantiate a screen at 720×1280, 1080×2340 and
  1920×1080 and assert containment, non-overlap and a 48 px touch floor. No rendered frame and no
  window required.
- **Verify a drift test by injecting drift.** The menu's destination-literal check was confirmed
  by typing `"hostt"` into it: two cases failed, and passed again on restore.
- **Make the static the test target.** `MenuArt` is entirely static functions precisely so the
  suite can ask each decision directly, without a scene tree.
- **Audit from both seats.** The hot seat gate checks that a face-down card stays face-down when
  viewed from the *other* side, which is the only cheap stand-in for V7 until `HostService` exists.

---

## 5. What is not covered

Honest list, so nobody mistakes green for complete.

- **Nothing has ever run on a real phone.** `make android-templates` (1.17 GB) has not been run.
  Touch is proven headlessly, which proves the verb routing and nothing about ergonomics,
  latency, thermals or battery.
- **`SELECT_OPTION`, `SELECT_YESNO`, `SELECT_EFFECTYN`, `SORT_CARD`, `SORT_CHAIN`** are parsed and
  answerable but never exercised, and no gesture names an option or an order.
- **35 of 97 `MSG_*` opcodes** are unimplemented. They degrade to `EV::UNHANDLED` (V13) rather
  than crash, which also means they fail silently.
- **No L2, so no V7 test.** Hidden-information filtering is asserted by convention in the hot
  seat, not by construction.
- **No replay determinism check.** `tools/replay_verify.py` does not exist; it arrives with
  replays. Until then, bump `native/vendor/ocgcore` only deliberately and record the SHA.
- **No performance budget.** `OCG_DuelProcess` timing on a mid-range phone is inference (I2 in
  ARCHITECTURE.md §0), not measurement.
