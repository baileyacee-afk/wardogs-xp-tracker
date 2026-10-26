using System;
using System.Collections.Concurrent;
using System.Collections.Generic;
using System.Diagnostics;
using System.Drawing;
using System.Drawing.Imaging;
using System.IO;
using System.Linq;
using System.Threading;
using Wardogs.Core;
using Wardogs.Reading;

namespace Wardogs.App
{
    // All screen capture and OCR happens on this one background thread, on a schedule:
    //   - the popup area about 3 times a second (OCR only when its white text changed), and
    //   - every 2 s: the cash at the top right and the Wardog Level panel (OCR only when it changed).
    // The window only draws; it hears about changes through the events below (raised on the UI thread).
    // Stop() ends the thread; nothing else keeps running in the background.
    public sealed class Worker
    {
        readonly Tracker tracker;
        readonly Settings settings;
        readonly Action<Action> post;        // runs an action on the UI thread
        readonly Func<IntPtr> hwnd;          // the tracker window, to keep it out of screenshots
        readonly Func<bool> windowHidden;
        readonly Action<bool> setWindowGhost; // makes the window invisible (true) / visible again for a capture
        readonly bool demo;

        Thread thread;
        readonly CancellationTokenSource cts = new();
        readonly AutoResetEvent wake = new(false);
        readonly ConcurrentQueue<Action> commands = new();

        public readonly PopupTracker Popups = new();

        // Read by the window to draw the status line.
        public volatile string LiveState = "waiting";   // on | off | blocked | waiting | paused
        public volatile string Status = "";
        public volatile bool Paused;

        public event Action Changed;                     // redraw
        public event Action<TierUp> TierReached;
        public event Action<HistoryEntry> Filed;         // a match was filed: redraw, then take its picture
        public event Action<string, string> Balloon;     // tray notification
        public event Action<HistoryEntry> ShowDetails;   // demo: open the filed match's breakdown
        public event Action EndedOrFiled;                // reset the frame highlight

        public Worker(Tracker tracker, Settings settings, bool demo, Action<Action> post, Func<IntPtr> hwnd, Func<bool> windowHidden, Action<bool> setWindowGhost)
        {
            this.tracker = tracker; this.settings = settings; this.demo = demo; this.post = post;
            this.hwnd = hwnd; this.windowHidden = windowHidden; this.setWindowGhost = setWindowGhost;
        }

        // ------------------------------------------------------------ thread
        public void Start()
        {
            thread = new Thread(Run) { IsBackground = true, Name = "Wardogs capture" };
            thread.SetApartmentState(ApartmentState.MTA);
            thread.Start();
        }

        public void Stop()
        {
            cts.Cancel();
            wake.Set();
            if (thread != null && !thread.Join(3000)) Log.Write("capture thread didn't stop in time");
        }

        // Runs something on the worker thread (between polls), e.g. a manual search or ending the match.
        public void Post(Action action) { commands.Enqueue(action); wake.Set(); }

        void Run()
        {
            var nextSlow = DateTime.Now; var nextPanel = DateTime.Now.AddSeconds(1); var nextPopup = DateTime.Now;
            while (!cts.IsCancellationRequested)
            {
                while (commands.TryDequeue(out var cmd)) Safe("command", cmd);
                var now = DateTime.Now;
                if (now >= nextSlow) { nextSlow = now.AddSeconds(2); var sw = Stopwatch.StartNew(); Safe("poll", SlowPoll); Perf.Add("slow", sw); }
                if (now >= nextPanel) { nextPanel = now.AddSeconds(1); var sw = Stopwatch.StartNew(); Safe("poll", PanelPoll); Perf.Add("panel-check", sw); }
                if (now >= nextPopup) { nextPopup = now.AddMilliseconds(Math.Max(100, settings.PopupPollMs)); Safe("popup", PopupPoll); }
                var next = nextSlow < nextPopup ? nextSlow : nextPopup;
                if (nextPanel < next) next = nextPanel;
                var wait = next - DateTime.Now;
                wake.WaitOne(Math.Max(1, (int)wait.TotalMilliseconds));
            }
        }

