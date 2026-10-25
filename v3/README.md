# Wardogs XP Tracker v3 (Windows app)

The same tracker as the PowerShell version (v2.x), rebuilt as a normal Windows program: one
`WardogsXpTracker.exe`, no console window, no `.cmd`. It reads the same data folder, so your
matches, pictures, settings and learned class symbols carry over.

## What's different from v2.x

- **One .exe.** Self-contained (about 78 MB): nothing else to install. Unsigned, so the first
  time a downloaded copy runs, Windows may say *Windows protected your PC*: click **More info**,
  then **Run anyway**.
- **Tray icon, always there.** Double-click it to show the window. Right-click: Show/Hide window,
  **Pause/Resume tracking** (nothing is read from the screen while paused), End match, Match
  details, Live popup tracking, popup area, click-through, opacity, Move window,
  **Start with Windows**, Shortcuts, Open data folder, **Exit**.
- **Taskbar button** while the window is open. Minimizing it (or the `-` button, or Ctrl+Shift+O)
  hides it to the tray.
- **One copy at a time.** Starting it again brings the running one to the front.
- **Exit really exits:** the capture thread stops and nothing is left running.
  `WardogsXpTracker.exe --exit` does the same from a script.
- **Lighter.** Screen reading runs on its own background thread, and text recognition takes about
  a quarter of the time it did in PowerShell.
- The first run keeps a copy of your data in `%LOCALAPPDATA%\WardogsXpTracker\backup-before-exe`.

Everything else (live popups, per-match breakdown, the deduced end-of-match bonus, the Wardog
Level reads, SAVE/PICTURE in match details, hotkeys) works as in v2.5; see the main
[README](../README.md).

## Install

Put `WardogsXpTracker.exe` somewhere permanent (for example
`%LOCALAPPDATA%\Programs\Wardogs XP Tracker`) and run it. It adds itself to the Start menu.
Quit the PowerShell version first: the two can't run at the same time.

## Build

Needs the .NET 10 SDK.

```
cd v3/src
dotnet publish -c Release -o ../publish
```

`v3/tools/Replay` replays recorded popup frames through the same reader code and compares the
XP it counts with Wardog Level reads (`dotnet run -c Release` there), and `Replay --data <folder>`
checks that a data folder loads.

## Layout

- `src/Core` - match bookkeeping, the bonus deduction, data files (no UI)
- `src/Reading` - screen capture, OCR, the Wardog Level panel, the popup reader
- `src/App` - the window, match details, popup-area picker, tray, hotkeys, shortcuts, the worker thread
