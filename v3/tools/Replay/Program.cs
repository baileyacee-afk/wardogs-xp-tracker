using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Drawing;
using System.Drawing.Imaging;
using System.Globalization;
using System.IO;
using System.Linq;
using Wardogs.App;
using Wardogs.Core;
using Wardogs.Reading;

// Usage:
//   Replay [session ...] [--events] [--out file.csv]   replay recorded frames through the popup reader
//   Replay --data <dataDir>                           load a data folder the app would use and report it
//   Replay --kills <dataDir>                          kills and assists counted in each saved match
static class Program
{
    [STAThread]
    static int Main(string[] args)
    {
        if (args.Length >= 2 && args[0] == "--data") return CheckData(args[1]);
        if (args.Length >= 2 && args[0] == "--kills")
        {
            foreach (var f in Directory.GetFiles(Path.Combine(args[1], "matches"), "*.json").OrderBy(f => f))
            {
                var ev = Json.ReadList<PopupEvent>(f);
                var (k, a) = Kills.Count(ev);
                Console.WriteLine($"{Path.GetFileNameWithoutExtension(f)}  kills {k,3}  assists {a,3}");
            }
            return 0;
        }
        if (args.Length >= 2 && args[0] == "--symbols")
        {
            // --symbols <dataDir>: how alike the learned and drawn class symbols are
            Symbols.Init(args[1], RoleIcons.DrawnGlyphs());
            var drawn = RoleIcons.DrawnGlyphs();
            foreach (var a in Roles.Order)
                Console.WriteLine($"{a,-9} " + string.Join(" ", Roles.Order.Select(b => $"{b.Substring(0, 3)}={PixelMath.Similarity(Symbols.Template(a), Symbols.Template(b)):N2}")) + $"  vs its drawing {PixelMath.Similarity(Symbols.Template(a), drawn[a]):N2}");
            return 0;
        }
        if (args.Length >= 2 && args[0] == "--ends")
        {
            // --ends <samplesDir>: every change in the menu boxes in the recordings, and which full screenshots are loading screens
            foreach (var dir in Directory.GetDirectories(args[1]).OrderBy(d => d))
            {
                Console.WriteLine(Path.GetFileName(dir));
                foreach (var f in Directory.GetFiles(dir, "full-*.jpg").OrderBy(f => f))
                {
                    using var src = (Bitmap)Image.FromFile(f);
                    using var box = src.Clone(new Rectangle(38, 842, 538, 49), PixelFormat.Format24bppRgb);
                    Console.WriteLine($"  {Path.GetFileName(f)} loading={Popups.IsLoadingScreen(box)}");
                    using var map = src.Clone(new Rectangle(38, 891, 730, 65), PixelFormat.Format24bppRgb);
                    if (Popups.IsLoadingScreen(box)) Console.WriteLine($"    map {Popups.ReadLoadingMap(map)}");
                }
                // The same steps as Worker.CashCheck: a banked cash counts once two reads in a row agree.
                int menus = 0, frames = 0, ends = 0; long? prevStart = null; long bank = 0, start = 0; DateTime hudAt = DateTime.MinValue; long biggest = 0;
                foreach (var f in Directory.GetFiles(Path.Combine(dir, "frames"), "*.jpg").OrderBy(f => f))
                {
                    using var src = (Bitmap)Image.FromFile(f);
                    using var box = src.Clone(new Rectangle(346, 0, 403, 59), PixelFormat.Format24bppRgb);
                    frames++;
                    var name = Path.GetFileNameWithoutExtension(f);
                    var at = DateTime.ParseExact(name.Substring(0, 6), "HHmmss", CultureInfo.InvariantCulture);
                    var h = Popups.ReadCashHud(box);
                    var m = h == null ? Popups.ReadMenuBoxes(box) : null;
                    if (m != null) menus++;
                    if (h == null && m == null) continue;
                    long first = h?.Life ?? m.Value.First, banked = h?.Banked ?? m.Value.Banked;
                    if ((at - hudAt).TotalSeconds <= 20)
                    {
                        if (banked - first == start) biggest = Math.Max(biggest, banked - bank);
                        if (Popups.IsPayout(first, banked, bank, start)) { ends++; Console.WriteLine($"  {name} END: banked {bank} -> {banked}, first box {first}"); hudAt = DateTime.MinValue; continue; }
                    }
                    if (h == null) continue;
                    long ls = banked - first;
                    if (ls == prevStart) { bank = banked; start = ls; hudAt = at; }
                    prevStart = ls;
                }
                Console.WriteLine($"  frames {frames}, menu reads {menus}, ends {ends}, biggest jump that added up {biggest}");
            }
            return 0;
        }
        if (args.Length >= 1 && args[0] == "--finalread") return FinalReadCheck();
        if (args.Length >= 1 && args[0] == "--driverwheel") return DriverWheelCheck();
        if (args.Length >= 1 && args[0] == "--panel") return PanelReplay();
        if (args.Length >= 2 && args[0] == "--ocr")
        {
            // --ocr <image> [x y w h]: the words and panel read from one picture
            using var src = (Bitmap)Image.FromFile(args[1]);
            var r = args.Length >= 6 ? new Rectangle(int.Parse(args[2]), int.Parse(args[3]), int.Parse(args[4]), int.Parse(args[5])) : new Rectangle(0, 0, src.Width, src.Height);
            using var bmp = src.Clone(r, PixelFormat.Format24bppRgb);
            var words = Ocr.Read(bmp);
            Console.WriteLine(string.Join(" | ", words.Select(w => $"{w.Text}@{w.X:N0},{w.Y:N0}")));
            var read = PanelReader.Read(words);
            Console.WriteLine($"roles {read.Count}: " + string.Join(" ", read.Order.Select(x => $"{x}=Lv{read.Progress[x].Level}/{read.Progress[x].Xp}/{read.Progress[x].NextXp}")));
            return 0;
        }
        return Replay(args);
    }

