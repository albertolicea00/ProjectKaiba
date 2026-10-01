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

Full technical plan, phase breakdown and estimates: **[docs/ARCHITECTURE.md](docs/ARCHITECTURE.md)**.

### MVP — Core System & Rules
- [ ] Phase 0 — Toolchain: GDExtension wrapper around `ocgcore`, Android + host builds
- [ ] Phase 0 — Card database and Lua script pipeline (`base.pck`)
- [ ] Phase 1 — Headless duel: full duel to `MSG_WIN` with no UI
- [ ] Local Offline Mode support
- [ ] Deck Editor with `.ydk` import/export
- [ ] Preconstructed Anime Decks (Classic DM / Kaiba era movies)
- [ ] Basic Local AI (strictly for development and testing purposes)

### MVP — Visuals & Gameplay
- [ ] 3D Field implementation (real-world scale)
- [ ] Dynamic Camera system
- [ ] Card animations (Summon/Attack)
- [ ] 3D Monsters via optional asset packs, always with 2D fallback
- [ ] VR-ready foundations (abstractions only — no VR build in the MVP)

### MVP — Multiplayer (LAN only)
- [ ] LAN Multiplayer support over TCP
- [ ] Direct IP Host & Join system
- [ ] LAN host discovery via UDP broadcast
- [ ] Replay recording and playback

---

### Post-MVP (not scheduled)
- [ ] PC client (mouse/keyboard camera rig)
- [ ] Compatibility with existing EDOPro, YGOPro and YDXPro servers *(isolated CTOS/STOC adapter — expect breakage on every EDOPro release)*
- [ ] EDOPro `.yrp` / `.yrpX` replay import/export
- [ ] Remote AI integration for complex decision making
- [ ] Downloadable asset packs
- [ ] VR client

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
