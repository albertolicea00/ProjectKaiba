# Duel loop — how a duel actually runs in this codebase

> L1 → L3, the operational view. `docs/ARCHITECTURE.md` §5–7 has the design rationale;
> this file is what you need to read a scene or write a new one.
> Last reviewed: 2026-10-05.

---

## 1. The pipeline, concretely

```
ocgcore  --raw bytes-->  MsgParser  --DuelEvent-->  DuelState     (the model)
                            (L1 C++)                    |
                                                        v
InputSource --InputIntent--> SelectionController --intent--> KaibaCore.respond()
   (L5)                            (L3)                           (L1)
```

Three event levels, and the distinction is load-bearing:

| level | what | lives |
|---|---|---|
| 0 | raw ocgcore bytes | inside `native/`, never above L1 |
| 1 | `DuelEvent` — a Dictionary, **replayable, lossless** | the duel's truth. Replays store this and only this (V9) |
| 2 | `VisualIntent` — lossy, disposable | `EventTranslator` → `AnimationDirector`. Dropping one costs an animation, never a rule |

---

## 2. The `KaibaCore` surface

Twelve bound methods. Everything crossing the boundary is a `Dictionary` or a
`PackedByteArray` — never a raw struct (V14).

```
get_core_version()            get_build_info()           run_selftest()
load_card_database(path)      get_card_info(code)        add_script_root(path)
start_duel(config)            poll_event()               send_response(response)
respond(event_type, intent)   end_duel()                 is_duel_running()
```

`respond()` is the high-level door: it takes a *named intent* and builds the byte response in
`response_builder.cpp`. `send_response()` is the raw escape hatch.

**Threading (V4, V8):** `start_duel()` hands the `OCG_Duel` to a dedicated `DuelThread`. No
`OCG_*` call ever happens on the main thread, and one duel handle is only ever touched from its
own thread. Events come back through a lock-free SPSC queue; `poll_event()` drains it from
`_process`. This is why the console driver is a **scene** and not a `--script`: it needs
`_process` to pump.

---

## 3. A duel from start to finish

1. `load_card_database("data/base/cards.cdb")` and `add_script_root("data/base/script")`.
2. `start_duel(config)` — decks, flags, and a **non-zero** `seed[4]`. An all-zero seed is
   rejected with `OCG_DUEL_CREATION_NULL_RNG_SEED`.
3. `poll_event()` every frame. Feed each `DuelEvent` to `DuelState.apply()`, then to
   `EventTranslator` for the visual layer.
4. The duel **parks** on an `MSG_SELECT_*`. Nothing advances until it is answered.
5. `SelectionController.set_pending(event)`. Taps arrive as `InputIntent`s. `resolve()` returns
   `{}` until enough have arrived to constitute an answer — a tap mid-selection is not an error.
6. `respond(event_type, intent)`. The duel resumes.
7. `MSG_WIN`, then `end_duel()`.

---

## 4. Answering selections

`SelectionController` handles eleven selection types with a six-verb input vocabulary.

| type | answered by |
|---|---|
| `SELECT_IDLECMD` | a tapped card, matched against `summon`/`spsummon`/`mset`/`sset`/`activate` |
| `SELECT_BATTLECMD` | a tapped card, matched against `activate`/`attack` |
| `SELECT_PLACE` | a tapped empty zone, validated against the flag mask |
| `SELECT_CARD`, `SELECT_TRIBUTE`, `SELECT_SUM` | one or more tapped cards, then `CONFIRM` |
| `SELECT_YESNO`, `SELECT_EFFECTYN` | the prompt's Yes / No |
| `SELECT_CHAIN` | a tapped chainable card, or cancel to pass |
| `SELECT_POSITION` | the prompt |
| `SELECT_OPTION`, `SORT_CARD`, `SORT_CHAIN` | **not really answerable yet** — see §7 |

### Handles, not passcodes

