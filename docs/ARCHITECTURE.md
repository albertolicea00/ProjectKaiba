# Project Kaiba — Architecture

> Living document. 5-year horizon. Decisions with rationale, not option menus.
> Verified against `../sdk/` on 2026-10-01.

---

## 0. Ground truth (verified, not inferred)

| fact | source |
|---|---|
| ocgcore v11.0, C API of 12 functions | `sdk/ygopro-core/ocgapi.h` |
| C++17, `-fno-rtti`, `-fexceptions`, static Lua 5.4 | `Android.mk`, `meson.build` |
| Official Android.mk already targets arm64-v8a (16KB pages) | `sdk/ygopro-core/Android.mk` |
| `OCG_DuelProcess` is blocking and synchronous | `ocgapi.h` |
| EDOPro translates 97 distinct `MSG_*` opcodes | `edopro/gframe/duelclient.cpp` |
| `sdk/edopro/ocgcore`, `sdk/ygopro/ocgcore`, `sdk/ygopro/script` are EMPTY | `ls` |
| No `cards.cdb` and no card `.lua` scripts anywhere in the SDK | `find` |
| ocgcore is **AGPL-3.0-or-later** | `ocgapi.h` header |

**Inferences** (labeled as such — verify before building on them):
- I1: ocgcore is deterministic given `(seed[4], flags, deck order, response sequence)`. This is the foundation of the replay system. It is how EDOPro produces `.yrp`, but confirm by reading `RNG/` before committing.
- I2: `OCG_DuelProcess` on a mid-range phone should stay under 16ms in normal cases, but long chains (FTK, loops) may exceed 200ms. Measure before budgeting the frame.

---

## 1. Overall architecture

Five layers. Hard rule: **no layer knows about the layer above it.**

```
┌─────────────────────────────────────────────┐
│  L5  Platform shell                         │  Android / PC / VR
│      CameraRig, InputSource, HUD            │  swappable
├─────────────────────────────────────────────┤
│  L4  Visual Layer (Godot, GDScript)         │
│      BoardView, CardView, MonsterAvatar     │  consumes VisualIntent
│      AnimationDirector, VFX, Audio          │  NEVER reads ocgcore
├─────────────────────────────────────────────┤
│  L3  Game Adapter (GDScript + C++)          │
│      DuelState (pure model)                 │  97 MSG_* → DuelEvent
│      EventTranslator → VisualIntent         │  ResponseBuilder
├─────────────────────────────────────────────┤
│  L2  Networking / Transport                 │
│      ITransport: Loopback | TcpLan | (WAN)  │  moves opaque bytes
├─────────────────────────────────────────────┤
│  L1  Core (GDExtension, C++)                │
│      KaibaCore → ocgapi.h                   │  dedicated thread
│      CardDB reader, ScriptVFS               │
└─────────────────────────────────────────────┘
```

**V1**: L4 never imports anything from L1 or L2.
**V2**: L3 never instantiates `Node3D`, `Texture`, or anything from the scene tree.
**V3**: all rules logic lives inside `libocgcore`. Writing a Yu-Gi-Oh! rule in GDScript is a bug.
**V4**: L1 runs on a dedicated thread. Any `OCG_*` call from the main thread is a bug.

### Why GDExtension and not a Godot module

GDExtension (`godot-cpp`). Concrete reasons:
- A module means recompiling the engine plus export templates per ABI. Roughly a 20-minute iteration cycle on Android. Unacceptable over 5 years.
- GDExtension produces `libkaiba_core.so` per ABI while the Godot editor stays stock. Rebuilds take seconds.
- Isolates AGPL contamination into one identifiable binary.

Cost: you must ship 3 Android ABIs (`arm64-v8a`, `armeabi-v7a`, `x86_64`) plus host builds (`macos arm64`, `linux x64`, `windows x64`) for the editor and CI.

---

## 2. Folder structure

