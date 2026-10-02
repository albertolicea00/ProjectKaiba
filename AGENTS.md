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
9. **Godot 4.6.3 segfaults on the first `--import` of a project with a GDExtension**, inside
   `EditorHelp::_gen_extensions_docs()` at shutdown. The import completes regardless; only the
   first one crashes. `make bootstrap-import` absorbs it. Upstream bug, not ours.

---

## 8b. Wire-format traps (found the hard way; all verified against vendor/ocgcore)

1. **`MSG_START`, `MSG_UPDATE_DATA` and `MSG_UPDATE_CARD` are never emitted by ocgcore.** No
   `new_message()` call site produces them. The host synthesises them: `MSG_START` from the
   duel configuration, the two UPDATE messages from `OCG_DuelQuery*`. EDOPro does this in
   `generic_duel.cpp`. Do not go looking for them in the core's message stream.
2. **Sequence width is not uniform inside a single message.** In `MSG_SELECT_IDLECMD` the
   summon / spsummon / mset / sset / activate lists write the sequence as `uint32_t`, but
   `repositionable_cards` writes it as `uint8_t`. Same split in `MSG_SELECT_BATTLECMD`
   between the activatable and attackable lists. Reading the wrong width desynchronises
   everything after it in the payload.
3. **`MSG_POS_CHANGE` does not carry a `loc_info`.** It writes code, controller, location,
   an 8-bit sequence, the previous position and the current position as separate bytes.
4. **`MSG_SUMMONED`, `MSG_SPSUMMONED`, `MSG_FLIPSUMMONED`, `MSG_CHAIN_END` and
   `MSG_ATTACK_DISABLED` have no payload at all.** They are pure sequencing markers.
5. **`MSG_SELECT_OPTION` writes its option count as `uint8_t`**, not `uint32_t` like every
   other list length in the select family.
6. **A zeroed `loc_info` in `MSG_ATTACK` / `MSG_BATTLE` means "direct attack"**, not
   "controller 0, location 0".
7. **`LOCATION_OVERLAY` (0x80) set in a loc_info's location** means the card is an xyz
   material: `seq` is then the host monster's sequence and `pos` is the index in its stack.

8. **`MSG_RETRY` (opcode 1) is how ocgcore rejects a response**, and it does **not** re-send
   the selection it rejected. A client that waits for a fresh `MSG_SELECT_*` after a bad answer
   waits forever. `MsgParser` surfaces it as `EV::RETRY`; L3 must answer the request it is still
   holding. This is also why `EV::UNHANDLED` and `EV::MALFORMED` sit at 1100/1101 instead of
   0/1 — opcode 1 was already taken.

9. **`MSG_SELECT_PLACE.flag` decoded** (from ocgcore's own validation, `playerop.cpp:588`):

   ```
   to_check = 1 << sequence
   if location is SZONE:  to_check <<= 8
   if not the asking player's side: to_check <<= 16
   a SET bit means the zone is NOT selectable
   ```

   So bits 0-6 are the asking player's monster zones, 8-15 their spell/trap zones, 16-22 the
   opponent's monster zones, 24-31 the opponent's spell/trap zones. Sides are relative to
   `event["player"]`, **not** to absolute player 0. Sequence caps: monster zones 0-6, spell
   zones 0-7. Answering with a zone whose bit is set yields `MSG_RETRY`, which is silent (see
   trap 8) — and answering a spell activation with a monster zone is the easy way to hit it.

10. **`MSG_SELECT_CARD` and `MSG_SELECT_TRIBUTE` share a prefix but not a card entry.**
    SELECT_CARD writes a packed `loc_info`; SELECT_TRIBUTE writes a loose controller/location/
    sequence triple plus a `release_param` byte. Reading the tribute entry as a `loc_info`
    overruns by four bytes per card. `MSG_SELECT_SUM` goes back to packed `loc_info` in both of
    its lists. There is no rule here to memorise — read the write site every time.
11. **`sum_param` in `MSG_SELECT_SUM` packs two alternatives**, low and high 16 bits
    (`field.cpp:2619`). A card whose Level may be treated as either value contributes whichever
    one makes the total work. Its `must` list is supplied by the engine and is not addressable
    by the answer, but does count toward the total.

`native/src/msg_parser.cpp` is the single place that knows any of this. Nothing above L1 may
read a raw packet.

## 9. Working rules

- Never reimplement a Yu-Gi-Oh! rule. If behavior looks wrong, the bug is in our adapter or in the
  card's Lua script, not in our code's understanding of the rules. (V3)
- `edopro/gframe/duelclient.cpp` is **reference documentation, not portable code**. It is coupled to
  Irrlicht. `core_utils.cpp` and `bufferio.h` from the same tree *are* portable — port those directly.
- When touching `native/vendor/ocgcore`, record the new pinned SHA in `CHANGELOG.md`. A core bump can
  break replay determinism (ARCHITECTURE.md R5). `tools/replay_verify.py` does not exist yet — it
  arrives with replays in Phase 3. Until then, bump the core only deliberately.
- Do not commit anything under `data/`. Card data and art are copyrighted.
- Do not turn the card script collection into a submodule. It is fetched by `make data-scripts`
  and gitignored on purpose; pinning it breaks Principle 2 (new cards must work as soon as their
  Lua exists). The rationale, and the one condition that would justify changing it, are in
  `.gitmodules` and `docs/ARCHITECTURE.md` section 7.
- State assumptions explicitly. Prefer saying "I don't know" over inventing engine behavior — the
  authority for ocgcore semantics is the source in `native/vendor/ocgcore/`, not memory.
