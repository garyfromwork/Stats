# Stats for Windower 4

Stats tracks each active enemy separately and archives completed fights in `data/combat_history.db`. It supports several characters using the same addon folder. The overlay shows the current character and that character's cumulative player damage for the session.

## Installation

Place this folder in `Windower4/addons/stats` and load it in game with `//lua load stats`. The addon requires Windower's `texts`, `config`, `resources`, and `sqlite3` libraries.

## Overlay

Drag the overlay with the left mouse button. Its position saves when you release the button and loads again the next time you use the addon. Position is saved in `data/settings.xml` for the current character.

Use `//stats overlay on` or `//stats overlay off` to control visibility. If the overlay is off screen, use `//stats position reset` to return it to `(100, 100)`.

When several enemies are active, the overlay shows one enemy and the active enemy count. Your first target in an attack becomes the overlay focus; incoming attacks from other enemies still update their own fights. Use `//stats active` to see enemy IDs and `//stats focus <enemy ID>` to choose one for the overlay. Each enemy is saved separately when defeated. Inactive fights are saved after two minutes without an action, and all active fights are saved on reset, zone change, or unload.

The session damage line remains visible after disengaging or zoning. Damage to the displayed enemy is labeled separately, so an enemy you have only defended against can show zero without resetting the session total. A login or character change starts a new character session and saves any fights from the previous one under that character's name.

## Commands

| Command | Action |
| --- | --- |
| `//stats` or `//stats show` | Show the current fight summary in chat |
| `//stats report` | Show the current fight details in chat |
| `//stats reset` | Save and clear all active fights |
| `//stats active` | List all active enemies and their IDs |
| `//stats focus <enemy ID>` | Show an active enemy on the overlay |
| `//stats review` | List this character's 10 most recent saved fights |
| `//stats review all` | List the 10 most recent fights for all characters |
| `//stats review <name>` | Search saved fights by enemy or player name |
| `//stats review <id>` | Show the saved fight with that ID |
| `//stats overlay [on|off]` | Set or toggle overlay visibility |
| `//stats position reset` | Return the overlay to its default position |
| `//stats export [character]` | Export saved fights for this character, or the named character |
| `//stats autolog [on|off]` | Show or change automatic CSV logging (on by default) |
| `//stats purge confirm` | Permanently delete saved fight history |
| `//stats help` | Show command help |

`//st` is an alias for `//stats`. `//stats purge` displays a warning and requires the explicit `confirm` argument.

## Data and settings

The addon tracks player melee, ranged attacks, weapon skills, spells, and damage dealing job abilities. It also tracks melee damage from trusts, pets, and other party members when enabled, plus incoming attacks on the party. Saved fight reports contain offensive totals and defensive counts. Session totals remain in memory until the addon is unloaded.

Combat data comes from Windower's `action` and `action message` events, not from parsing chat text. In-game chat filters do not change what Stats records. The legacy `parse_to_chat` setting only controls the addon's new-fight announcement.

The settings file controls `overlay_enabled`, `overlay_position`, `parse_to_chat`, `track_party`, `track_trusts`, `track_pets`, and `auto_log`. The fight database and settings file are local to this addon folder.

On each saved fight, automatic logging appends action rows to `data/<Character>_stats_log.csv`. `//stats export` exports the current character; `//stats export Alice` exports Alice's saved fights even while logged in as another character. The command creates `data/<Character>_stats_YYYYMMDD_HHMMSS.csv` using the character name stored in the database. Both files include `character` and `player_total_damage` columns. Fights still in progress are included after they are saved by a victory, timeout, reset, zone change, logout, or unload. CSV rows describe each action category and defensive source, so a fight may occupy several rows.

SQLite uses write-ahead logging and waits briefly for concurrent writes so multiple game instances can share the fight database. Each fight's database rows are saved together.

If a fight cannot be saved before unload, Stats writes its details to `data/<Character>_stats_recovery.txt`.

Older databases are upgraded on load to add defensive tracking columns. Existing fight and damage rows are retained.