```
ProjectKaiba/
├─ native/                        # all C++, outside the Godot project
│  ├─ SConstruct                  # standard godot-cpp build
│  ├─ godot-cpp/                  # submodule
│  ├─ vendor/
│  │  ├─ ocgcore/                 # submodule → edo9300/ygopro-core
│  │  └─ lua/                     # submodule, 5.4
│  └─ src/
│     ├─ register_types.cpp
│     ├─ kaiba_core.cpp/.h        # Godot Object: duel facade
│     ├─ duel_thread.cpp/.h       # worker + SPSC queues
│     ├─ card_db.cpp/.h           # cdb → OCG_CardData (cardReader)
│     ├─ script_vfs.cpp/.h        # ScriptReader over mounted packs
│     ├─ msg_parser.cpp/.h        # 97 MSG_* → DuelEvent  ← the real work
│     ├─ query_parser.cpp/.h      # OCG_DuelQuery* → QuerySnapshot
│     ├─ response.cpp/.h          # DuelResponse → OCG_DuelSetResponse buffer
│     └─ replay.cpp/.h            # deterministic serialization
│
├─ game/                          # Godot 4 project
│  ├─ project.godot
│  ├─ bin/                        # .so/.dll per ABI + kaiba.gdextension
│  ├─ core/                       # L3 — zero scene dependencies
│  │  ├─ duel/
│  │  │  ├─ duel_state.gd         # pure model: zones, cards, LP, phase
│  │  │  ├─ duel_card.gd          # id, loc, pos, current atk/def
│  │  │  ├─ event_translator.gd   # DuelEvent → VisualIntent[]
│  │  │  └─ intent_queue.gd
│  │  ├─ deck/
│  │  │  ├─ deck_model.gd
│  │  │  ├─ ydk_io.gd             # .ydk import/export (EDOPro compatible)
│  │  │  └─ deck_validator.gd     # lflist, counts
│  │  ├─ registry/
│  │  │  ├─ card_registry.gd      # id → metadata (name, text, set)
│  │  │  ├─ visual_registry.gd    # id → VisualDefinition  ← §9
│  │  │  └─ pack_manager.gd       # .pck mounting, priorities  ← §8
│  │  └─ replay/
│  │     └─ replay_io.gd
│  ├─ net/                        # L2
│  │  ├─ i_transport.gd           # interface
│  │  ├─ loopback_transport.gd    # solo/AI: host runs in-process
│  │  ├─ tcp_transport.gd         # LAN
│  │  ├─ lan_discovery.gd         # UDP broadcast
│  │  ├─ host_service.gd          # arbiter: sole owner of the ocgcore instance
│  │  ├─ client_service.gd        # consumes events, emits responses
│  │  └─ protocol/
│  │     └─ packets.gd            # KTOS/STOK, project-owned wire format
│  ├─ ai/
│  │  ├─ ai_agent.gd              # interface: (DuelState, request) → Response
│  │  └─ heuristic_agent.gd       # MVP: basic rules
│  ├─ view/                       # L4
│  │  ├─ board/ card_view.gd, monster_slot.gd, board_view.gd
│  │  ├─ avatar/ monster_avatar.gd, avatar_pool.gd
│  │  ├─ anim/   animation_director.gd, timeline_builder.gd
│  │  └─ fx/
│  ├─ platform/                   # L5
│  │  ├─ camera/ camera_rig.gd, rig_mobile.gd, rig_pc.gd, rig_vr.gd
│  │  └─ input/  input_source.gd, touch_source.gd, mouse_source.gd, xr_source.gd
│  ├─ ui/ main_menu/, deck_editor/, lobby/, hud/
│  └─ scenes/                     # §4
│
├─ data/                          # NOT versioned (see .gitignore)
│  ├─ base/     cards.cdb, script/*.lua, pics/
│  └─ packs/    *.pck
│
├─ tools/
│  ├─ pack_builder/               # headless Godot script → .pck
│  ├─ cdb_check.py
│  └─ replay_verify.py            # re-simulates replays in CI
└─ docs/
```

---

## 3. Modules