    // The Driver wheel read as "O": it must not become level 0 with the real level (18) taken as the XP,
    // and a match that already took 18 must correct back to 86,397 without counting it as XP earned.
    static int DriverWheelCheck()
    {
        int bad = 0;
        void Ok(bool ok, string what) { if (!ok) bad++; Console.WriteLine($"{(ok ? "ok  " : "FAIL")} {what}"); }

        var words = new List<OcrWord>
        {
            new("DRIVER", 100, 100, 60, 14), new("O", 120, 125, 20, 20), new("18", 122, 150, 16, 14),
            new("86,397", 95, 175, 50, 12), new("/", 147, 175, 6, 12), new("95,750XP", 100, 195, 60, 12),
        };
        var p = PanelReader.Read(words).Progress["driver"];
        Ok(p.Level == 18 && p.Xp == 86397, $"panel with the wheel read as O: Lv{p.Level} {p.Xp} (want Lv18 86397)");

        var tmp = Path.Combine(Path.GetTempPath(), "wd-driverwheel");
        if (Directory.Exists(tmp)) Directory.Delete(tmp, true);
        Directory.CreateDirectory(tmp);
        Dictionary<string, RoleProgress> Read(int lv, long driver, long medic) => Roles.Order.ToDictionary(r => r, r =>
            r == "driver" ? new RoleProgress { Level = lv, Xp = driver, NextXp = 95750 } : new RoleProgress { Level = 20, Xp = r == "medic" ? medic : 50000, NextXp = 900000 });

        // Outside a match: a lower level with lower XP is never taken, however often it's read.
        var tr = new Tracker(tmp);
        tr.AddRead(Read(18, 86339, 500000));
        tr.CompleteMatch(true);
        for (int i = 0; i < 5; i++) tr.AddRead(Read(0, 18, 500000));
        Ok(tr.State.Last["driver"] == 86339 && tr.State.Levels["driver"] == 18, $"five reads of Lv0 18 after a match: {tr.State.Last["driver"]} Lv{tr.State.Levels["driver"]} (want 86339 Lv18)");

        // The state from the bug: the match started with the misread already in.
        Directory.Delete(tmp, true); Directory.CreateDirectory(tmp);
        tr = new Tracker(tmp);
        tr.AddRead(Read(0, 18, 500000));
        tr.AddPopupEvent("xp", 250, "KILL", "medic", false);
        tr.AddRead(Read(0, 18, 500250));
        for (int i = 0; i < 3; i++) tr.AddRead(Read(18, 86397, 500250));
        var gains = tr.RoleGains();
        Ok(tr.State.Last["driver"] == 86397 && tr.State.Levels["driver"] == 18, $"correct reads take over: {tr.State.Last["driver"]} Lv{tr.State.Levels["driver"]} (want 86397 Lv18)");
        Ok(gains.GetValueOrDefault("driver") == 0 && gains.GetValueOrDefault("medic") == 250, $"match gains: driver {gains.GetValueOrDefault("driver")} (want 0), medic {gains.GetValueOrDefault("medic")} (want 250)");
        Ok(tr.WardogLevel() == 18 + 5 * 20, $"wardog level {tr.WardogLevel()} (want {18 + 5 * 20})");
        Console.WriteLine(bad == 0 ? "all ok" : $"{bad} failed");
        return bad;
    }

