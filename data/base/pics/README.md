# Artwork (Pics) Directory

This directory contains all the card images used by the game.
Due to copyright reasons (see `DISCLAIMER.md`), these files are NOT included in the repository and are ignored by version control.

## Quality Tiers & Folder Structure

To support the "Mobile First" architecture and allow scalable graphics across all devices, the visual layer (`CardView`) expects images to be organized by resolution. Place your downloaded `.jpg` or `.png` files in the corresponding folders. 

The aspect ratio of a standard card is roughly **1:1.45** (59mm × 86mm). Below are the target vertical resolutions for each tier:

| Tier | Folder | Target Height | Example Size (W×H) | Primary Use Case |
| :--- | :--- | :--- | :--- | :--- |
| **Low Def** | `ld/` | ~360p | 248 × 360 | Minimum RAM usage. For low-end mobile devices and 3D board rendering. |
| **Standard** | `sd/` | ~480p | 331 × 480 | Default balanced quality for normal mobile gameplay. |
| **High Def** | `hd/` | ~720p | 496 × 720 | High quality for mid-range devices or zoomed-in views. |
| **Full HD** | `fhd/` | ~1080p | 744 × 1080 | For high-end mobile devices and 1080p PC displays. |
| **Quad HD** | `qhd/` | ~1440p | 993 × 1440 | For 1440p PC displays. |
| **Ultra HD** | `uhd/` | ~2160p | 1489 × 2160 | Maximum quality for extreme close-ups, 4K monitors, or VR clients. |

## Naming Convention

All images must be named using their unique 8-digit card ID (passcode) provided by the `ocgcore` engine.

*   **Format:** `[card_id].jpg` (or `.png`)
*   **Example:** `89631139.jpg` (Blue-Eyes White Dragon)

*Note: You can use community tools to download image sets in various resolutions and copy them into these respective directories.*