| module | layer | responsibility | language |
|---|---|---|---|
| `KaibaCore` | L1 | ocgcore facade, process/message/response cycle | C++ |
| `DuelThread` | L1 | worker thread, SPSC in/out queues | C++ |
| `CardDB` | L1 | `cardReader` over SQLite cdb, fully RAM-cached | C++ |
| `ScriptVFS` | L1 | `scriptReader` over mounted packs; resolves `c<id>.lua` | C++ |
| `MsgParser` | L1 | 97 `MSG_*` → typed `DuelEvent` | C++ |
| `ReplayIO` | L1/L3 | record and play back | C++ + gd |
| `HostService` | L2 | authoritative arbiter. Sole owner of the `OCG_Duel` | gd |
| `ClientService` | L2 | mirrored state, UI, responses | gd |
| `ITransport` | L2 | opaque bytes. Two implementations for the MVP | gd |
| `DuelState` | L3 | pure board model | gd |
| `EventTranslator`| L3 | `DuelEvent` → `VisualIntent[]` | gd |
| `PackManager` | L3 | mount/unmount packs, priority resolution | gd |
| `VisualRegistry` | L3 | `CardID → VisualDefinition` with fallback | gd |
| `BoardView` | L4 | 3D field scene | gd |
| `AnimationDirector`| L4 | consumes intents, drives timelines | gd |
| `CameraRig` | L5 | swappable per platform | gd |
| `InputSource` | L5 | touch/mouse/XR → `InputIntent` | gd |

---

## 4. Godot scenes

```
Main.tscn                      autoloads: PackManager, CardRegistry, VisualRegistry, AudioBus
└─ SceneRouter

MainMenu.tscn                  Solo / Host Duel / Join Duel / Decks / Replays
DeckEditor.tscn                virtualized list + filters + touch drag
Lobby.tscn                     Host: IP + QR. Join: discovered LAN list + manual IP

Duel.tscn                      ← the scene that matters
├─ DuelController              creates HostService and/or ClientService
├─ World3D (Node3D)
│  ├─ Table                    1.20m × 0.75m REAL SCALE  ← §10
│  ├─ BoardView
│  │  ├─ ZoneAnchors           Marker3D: MZ0..4, SZ0..4, EMZ0..1, GY, Banish, Deck, Extra
│  │  ├─ CardPool              recycled CardView instances
│  │  └─ AvatarPool            recycled MonsterAvatar instances
│  ├─ FXLayer
│  └─ CameraRig                swappable child
│     └─ [RigMobile|RigPC|RigVR]
├─ AnimationDirector
├─ UILayer (CanvasLayer)       mobile/PC only; VR substitutes UIWorld3D
│  ├─ PhaseBar, LPDisplay, ChainPrompt, SelectionOverlay
└─ InputLayer
   └─ [TouchSource|MouseSource|XRSource]
```

**V5**: `BoardView` reads only from `DuelState`. Never from `KaibaCore`.
**V6**: nothing under `World3D/` uses screen-space coordinates.

---

## 5. Data flow

### Duel loop

```
1. HostService.start()
     → KaibaCore.create_duel(seed, flags, players)
     → OCG_DuelNewCard for every card in both decks
     → OCG_StartDuel

2. DuelThread loop:
     status = OCG_DuelProcess(duel)
     while (buf = OCG_DuelGetMessage(duel)):
         for packet in PacketStream(buf):
             ev = MsgParser.parse(packet)       # typed DuelEvent
             out_queue.push(ev)
     if status == AWAITING: block until a response arrives

3. HostService drains out_queue:
     - filters by visibility (opponent hand, deck → hidden)
     - sends serialized DuelEvent to each ClientService over ITransport
     - appends to ReplayBuffer

4. ClientService receives DuelEvent:
     DuelState.apply(ev)                        # pure, deterministic model
     intents = EventTranslator.translate(ev)    # 0..N VisualIntent
     AnimationDirector.enqueue(intents)

5. If the event requires input (MSG_SELECT_*):
     ClientService.pending_request = ev
     UI renders the selection on top of DuelState
     user taps → InputIntent → ResponseBuilder → DuelResponse
     → ITransport → HostService → KaibaCore.set_response(bytes)
     → DuelThread unblocks, back to (2)
```

