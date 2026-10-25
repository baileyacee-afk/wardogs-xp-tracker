# Wardogs XP Tracker

A small always-on-top window that tracks the XP each **role (class)** earns per match toward
its **2,500 XP end-of-match bonus cap**, with alerts at every 500 XP tier.
Each role has its own cap, so once one is maxed you can switch roles and earn another bonus.

It reads the XP and cash popups live as you play, keeps a per-match breakdown of every one
(kills, assists, revives, building...), and works out the end-of-match bonus afterwards.
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

To preview it without the game (a made-up match, start to finish), run:

```
powershell -ExecutionPolicy Bypass -File XpTracker.ps1 -Demo
```

> Wardogs must be in **Borderless** or **Windowed** mode.

## How it tracks your XP

Everything is read from the screen (screenshots + Windows OCR); it never touches the game's
memory or files.

- **Live popups.** About 3 times a second the tracker looks at the XP and cash popups under the
  cash boxes at the top right. It only runs text recognition when they change, counts each popup
  once, and credits XP to the class shown by the popup's symbol. The status line says
  **LIVE: reading popups** while this is working. **Ctrl+Shift+C** turns it on/off.
- **The Wardog Level screen.** Open it whenever you like: its exact totals replace the popup
  estimates, so any popup that was missed or misread is corrected there. The first time, the
  tracker finds it on its own within a few seconds (or press **Ctrl+Shift+U**).

### Each match

1. Just play. Popups are counted from the moment they appear.
2. When the match is over, press **END MATCH** (or **Ctrl+Shift+N**).
3. Open the **Wardog Level** screen once. That read files the match under **Recent Matches**, with
   the **end-of-match bonus (deduced)** for each class: the XP that arrived after the match ended.
   The bonus is a fixed XP per tier, so the tracker also tells your placement (700 per tier = 2nd).

Press END MATCH a second time to file a match straight away without the bonus.

### What you see

- **Wardog level** (all six role levels added up) and levels gained this match.
- **Match Bonus:** how many of the six classes have maxed their bonus, a symbol and mini bar per
  class, a line about the class you're playing, and **cash this match**: how much your banked cash
  (top right) has changed since the match began, so gear you buy counts against it. The game's own
  red counter resets every life. Until the banked cash has been read, it shows the popup total.
- **Roles:** each class's XP this match, tier, and bar toward 2,500.
- **DETAILS** (or click any match under Recent Matches): total XP and cash, the deduced bonus,
  XP and cash grouped by reason with counts, and every popup in order with its time.
  **PICTURE** opens a picture of the tracker right after that match was filed, and **SAVE**
  writes the whole page, picture included, as one file in `Documents\Wardogs XP Tracker` that
  opens in your browser.

At each 500 XP tier you get a sound and a notification naming the class, and the window's border
flashes. At 2,500 that class turns green and shows **MAX**.

### How sure the numbers are

A popup that was missed would show up as extra bonus, so each match carries **confidence notes**
when something could have gone wrong: popup reads that couldn't be understood, time with live
tracking off, XP that couldn't be matched to a class, cash amounts where the `$` was misread, or a
bonus that isn't a clean multiple of the per-tier payout.

## Setting the popup area

The popup area defaults to just under the cash boxes at the top right. If your screen layout is
different, right-click the tray icon > **Set popup area...**, drag a box around where the popups
stack up (tall enough for 6-8 rows), and press **Save** or Enter. *Reset popup area* puts it back.

## Hotkeys

| Keys                | Action                                          |
|---------------------|-------------------------------------------------|
| Ctrl+Shift+N        | End match (press again to file it right away)   |
| Ctrl+Shift+C        | Live popup tracking on / off                    |
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
- **Popups aren't being counted:** check the status line says *LIVE: reading popups*. If it says
  the window covers the popup area, move it (Ctrl+Shift+M). Otherwise set the popup area (tray >
  *Set popup area...*). Popups it couldn't read are saved as pictures in the `unparsed` folder.
- **It runs but the Wardog Level numbers never change:** read the status line at the bottom of
  the window; it says what's wrong (game not detected, black screen capture, OCR language missing,
  panel not found). Open the Wardog Level screen and press **Ctrl+Shift+U**. If it still can't find
  it, send `last-scan.png` and `tracker.log` from the data folder (tray menu > *Open data folder*).
- **An error box appears:** the message and `tracker.log` in the data folder say what went wrong.

## Notes

- Popups show a reason ("KILL 250XP", "CONTROL ZONE PRESENCE +$160"); one row can show cash and
  then XP for the same action, and each is counted. XP rows end with the class symbol; reasons that
  always belong to one class (kills, revives, building, spotting...) are credited by reason.
- The tracker learns what each class symbol looks like on your screen from those reasons
  (`symbols.json` in the data folder), so telling classes apart improves as you play.
- The bonus rules (per class, 500 XP per tier, 5 tiers) come from player testing. They're set at
  the top of `TrackerCore.ps1` if the game changes them.
- Live tracking costs very little: a tiny screenshot about 3 times a second, and text recognition
  (about 0.15 s) only when the popups change.
- Data lives in `%LOCALAPPDATA%\WardogsXpTracker` (tray menu > *Open data folder*):
  `match.json` (current match), `history.json` (past matches), `matches\` (every popup of each
  past match), `symbols.json`, `unparsed\`, `settings.json`, `tracker.log`.

## License

[MIT](LICENSE). A fan-made tool, not affiliated with the makers of Wardogs.