    // Whole matches through the tracker, ending on the next match's loading screen.
    static int FinalReadCheck()
    {
        var tmp = Path.Combine(Path.GetTempPath(), "wd-finalread");
        Dictionary<string, RoleProgress> Read(long inf, long med) => Roles.Order.ToDictionary(r => r, r => new RoleProgress { Level = 10, Xp = r == "infantry" ? inf : r == "medic" ? med : 50000, NextXp = 900000 });
        int bad = 0;
        void Check(string name, Action<Tracker> play, long? bonus, long xp)
        {
            if (Directory.Exists(tmp)) Directory.Delete(tmp, true);
            Directory.CreateDirectory(tmp);
            var tr = new Tracker(tmp);
            play(tr);
            var e = tr.CompleteMatchAtLoading();
            bool ok = e.BonusTotal == bonus && e.Xp == xp;
            if (!ok) bad++;
            Console.WriteLine($"{(ok ? "ok  " : "FAIL")} {name}: bonus {e.BonusTotal?.ToString() ?? "none"} (want {bonus?.ToString() ?? "none"}), total {e.Xp} (want {xp}), placement {e.Placement}");
            var after = tr.AddRead(Read(100000 + xp, 200000));
            Console.WriteLine($"     next match starts clean: gains {tr.RoleGains().Values.Sum()}");
        }
        Check("bonus read just before loading", tr =>
        {
            tr.AddRead(Read(100000, 200000));
            tr.AddPopupEvent("xp", 1000, "KILL", "infantry", false);
            tr.AddRead(Read(101000 + 1400, 200000));
            tr.AddRead(Read(101000 + 1400, 200000));
        }, 1400, 2400);
        Check("bonus shows after a read of the same totals", tr =>
        {
            tr.AddRead(Read(100000, 200000));
            tr.AddPopupEvent("xp", 1000, "KILL", "infantry", false);
            tr.AddRead(Read(101000, 200000));
            tr.AddRead(Read(101000 + 1400, 200000));
        }, 1400, 2400);
        Check("popups after the last read: still playing then", tr =>
        {
            tr.AddRead(Read(100000, 200000));
            tr.AddRead(Read(101400, 200000));
            tr.AddPopupEvent("xp", 250, "KILL", "infantry", false);
        }, null, 1650);
        Check("only a few missed popups: not a bonus", tr =>
        {
            tr.AddRead(Read(100000, 200000));
            tr.AddPopupEvent("xp", 1000, "KILL", "infantry", false);
            tr.AddRead(Read(101100, 200000));
        }, null, 1100);
        Check("no read at all", tr => tr.AddPopupEvent("xp", 250, "KILL", "infantry", false), null, 250);
        foreach (var (came, had, map, want) in new (bool, string, string, bool)[]
        {
            (true, "ZESTAFONA", "ZESTAFONA", true), (true, "ZESTAFONA", "ZESTAF0NA", true), (true, "ZESTAFONA", "BAKURANI", false),
            (true, null, "BAKURANI", true), (true, "ZESTAFONA", null, true), (false, "ZESTAFONA", "ZESTAFONA", false),
        })
        {
            bool ok = Popups.IsRejoin(came, had, map) == want;
            if (!ok) bad++;
            Console.WriteLine($"{(ok ? "ok  " : "FAIL")} rejoin: came back {came}, match on {had ?? "unknown"}, loading {map ?? "unreadable"}: {want}");
        }
        return bad;
    }

