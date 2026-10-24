# Changelog

Versions match the [GitHub releases](https://github.com/baileyacee-afk/wardogs-xp-tracker/releases).
The version you're running shows when you hover over the tray icon.

## v1.0

First release.

- Always-on-top window that tracks each role's XP per match toward its 2,500 XP end-of-match
  bonus cap, with a bar and tier (one per 500 XP, up to 5) for every role.
- The role you're playing is featured at the top; each tier plays a sound and shows a
  notification, and a maxed role turns green.
- Reads your XP from the in-game Wardog Level screen with Windows' built-in text recognition,
  every 2 seconds while it's open. Never touches the game's memory or files.
- Finds the Wardog Level screen on its own, on any monitor and resolution, and keeps reading it
  even when a role name or number is misread.
- Misread protection per role: a big drop in a role's XP is ignored, and other odd changes count
  only after 3 identical reads.
- Next Match (Ctrl+Shift+N) files the match into Recent Matches with each role's result.
- Opens in the top-right of your screen (second monitor if you have one); drag it anywhere or
  press Ctrl+Shift+M to jump between corners.
- Launcher checks the zip was extracted; the status line explains anything that stops it reading.
