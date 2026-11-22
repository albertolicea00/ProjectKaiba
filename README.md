# 🃏 Project Kaiba

> **It's Time to D-D-D-D-D-D-Duel!**

<div>
  <img src="https://img.shields.io/badge/Unofficial-Fan%20Client-blueviolet" alt="Unofficial Fan Client">
  <img src="https://img.shields.io/badge/Non--Commercial-Educational-green" alt="Non-Commercial Educational">
  <img src="https://img.shields.io/badge/Zero%20Game%20Assets-Included-lightgrey" alt="Zero Assets Included">
</div>

**Project Kaiba** is an unofficial, open fan-made Yu-Gi-Oh! game client built with Godot 4 and `ocgcore`, created for educational study, experimentation, and offline duels with friends.

*This repository contains client code only. No copyrighted card databases, card artwork, or proprietary assets are distributed or hosted in this repository.*
<!-- Not affiliated with Konami. Non-commercial and unmonetized. -->
---

## 🎯 Goals

- 🏠 **Local First** — Everything works completely offline (cards, images, scripts, decks, replays). No mandatory login or servers.
- ⚙️ **Total Compatibility** — Reusing EDOPro/YGOPro and existing Lua scripts to avoid reimplementing Yu-Gi-Oh! rules.
- 📱 **Mobile First** — The core experience is designed for Android, focusing on touch controls, mid-range mobile performance, and battery efficiency.
- 👥 **LAN & Direct Play** — Host and join private duels with friends locally or via direct IP connection, without relying on central matchmaking servers.
- 🏗️ **Decoupled Architecture** — Clean separation between the rule engine (EDOPro/YGOPro Core), Networking Layer, Game Adapter, and Visual Layer.
- 🐉 **3D Monsters & Assets** — Modular system for 3D monster models without tying game logic to visuals.
- 🖥️ **Future Platforms** — Architecture ready for PC and VR expansion.

---

## 🗺️ Roadmap

Where the project stands and what is next: **[ROADMAP.md](ROADMAP.md)**.

- [x] **Core Rules Engine** — C++ `ocgcore` integration via GDExtension, headless duel execution
- [x] **Deck Loading** — External `.ydk` deck format parsing and in-game deck picker
- [~] **Touch UI & Solo Play** — Mobile-first 3D field, dynamic camera, animations, audio, and solo duels
- [ ] **Network Layer (L2)** — Decoupled host/client services and loopback transport
- [ ] **LAN Multiplayer** — Local TCP duels and UDP broadcast discovery
- [ ] **AI Opponent** — Local heuristic agent
- [ ] **3D Monster Avatars** — Optional 3D asset packs with 2D fallbacks
- [ ] **Replays** — Deterministic duel recording and playback (`KBRP`)
- [ ] **Future Platforms** — PC client and VR support (Post-MVP)

---

## 📖 Documentation

Full technical plan, architecture rationale, and project guides:

| Document | Description |
|---|---|
| **[ROADMAP.md](ROADMAP.md)** | Current project status, next actions, and settled decisions |
| **[AGENTS.md](AGENTS.md)** | Operating rules, invariants, and contribution standards |
| **[docs/ARCHITECTURE.md](docs/ARCHITECTURE.md)** | Full technical architecture, design rationale, and layer map |
| **[docs/BUILD.md](docs/BUILD.md)** | Toolchain setup, compilation, and Android/host builds |
| **[docs/DATA.md](docs/DATA.md)** | Card database, scripts, and asset management (none versioned) |
| **[docs/DUEL.md](docs/DUEL.md)** | Duel loop, selection handling, and engine message coverage |
| **[docs/UI.md](docs/UI.md)** | Screens, navigation contract, menu dress, and input verbs |
| **[docs/TESTING.md](docs/TESTING.md)** | Test suites, the ten quality gates, and verification scripts |

---

## 📚 References

Project Kaiba is inspired by and makes use of ideas and concepts from existing open-source Yu-Gi-Oh! projects:

- [YGOPro Core — edo9300](https://github.com/edo9300/ygopro)
- [YGOPro Core — Fluorohydride](https://github.com/Fluorohydride/ygopro-core)
- [EDOPro — edo9300](https://github.com/edo9300/edopro)
- [YGOPro — Fluorohydride](https://github.com/Fluorohydride/ygopro-core)

These projects are listed as references for their existing duel engine, rules implementation, and related technical work.

---

## 🔒 Non-Commercial & Educational Scope

Project Kaiba is **strictly non-commercial and unmonetized**.

It is a client architecture study and fan project created for experimentation, learning Godot 4 / GDExtension mechanics, and playing duels with friends locally or over LAN.

---

## ⚖️ Legal Disclaimer

Project Kaiba is an unofficial fan-made project and is **not affiliated with, sponsored by, or endorsed by Konami**.

> [!WARNING]
> **Yu-Gi-Oh!** and all rights to the original game — including characters, story, images, audio, cards, artwork, trademarks, and assets — belong to Konami and their respective owners.
> 
> This repository provides client code only and distributes **zero copyrighted game data, cards, or artwork**. All required card databases, card arts, and scripts must be supplied locally by the user.
> 
> For full details, please read the [Disclaimer & Copyright Notice](DISCLAIMER.md).

---

<p align="center">
  <i>Fan-made educational client. Support the official Yu-Gi-Oh! releases.</i>
</p>
