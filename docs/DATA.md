# Game data

This is the other half of Phase 0, and the project's current hard blocker (ARCHITECTURE.md R2).
Without card data and Lua scripts there is no duel, only a toolchain.

**Nothing under `data/` is versioned.** Card text and artwork are copyrighted. See `DISCLAIMER.md`.

---

## Layout

```
data/
├─ base/
│  ├─ cards.cdb          SQLite card database
│  ├─ script/            c<id>.lua, constant.lua, utility.lua, procedure scripts
│  └─ pics/              card artwork (not obtainable from any official source)
└─ packs/                built .pck asset packs (ARCHITECTURE.md section 8)
```

`ScriptVFS` resolves a `scriptReader` request for `"c12345678.lua"` against `base/script/`, then
against any mounted pack in priority order.

---

## Sources

Verified against EDOPro's own source (`gframe/game.cpp:206`, `README.md`):

| content | repository |
|---|---|
| Card scripts | `https://github.com/ProjectIgnis/CardScripts` |
| Card databases | `https://github.com/ProjectIgnis/BabelCDB` |
| AI (reference only) | `https://github.com/ProjectIgnis/windbot` |

**Use the ProjectIgnis script collection, not `Fluorohydride/ygopro-scripts`.** We pin
`edo9300/ygopro-core` (OCG core v11). The Fluorohydride scripts target the older Fluorohydride
core and use a different Lua API; they will fail at load or behave incorrectly.

`BabelCDB` ships many `.cdb` files (one per set/era) rather than a single `cards.cdb`. They are
plain SQLite and can be merged. `tools/cdb_check.py` should verify the merged result before it is
used.

Artwork is not distributed by any of these projects and must be sourced separately.

---

## `cards.cdb` schema

Two tables joined on `id`. Statement taken verbatim from EDOPro's `data_manager.cpp:24`:

```sql
SELECT datas.id, datas.ot, datas.alias, datas.setcode, datas.type, datas.atk, datas.def,
       datas.level, datas.race, datas.attribute, datas.category,
       texts.name, texts.desc, texts.str1 ... texts.str16
FROM datas, texts
WHERE texts.id = datas.id
ORDER BY texts.id;
```

### Columns the rules engine needs

`CardDB` fills `OCG_CardData` from `datas`. Three columns are packed and must be decoded, not
copied. Logic mirrors `data_manager.cpp:120-157`.

| column | maps to | decoding |
|---|---|---|
| `id` | `code` | direct |
| `alias` | `alias` | direct |
| `type` | `type` | direct |
| `race` | `race` | direct, **64-bit** (`uint64_t`) |
| `attribute` | `attribute` | direct |
| `atk` | `attack` | direct |
| `setcode` | `setcodes` | **packs 4 x uint16**: `(setcode >> (i * 16)) & 0xffff` for `i` in 0..3. Drop zeroes, then append a terminating `0`. `OCG_CardData.setcodes` is a zero-terminated `uint16_t*` owned by us |
| `level` | `level`, `lscale`, `rscale` | **three fields in one int**: `level = raw & 0xff`, negated if `raw < 0` (cards with a "?" level); `lscale = (raw >> 24) & 0xff`; `rscale = (raw >> 16) & 0xff` |
| `def` | `defense` or `link_marker` | if `type & TYPE_LINK`, the column holds `link_marker` and `defense` is 0. Otherwise it is `defense` and `link_marker` is 0 |

### Columns the rules engine does not use

`ot` and `category` are absent from `OCG_CardData`. They are client-side only:

- `ot` — OCG/TCG/anime availability flags. Used by `deck_validator.gd`.
- `category` — effect category bitmask. Used by deck editor filters.

`texts.name`, `texts.desc` and `str1..str16` feed `CardRegistry`. `str1..str16` are the per-card
effect labels shown when a card offers multiple options.

---

## Memory strategy

`cardReader` is called thousands of times per duel (ARCHITECTURE.md section 6). Load the entire
database into an `unordered_map<uint32_t, OCG_CardData>` at boot and serve from memory. A full cdb
is roughly 30 MB resident. There must be zero SQLite access on the hot path.

`setcodes` arrays are owned by us and freed through `cardReaderDone`. Allocate them from a
per-duel arena rather than one heap allocation per card.

---

## A note on the AI

EDOPro's AI, **windbot**, is a separate C# process that speaks the YGOPro network protocol. It is
not a library and cannot be linked into an Android build. The MVP's `heuristic_agent.gd`
(ARCHITECTURE.md Phase 2) is unrelated to it and must be written from scratch. Windbot stays
useful as a reference for decision heuristics and as a Post-MVP option on PC, where spawning a
process is acceptable.
