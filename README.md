# 🃏 Project Kaiba

> **It's Time to D-D-D-D-D-D-Duel!**

<div>
  <img src="https://img.shields.io/badge/Unofficial-Project-blueviolet" alt="Unofficial Project">
  <img src="https://img.shields.io/badge/Fanmade-Project-orange" alt="Fanmade">
  <img src="https://img.shields.io/badge/Purpose-Learning-green" alt="Purpose">
  <img src="https://img.shields.io/badge/Distribution-Prohibited-red" alt="Not for Distribution">
</div>

**Project Kaiba** is a personal, fan-made mobile Yu-Gi-Oh! project created for my own use and to play duels with friends.

*This project is not intended for public distribution, commercial use, or release.*
<!-- Not affiliated with Konami. Not for distribution or monetization. -->
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

## 🔒 Personal Project

Project Kaiba is **not a commercial product** and is **not intended to be distributed publicly**.

It is a personal development project created for experimentation, learning, and playing Yu-Gi-Oh! duels with friends.

---

## ⚖️ Legal Disclaimer

Project Kaiba is an unofficial fan-made project and is **not affiliated with, sponsored by, or endorsed by Konami**.

> [!WARNING]
> **Yu-Gi-Oh!** and all rights to the original game — including characters, story, images, audio, cards, artwork, trademarks, and assets — belong to Konami and their respective owners.
> 
> This repository is strictly for personal use, learning, and playing with friends. It is not intended for public distribution. Do not publish or distribute this repository, as it may contain copyrighted assets.
> 
> For more details, please read the full [Disclaimer & Copyright Notice](disclaimer.md).

---

<p align="center">
  <i>For personal use and playing with friends.</i>
</p>
