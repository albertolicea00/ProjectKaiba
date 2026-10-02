Act as the lead architect of a card video game and as the CTO of a long-term indie project.

Target technologies:
- Godot 4
- C++
- Lua
- EDOPro / ocgcore
- Android (priority)
- PC (future)
- VR (future)

I am developing a modern Yu-Gi-Oh! client inspired by Duel Links and Master Duel, but using EDOPro as the rules engine.

## PROJECT PRINCIPLES

### 1. Local First
Everything must work completely offline.
- All cards available locally.
- All Lua scripts available locally.
- All images available locally.
- Decks are stored locally.
- Replays are stored locally.
- No reliance on external servers.
- No mandatory accounts.
- No mandatory login.

### 2. Total Compatibility
I do not want to reimplement the rules.

The goal is to reuse:
- ocgcore
- existing Lua scripts
- card databases

New cards must work automatically as long as their Lua scripts exist.

### 3. Mobile First
The primary experience will be Android.

Design with these in mind:
- touch input
- mid-range mobile devices
- battery life
- performance

### 4. Future PC and VR
The architecture must allow for:
- mobile client
- PC client
- VR client

Without modifying the game logic. The rules must never depend on the graphical interface.

## DESIRED ARCHITECTURE
I want to clearly separate:

```text
EDOPro Core
↓
Networking Layer
↓
Game Adapter
↓
Visual Layer
↓
Mobile / PC / VR
```

Logic and rules must be completely decoupled from the visual presentation.

## MULTIPLAYER

### INITIAL PHASE
I do not want matchmaking.
I do not want a backend.
I do not want dedicated servers.

I want:
- Offline
- Practice mode
- AI
- LAN multiplayer
- Host via local IP

Examples:
Player A creates a game: `192.168.1.10`
Player B connects: `192.168.1.10`
...and they play.

### FUTURE PHASE
Be able to add:
- matchmaking
- dedicated servers
- friends
- ranking

Without having to redo the architecture.

## HOST AND CLIENT
I am considering two options:

**OPTION A**
- Host Application
- Client Application

**OPTION B**
A single application with:
- HostService
- ClientService

And modes:
- Host Duel
- Join Duel
- Solo Play

Analyze which architecture is better for maintenance, scalability, and development speed.

## 3D MONSTERS
I want support for this starting from the MVP.
But I DO NOT want the rules to depend on the models.

Design something similar to:
```text
CardID
↓
Visual Definition
```

Example:
```text
CardID 89631139
↓
Blue Eyes Model

CardID 123456
↓
2D Card Fallback
```

Every card must work even if a 3D model does not exist.

The system must support:
- 2D art
- 3D model
- summon animation
- attack animation
- future skins

## ASSETS
I want to support optional packages.

Example:
- **Base Game:** cards, scripts, images
- **Monster Pack:** 3D models
- **Anime Pack:** cinematics
- **VR Pack:** VR assets

Design a modular system for this.

## MVP
I want the MVP to include:
- Android
- Full integration with EDOPro
- 3D Field
- Dynamic camera
- Card animations
- Deck editor
- LAN multiplayer
- Offline mode
- Local AI
- 10 iconic 3D monsters
- System prepared for VR

I want a complete plan that includes:
1. General architecture.
2. Folder structure.
3. Modules.
4. Godot scenes.
5. Data flow.
6. Communication with EDOPro.
7. Recommended format for events.
8. Asset system.
9. 3D monster system.
10. Future VR strategy.
11. Technical risks.
12. Phased roadmap.
13. Estimate for a single developer using Claude Opus as the primary assistant.

Do not give me generic answers.
Act as if you were designing the architecture for a real project that must be maintained for the next 5 years.