        void Safe(string what, Action a)
        {
            try { a(); }
            catch (Exception e)
            {
                Log.Write($"{what} ERROR {e.GetType().Name}: {e.Message}");
                if (what == "poll") SetStatus($"Problem reading the screen: {e.Message}");
            }
        }

        void Raise(Action a) { if (!cts.IsCancellationRequested) post(a); }
        void RaiseChanged() => Raise(() => Changed?.Invoke());
        void Notify(string title, string text) { if (!demo) Raise(() => Balloon?.Invoke(title, text)); }

        public void SetStatus(string text) { if (Status == text) return; Status = text; RaiseChanged(); }

        void SetLive(string value) { if (LiveState == value) return; LiveState = value; RaiseChanged(); }

        // Screenshot an area, briefly making our window invisible if it's in the way.
        Bitmap CaptureAvoidingSelf(Rectangle r)
        {
            var own = Native.WindowRect(hwnd());
            bool ghost = !windowHidden() && !own.IsEmpty && r.IntersectsWith(own);
            if (ghost) { setWindowGhost(true); Thread.Sleep(120); }
            try { return GameScreen.Capture(r); }
            finally { if (ghost) setWindowGhost(false); }
        }

        // ------------------------------------------------------------ every 2 s: cash and the Wardog Level panel
        int tick;
        int[] panelLastGrid; DateTime panelLastOcr = DateTime.MinValue; bool panelOpen;
        string findNote = ""; int shortReads; string lastRoles = ""; string lastNote = "";
        DateTime lastScanSaved = DateTime.MinValue;
        volatile bool gameNow;

        void SlowPoll()
        {
            tick++;
            tracker.SaveIfDue();
            Perf.WriteIfDue();
            if (demo) { DemoStep(); return; }
            var game = GameScreen.GameProcess();
            gameNow = game != null;
            // Time in a match without live tracking makes the deduced bonus less certain.
            if (tracker.IsMatchActive() && tracker.State.EndRequested == null && LiveState != "on") tracker.AddLiveGap(2);
            if (Paused) return;
            if (game != null && settings.Continuous) { var sw = Stopwatch.StartNew(); CashCheck(); Perf.Add("cash", sw); }

            var rect = GameScreen.ParseRect(settings.PanelRect);
            if (rect.IsEmpty)
            {
                // Don't know where the panel is yet: search the game window every ~6 s, or all monitors
                // every ~10 s when the game window can't be identified.
                var where = game != null ? "Looking for the Wardog Level screen in the game window." : "Game window not detected, searching all monitors.";
                SetStatus($"{where} {findNote}".Trim());
                if (tick % (game != null ? 3 : 5) == 0) FindPanel(false, false);
                return;
            }
        }

        // Every second: is the Wardog Level panel open? The check is a pixel count, not OCR. The panel's
        // white text always covers about the same number of pixels (about 2,070 at 1080p, learned from the
        // first good read), while the game scene behind it almost never comes close. So OCR runs as soon
        // as the panel opens (even a quick hover over the level box), and every 2 s while it stays open.
        int panelTick;
        bool inRange;

