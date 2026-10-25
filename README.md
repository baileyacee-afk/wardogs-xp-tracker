# Wardogs XP Tracker

A small always-on-top window that tracks the XP each **role (class)** earns per match toward
its **2,500 XP end-of-match bonus cap**, with alerts at every 500 XP tier.
Each role has its own cap, so once one is maxed you can switch roles and earn another bonus.
No install needed: it uses PowerShell and Windows' built-in text recognition.

## Download

Get the latest version from the **[Releases page](https://github.com/baileyacee-afk/wardogs-xp-tracker/releases/latest)**:
under *Assets*, download `wardogs-xp-tracker-vX.Y.zip`. What changed in each version is in
[CHANGELOG.md](CHANGELOG.md). To update, download the new zip and replace the old folder; your
matches and settings are kept.

## Start

1. Right-click the zip > *Properties* > tick **Unblock**, then **extract it** (right-click >
   *Extract All...*). Running it from inside the zip doesn't work.
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

The header shows your **Wardog level** (all six role levels added up) and how many levels you've
gained this match. Below it, **Match Bonus** shows how many of the six roles have maxed their
bonus this match, each role's symbol with a mini bar toward 2,500, and a line about the role
you're playing (whichever last gained XP). Every role also has its own row with its symbol, XP
this match, its tier, and a bar toward 2,500.
At each 500 XP tier you get a sound and a notification naming the role, and the window's border
flashes. At 2,500 that role turns green and shows **MAX**.

Pressing Next Match files the finished match under **Recent Matches**, with each role's result.

## Recording samples

Live tracking of the in-match XP and cash popups is in the works. To build it, the tracker needs
real examples of those popups. This recorder is temporary and will be removed once that's done.

1. Press **Ctrl+Shift+R** (or tray > **Record samples** > *Start recording*) and play normally.
   The status line shows **REC**, the time and the frame count.
2. Open the **Wardog Level** screen now and then, especially after switching class. Those reads
   tell which class each popup symbol belongs to, so you don't need to record one class at a time.
3. Press **Ctrl+Shift+R** again to stop. Record as many sessions as you like; aim to cover all
   six classes overall.
4. On the end-of-match screen, press **Ctrl+Shift+S** to save a full screenshot.

Recordings are saved in tray > Record samples > *Open samples folder*, one folder per session.
Recording uses a little CPU (well under 2% on a typical PC) and about 30 KB per frame; a session
stops itself at 5,000 frames or when the disk has less than 2 GB free.

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
| Ctrl+Shift+R        | Start / stop recording samples                  |
| Ctrl+Shift+S        | Save a full screenshot of the game              |

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
- Misreads are filtered per role: a big drop in a role's XP during a match is always ignored, and
  smaller odd changes count only after 3 identical reads in a row.
- The bonus rules (per role, 500 XP per tier, 5 tiers) come from player testing. They're set at the
  top of `TrackerCore.ps1` if the game changes them.
- Data lives in `%LOCALAPPDATA%\WardogsXpTracker` (tray menu > *Open data folder*):
  `match.json` (current match), `history.json` (past matches), `settings.json`, `tracker.log`.

## License

[MIT](LICENSE). A fan-made tool, not affiliated with the makers of Wardogs.