### Two state models, deliberately

- **DuelState** (L3): authority for UI. Updates *immediately* when an event is applied.
- **BoardView** (L4): chases DuelState with animation, may lag two seconds behind.

Never sync BoardView against the core. If the user skips animations, BoardView snaps to DuelState. This is what lets you have Duel-Links-tier animation without ever stalling the duel clock.

### Which seat is "mine" is not board state

`DuelState` holds `turn_player` but never "the local player". A board does not know who is
looking at it, and giving it a seat would be the same mistake as baking a viewer's perspective
into the Level-1 event stream — which we explicitly refused (see the player-coordinate note in
`native/src/duel_event.h`).

The reason is the same in both places: a replay must be watchable from either side, and a
spectator has no seat at all. A model that committed to one viewer could not serve either.

So the seat lives in the viewing layer. `DuelHud.local_player` carries it today; when
networking lands, `ClientService` sets it from the seat the host assigned. Nothing in the model
changes, which is the point.

### Visibility / anti-cheat

**V7**: hidden-information filtering happens in `HostService`, before the transport. Never in the client.
On a friends-only LAN the risk is low, but filtering client-side forces a rewrite when dedicated servers arrive. EDOPro already does this: `Query::GenerateBuffer(is_for_public_buffer, check_hidden)` in `core_utils.h`. Mirror that semantics.

---

## 6. Communication with ocgcore

### Exact surface to wrap

```cpp
OCG_CreateDuel(&duel, &options)       // options: seed[4], flags, team1/2, 4 callbacks
OCG_DuelNewCard(duel, &info)          // populate decks
OCG_StartDuel(duel)
OCG_DuelProcess(duel)                 // → END | AWAITING | CONTINUE
OCG_DuelGetMessage(duel, &len)        // raw buffer, parse with PacketStream
OCG_DuelSetResponse(duel, buf, len)
OCG_LoadScript(duel, buf, len, name)
OCG_DuelQuery / QueryLocation / QueryField
OCG_DestroyDuel(duel)
```

### Callbacks (the four contracts to implement)

```cpp
cardReader(payload, code, OCG_CardData* out)   // ← SQLite cdb. Cache EVERYTHING in RAM at boot.
cardReaderDone(payload, OCG_CardData*)         // free setcodes
scriptReader(payload, duel, name)              // ← ScriptVFS. name = "c12345678.lua" or "constant.lua"
logHandler(payload, str, type)                 // ← Godot console. ERROR here means a broken script.
```

`cardReader` is called **thousands of times per duel**. `OCG_CardData.setcodes` is a zero-terminated `uint16_t*` owned by the caller: use a per-duel arena, release in `cardReaderDone`. A typical cdb fits in roughly 30MB of RAM — load it entirely at startup and serve from an `unordered_map`. Zero I/O on the hot path.

### Threading

`OCG_DuelProcess` blocks. One dedicated thread per duel instance.
Main↔duel communication over two lock-free SPSC queues. No mutex on the render thread.

**V8**: `OCG_Duel` is touched only from `DuelThread`.

### Build

```
native/SConstruct → godot-cpp + ocgcore + lua 5.4
targets: android{arm64-v8a, armeabi-v7a, x86_64}, linux.x86_64, macos.universal, windows.x86_64
ocgcore flags: -std=c++17 -fexceptions -fno-rtti -fvisibility=hidden -DOCGCORE_EXPORT_FUNCTIONS
android arm64: -Wl,-z,max-page-size=16384   # mandatory, Android 15+
```

Link ocgcore **statically** into `libkaiba_core.so`. One less binary to ship, and no dynamic symbol resolution on Android.

### What cannot be reused

`duelclient.cpp` (4658 lines, 97 `case MSG_*`) is coupled to Irrlicht and `ClientField`. **It is not portable. It is documentation.** The message interpretation layer must be reimplemented. This is the project's largest hidden cost — see §11 R1.