        void PanelPoll()
        {
            if (demo || Paused) return;
            var rect = GameScreen.ParseRect(settings.PanelRect);
            if (rect.IsEmpty) return;
            panelTick++;
            if (!gameNow && panelTick % 3 != 0) return;   // game not detected: every 3 s
            PanelRead read;
            int white;
            using (var bmp = CaptureAvoidingSelf(rect))
            {
                var grid = PixelMath.WhiteGrid(bmp, 24, 16, PopupTuning.GateWhite, PopupTuning.GateSpread);
                white = PixelMath.Sum(grid);
                bool changed = PixelMath.GridDiff(grid, panelLastGrid) >= 0.03;
                double since = (DateTime.Now - panelLastOcr).TotalSeconds;
                if (!PanelGate.ShouldRead(white, changed, since, panelOpen, settings.PanelWhite, out inRange))
                {
                    if (white < 30 || (settings.PanelWhite > 0 && !inRange)) panelOpen = false;
                    return;
                }
                panelLastGrid = grid; panelLastOcr = DateTime.Now;
                var sw = Stopwatch.StartNew();
                read = PanelReader.Read(Ocr.Read(bmp));
                Perf.Add("panel-ocr", sw);
            }
            panelOpen = read.Count > 0;
            if (read.Count == 0) return;   // panel not open right now
            // Remember how much white text the open panel has, to spot it without OCR from now on.
            if (read.Progress.Values.Count(p => p.Xp != null) >= Roles.MinRoles)
            {
                int learned = PanelGate.Learn(settings.PanelWhite, white, inRange);
                if (Math.Abs(learned - settings.PanelWhite) > settings.PanelWhite / 20)
                {
                    settings.PanelWhite = learned; Program.SaveSettings();
                    Log.Write($"panel text learned: {learned} white pixels");
                }
            }
            var game = GameScreen.GameProcess();
            var roles = string.Join(",", read.Order.OrderBy(x => x));
            if (roles != lastRoles) { Log.Write($"reading roles: {roles}"); lastRoles = roles; }
            if (read.Count >= Roles.MinRoles) UseRead(read);
            // A widened box that now shows all 6 roles: tighten it so later reads are quicker.
            if (read.Count == 6 && settings.PanelRoles < 6)
            {
                SetPanelRect(rect, read, 6);
                Log.Write($"panel box tightened to {settings.PanelRect} (all 6 roles)");
            }
            // The panel is open but some roles are missing: every ~20 s, re-search for a better lock.
            if (read.Count < 6 && game != null)
            {
                shortReads++;
                if (shortReads % 10 == 0) FindPanel(false, true);
            }
        }

        void UseRead(PanelRead read)
        {
            var res = tracker.AddRead(read.Progress);
            if (!string.IsNullOrEmpty(res.Note) && res.Note != lastNote) Log.Write($"read: {res.Note}");
            lastNote = res.Note;
            if (!res.Accepted) return;
            foreach (var t in res.NewTiers) AnnounceTier(t);
            Status = "";
            if (res.Filed != null) OnFiled(res.Filed);
            else RaiseChanged();
        }

        void AnnounceTier(TierUp t)
        {
            Log.Write($"{t.Role} tier {t.Tier} at {tracker.RoleGains()[t.Role]} XP");
            Raise(() => TierReached?.Invoke(t));
        }

        // Saves the screen box to read from now on, from a read of an image taken at origin.
        // With all 6 roles, a small margin is enough. With some missing, the box is widened by a whole column
        // and row on every side, so the missing ones are inside it whichever side they're on.
        void SetPanelRect(Rectangle origin, PanelRead read, int roles)
        {
            var b = read.Bounds.Value;
            int padX, padY;
            if (roles >= 6) { padX = 60; padY = 60; }
            else { padX = Num.R(read.GridCol + 40); padY = Num.R(read.GridRow + 40); }
            settings.PanelRect = $"{Num.R(origin.X + b.X - padX)},{Num.R(origin.Y + b.Y - padY)},{Num.R(b.Width + 2 * padX)},{Num.R(b.Height + 2 * padY)}";
            settings.PanelRoles = roles;
            Program.SaveSettings();
        }

        // Where to search for the panel: the game window if we can find it, otherwise every monitor.
        static List<Rectangle> SearchAreas()
        {
            if (GameScreen.GameProcess() != null) return new List<Rectangle> { GameScreen.GameRect() };
            return System.Windows.Forms.Screen.AllScreens.Select(s => s.Bounds).ToList();
        }