    static int CheckData(string dir)
    {
        var tmp = Path.Combine(Path.GetTempPath(), "wd-datacheck");
        if (Directory.Exists(tmp)) Directory.Delete(tmp, true);
        Directory.CreateDirectory(tmp);
        foreach (var f in new[] { "match.json", "history.json", "settings.json", "symbols.json" })
            if (File.Exists(Path.Combine(dir, f))) File.Copy(Path.Combine(dir, f), Path.Combine(tmp, f));
        var tr = new Tracker(tmp);
        Console.WriteLine($"match: started {tr.State.Start:g}, base {(tr.State.Base == null ? "none" : tr.State.Base.Count + " roles")}, last {tr.State.Last.Count} roles, events {tr.State.Events.Count}, wardog level {tr.WardogLevel()}");
        Console.WriteLine($"history: {tr.History.Count} matches");
        foreach (var h in tr.History)
        {
            var ev = tr.LoadEvents(new HistoryEntry { EventsFile = h.EventsFile, Start = h.Start });
            if (h.EventsFile != null) ev = Json.ReadList<PopupEvent>(Path.Combine(dir, h.EventsFile));
            Console.WriteLine($"  {h.Start:g}  {h.Xp,7} XP  roles {string.Join(" ", h.Roles.Select(r => r.Key + "=" + r.Value))}  bonus {h.BonusTotal}  net cash {h.NetCash}  events {ev.Count}/{h.EventCount}  warnings {h.Warnings.Count}  pic {h.Snapshot}");
        }
        var settings = Json.Read<Settings>(Path.Combine(tmp, "settings.json"));
        Console.WriteLine($"settings: panel {settings?.PanelRect} ({settings?.PanelRoles} roles), window {settings?.WindowPos}, live {settings?.Continuous}, start menu {settings?.StartMenuShortcut}");
        // Round trip: save with the app's writer and load again.
        tr.Save();
        var again = new Tracker(tmp);
        Console.WriteLine($"round trip: history {again.History.Count}, last {again.State.Last.Count} roles, levels {string.Join(",", again.State.Levels.Select(l => l.Key + "=" + l.Value))}");
        return 0;
    }

