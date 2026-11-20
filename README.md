# LFG Rivals

A WoW addon that turns Looking-For-Group into a recruiting list: **healers first, then DPS sorted by how little they'd compete with you for loot.** Inspired by LFG Forever's role/class filters.

## Install

Copy the `LFGRivals` folder into `World of Warcraft/<flavor>/Interface/AddOns/`.

The TOC lists interface `11507, 16001`. If the client says "out of date", run `/dump select(4, GetBuildInfo())` in game and put that number in `LFGRivals.toc`.

## Use

- `/rivals` (or `/lfgr`) toggles the window, and so does the **minimap button** (left-click). Right-click the button to search now, drag it to move it around the minimap, and use `/rivals minimap` to hide or show it.
- **Search:** pick a category (Dungeons, Raids…) and an activity (one specific dungeon, or "All"), like Blizzard's LFG browser. Picking one searches right away, and later refreshes reuse that pick.
- **Me:** click the class or spec button to cycle forward, right-click to go back. Your spec is auto-detected from talents until you pick one by hand (`/rivals reset` re-detects it).
- Click a row to whisper, shift-click to invite. The `W` and `+` buttons do the same.
- Hover a row for the full LFG note, the likely spec(s) and the score.
- Toggles: show tanks, solo players only (hides groups already formed), include chat LFG.

## Where players come from

1. **Group Finder listings** (`C_LFGList`), including role, class and spec when the client provides them.
2. **"LFG" messages in chat channels.** Class comes from the sender's GUID, and role/spec come from keywords ("resto", "shadow", "boomkin", "tank"…). Messages containing "LFM", "LF2M" or "need" are ignored, since those are groups recruiting, not players looking. Chat entries expire after 15 minutes.

## Auto-refresh (timer + your keystrokes)

Blizzard only lets a Group Finder search start from a real click or key press, so a plain timer can't search on its own. Instead:

- Every *N* seconds (`Auto:` button, or `/rivals poll 30`, `/rivals poll off`; minimum 15s) a refresh becomes **due**.
- The **next key you press** after that (W, a spell, anything, out of combat) fires the search. The key still does its normal thing.
- Any search, whether yours, the keybind's or Blizzard's own UI, resets the timer.
- There are also keybinds under *Key Bindings → AddOns → LFG Rivals* for "Toggle window" and "Refresh".

Searches use the category/activity picked in the window. If nothing is picked, Refresh falls back to re-running Blizzard's last Group Finder search.

## The "Rival" score (0–100)

How much that player wants the same drops as you. Lower is better.

| Bucket | Weight | How it's computed |
|---|---|---|
| Armor | 45 | Armor-type overlap (e.g. mail hunter vs leather rogue = 0.6) × stat similarity |
| Rings/neck/cloak/trinkets | 25 | Stat similarity |
| Weapons | 20 | Share of *your* weapon types they also use × stat similarity |
| Tier set | 10 | Same class |

Stat families: `agi`, `str`, `tank`, `spell`, `heal`. Similarity: same = 1, agi↔str 0.6, str↔tank 0.5, agi↔tank 0.3, spell↔heal 0.3, everything else 0.

Examples, as a Combat Rogue: Mage 0, Fury Warrior 27, Hunter 67, Cat Druid 78, another Rogue 100.

When the spec isn't known (e.g. a Druid listed as DPS with no note), the score is the average over the possible specs, and the Spec column shows e.g. `Balance/Cat`.

All tuning lives in `Data.lua` (`SPECS`, `STAT_SIM`, `WEIGHTS`, `SPEC_KEYWORDS`). The class list assumes Vanilla-style classes and specs.
