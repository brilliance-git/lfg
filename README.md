# LFG Rivals

A WoW addon that turns Looking-For-Group into a recruiting list: **healers first, then DPS sorted by how little they'd compete with you for loot.** Inspired by LFG Forever's role/class filters.

## Install

Copy the `LFGRivals` folder into `World of Warcraft/<flavor>/Interface/AddOns/`.

The TOC lists interface `11507, 16001`. If the client says "out of date", run `/dump select(4, GetBuildInfo())` in game and put that number in `LFGRivals.toc`.

## Use

- `/rivals` (or `/lfgr`) toggles the window, and so does the **minimap button** (left-click). Right-click the button to search now, drag it to move it around the minimap, and use `/rivals minimap` to hide or show it.
- **Search:** pick a category (Dungeons, Raids…) and an activity, like Blizzard's LFG browser. Dungeons are sorted by level and show their range: green if your level is in it, orange if it's above you, grey if you've outleveled it. "Dungeons for my level" searches every dungeon whose range includes you. Ranges come from ForeverDungeonJournal when it's installed, otherwise from the game's LFG data. The game won't let an addon search from a dropdown pick, so picking makes a refresh due and the search runs on your next key press or Refresh click.
- **Me:** click the class or spec button to cycle forward, right-click to go back. Your spec is auto-detected from talents until you pick one by hand (`/rivals reset` re-detects it).
- **Players tab:** solo listers and chat LFG. Columns are role, name, level, Rival score and note. Click a row to whisper, shift-click to invite. The `W` and `+` buttons do the same. Hover a row for the full note and the likely spec(s).
- **Groups tab:** listed groups with a crown on the leader, the activity and note, role icons for current members (with a class-colored bar), and faded icons for open slots showing the role the group still wants (raids show counts instead). Hover an icon for that member's name, class, level and Rival score. Groups are sorted by their *worst* gear rival for you, lowest first. Click a group to whisper the leader.
- **Build group:** suggests the best healer, tank and DPS for your open slots (lowest Rival first, counting who's already in your party). `Invite next` invites the next suggested player you haven't invited yet, one per click.
- **Zones:** the Zone column shows where each player is (green when they're in or next to the picked dungeon, using ForeverDungeonJournal's locations). Group rows show the leader's zone, and member tooltips show everyone's.
- **People you know:** friends, guildmates and favorites are listed first in their section, tagged `friend`, `guild` or `fav`. People you've grouped with get a `met` tag (kept 60 days). Right-click any player or group for Whisper, Invite, Favorite, Avoid and a private note. Avoided players and groups with an avoided member are greyed at the end, or hidden if you choose that in Options.
- **Needs my role** (Groups tab): open slots for your role pulse, groups with one get a green edge, and with the checkbox on, groups without one are greyed at the end.
- **Join** (Groups tab): sends your group message to the leader right away and accepts that leader's invite automatically for the next 5 minutes. `W` still only types the message so you can edit it first.
- **Sorting:** click the Name, Level, Rival or Zone header to sort by it, and click again to flip the order. Healers, tanks and DPS keep their own sections.
- **Greyed, not hidden:** players outside the level range, asking for another dungeon, or marked avoid stay listed, greyed at the end of their section, with the reason in their tooltip. Options can hide them instead.
- **Clear** (or `/rivals clear`) empties the player and group lists and closes the group suggestion. The lists stay empty until your next search comes back. `Close` on the suggestion header closes just the suggestion.
- **Contacted players:** anyone you whisper or invite gets dimmed with a `w` or `inv` tag for 2 hours, so you don't message them twice.
- **Resize** the window from the bottom-right corner. The size is saved.
- Toggles: show tanks (Players tab), include chat LFG.
- `/rivals debug` prints what the Group Finder API returned. Paste it into an issue if search results don't show up.

## Options (`Options` button or `/rivals options`)

- **Alerts:** when a new healer, or a DPS at or under your alert score (default 30), shows up while the window is closed, you get a chat line, a sound and a pulsing minimap button. `/rivals alerts` toggles them.
- **Level filter:** with one dungeon picked, only players inside that dungeon's level range are shown (on by default). Otherwise you can show only players within *N* levels of you (`/rivals level 5`, `0` = off). Players with no known level (chat) are always shown. Chat LFG that names a different dungeon ("LFG rfk heal") is hidden while you've picked a dungeon.
- **Hide DPS above** a Rival score (`/rivals max 60`).
- **Whisper messages:** text typed into chat when you click `W`, one for players and one for group leaders. `{name}`, `{dungeon}`, `{role}` and `{me}` get filled in. You still press Enter to send.

## Where players come from

1. **Group Finder listings** (`C_LFGList`), including role, class and spec when the client provides them.
2. **"LFG" messages in chat channels.** Class comes from the sender's GUID, and role/spec come from keywords ("resto", "shadow", "boomkin", "tank"…). Messages containing "LFM", "LF2M" or "need" are ignored, since those are groups recruiting, not players looking. Chat entries expire after 15 minutes.

## Auto-refresh (timer + your keystrokes)

Blizzard only lets a Group Finder search start from a real click or key press, so a plain timer can't search on its own. Instead:

- Every *N* seconds (`Auto:` button cycles off/5/10/15/30s, or `/rivals poll 10`, `/rivals poll off`) a refresh becomes **due**.
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

### Dungeon loot

When you've picked one dungeon and the addon knows at least 4 of its drops, the score uses that dungeon's loot instead of the table above. Each drop counts by how much you'd want it (armor type or weapon type, times how well its stats fit your spec). A player's score is the share of *your* wanted drops that they'd also want. The line at the bottom of the window says which model is in use.

Loot comes from up to three places:

1. **The ForeverDungeonJournal addon**, if you have it installed. Its full boss loot lists are read live in game (nothing is copied), so custom dungeons like Krol'dok Stronghold work from the first run.
2. **The game's own Dungeon Journal**, if the client has one (`EJ_*` functions).
3. **Drops you've seen.** Every green-or-better equippable item you see drop in a dungeon (in your loot window or in loot chat) is saved per dungeon. Custom dungeons fill in as you run them.

`/rivals loot` shows what's known for the picked dungeon.

## Troubleshooting

- `/rivals log` opens a copyable log (Ctrl+A, Ctrl+C) of every search attempt, blocked action, Group Finder event and scan. `/rivals verbose` echoes it to chat as it happens.
- The log also records every `C_LFGList.Search` call, including Blizzard's own, so running one search in Blizzard's LFG window shows the arguments this client uses.
- The log is saved in `WTF/Account/<account>/SavedVariables/LFGRivals.lua` (`log` = this session, `logPrev` = last session).
- If the game blocks the addon's search ("Interface action failed because of an AddOn"), LFG Rivals stops trying for the rest of the session. Search in Blizzard's LFG window instead and the results still fill this window.

## Searching on WoW Forever

Confirmed on 1.60.1 (build 71037): addons may call `C_LFGList.Search(categoryID, 0, 0, nil, nil, nil, activityIDs)` **once per click or key press**. A second call in the same key press is blocked ("Interface action failed because of an AddOn"). LFG Rivals makes exactly one call.

If the client ever does block a search, LFG Rivals remembers it for that client build and stops trying, so the popup doesn't repeat. Search in Blizzard's LFG window in the meantime (results still show here), or type `/rivals unblock` to retry.