    // The worker's panel check (pixel count, OCR only when it looks open) over every recorded frame.
    static int PanelReplay()
    {
        var samples = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "WardogsXpTracker", "samples");
        var rect = new Rectangle(312, 20, 399, 381);   // the panel box, in the recorded corner's coordinates
        int learnedWhite = 0, ocrs = 0, reads = 0, frames = 0; int[] lastGrid = null; DateTime lastOcr = DateTime.MinValue; bool open = false;
        foreach (var sess in Directory.GetDirectories(samples).OrderBy(x => x))
        {
            var day = DateTime.ParseExact(Path.GetFileName(sess).Substring(0, 10), "yyyy-MM-dd", CultureInfo.InvariantCulture);
            var lastCheck = DateTime.MinValue;
            foreach (var f in Directory.GetFiles(Path.Combine(sess, "frames"), "*.jpg").OrderBy(x => x, StringComparer.Ordinal))
            {
                var now = day + TimeSpan.ParseExact(Path.GetFileNameWithoutExtension(f), @"hhmmss\-fff", CultureInfo.InvariantCulture);
                if ((now - lastCheck).TotalSeconds < 0.95) continue;   // checked once a second
                lastCheck = now; frames++;
                Bitmap bmp;
                using (var src = (Bitmap)Image.FromFile(f)) bmp = src.Clone(rect, PixelFormat.Format24bppRgb);
                using (bmp)
                {
                    var grid = PixelMath.WhiteGrid(bmp, 24, 16, PopupTuning.GateWhite, PopupTuning.GateSpread);
                    int white = PixelMath.Sum(grid);
                    bool changed = PixelMath.GridDiff(grid, lastGrid) >= 0.03;
                    double since = (now - lastOcr).TotalSeconds;
                    if (!PanelGate.ShouldRead(white, changed, since, open, learnedWhite, out bool inRange))
                    {
                        if (white < 30 || (learnedWhite > 0 && !inRange)) open = false;
                        continue;
                    }
                    lastGrid = grid; lastOcr = now; ocrs++;
                    var read = PanelReader.Read(Ocr.Read(bmp));
                    open = read.Count > 0;
                    if (read.Progress.Values.Count(p => p.Xp != null) >= Roles.MinRoles)
                    {
                        reads++;
                        learnedWhite = PanelGate.Learn(learnedWhite, white, inRange);
                        Console.WriteLine($"{now:HH:mm:ss.f} read {read.Count} roles ({string.Join(" ", read.Order.Select(r => r + "=" + read.Progress[r].Xp))})  white {white}{(inRange ? "" : " (fallback look)")}");
                    }
                }
            }
        }
        Console.WriteLine($"checks {frames}, OCR runs {ocrs} ({100.0 * ocrs / Math.Max(1, frames):N1}%), reads {reads}, learned white {learnedWhite}");
        return 0;
    }

    sealed class Ev { public DateTime T; public string Kind, Reason; public PopupTrack Track; }

    static int Replay(string[] args)
    {
        bool show = args.Contains("--events");
        string outFile = null;
        int oi = Array.IndexOf(args, "--out"); if (oi >= 0 && oi + 1 < args.Length) outFile = args[oi + 1];
        var samples = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "WardogsXpTracker", "samples");
        var sessions = args.Where(a => !a.StartsWith("--") && a != outFile).ToList();
        if (sessions.Count == 0) sessions = Directory.GetDirectories(samples).Select(Path.GetFileName).OrderBy(x => x).ToList();

        var data = Path.Combine(Path.GetTempPath(), "wd-replay-" + Process.GetCurrentProcess().Id);
        Directory.CreateDirectory(data);
        Symbols.Init(data, RoleIcons.DrawnGlyphs());

        var popup = new Rectangle(393, 48, 364, 226);   // default popup area, in the recorded corner's coordinates
        var tracker = new PopupTracker();
        var events = new List<Ev>(); var unparsed = new List<string>();
        int[] lastGrid = null; DateTime lastOcr = DateTime.MinValue; int ocrCount = 0, frames = 0; double ocrMs = 0;
        foreach (var sess in sessions)
        {
            tracker.Reset(); lastGrid = null;
            var day = DateTime.ParseExact(sess.Substring(0, 10), "yyyy-MM-dd", CultureInfo.InvariantCulture);
            foreach (var f in Directory.GetFiles(Path.Combine(samples, sess, "frames"), "*.jpg").OrderBy(x => x, StringComparer.Ordinal))
            {
                var now = day + TimeSpan.ParseExact(Path.GetFileNameWithoutExtension(f), @"hhmmss\-fff", CultureInfo.InvariantCulture);
                Bitmap bmp;
                using (var src = (Bitmap)Image.FromFile(f)) bmp = src.Clone(popup, PixelFormat.Format24bppRgb);
                using (bmp)
                {
                    frames++;
                    var grid = PixelMath.WhiteGrid(bmp, 24, 16, PopupTuning.GateWhite, PopupTuning.GateSpread);
                    double diff = PixelMath.GridDiff(grid, lastGrid);
                    double since = (now - lastOcr).TotalSeconds;
                    if ((diff < PopupTuning.GateDiff && since < PopupTuning.ForceOcr) || since < PopupTuning.MinOcrGap) { tracker.Seen(now); continue; }
                    lastGrid = grid;
                    if (tracker.Tracks.Count == 0 && !Popups.AnyShowing(bmp)) continue;
                    lastOcr = now; ocrCount++;
                    var sw = Stopwatch.StartNew();
                    var rows = Popups.ReadArea(bmp);
                    var res = tracker.Update(rows, now);
                    ocrMs += sw.Elapsed.TotalMilliseconds;
                    foreach (var t in res.New) events.Add(new Ev { T = now, Kind = t.Kind, Reason = t.Reason, Track = t });
                    foreach (var r in rows.Where(r => r.Kind == "unparsed")) if (!tracker.NearTrack(r)) unparsed.Add(r.Text);
                }
            }
        }

        Console.WriteLine($"frames {frames}, OCR runs {ocrCount} ({100 * ocrCount / Math.Max(1, frames)}%), avg OCR+parse {ocrMs / Math.Max(1, ocrCount):N0} ms");
        Console.WriteLine($"events: {events.Count}  (xp {events.Count(e => e.Kind == "xp")}, cash {events.Count(e => e.Kind == "cash")}); xp with no class: {events.Count(e => e.Kind == "xp" && e.Track.Role == null)}; uncertain cash: {events.Count(e => e.Track.Uncertain)}; unparsed reads: {unparsed.Count}");
        Console.WriteLine("--- by reason");
        foreach (var g in events.GroupBy(e => e.Kind + ", " + e.Reason).OrderByDescending(g => g.Count()))
            Console.WriteLine($"{g.Count(),4} x {g.Key,-40} total {g.Sum(e => (long)e.Track.Amount),7}   classes: {string.Join(" ", g.GroupBy(e => e.Track.Role ?? "").Select(x => x.Key + "=" + x.Count()))}");
        if (show)
        {
            Console.WriteLine("--- events");
            foreach (var e in events) Console.WriteLine($"{e.T:HH:mm:ss.f} {e.Kind,-4} {e.Track.Amount,7} {e.Track.Role,-9} {e.Reason}{(e.Track.Uncertain ? " (uncertain)" : "")}");
        }
        Console.WriteLine("--- unparsed (most common)");
        foreach (var g in unparsed.GroupBy(x => x).OrderByDescending(g => g.Count()).Take(12)) Console.WriteLine($"{g.Count(),4}  {g.Key}");

        var d = new DateTime(2026, 10, 24);
        var windows = new[]
        {
            ("21:25:14", "21:41:36", new Dictionary<string, long?> { ["infantry"] = 200, ["recon"] = 19, ["medic"] = 250, ["driver"] = 0, ["support"] = 1708, ["pilot"] = 0 }),
            ("21:41:36", "21:53:30", new Dictionary<string, long?> { ["infantry"] = 750, ["recon"] = 150, ["medic"] = 325, ["driver"] = 1025, ["support"] = 180, ["pilot"] = null }),
        };
        foreach (var (from, to, reads) in windows)
        {
            var a = d + TimeSpan.Parse(from); var b = d + TimeSpan.Parse(to);
            Console.WriteLine($"--- XP between reads {from} and {to}: popups vs Wardog Level");
            foreach (var r in Roles.Order)
            {
                long sum = events.Where(e => e.Kind == "xp" && e.Track.Role == r && e.T >= a && e.T < b).Sum(e => (long)e.Track.Amount);
                Console.WriteLine($"  {r,-9} popups {sum,6}   reads {reads[r],6}");
            }
        }
        if (outFile != null)
            File.WriteAllLines(outFile, new[] { "T,Kind,Amount,Reason,Role,Uncertain" }.Concat(events.Select(e => $"{e.T:o},{e.Kind},{e.Track.Amount},{e.Reason},{e.Track.Role},{e.Track.Uncertain}")));
        try { Directory.Delete(data, true); } catch { }
        return 0;
    }
}
