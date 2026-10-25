# Changelog

Versions match the [GitHub releases](https://github.com/baileyacee-afk/wardogs-xp-tracker/releases).
The version you're running shows when you hover over the tray icon.

## v2.4

- The match picture is now the tracker right after the match is filed: the match at the top of
  Recent Matches with its totals and bonus, and your Wardog level. The last match filed before
  this update gets its picture when the tracker starts, if no new match has begun.

## v2.3

- **Save a match:** SAVE in match details writes the whole page (summary, bonus, cash, XP and cash
  by reason, every popup) as one HTML file in `Documents\Wardogs XP Tracker` and opens it.
- **Picture of the tracker at the end of each match:** taken when the match is filed. PICTURE in
  match details opens it, and it's included in the saved page.

## v2.2

- **Cash this match now includes gear you buy.** Buying gear has no popup, so it was missing. The
  tracker now reads your banked cash at the top right while you play and shows how much it changed
  since the match began (the first life it saw). Match details show both this and the popup total.

## v2.1

- **Wardog Level reads work again:** the level number under the Recon, Driver and Pilot icons is
  often misread, which made the tracker see only 3 of 6 classes and throw the read away. A class
  now counts whenever its XP is readable; an unreadable level keeps the last known one.
- **Automatic end of match is off:** the in-match cash boxes (per-life cash, banked cash, level)
  look just like the results screen, so it could have ended a match while you were still playing.
  Press END MATCH (Ctrl+Shift+N) when the match is over.

## v2.0

Live popup tracking, a breakdown of every match, and the deduced end-of-match bonus.

- **Live popups:** reads the XP and cash popups under the top-right cash boxes about 3 times a
  second, running text recognition only when they change. Each popup is counted once (rows are
  followed as they stack, age and leave), XP is credited to the class from its reason or its
  symbol, and cash is added up for the match. **Ctrl+Shift+C** turns it on/off.
- **Wardog Level reads correct drift:** when one comes in, its exact totals replace the popup
  estimates for that class.
- **End of match:** the results screen is noticed automatically (or press END MATCH /
  Ctrl+Shift+N). The next Wardog Level read files the match with the **end-of-match bonus
  (deduced)** per class and your placement worked out from the per-tier payout.
- **Match details** (DETAILS button, or click a match under Recent Matches): totals, the deduced
  bonus, XP and cash by reason with counts, and every popup in order. Each match's popups are
  saved, so past matches can be opened later.
- **Confidence notes** on each match when something could have skewed the bonus: unreadable popup
  reads, live tracking off, XP with no class, uncertain cash amounts, or a bonus that isn't a clean
  multiple of the payout.
- **Set popup area...** in the tray to point it at the right spot; unreadable popups are logged
  and saved as pictures for tuning.
- Light on CPU: about a quarter of one core during busy fights (around 2% of a 16-thread CPU),
  less when nothing is popping. The log notes where the time goes once a minute.
- Class symbols redrawn to match the game's shapes more closely.
- The sample recorder is gone (Ctrl+Shift+R / Ctrl+Shift+S); thanks for recording!

## v1.4

- The Match Bonus section now shows **how many of the six roles have maxed their bonus** this
  match ("2 / 6 roles maxed"), with each role's symbol and a mini bar toward its 2,500 XP cap
  (gold while filling, green when maxed; the role you're playing is highlighted). An
  **ALL MAXED** badge appears when all six are done.
- A line under it describes the role you're playing: its XP and XP to the next tier, or that
  it's maxed and you can switch roles. (Replaces the single-role number and bar.)

## v1.3

- Your **Wardog level** (all six role levels added up) is shown large at the top, with the
  levels gained this match next to it.
- Each class has its symbol next to its name (Assault arrowhead, Medic cross, Support wrench,
  Recon crosshair, Driver steering wheel, Pilot wings), also on the featured role. Symbols are
  gold for the role you're playing and green once a role's bonus is maxed.

## v1.2

- Sample recorder is now a plain start/stop (Ctrl+Shift+R); there's no class to pick. Which class
  each popup belongs to is worked out from the Wardog Level reads logged while recording, so
  getting XP for several classes in one recording is fine.
- The recorder is temporary and will be removed once live popup tracking is built.

## v1.1

Sample recorder, to collect real examples of the in-match XP and cash popups for the upcoming
live popup tracking.

- Tray > **Record samples**: pick the class you're about to play, then record. **Ctrl+Shift+R**
  starts/stops (reusing the last class picked); each recording is its own session folder.
- Saves the top-right corner of the game twice a second (skipping unchanged frames), a full
  screenshot every 2 minutes, and every Wardog Level read made while recording.
- **Ctrl+Shift+S** saves a full screenshot any time, for example of the end-of-match screen.
- Stops itself at 5,000 frames (about 150 MB) or when the disk has less than 2 GB free.
- The status line shows REC, the class, elapsed time and frame count while recording.

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
