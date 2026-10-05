# UI — screens, navigation, dress and input

> Layers L4 (visual) and L5 (shell). Last reviewed: 2026-10-05.
> Rules that must hold here: V1, V2, V5, V6, V11, V12 in `AGENTS.md`.

---

## 1. The screens that exist

| destination | scene | what it is |
|---|---|---|
| `menu` | `ui/main_menu/main_menu.tscn` | Solo / Host / Join / Decks / Controls, as carved stone slabs |
| `solo` | `scenes/solo_test.tscn` | the duel. A hot seat: both turns are yours |
| `decks` | `ui/deck_picker/deck_picker.tscn` | lists the `.ydk` files found on disk and picks one |
| `controls` | `ui/controls/controls_screen.tscn` | every gesture, touch and PC, in one table |

`host`, `join` and `replays` are named in the menu because they are named in the roadmap. Choosing
one routes **back to the menu carrying the line of `SceneRouter.PENDING`** that says which phase
builds it. An unknown destination does the same with a different line — a typo should put the
player somewhere, not nowhere.

There is **no deck editor**, on purpose. See `ROADMAP.md` §4 and the header of `DeckLibrary`.

`scenes/solo.tscn` (one seat yours, `PassiveAgent` on the other) still exists and is still gated
by `make solo`. It lost its menu entry because, with a passive opponent, players could not tell
the two modes apart. It gets the entry back when `heuristic_agent` lands.

---

## 2. The navigation contract

One signal, looked up **by name**, so the router never depends on a screen's type:

```gdscript
signal chose(destination: String)     # every screen that can navigate
```

`SceneRouter.go(destination)` swaps the scene and emits `changed(destination)`. A screen that can
show text exposes `show_message(text)`, which is how `PENDING` lines get back to the player.

**This contract cost a bug and now has a guard.** `DeckPicker` once declared
`signal chose(entry: Dictionary)` — same verb, different payload — and because the router connects
by name, it handed a Dictionary to a String parameter. The error pointed at the *emitter*
(`Cannot convert argument 1 from Dictionary to String`) rather than at the disagreement.

`SceneRouter._takes_a_destination(scene)` now inspects the signal's declared argument before
connecting and refuses a mismatch loudly. Four UI cases cover it: correct signature, wrong
payload, no arguments, no signal.

So the picker speaks two verbs, and they mean different things:

```gdscript
signal deck_chosen(entry: Dictionary)   # which deck
signal chose(destination: String)       # where to go next
signal cancelled                        # Back, also mirrored through chose("menu")
```

**Rule: `chose` means navigation and nothing else.** A screen with a second thing to report names
it something else.

---

## 3. The dress — `game/ui/menu_art.gd`

Every full-screen menu wears the same art. All of it is `static`, the script owns no state and
never enters the tree, which is what lets `ui_test.gd` ask each decision directly with no window
and no rendered frame.

| call | decides |
|---|---|
| `background_for_orientation(orientation)` | **which of two background files** to hang — `background-menu-v.jpeg` or `-h.jpeg` |
| `current_background()` | the one and only place the device's orientation is read |
| `resting_slab()` / `pressed_slab()` | the nine-patch stone frame, from `frame-menu.png` |
| `dress_slab(button, face)` | the whole slab treatment for one row |
| `letter(control, face)` | the font, size, colour, shadow and outline |
| `menu_font(path)` | Papyrus **from the system path only**, `null` when absent |
| `content_panel()` | the dark panel that keeps dense content legible over a photograph |

It lives in `game/ui/`, not in `game/ui/main_menu/`, because three screens wear it and a file
three siblings share is not one sibling's property.

### Two art rules that are enforced, not merely intended

**No widget sizes itself from the screen.** ARCHITECTURE.md §10 rule 4. In VR this layer becomes a
world-space quad whose pixel size is an arbitrary texture resolution, so a layout that branched on
viewport size would stop meaning anything there. `ui_test.gd` greps all of `game/ui/` for it.

Choosing an *asset* from a device fact is a different act and is allowed: it selects a file, never
a size, a position or a number of columns. The layout is identical whichever texture comes back,
so on a headset the landscape cut loads and nothing else changes. The test counts that call across
all of `game/ui/` and demands **exactly one**.

**Papyrus is never bundled.** It is a licensed Apple system font, loaded from
`/System/Library/Fonts/Supplemental/Papyrus.ttc` when present. `menu_font()` returns `null`
otherwise and every screen falls back to the engine face. A grep forbids the font, the system path
and the raw texture-stylebox calls from appearing in any screen directory.

### Why dense screens get a panel and the menu does not

The menu is six words over a photograph and that breathes. A gesture table or a deck list over the
same photograph does not. `content_panel()` is a near-opaque dark fill with a sandstone edge. The
controls table gives **each row its own panel**, so the temple shows between the rows and the
screen still reads as the menu's sibling rather than a dark rectangle pasted over a picture.