An `InputIntent` carries a **handle**. A selection event carries lists of
`{"card": code, "at": {con, loc, seq, pos}}`. The bridge is `DuelState`: the handle names a
`DuelCard`, the card knows its controller/location/sequence, and that triple plus the passcode is
matched against every entry of every offered list.

It has to be the handle. **Two copies of one card in a hand share a passcode, and a face-down card
reports `0`.** The passcode is still compared when both sides know it, as a second opinion that
catches a `DuelState` that has drifted out of step with the engine.

### One tap, several meanings

A card in hand is offered in several lists at once — a monster as both `summon` and `mset`, a
spell as both `activate` and `sset` — and nothing in the request says which the player meant.

`IDLE_PRIORITY` encodes "the most committal reading of a tap wins". `IDLE_ALT_PRIORITY` is the
other half: the `SELECT_ALT` verb (drag down / middle click) reads **set before play**, so the
player says which reading they meant instead of a table guessing.

### Silence when there is nothing to do

`auto_answer()` cancels a `SELECT_CHAIN` that is **not forced** and whose offer list is **empty**,
without ever asking. Any other type is a real question. When there *is* something to do,
`actionable_handles(state)` computes the offered set from `OFFER_LISTS` and the board lights those
cards.

---

## 5. The failure mode that defines this layer

**A wrong answer is not reported as a wrong answer.** ocgcore replies `MSG_RETRY` and **does not
resend the selection it rejected**. A client that waits for a fresh `MSG_SELECT_*` waits forever;
the duel simply appears to hang.

Consequences baked into the code:

- `MsgParser` surfaces it as `EV::RETRY`, and `EV::UNHANDLED`/`EV::MALFORMED` sit at **1100/1101**
  because opcode 1 was already `MSG_RETRY`.
- L3 must re-arm and answer **the request it is still holding**, not wait for a new one.
- The refusal must be **visible on screen**. A silent refusal is indistinguishable from a freeze.
- Every key `SelectionController` produces was read off `response_builder.cpp`, and every
  validation rule off `vendor/ocgcore/playerop.cpp`. Nothing here is guessed, because guessing
  costs a hang rather than an error message.

---

## 6. Message coverage

62 of 97 opcodes parsed. Each has a `static_assert` tying its `EV` value to the real `MSG_*`
constant, so a core bump that renumbers anything fails the build instead of desynchronising.

Unimplemented opcodes become `EV::UNHANDLED` with a WARN and the duel continues (V13) — safe, and
also silent, which is why the remaining 35 are tracked as risk R1 in `ROADMAP.md`.

`MSG_START`, `MSG_UPDATE_DATA` and `MSG_UPDATE_CARD` are **never emitted by ocgcore**. The host
synthesises them. Do not go looking for them in the stream.

All the wire-format traps — non-uniform sequence widths, `MSG_POS_CHANGE` carrying no `loc_info`,
the `SELECT_PLACE` flag mask, `SELECT_TRIBUTE`'s loose triple, `sum_param`'s two packed
alternatives — are in `AGENTS.md` §8b. `native/src/msg_parser.cpp` is the single place that knows
any of it.

---

## 7. Known gaps

- **`SELECT_OPTION` and `SORT_CARD` have no gesture.** The six-verb vocabulary cannot name an
  option or an order, so they are answered with their least-destructive default — first option,
  decline the sort — and flagged by `can_answer()`. A card with two effects to choose between
  leaves the player stuck. This is N2 in `ROADMAP.md`.
- **`MSG_SELECT_COUNTER`, `MSG_SELECT_UNSELECT_CARD` and the `MSG_ANNOUNCE_*` family** are not
  answered at all — `MsgParser` does not parse them yet.
- **No L2.** Every duel scene talks to `KaibaCore` directly, so V7 (hidden-information filtering
  in `HostService`) has nowhere to live. `ROADMAP.md` §2.
- **The only opponent is `PassiveAgent`**, which passes on everything.