        // Searches for the Wardog Level panel and remembers where it is.
        // upgrade: a quiet re-search that only replaces the saved spot if it now sees more roles.
        void FindPanel(bool manual, bool upgrade)
        {
            int blank = 0, best = 0; var areas = SearchAreas();
            foreach (var area in areas)
            {
                using var bmp = CaptureAvoidingSelf(area);
                List<OcrWord> words;
                if (PixelMath.IsBlank(bmp)) { blank++; words = new List<OcrWord>(); } else words = Ocr.Read(bmp);
                var read = PanelReader.Read(words);
                best = Math.Max(best, read.Count);
                if (upgrade && read.Count <= settings.PanelRoles) continue;
                // Two roles are enough to lock on: the box is widened to the whole grid until all 6 show.
                if (read.Count >= 2 && read.Bounds != null)
                {
                    SetPanelRect(area, read, read.Count);
                    Log.Write($"panel found at {settings.PanelRect} with roles: {read.Keys()}{(upgrade ? " (better lock)" : "")}");
                    findNote = "";
                    UseRead(read);
                    if (manual) Notify("Wardogs XP Tracker", $"Found the Wardog Level screen ({read.Count} of 6 roles). It will be read automatically from now on.");
                    return;
                }
                if (upgrade) continue;
                // Keep a copy of what we saw (at most every 30 s) so a failed search can be checked.
                if (manual || (DateTime.Now - lastScanSaved).TotalSeconds > 30)
                {
                    try { bmp.Save(Path.Combine(tracker.DataDir, "last-scan.png"), ImageFormat.Png); } catch { }
                    lastScanSaved = DateTime.Now;
                    Log.Write($"scan of {area} found {words.Count} words, roles: {read.Keys()} {(words.Count > 0 ? "| first words: " + string.Join(" ", words.Take(12).Select(w => w.Text)) : "")}");
                }
            }
            findNote =
                blank == areas.Count ? "The screen capture came out black. Switch Wardogs to Borderless (not exclusive fullscreen) and turn off HDR if it is on."
                : best > 0 ? $"Found only {best} of 6 roles on the Wardog Level screen. Make sure the whole panel is visible."
                : "Open the Wardog Level screen in game. If it is already open, press Ctrl+Shift+U.";
            if (manual) SetStatus($"Couldn't find the Wardog Level screen. {findNote}");
        }

        // Ctrl+Shift+U / tray: search now and say what happened.
        public void ManualFind() => Post(() => FindPanel(true, false));

        // ------------------------------------------------------------ cash at the top right
        // Reads this life's cash and banked cash while playing, so the match's cash includes gear bought
        // (which has no popup). OCR sometimes drops the minus sign, so a read only counts when the one
        // before it agrees on the banked cash this life started with.
        int[] cashLastGrid; DateTime cashLastOcr = DateTime.MinValue; long? cashPrevLifeStart;

        void CashCheck()
        {
            if (tracker.State.EndRequested != null) return;   // after the match: the results payout isn't this match's play
            using var bmp = GameScreen.Capture(Reading.Popups.CashRect());
            var grid = PixelMath.WhiteGrid(bmp, 24, 4, PopupTuning.GateWhite, PopupTuning.GateSpread);
            bool stale = (DateTime.Now - cashLastOcr).TotalSeconds >= 10;
            if (PixelMath.GridDiff(grid, cashLastGrid) < 0.05 && !stale) return;
            cashLastGrid = grid; cashLastOcr = DateTime.Now;
            var read = Reading.Popups.ReadCashHud(bmp);
            if (read == null) return;
            long lifeStart = read.Value.Banked - read.Value.Life;
            bool confirmed = lifeStart == cashPrevLifeStart;
            cashPrevLifeStart = lifeStart;
            if (confirmed && tracker.SetBankRead(read.Value.Banked, lifeStart)) RaiseChanged();
        }

        // ------------------------------------------------------------ live popups
        int[] popLastGrid; DateTime popLastOcr = DateTime.MinValue;
        readonly Dictionary<string, DateTime> unparsedSeen = new();

