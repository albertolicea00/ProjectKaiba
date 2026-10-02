# Game Data
This folder is ignored by git to avoid committing copyrighted assets.

To set up the database and artwork:
1. Place your card database inside this `base` folder. 
   - The engine expects the active database to be named exactly `cards.cdb`.
   - **Language Convention:** For localized databases, use the `cards.<lang>.cdb` format (e.g., `cards.es.cdb` for Spanish, `cards.en.cdb` for English). When you want to play in a specific language, simply rename or copy that file to `cards.cdb`.
2. Place all `.lua` card scripts inside `script/`.
3. Place all `.jpg` or `.png` card artworks inside `pics/` according to the resolution folders (see `pics/README.md`).

---

## 🛠️ Community Tools & Resources

Since these assets cannot be bundled with the repository, here is where you can obtain them:

### 1. Card Databases (`.cdb`)
*   **English (Official):** Maintained by the EDOPro team at Project Ignis.
    *   *Repository:* [ProjectIgnis/BabelCDB](https://github.com/ProjectIgnis/BabelCDB)
    *   *Direct link:* `https://raw.githubusercontent.com/ProjectIgnis/BabelCDB/master/cards.cdb`
*   **Spanish (Community):** Translated by the Hispanic community.
    *   *Repository:* [ryoken08/CDBEsp](https://github.com/ryoken08/CDBEsp)
    *   *Direct link:* `https://raw.githubusercontent.com/ryoken08/CDBEsp/master/cards.cdb`

### 2. Card Artwork (`pics/`)
To download the images (which take up gigabytes of space), do not commit them. Instead, use the built-in downloader script provided in this repository which fetches them automatically from the public YGOPRODeck API:
*   *Command:* Run `./tools/artwork-dl-ygoprodeck.sh --sd` (for standard definition) or `--hd` (for high definition).

### 3. Lua Scripts (`script/`)
The engine requires the Lua scripts that define how each card effect resolves. 
*   *Source:* The easiest way to get these is to install a standard **EDOPro** or **YGOPro** client on your PC, zip the `script/` folder, and extract it here into `data/base/script/`.