Portable nearly as-is: `core_utils.cpp` (`PacketStream`, `Query`, `ReadLocInfo`) and `bufferio.h`. Roughly 500 lines of pure parsing with no UI dependencies. Port these first.

---

## 7. Event format

Three levels. Do not collapse them.

### Level 0 — Wire (ocgcore bytes)
What `OCG_DuelGetMessage` emits. `[u8 msg][payload...]`. Opaque. This is what travels over the network.

### Level 1 — `DuelEvent` (L1→L3)
Typed struct emitted by `MsgParser`. Lossless. Replayable.

```gdscript
# Represented as a Dictionary at the GDScript boundary (cheap to serialize)
{
  "t": EV.MOVE,
  "card": 89631139,
  "from": {"con": 0, "loc": LOC.HAND,  "seq": 2, "pos": POS.FACEDOWN},
  "to":   {"con": 0, "loc": LOC.MZONE, "seq": 2, "pos": POS.FACEUP_ATK},
  "reason": REASON.SUMMON
}
```

Minimum set for the MVP. The 97 `MSG_*` opcodes are not all needed up front — prioritize:

`START, DRAW, MOVE, POS_CHANGE, SET, SUMMONING, SUMMONED, SPSUMMONING, SPSUMMONED, FLIPSUMMONING, FLIPSUMMONED, CHAINING, CHAINED, CHAIN_SOLVING, CHAIN_SOLVED, CHAIN_END, NEW_TURN, NEW_PHASE, DAMAGE, RECOVER, LPUPDATE, ATTACK, BATTLE, ATTACK_DISABLED, SELECT_IDLECMD, SELECT_BATTLECMD, SELECT_EFFECTYN, SELECT_YESNO, SELECT_OPTION, SELECT_CARD, SELECT_CHAIN, SELECT_PLACE, SELECT_POSITION, SELECT_TRIBUTE, SELECT_SUM, SORT_CARD, HINT, CONFIRM_CARDS, SHUFFLE_*, UPDATE_DATA, UPDATE_CARD, WIN`

That is roughly 45 of 97 and covers over 95% of real duels. The remaining 52 are edge cases (counters, announce, rock-paper-scissors, special modes) and get added incrementally. **Every unimplemented `MSG_` must log a WARN with the opcode and keep going — never crash.**

### Level 2 — `VisualIntent` (L3→L4)
Semantic. Lossy, enriched, disposable.

```gdscript
{
  "kind": "SUMMON",
  "card_id": 89631139,
  "from_anchor": "HAND_P0",
  "to_anchor": "MZ_P0_2",
  "face": "UP_ATK",
  "duration": 1.4,
  "blocking": true
}
```

An intent carries `card_id`, never a resolved `VisualDefinition`. L3 producing one would mean L3
instantiating an L4 Resource, which breaks V2, V11 and V12 at once. L4 resolves the visual from
`card_id` through `VisualRegistry` at the moment it needs it (§9). The anchor grammar
(`MZ_P0_2`, `EMZ_P1_0`, `ST_P0_3`, `FZ_P0`, `OVL_MZ_P0_2_1`, `PLAYER_P1`, `NOWHERE`) is the only
shared vocabulary between the two layers.

**V9**: replays store Level 1 only. Never Level 2. Changing animations must not invalidate replays.

### Replay

```
header: magic "KBRP", version, core_version{major,minor}, script_sha[20], flags
        seed[4], host_info, deck_p0[], deck_p1[]
body:   DuelResponse[]   # responses only — the duel is re-simulated
tail:   DuelEvent[]      # OPTIONAL "fat replay" fallback
```

### Why the script collection is not a submodule

`ocgcore` is pinned as a submodule; the ProjectIgnis card scripts deliberately are not, even
though a script change alters how a card resolves and therefore threatens replay determinism in
exactly the way a core bump does (R5).

