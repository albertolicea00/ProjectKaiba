# Project Kaiba — Roadmap

> **This file is the single roadmap.** `docs/ARCHITECTURE.md` section 12 points here.
> Last reviewed: 2026-10-05.
>
> Read `docs/ARCHITECTURE.md` for *why* the design is shaped this way, `AGENTS.md` for the rules
> that must hold while changing it, and this file for *what is done, what is next, and why in
> that order*.

---

## 1. Where the project actually is

Work did not follow the original phase order, so this table is the real state. A roadmap nobody
trusts is worse than no roadmap.

| phase | state | evidence |
|---|---|---|
| 0 — Data and toolchain | **done** | all three Android ABIs build; arm64 carries the 16 KB page flag; `make selftest` prints the ocgcore version |
| 1 — Headless duel | **done** | `make duel-real` plays a duel to `MSG_WIN` against real card data. `MsgParser` covers 62 of 97 opcodes; the rest degrade to `EV::UNHANDLED` (V13) |
| 2 — First playable duel | **mostly done**, two gaps | `make touch`, `make solo`, `make solo-test`, `make test-ui` all green. Missing: `HostService`/`ClientService`/`LoopbackTransport` (there is no L2 at all) and `heuristic_agent` (the only opponent is `PassiveAgent`, which passes on everything) |
| 3 — Decks, LAN, replays | **decks done, differently**; LAN and replays not started | `.ydk` loading, validation and a deck picker ship. There is deliberately **no deck editor** — see §4. `game/net/` does not exist |
| 4 — Polish and 3D | partial, out of order | dynamic camera, summon/attack VFX, audio, real card faces, zone markers and the card preview all landed early. No 3D models, no `PackManager`, no `VisualRegistry` |
| 5 — MVP release | not started | |

### Built but never in the plan

Real card faces from `data/base/pics/`, the large card preview with database text, zone markers,
stable card handles, the themed card back, the hot-seat solo mode, the controls table, the Duel
Links-style menu dress, auto-passing empty prompts and the actionable-card glow.

All of it came out of *using* the thing. That is the argument for shipping something playable
early, and it is also why the phase table above no longer matches the phase list in §6.

---

## 2. The one thing blocking everything else: there is no L2

`game/net/` does not exist. No `ITransport`, no `HostService`, no `ClientService`. Every duel
scene talks to `KaibaCore` directly. That works for solo play and is exactly why solo play
arrived so fast.

Three consequences, in the order they bite:

1. **Invariant V7 has nowhere to live.** Hidden-information filtering is supposed to happen in
   `HostService`, before the transport. Today nothing filters, because there is no transport and
   both seats are the same process. The hot seat hides what it should by convention, not by
   construction — `solo_test` deliberately reveals both hands, and nothing but care stops a
   future scene from doing the same by accident.
2. **LAN cannot start.** `TcpTransport` plugs into an interface nobody wrote. Host and Join are
   menu entries that route straight back to the menu with an explanation.
3. **The architecture diagram describes a layer that is not there.** That is the drift that makes
   a document stop being worth reading.

The shape is already decided (ARCHITECTURE.md §5): `HostService` owns the `OCG_Duel` and the
event filter, `ClientService` holds the mirrored `DuelState`, and **solo play runs over a
`LoopbackTransport`** so the single-player path exercises the same code as LAN.

Doing this *before* LAN rather than during it is the difference between adding a layer and
retrofitting one. It is the next structural task.

---

## 3. Next actions, ordered

Ordered by what unblocks the most, not by what is most fun.

### N1 — Build L2 behind the existing solo path *(next)*

- `game/net/transport.gd` — `ITransport`: `send(bytes)`, `received(bytes)` signal, `close()`.
- `game/net/loopback_transport.gd` — both ends in one process, no sockets.
- `game/net/host_service.gd` — owns `KaibaCore`, runs the duel, **filters per seat** (V7).
- `game/net/client_service.gd` — owns a `DuelState`, sends responses, knows nothing about ocgcore.
- Rewire `scenes/solo_test.tscn` to go through it. **Every current gate must stay green** — that
  is the proof the refactor was behaviour-preserving.

Exit: `make solo` and `make solo-test` pass with the core reached only through `HostService`,
and a grep proves no scene outside `game/net/` names `KaibaCore`.

### N2 — Close the unexercised selections

`SELECT_OPTION`, `SELECT_YESNO`, `SELECT_EFFECTYN`, `SORT_CARD` and `SORT_CHAIN` are parsed,
routed and answerable, but **no gesture names an option or an order** and no test drives them.
A card with two effects to choose between leaves the player stuck today.

Needs: an option list in `DuelHud` (it already renders a yes/no prompt), a drag-to-reorder for
sorts, and a scripted case per type in `duel_selectors.gd`.

### N3 — `heuristic_agent`

`PassiveAgent` passes on everything, which is why `solo` and `solo_test` looked identical to the
player and were collapsed into one menu entry. An opponent that summons the biggest thing it can
and attacks when it wins the maths is enough to earn the second entry back.

### N4 — LAN (`TcpTransport`, `LanDiscovery`, `Lobby`)

Only after N1. UDP broadcast for discovery, TCP for the duel, the payload staying **raw ocgcore
bytes** so EDOPro-server compatibility stays cheap if it is ever wanted (it is Post-MVP).

### N5 — Replays