        void PopupPoll()
        {
            if (demo) return;
            if (Paused) { SetLive("paused"); return; }
            if (!settings.Continuous) { SetLive("off"); return; }
            if (!gameNow) { SetLive("waiting"); return; }
            var rect = Reading.Popups.PopupRect(settings.PopupRect);
            var own = Native.WindowRect(hwnd());
            if (!windowHidden() && !own.IsEmpty && rect.IntersectsWith(own)) { SetLive("blocked"); return; }
            SetLive("on");
            var now = DateTime.Now;
            var sw = Stopwatch.StartNew();
            bool ocr = false;
            using (var bmp = GameScreen.Capture(rect))
            {
                var grid = PixelMath.WhiteGrid(bmp, 24, 16, PopupTuning.GateWhite, PopupTuning.GateSpread);
                double diff = PixelMath.GridDiff(grid, popLastGrid);
                double since = (now - popLastOcr).TotalSeconds;
                if ((diff < PopupTuning.GateDiff && since < PopupTuning.ForceOcr) || since < PopupTuning.MinOcrGap) { Popups.Seen(now); Perf.Add("popup-check", sw); return; }
                popLastGrid = grid;
                if (Popups.Tracks.Count == 0 && !Reading.Popups.AnyShowing(bmp)) { Perf.Add("popup-check", sw); return; }   // no popups showing
                popLastOcr = now;
                ocr = true;
                var rows = Reading.Popups.ReadArea(bmp);
                var res = Popups.Update(rows, now);
                bool changed = false;
                foreach (var t in res.New)
                {
                    var (ev, tiers) = tracker.AddPopupEvent(t.Kind, t.Amount, t.Reason, t.Role, t.Uncertain);
                    t.EventId = ev.Id;
                    foreach (var tu in tiers) AnnounceTier(tu);
                    changed = true;
                }
                foreach (var t in res.Changed)
                {
                    if (t.EventId == null) continue;
                    foreach (var tu in tracker.UpdatePopupEvent(t.EventId.Value, t.Amount, t.Uncertain)) AnnounceTier(tu);
                    changed = true;
                }
                foreach (var r in rows.Where(r => r.Kind == "unparsed")) SaveUnparsed(bmp, r, now);
                if (changed) RaiseChanged();
            }
            Perf.Add(ocr ? "popup-ocr" : "popup-check", sw);
        }

        // A popup row with numbers that couldn't be understood: log it once, keep a picture for tuning
        // (the last 50), and count it toward the match's confidence warning. Rows that are just a misread
        // of a row already being followed don't count.
        void SaveUnparsed(Bitmap bmp, PopupRow row, DateTime now)
        {
            if (Popups.NearTrack(row)) return;
            if (unparsedSeen.TryGetValue(row.Text, out var last) && (now - last).TotalSeconds < 6) return;
            unparsedSeen[row.Text] = now;
            if (unparsedSeen.Count > 500) unparsedSeen.Clear();
            tracker.AddUnparsedRead();
            Log.Write($"unparsed popup: {row.Text}");
            try
            {
                var dir = Path.Combine(tracker.DataDir, "unparsed");
                Directory.CreateDirectory(dir);
                int y = Math.Max(0, Num.R(row.Y - 0.6 * row.H)); int h = Math.Min(bmp.Height - y, Num.R(2.2 * row.H));
                if (h <= 0) return;
                using (var crop = bmp.Clone(new Rectangle(0, y, bmp.Width, h), PixelFormat.Format24bppRgb))
                    crop.Save(Path.Combine(dir, now.ToString("yyyyMMdd-HHmmss-fff") + ".png"), ImageFormat.Png);
                foreach (var f in new DirectoryInfo(dir).GetFiles("*.png").OrderByDescending(f => f.Name).Skip(50)) f.Delete();
            }
            catch { }
        }

        // Ctrl+Shift+C / tray, the popup area picker, and Pause/Resume all start popup reading afresh.
        public void ResetPopups() => Post(() => { Popups.Reset(); popLastGrid = null; RaiseChanged(); });

        // ------------------------------------------------------------ end of match
        // Ctrl+Shift+N / END MATCH: marks the match over; the next Wardog Level read files it with the bonus.
        // Pressing it again files it right away, without the bonus.
        public void EndMatch() => Post(DoEndMatch);

        void DoEndMatch()
        {
            if (tracker.State.EndRequested == null)
            {
                if (!tracker.IsMatchActive()) { SetStatus("Nothing to file yet: no XP or popups this match."); return; }
                tracker.RequestEndMatch();
                Popups.Reset();
                Log.Write("match ended");
                Notify("Match ended", "Open the Wardog Level screen to read your final XP. The tracker works out the end-of-match bonus from it.");
                Status = "";
                Raise(() => EndedOrFiled?.Invoke());
                RaiseChanged();
            }
            else
            {
                Status = "";
                OnFiled(tracker.CompleteMatch(true));
            }
        }