Layouts are proven by measuring rects headlessly at 720×1280, 1080×2340 and 1920×1080: frame
containment, no sibling overlap, a 48 px touch floor, and every panel enclosing the text under it.

---

## 4. Input — one table, both devices

`game/platform/input/input_source.gd` holds `BINDINGS`, the single place any gesture is written
down. `TouchSource` and `MouseSource` implement it; the controls screen *renders* it, so a verb
cannot be added without appearing in the player-facing table.

| verb | does | touch | PC |
|---|---|---|---|
| `SELECT_CARD` | plays it the usual way: summon, activate, attack | tap the card | left click |
| `SELECT_ALT` | plays it the other way: **set** face-down | short drag downwards | middle click, or Shift+click |
| `SELECT_ZONE` | answers a request for a place | tap the empty zone | left click the empty zone |
| `POINT_AT` | **shows the card up close. Never counts as an answer** | press and hold | hover |
| `CONFIRM` | yes, finish a multi-card selection, next phase | the Yes/Confirm button on the prompt | Enter / Space / the button |

`CONFIRM` is a button rather than a gesture on purpose: there is no finger movement for "yes", and
a yes/no question deserves a visible yes rather than an undocumented flick.

A test asserts **every verb is reachable on a phone** — that is what caught `CONFIRM` existing in
the enum with nothing able to emit it.

---

## 5. The board — `game/view/board/`

`BoardView` owns anchors (zones in 3D), the `CardPool`, zone markers and highlights. It reads
**only** from `DuelState` (V5) and never touches `KaibaCore` (V1).

Things worth knowing before changing it:

- **`zone_turns(anchor)` is why spells stopped being drawn sideways.** ocgcore encodes a *set*
  spell as `FACEDOWN_DEFENSE`, the same position value that lays a monster on its side. The
  position is not enough; the zone has to be consulted too.
- **Stable card handles.** `DuelState` mints an integer handle per card, derived from the Level-1
  event stream. `view_by_handle()` / `take_view_by_handle()` are how the visual layer follows a
  card across zones. Handles are **never stored in replays** (V9) — they are regenerated on
  playback from the same stream.
- **`highlight_cards(handles)`** lights the cards a pending selection is actually offering.
  `SelectionController.actionable_handles(state)` computes the set from `OFFER_LISTS`.
- **`highlight_zones(anchors)`** does the same for places.
- `refresh_art(art)` swaps in real faces once `CardArt` has resolved them; the card back comes from
  `data/base/pics/back`.

`CardArt` is an LRU with a byte budget. The themed card back is deliberately **outside** the
budget — it is on screen constantly, and evicting it would be the one eviction that always costs.

---

## 6. The HUD and the preview

`DuelHud` reads the model and renders life points (rolling, not snapping), the turn owner, the
phase banner, pile badges, the pending prompt and the combat readout
(`set_combat(attacker, defender)` — the deciding number, so an attack that trades is legible).

`CardPreview` shows a card large with its database text: type line, attribute, race, ATK/DEF, link
markers, effect text. It is reached through `POINT_AT`, which is why that verb can never count as
an answer — looking at a card must always be safe.

A preview only ever shows what the seat is allowed to see. A face-down card is audited from
*both* seats in `make solo-test`, which is the cheapest available stand-in for V7 until
`HostService` exists.

---

## 7. Prompts: silence when there is nothing to do

A duel used to ask `Respond with an effect? 0 available, cancel to pass` — a question with no
answers. Now:

- `SelectionController.auto_answer()` returns a cancel for a **non-forced** `SELECT_CHAIN` whose
  offer list is empty. The prompt never reaches the player.
- When there *is* something to do, the offered cards glow instead
  (`actionable_handles()` → `highlight_cards()`).

The safety conditions matter: it auto-passes **only** `SELECT_CHAIN`, **only** when not forced,
and **only** when the list is genuinely empty. Any other selection type is a real question.

---

## 8. Refusals have to be visible

`respond()` returns ok for a well-formed intent, but ocgcore can still reject it with `MSG_RETRY`
— **and `MSG_RETRY` does not re-send the selection it rejected** (`AGENTS.md` §8b trap 8). A scene
that clears its pending state on a well-formed answer then waits forever for a question that
never comes. That froze a real duel.

The fix is two parts: re-arm the selection that is still outstanding, and **say so on screen**. A
silent refusal is indistinguishable from a hang.

---

## 9. Gotchas specific to this layer

- **A new or moved `class_name` needs a reimport** before anything referencing it compiles. The
  error names the *referencing* file, which is why this has cost time twice. Run
  `make bootstrap-import`.
- **GDScript lambdas capture by value.** `chosen = entry` inside a lambda rebinds the copy. Use
  `merge()` on a Dictionary you intend to mutate.
- **`set_process(false)` does not stop signal-driven input.** A scene that has ended must also
  disconnect, or it keeps taking taps after teardown.
- **`get_script_constant_map()` returns empty on Godot 4.6.3.** Any coverage test built on it loops
  over nothing and passes vacuously.