`KBRP` container, Level-1 `DuelEvent` only (V9), `script_sha` in the header so a replay that was
recorded against a different card script collection says so instead of desyncing silently.
`tools/replay_verify.py` lands here.

### N6 — `MsgParser` batch 2 and 3

62 → ~80 → 97 opcodes. Mechanical, well-referenced, and the single best-case task for an agent.
Each opcode needs its `static_assert` against the `MSG_*` value and a decode test.

### N7 — 3D monsters

`PackManager`, `VisualRegistry`, `MonsterAvatar`, `AvatarPool`, then the first three models.
By design (V12) this touches **zero lines** in L1–L3. It is also the only MVP item that is not
structural: cutting it saves roughly 14 weeks and changes nothing architecturally.

---

## 4. Decisions that are settled — do not relitigate

| decision | why |
|---|---|
| **No deck editor.** Decks are external `.ydk` files the player picks | Every other client already speaks `.ydk` and does search, filtering and banlists better. Owning a format would cut this client off from all of them |
| **The card script collection is not a submodule** | Pinning it breaks Principle 2 — a new card must work the moment its Lua exists. Fetched by `make data-scripts`, gitignored on purpose |
| **LAN only; no EDOPro server compatibility in the MVP** | CTOS/STOC is a moving target that breaks on every EDOPro release. Keeping the payload as raw ocgcore bytes is what keeps it cheap later |
| **`solo` and `solo_test` are one menu entry** | While the opponent has no opinion to have, the difference is not worth two entries. `scenes/solo.tscn` and `PassiveAgent` are still gated by `make solo`, waiting for N3 |
| **Papyrus is loaded from the system, never bundled** | It is a licensed Apple font. `MenuArt.menu_font()` returns `null` when it is absent and every screen falls back to the engine face |
| **No widget sizes itself from the screen** | ARCHITECTURE.md §10 rule 4. In VR this layer becomes a world-space quad whose pixel size is an arbitrary texture resolution. Two tests grep for it |
| **`data/` is never committed** | Card data and art are copyrighted. See `DISCLAIMER.md` |

---

## 5. Risks, ranked by expected damage

1. **R1 — the 97-opcode layer.** 35 opcodes still unimplemented. They degrade safely (V13) but
   each one is a card that silently does nothing visible. Highest variance in the estimate.
2. **R2 — replay determinism across a core bump.** `native/vendor/ocgcore` is pinned; bumping it
   can invalidate every stored replay. Record the SHA in `CHANGELOG.md` on every bump.
3. **R3 — retrofitting L2.** Grows with every scene that talks to `KaibaCore` directly. This is
   why N1 is first.
4. **R4 — Android thermals and battery.** Unmeasured. `make android-templates` (1.17 GB) has not
   been run, so **nothing has ever been tested on a real phone.** Touch is proven only headlessly.
5. **R5 — 3D art.** Zero speedup from an agent. Either bought, generated, or the schedule moves.

---

## 6. Original phase plan, for reference

Kept because the phase names are cited elsewhere (`SceneRouter.PENDING`, ARCHITECTURE.md).
§1 is the authority on what is actually done.

- **Phase 0 — Data and toolchain.** Submodules, `base.pck`, SConstruct for macOS + android-arm64,
  "hello ocgcore". → *Godot prints 11.0 on Android.*
- **Phase 1 — Headless duel.** `core_utils`/`bufferio`, `CardDB`, `ScriptVFS`, `DuelThread`,
  `MsgParser` batch 1, `DuelState`, a console driver. → *A full duel in the logs.*
- **Phase 2 — First playable duel.** `BoardView` as 2D-in-3D, `EventTranslator`,
  `AnimationDirector`, `TouchSource`, HUD, `LoopbackTransport`, a dumb agent. → *A full duel on
  your phone against a bad AI. The first real milestone.*
- **Phase 3 — Decks, LAN, replays.** `.ydk` I/O and validator, `TcpTransport`, `LanDiscovery`,
  `Lobby`, replay record/playback, `MsgParser` batch 2. → *A LAN duel against a friend.*
- **Phase 4 — Polish and 3D.** `PackManager`, `VisualRegistry`, `MonsterAvatar`, first 3 models,
  dynamic camera, VFX, `MsgParser` batch 3, Android profiling. → *It looks like a game.*
- **Phase 5 — MVP release (private).** Remaining 7 models, battery and thermal work, network
  error handling, signed Android export, real testing with friends.
- **Phase 6+ — Future.** PC (`RigPC`, `MouseSource`), remote AI, EDOPro/YGOPro server
  compatibility as an isolated adapter, downloadable packs, VR (Phase 7).

---

## 7. Estimate

One developer at ~15 h/week with an agent pair, assuming no self-produced 3D art:
**53–83 weeks ≈ 13–20 months**, or 5–8 months full-time. The full breakdown and the honest
per-task speedup table are in `docs/ARCHITECTURE.md` §13.

Phases 0 and 1 are done, which removes the two items that could not be shortened.

---

## 8. Picking this up after a break

```bash
make doctor          # toolchain sanity
make host            # build the GDExtension for this machine
make verify smoke duel test-gd duel-real test-selectors touch test-ui solo solo-test
```

Ten gates, all green as of 2026-10-05 (52 UI cases, 0 failed). If one fails after a pull, read
`docs/TESTING.md` first — several of these gates have failed *vacuously* in the past, and the
section on that is there so the same hour is not spent twice.

Then read §2 and §3 of this file. N1 is the next task.