The reason is Principle 2: *new cards must work automatically as soon as their Lua exists*. A
pinned submodule means a new card does not appear until somebody raises the pin by hand, and the
collection receives commits daily. Pinning it would trade the project's stated goal for a
guarantee we can get more cheaply.

Instead, `script_sha` records which collection a replay was made against. On playback, a
mismatch is a warning and a switch to the recorded event tail, the same path a `core_version`
mismatch already takes.

**Known limit, stated plainly:** `make data-scripts` clones with `--depth 1`, so a recorded SHA
is diagnostic, not reproducible — you cannot check out the exact old revision to re-simulate
against it. Dropping `--depth 1` buys that back at roughly 500 MB. Worth revisiting if replay
fidelity across script updates ever becomes a real complaint rather than a theoretical one.

A thin replay (responses only) is a few KB, but **breaks if ocgcore behavior changes**. Hence the optional tail: if `core_version` mismatches on open, play back the recorded event stream instead of re-simulating. Two modes, one file. This decision is what saves your replay library over a 5-year horizon.

Importing/exporting EDOPro `.yrp`/`.yrpX`: deferred, not MVP.

---

## 8. Asset system

### Format
Godot's native `.pck`. `ProjectSettings.load_resource_pack(path, replace_files=false)` mounts over `res://` at runtime.

### Pack layout

```
monster_pack_dm.pck
├─ pack.json
└─ packs/monster_pack_dm/
   ├─ visuals/89631139.tres        # VisualDefinition
   ├─ models/blue_eyes.glb
   └─ audio/blue_eyes_summon.ogg
```

```json
{
  "id": "monster_pack_dm",
  "name": "Duel Monsters 3D Pack",
  "version": "1.2.0",
  "kind": "visual",
  "priority": 100,
  "requires": { "base": ">=1.0.0" },
  "provides_cards": [89631139, 46986414, 74677422],
  "size_mb": 180,
  "platforms": ["android", "pc"]
}
```

### Pack kinds

| kind | contents | required |
|---|---|---|
| `base` | cards.cdb, Lua scripts, 2D art | **yes** |
| `visual` | 3D models, animations, VFX, audio | no |
| `cinematic` | summon cutscenes | no |
| `xr` | VR assets, world-space UI | no |
| `skin` | sleeves, playmats, UI themes | no |

### Resolution

At boot, `PackManager` scans `data/packs/*.pck`, validates `requires`, sorts by ascending `priority`, mounts. Builds the `card_id → [pack_ids]` index.
Higher priority wins. A pack can override another pack's visual — that is the foundation for future skins with no new code.

**V10**: unmounting any pack with `kind != base` must never prevent a duel from being played. Automated test: run the duel suite with **only** `base` mounted.

Downloadable on-demand packs land in Phase 5+. On Android, `data/packs/` lives in external app storage, not inside the APK. The APK ships `base` only, or nothing at all (first-launch download).

---

## 9. 3D monster system

### The contract

```
CardID ──→ VisualRegistry.resolve(id) ──→ VisualDefinition
                                             ├─ model exists → MonsterAvatar
                                             └─ no model     → 2D CardView
```

`VisualRegistry.resolve()` **never returns null.** There is always a fallback.

### `VisualDefinition` (Resource)

```gdscript
class_name VisualDefinition extends Resource

@export var card_id: int
@export var display_mode: DisplayMode      # CARD_2D | MODEL_3D | CARD_2D_WITH_FX
@export var model: PackedScene             # .glb; null means fallback
@export var scale_on_field: float = 1.0
@export var board_footprint: Vector2       # keeps it out of neighboring zones
@export var anim_map: Dictionary           # "idle"/"summon"/"attack"/"hit"/"destroyed" → clip name
@export var summon_fx: PackedScene
@export var attack_fx: PackedScene
@export var sfx: Dictionary
@export var lod_bias: float = 1.0          # mobile budget
@export var variants: Array[VisualDefinition]  # skins / alt-arts
```

### Scene separation

