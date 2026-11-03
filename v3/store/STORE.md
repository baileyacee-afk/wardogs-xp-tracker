# Publishing on the Microsoft Store

## One-time setup (in Partner Center, https://partner.microsoft.com/dashboard)

1. Sign up as an individual developer.
2. Apps and games > New product > **MSIX or PWA app**, and reserve the name.
3. Your app > Product management > **Product identity**: copy `Package/Identity/Name`,
   `Package/Identity/Publisher` and `Package/Properties/PublisherDisplayName` into `identity.json`.

## Each release

1. `powershell -File v3\store\build-msix.ps1` builds `v3\store\out\WardogsXpTracker-<version>.msix`.
   The version comes from `src\WardogsXpTracker.csproj` and must go up for every upload.
2. Partner Center > your app > Start update (first time: Start submission) > Packages: upload the .msix.
   The Store signs it, so it needs no certificate.

## How the Store version differs (Program.Packaged)

- It's called **Match Bonus Tracker** (Program.AppName), without the game's name. The GitHub version
  keeps its name.
- Data lives in the package's folder (`%LOCALAPPDATA%\Packages\<package>\LocalState`). The first run copies
  the matches, settings and symbols from `%LOCALAPPDATA%\WardogsXpTracker` and writes `imported-from.txt`.
- Start with Windows is the package's startup task, not the Run key. Windows makes the Start menu entry,
  so the Shortcuts menu is hidden.
- VERSIONS becomes WHAT'S NEW and opens CHANGELOG.md: the Store does the updates.

## Submission answers

- **Privacy policy URL:** https://github.com/baileyacee-afk/wardogs-xp-tracker/blob/main/PRIVACY.md
- **Category:** Utilities & tools (or Games > a gaming companion category, if offered).
- **runFullTrust justification:** "A desktop (WPF) app: it sits in the tray, registers global hotkeys and
  reads the game's XP popups from screenshots with Windows' text recognition while the game runs."
- **Age rating:** no user-generated content, no communication, no purchases, no data collection.
- **Screenshots:** at least one, 1366x768 or larger: the tracker window next to the game.

### Search terms (up to 7)

wardogs, wardogs xp tracker, wardogs xp, xp tracker, match bonus, class xp, wardog level

### Short description

Tracks each class's XP toward the end-of-match bonus in Wardogs while you play.

### Description

Match Bonus Tracker (formerly Wardogs XP Tracker) is a companion app for Wardogs: a small always-on-top window that tracks the XP each class earns during a match
toward its 2,500 XP end-of-match bonus cap.

- Reads the XP and cash popups live, and your Wardog Level screen for exact totals.
- Shows a bar and tier for every class, plays a sound at each new tier, and turns a class green once its
  bonus is maxed.
- Notices the end of a match, works out the bonus you got, and keeps a breakdown of every match: XP and
  cash by reason, kills and assists.
- Hotkeys work while the game has focus; the tray icon has everything else.

It only reads the screen with Windows' built-in text recognition. It never touches the game's memory or
files, and it sends no data anywhere.

Not made by or affiliated with the developers of Wardogs.