        void OnFiled(HistoryEntry e)
        {
            Log.Write($"match filed: {e.Xp} XP, bonus {e.BonusTotal}, cash {e.NetCash} (popups {e.Cash}), {e.EventCount} popups, warnings {e.Warnings.Count}");
            var bonus = e.BonusTotal != null ? $"End-of-match bonus: +{e.BonusTotal:N0} XP{(e.Placement != null ? $" ({e.Placement})" : "")}." : "No end-of-match bonus deduced.";
            Notify("Match filed", $"{bonus} Click it under Recent Matches for the full breakdown.");
            Raise(() => { EndedOrFiled?.Invoke(); Filed?.Invoke(e); });
        }

        // ------------------------------------------------------------ demo mode (made-up match, no game needed)
        static readonly Dictionary<string, long> demoXp = new() { ["infantry"] = 130627, ["medic"] = 269872, ["support"] = 118408, ["recon"] = 43655, ["driver"] = 45030, ["pilot"] = 37159 };
        static readonly Dictionary<string, int> demoLv = new() { ["infantry"] = 21, ["medic"] = 28, ["support"] = 20, ["recon"] = 13, ["driver"] = 14, ["pilot"] = 12 };
        static readonly Dictionary<string, long> demoNext = new() { ["infantry"] = 145400, ["medic"] = 288450, ["support"] = 127200, ["recon"] = 43750, ["driver"] = 54750, ["pilot"] = 37500 };
        static readonly object[] demoSteps =
        {
            "read",
            new[] { ("xp", 250, "KILL", "infantry"), ("cash", 160, "CONTROL ZONE PRESENCE", "") },
            new[] { ("xp", 200, "KILL ASSIST", "infantry"), ("xp", 8, "BUILDING", "support"), ("xp", 8, "BUILDING", "support") },
            new[] { ("xp", 250, "REVIVED TEAMMATE", "medic"), ("cash", 375, "REVIVED PLAYER ASSIST", "") },
            new[] { ("xp", 525, "SUPPLIES DELIVERED", "driver"), ("cash", -20, "VEHICLE REFUELLING", "") },
            new[] { ("xp", 250, "KILL", "infantry"), ("xp", 250, "KILL", "infantry"), ("xp", 150, "SPOTTED TARGET DESTROYED", "recon") },
            new[] { ("xp", 400, "SUPPLIES DELIVERED", "pilot"), ("xp", 25, "TACTICAL DEPLOYMENT", "pilot") },
            new[] { ("xp", 250, "KILL", "infantry"), ("xp", 200, "KILL ASSIST", "infantry"), ("cash", 250, "CONTROL ZONE ENTERED", "") },
            new[] { ("xp", 250, "KILL", "infantry"), ("xp", 250, "KILL", "infantry"), ("xp", 180, "SUPPLIES DEPOSITED", "support") },
            new[] { ("xp", 250, "KILL", "infantry"), ("xp", 250, "KILL", "infantry"), ("xp", 250, "KILL", "infantry") },
            "end", "final",
        };

        void DemoStep()
        {
            LiveState = "on";
            int i = tick - 1;
            if (i >= demoSteps.Length) return;
            var step = demoSteps[i];
            if (step is string s && s == "end") { DoEndMatch(); return; }
            if (step is (string, int, string, string)[] popups)
            {
                foreach (var (kind, amount, reason, role) in popups)
                {
                    var (_, tiers) = tracker.AddPopupEvent(kind, amount, reason, role == "" ? null : role, false);
                    foreach (var t in tiers) AnnounceTier(t);
                }
                RaiseChanged();
                return;
            }
            // "read" at the start; "final" after the match: the bonus is 700 XP per tier (2nd place)
            if ((string)step == "final")
                foreach (var r in Roles.Order) demoXp[r] += tracker.State.EndGains.GetValueOrDefault(r) + 700 * Roles.Tier(tracker.State.EndGains.GetValueOrDefault(r));
            foreach (var r in Roles.Order) while (demoXp[r] >= demoNext[r]) { demoLv[r]++; demoNext[r] += 12000; }
            var read = new PanelRead();
            foreach (var r in Roles.Order) { read.Progress[r] = new RoleProgress { Level = demoLv[r], Xp = demoXp[r], NextXp = demoNext[r] }; read.Order.Add(r); }
            UseRead(read);
            if ((string)step == "final" && tracker.History.Count > 0) { var h = tracker.History[0]; Raise(() => ShowDetails?.Invoke(h)); }
        }
    }
}