`MonsterSlot` (child of `ZoneAnchors/MZ_P0_2`) is a pure container. It holds exactly one of:
- `CardView` — quad plus art texture. Always available.
- `MonsterAvatar` — loads the `.glb`, applies `anim_map`.

**V11**: `DuelState` never references `VisualDefinition`, `PackedScene`, or `MonsterSlot`. Only `card_id` and zone coordinates.
**V12**: adding or removing a 3D model touches zero lines in L1–L3.

### Mobile budget (mid-range, target 60fps / 30fps floor)

- Max 6 simultaneous 3D avatars on the field. The 7th degrades to `CARD_2D`.
- ≤12k tris per model, 1 material, 1024² atlas, no skeleton over 48 bones.
- `AvatarPool` pre-instantiates; never `load()` mid-animation. Preload when the decklist resolves — both decklists are known at duel start, so prefetch visuals for those 40-60 cards.
- With the 3D pack unmounted, the duel runs identically in 2D. That is the §8 V10 test.

### The MVP ten

Pick by *frequency in the MVP's preconstructed decks*, not by iconic status. A model nobody summons in a test match contributes nothing. Blue-Eyes, Dark Magician, Red-Eyes, Summoned Skull, Kuriboh, Curse of Dragon, Gaia, Celtic Guardian, Mystical Elf, Obelisk — but validate against the final decklists.

---

## 10. VR strategy

Do not build VR for the MVP. **Build so that VR never requires a rewrite.** Five rules, near-zero cost today:

1. **Real-world scale from day one.** The table is 1.20m × 0.75m in Godot units. Cards are 8.6cm × 5.9cm. Build the field at arbitrary scale and porting to VR means redoing all the art.
2. **CameraRig as a swappable node.** `Duel.tscn` contains no direct `Camera3D`. It contains a slot. `RigVR` will be an `XROrigin3D`.
3. **Input abstraction.** Everything goes through `InputIntent {select_card(ref), confirm, cancel, point_at(zone)}`. `TouchSource`, `MouseSource`, and `XRSource` emit it. L3/L4 never learn which one did.
4. **No `CanvasLayer` dependency in UI logic.** The HUD lives in `UILayer`, but each widget is built from pure `DuelState` data. In VR it is re-instantiated as `UIWorld3D` with `SubViewport` on quads. The actual rule: **no widget queries `get_viewport().size`** to make a logic decision.
5. **No screen raycasts in L3/L4.** Selection means `InputSource` resolves to a `card_ref`, not to coordinates.

The real VR phase (Phase 7+) is `RigVR` + `XRSource` + `UIWorld3D` + an `xr` pack. Estimated 6-10 weeks *if* these five rules held. Over 6 months if they did not.

---

## 11. Technical risks (ordered by expected damage)

| id | risk | prob | impact | mitigation |
|---|---|---|---|---|
| R1 | **Reimplementing the 97-opcode `MSG_*` layer.** It is 40% of the project and invisible in any optimistic roadmap | high | critical | Implement in 3 batches (45 → 70 → 97). WARN-and-continue on unsupported opcodes. Regression tests against real EDOPro replays |
| R2 | **No cards and no scripts.** The SDK contains no cdb and no card `.lua`. Without these there is no duel | **certain, today** | blocking | Phase 0. Init submodules, obtain cdb + scripts, build the `base.pck` pipeline. Before any game code |
| R3 | **AGPL-3.0.** ocgcore is AGPL-or-later. Linking it makes the whole binary a derivative work | certain | legal | You do not distribute (per README). Keep ocgcore in its own identifiable binary and document it. **If distribution ever becomes the plan, consult a lawyer — this is not legal advice** |
| R4 | Konami. Assets, names, artwork | — | legal | Already covered by DISCLAIMER.md. Do not publish the repo. Do not monetize |
| R5 | Replay determinism broken by an ocgcore update | medium | high | Optional fat replay (§7). CI runs `replay_verify.py` against all replays on every core bump |
| R6 | `cardReader` called thousands of times → Android stutter | medium | medium | Preload the whole cdb into RAM at boot. Measure with 3 profiling duels |
| R7 | Long `OCG_DuelProcess` (FTK/loops) blocks → network timeout | medium | medium | The dedicated thread already isolates it from render. Watchdog in HostService: over 5s, warn — do not kill |
| R8 | Struct alignment / ABI mismatch between C++ and GDScript on armeabi-v7a | medium | medium | Do not pass structs. Only `Dictionary` / `PackedByteArray` across the boundary. Pay the copy |
| R9 | 3D art scope. 10 rigged and animated models is artist work, not programmer work | high | high | 2D fallback always alive (§9 V12). Lets you ship the MVP with zero models if needed |
| R10 | EDOPro public server compatibility. `HostInfo.version` and `ClientVersion` are a moving target | high | low | **Explicitly out of scope.** See §12 Phase 6 |
| R11 | Solo-dev burnout over 5 years | high | critical | Every phase ends in something *playable*. Phase 2 is already playable |

