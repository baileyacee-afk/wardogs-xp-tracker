# Wardogs XP Tracker

A small always-on-top window that tracks the XP each **role (class)** earns per match toward
its **2,500 XP end-of-match bonus cap**, with alerts at every 500 XP tier.
Each role has its own cap, so once one is maxed you can switch roles and earn another bonus.
No install needed: it uses PowerShell and Windows' built-in text recognition.

## Start

1. **Extract the zip first** (right-click it > *Extract All...*). Running it from inside the zip
   doesn't work.
2. Double-click **Start XP Tracker.cmd** in the extracted folder.

It opens in the top-right corner of your screen (your second monitor, if you have one). Drag it
anywhere, or press **Ctrl+Shift+M** to jump between corners; it remembers where you put it.
Right-click the tray icon for options, including *Move window*.

To preview it without the game, run:

```
powershell -ExecutionPolicy Bypass -File XpTracker.ps1 -Demo
```

> Wardogs must be in **Borderless** or **Windowed** mode.

## How it tracks your XP

The game only shows XP on the **Wardog Level** screen, so the tracker reads that screen whenever
it's open (screenshots + Windows OCR; it never touches the game's memory or files).

1. **First time:** open the Wardog Level screen. The tracker finds it on its own within a few
   seconds (or press **Ctrl+Shift+U**) and remembers where it is.
2. **Each match:** press **Ctrl+Shift+N** (or *Next Match*) at the start, then open the Wardog
   Level screen once so it saves your starting XP.
3. **During the match:** open the Wardog Level screen whenever you like. The tracker reads it every
   2 seconds while it's open and updates your match XP.

The top of the window features the role you're playing (whichever last gained XP); every role
also has its own row with XP this match, its tier, and a bar toward 2,500.
At each 500 XP tier you get a sound and a notification naming the role, and the window's border
flashes. At 2,500 that role turns green and shows **MAX**.

Pressing Next Match files the finished match under **Recent Matches**, with each role's result.

## Hotkeys

| Keys                | Action                                          |
|---------------------|-------------------------------------------------|
| Ctrl+Shift+N        | Next match (saves the current one to history)   |
| Ctrl+Shift+U        | Find the Wardog Level screen now                |
| Ctrl+Shift+O        | Show / hide                                     |
| Ctrl+Shift+L        | Click-through (mouse passes through to the game)|
| Ctrl+Shift+PageUp   | More opaque                                     |
| Ctrl+Shift+PageDown | More transparent                                |
| Ctrl+Shift+M        | Move to the next corner of the screen           |

## Troubleshooting

- **Nothing happens when I double-click it:** extract the zip first, then run it from the
  extracted folder.
- **"Windows protected your PC":** click *More info* > *Run anyway*. Or, before extracting,
  right-click the zip > *Properties* > tick *Unblock*.
- **I can't see the window:** press **Ctrl+Shift+O** (show/hide) or **Ctrl+Shift+M** (move to a
  corner), or use the tray icon's *Move window* menu. If the game is in exclusive fullscreen,
  switch it to Borderless.
- **It runs but the numbers never change:** read the status line at the bottom of the window; it
  says what's wrong (game not detected, black screen capture, OCR language missing, panel not
  found). Open the Wardog Level screen and press **Ctrl+Shift+U**. If it still can't find it, send
  `last-scan.png` and `tracker.log` from the data folder (tray menu > *Open data folder*).
- **An error box appears:** the message and `tracker.log` in the data folder say what went wrong.

## Notes

- A role's match XP = its XP now minus its XP when the match started.
- A read that looks wrong (XP going down, or a huge jump) is ignored unless the next read agrees.
- The bonus rules (per role, 500 XP per tier, 5 tiers) come from player testing. They're set at the
  top of `TrackerCore.ps1` if the game changes them.
- Data lives in `%LOCALAPPDATA%\WardogsXpTracker` (tray menu > *Open data folder*):
  `match.json` (current match), `history.json` (past matches), `settings.json`, `tracker.log`.
