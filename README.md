# Stats - FFXI Windower Addon

**Author:** Garyfromwork
**Version:** 1.0.0
**Commands:** `//stats` or `//st`

## Overview

Stats is a comprehensive combat statistics tracking addon for Final Fantasy XI (Windower). It monitors your combat performance in real-time, tracking accuracy, damage, and spell effectiveness on a per-fight basis.

Unlike other parsing tools that aggregate all combat data together, Stats keeps each fight separate, allowing you to analyze your performance against specific enemies and compare results across multiple encounters.

## Features

- **Per-Fight Tracking** - Statistics are tracked separately for each enemy you engage
- **Melee Statistics** - Accuracy, critical hit rate, damage min/max/average
- **Ranged Statistics** - Accuracy, critical hit rate, damage tracking
- **Weapon Skill Analysis** - Per-WS accuracy, damage min/max/average
- **Magic Accuracy** - Track how often enfeebling spells land vs resist
- **Spell Damage** - Min/max/average damage for nukes
- **Job Ability Tracking** - Damage from abilities like Jump, Chi Blast, etc.
- **Fight History** - Review past fights and compare performance
- **Enemy Aggregation** - Combine stats across all fights with the same enemy type
- **Real-Time Overlay** - Draggable on-screen display showing current fight stats
- **Export Function** - Save your stats to a text file for later analysis

## Installation

1. Download the Stats addon
2. Extract to your `Windower/addons/Stats/` folder
3. In-game, load with `//lua load stats`
4. (Optional) Add to your `Windower/scripts/init.txt` for auto-loading

### File Structure

```
Windower/addons/Stats/
├── Stats.lua        # Main addon file
├── tracker.lua      # Statistics tracking module
├── display.lua      # Display and overlay module
└── data/            # Export directory (created automatically)
```

## Commands

| Command | Description |
|---------|-------------|
| `//stats` | Show current fight summary |
| `//stats report` | Show detailed fight report |
| `//stats reset` | Reset current fight and save to history |
| `//stats history` | Show recent fight history |
| `//stats enemy <name>` | Show aggregated stats for an enemy type |
| `//stats spell <name>` | Show accuracy/damage for a specific spell |
| `//stats ws <name>` | Show stats for a specific weapon skill |
| `//stats session` | Show session-wide totals |
| `//stats export [filename]` | Export stats to a text file |
| `//stats parse [on/off]` | Toggle live damage output to chat |
| `//stats overlay [on/off]` | Toggle on-screen overlay |
| `//stats clear` | Clear all history and session data |
| `//stats help` | Display command help |

## Usage Examples

### Basic Usage

Simply engage an enemy and Stats will automatically begin tracking. After the fight:

```
//stats
```

Output:
```
=== Greater Colibri ===
Melee Accuracy: 92% (184/200)
Melee Damage: 12450 (Min: 45 / Max: 187)
Weapon Skills Used: 3 types
Spells Cast: 2 types
```

### Detailed Report

For comprehensive fight analysis:

```
//stats report
```

Output:
```
========== Detailed Report: Greater Colibri ==========
Duration: 2:34
Result: Victory
--- Melee ---
  Accuracy: 92% (184 hits / 200 swings)
  Crit Rate: 12% (22 crits)
  Damage: 12450 total (Avg: 67)
  Normal: Min 45 / Max 112
  Critical: Min 98 / Max 187
--- Weapon Skills ---
  Savage Blade:
    Uses: 5 (Hit: 100%) | Damage: 24500
    Min: 4200 / Max: 5800 / Avg: 4900
  Chant du Cygne:
    Uses: 3 (Hit: 100%) | Damage: 31200
    Min: 9800 / Max: 11400 / Avg: 10400
```

### Tracking Magic Accuracy

To check how well your enfeebling magic is landing:

```
//stats spell "Sleep II"
```

Output:
```
=== Spell Stats: Sleep II ===
Sleep II:
  Casts: 15 | Landed: 12 (80%) | Resisted: 3
```

This is particularly useful for determining if you need more Magic Accuracy gear against specific enemies.

### Enemy Type Analysis

To see your aggregate performance against a type of enemy:

```
//stats enemy Colibri
```

This combines all fights with enemies containing "Colibri" in their name, showing your overall accuracy and damage patterns.

### Weapon Skill Comparison

To analyze a specific weapon skill:

```
//stats ws "Savage Blade"
```

Output:
```
=== Weapon Skill Stats: Savage Blade ===
Savage Blade:
  Uses: 45 | Hits: 43 (95%)
  Damage: 198000 total
  Min: 3200 / Max: 6800 / Avg: 4400
```

## Understanding the Statistics

### Melee Accuracy

- **Swings**: Total auto-attack attempts
- **Hits**: Successful attacks that dealt damage
- **Accuracy %**: (Hits / Swings) * 100
- **Crit Rate**: Percentage of hits that were critical

### Weapon Skills

- **Uses**: Number of times you used the WS
- **Hits**: WSs that dealt damage (vs misses)
- **Min/Max/Avg**: Damage range and average

### Magic Accuracy

- **Casts**: Total spell cast attempts
- **Landed**: Spells that took effect
- **Resisted**: Full resists (no effect)
- **Accuracy %**: (Landed / Casts) * 100

Note: Partial resists (reduced damage/duration) are counted as "Landed" but also flagged as "Resisted" for tracking.

## On-Screen Overlay

The overlay provides real-time statistics during combat. It can be:

- **Toggled**: `//stats overlay on/off`
- **Dragged**: Click and drag to reposition
- **Customized**: Position saves between sessions

The overlay shows:
- Enemy name
- Melee accuracy and damage range
- Weapon skill summary
- Spell accuracy summary

## Configuration

Settings are automatically saved and include:

| Setting | Default | Description |
|---------|---------|-------------|
| `parse_to_chat` | false | Show damage numbers in chat log |
| `overlay_enabled` | true | Show on-screen overlay |
| `auto_reset_on_new_fight` | true | Auto-reset when engaging new enemy |
| `history_limit` | 50 | Maximum fights to keep in history |

## Tips

1. **Use `//stats enemy` for farming** - Track your accuracy against specific mobs to optimize gear sets

2. **Compare WS performance** - Use `//stats ws` to see which weapon skill performs best

3. **Test magic accuracy** - Cast debuffs and check `//stats spell` to see if you need more macc

4. **Export before logging** - Use `//stats export` to save your session data

5. **Reset between tests** - Use `//stats reset` when changing gear to get clean comparisons

## Troubleshooting

**Stats not tracking?**
- Ensure you are the one dealing damage (party member damage is not tracked by default)
- Check that the addon is loaded: `//lua list`

**Overlay not showing?**
- Toggle with: `//stats overlay on`
- Check if it's positioned off-screen and use `//stats clear` to reset

**Numbers seem wrong?**
- Multi-hit weapon skills show total damage, not per-hit
- Critical hits are tracked separately from normal hits for min/max

## Changelog

### Version 1.0.0
- Initial release
- Melee, ranged, weapon skill, spell, and ability tracking
- Per-fight and session statistics
- On-screen overlay
- Fight history and enemy aggregation
- Export functionality
