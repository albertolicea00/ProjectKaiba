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
*   **Japanese / OCG (Community):**
    *   Since the Asian YGOPro community does not maintain a permanent central GitHub repository for databases, there is no direct download link. To obtain the Japanese database (`cards.ja.cdb`), search the web for **"YGOPro ADS 日本語"** (the Japanese equivalent of EDOPro), download the client, and extract the `cards.cdb` file from its installation folder.

### 2. Card Artwork (`pics/`)
To download the images (which take up gigabytes of space), do not commit them. Instead, use the built-in downloader script provided in this repository which fetches them automatically from the public YGOPRODeck API:
*   *Command:* Run `./tools/artwork-dl-ygoprodeck.sh --sd` (for standard definition) or `--hd` (for high definition).

### 3. Lua Scripts (`script/`)
The engine requires the Lua scripts that define how each card effect resolves.
*   *Command:* Run `make data-scripts` from the repository root. It clones [ProjectIgnis/CardScripts](https://github.com/ProjectIgnis/CardScripts) into `data/base/script/` as a git working copy (~115 MB), so refreshing later is just `git -C data/base/script pull`.
*   **Use the ProjectIgnis collection, not Fluorohydride's.** We pin the EDOPro core (OCG v11); the Fluorohydride scripts target the older core and use a different Lua API, so they fail at load.

The clone is searched in this order:

| Folder | Contents |
| :--- | :--- |
| `script/` | shared library: `constant.lua`, `utility.lua`, `proc_*.lua`, `chain.lua` |
| `script/official/` | ~13,500 card scripts |
| `script/unofficial/` | ~5,500 anime and custom cards |
| `script/pre-release/` | ~130 upcoming cards |

> [!NOTE]
> The two library scripts are loaded by the host, not requested by the engine. ocgcore only ever
> asks for `c<code>.lua`. If they are missing, every card logs `attempt to call an error function`
> and no effect fires — which looks like missing card scripts but is not. See `docs/DATA.md`.