---

## 12. Roadmap

**Moved to [../ROADMAP.md](../ROADMAP.md).** One roadmap, so the two cannot drift apart.

It carries the real state per phase, the original phase plan for reference, the ordered next
actions, the settled decisions, and the ranked risks.

The one thing worth repeating here, because it contradicts section 1 of this document: **L2 does
not exist.** `game/net/` is empty, every duel scene talks to `KaibaCore` directly, and so V7
(hidden-information filtering in `HostService`, before the transport) has nowhere to live and LAN
cannot start. The shape is already decided in section 5 — `HostService` owns the `OCG_Duel` and
the filter, `ClientService` holds the mirrored `DuelState`, and solo play runs over a
`LoopbackTransport` so the single-player path exercises the same code as LAN. Doing it before LAN
rather than during it is the difference between adding a layer and retrofitting one.

---

## 13. Estimate — one developer, with Claude Opus

**Stated assumptions** (if these change, the estimate changes):
- S1: developer is competent in Godot/GDScript **and** has prior C++ and native build-system experience. If C++ is new, multiply by 1.5.
- S2: ~15 h/week (side project). Full-time divides by roughly 2.7.
- S3: **no self-produced art.** 3D models are purchased, AI-generated, or third-party. Modeling them yourself adds 6 months minimum.
- S4: Claude Opus as a pair. Honest multipliers below, not marketing ones.

**Where Claude helps and where it does not:**

| kind of work | real speedup |
|---|---|
| `MSG_*` parsers (97 opcodes, repetitive, readable reference exists) | **3-4×** — the best case in this project |
| Deck editor UI, networking boilerplate, serialization | 2-3× |
| GDExtension glue, SConstruct, Android.mk | 2× |
| Architecture, schema design, review | 1.5× |
| **Debugging a deterministic native engine** (thread heisenbugs, ABI issues, memory corruption, replay non-determinism) | **~1×** — no shortcut, you read memory |
| 3D art, rigging, animation | **0×** |

| phase | weeks (15h/week) |
|---|---|
| 0 — Data and toolchain | 3-5 |
| 1 — Headless duel | 10-16 |
| 2 — First playable duel | 12-18 |
| 3 — Decks, LAN, replays | 10-14 |
| 4 — Polish and 3D | 12-20 |
| 5 — MVP release | 6-10 |
| **total** | **53-83 weeks** |

**≈ 13-20 months at 15 h/week. ≈ 5-8 months full-time.**

The range is wide because R1 (the 97-opcode layer) and R9 (3D art) are the two dominant variances, and both are hard to bound before Phase 1 is done.

**If you want to shorten it:** 3D monsters and "VR-ready system" are the only MVP items that are not structural. Cutting 3D from the MVP saves roughly 14 weeks and changes nothing architecturally — that is literally the point of `VisualRegistry` (§9 V12). VR preparation (§10) costs almost nothing *now* and a great deal later: keep it.

**What cannot be shortened:** Phase 0 and Phase 1. Without card data and a headless duel running, everything else is speculation.
