using System;
using System.Collections.Generic;
using System.Drawing;
using System.Drawing.Imaging;
using System.IO;
using System.Linq;
using System.Text.RegularExpressions;
using Wardogs.Core;

namespace Wardogs.Reading
{
    // Live popup reader.
    //
    // Watches the list of XP and cash popups under the game's top-right cash boxes and reports each new
    // row once: XP (with the class it went to) or cash, the amount and the reason shown.
    //
    // What the popups look like (from recorded games):
    //   "KILL  250XP <class symbol>"     XP rows end with the class symbol (Assault arrowhead, Medic cross,
    //   "CONTROL ZONE PRESENCE  +$160"   Support wrench, Recon crosshair, Driver wheel, Pilot wings).
    //   New rows fade in at the bottom (about 21 px apart at 1080p) and stay ~5 s; the newest amount
    //   briefly sits on a white highlight. Cash rows have no class symbol.
    //
    // Keeping it cheap: each poll grabs only the popup area and compares a fingerprint of its white text
    // with the previous one; OCR (the expensive part) only runs when the text changed.
    public static class PopupTuning
    {
        public const int WhiteMin = 185;        // popup text pixels: every channel at least this bright...
        public const int WhiteSpread = 60;      // ...and nearly grey
        public const int GateWhite = 235;       // the change check only looks at pure white (popup text), not light sky
        public const int GateSpread = 20;
        public const double GateDiff = 0.05;    // white-text fingerprint change that triggers OCR
        public const double ForceOcr = 1.5;     // seconds: OCR anyway this often while popups are showing
        public const double MinOcrGap = 0.5;    // seconds: never OCR more often than this (rows stay up 5+ s)
        public const double OcrScale = 3;       // popup text is small: enlarge this much before OCR
        public const double RowGone = 2.5;      // seconds unseen (not even as garbled text) before a row counts as gone
        public const double RowLife = 6;        // seconds a row normally stays (kill rows can linger ~8 s)
        public const double RowMaxAge = 12;     // no row stays longer than this; an "older" one is really a new identical row
        public const double Flash = 0.5;        // white share of the amount box that means "just added" highlight
        public const int GlyphSize = 16;
        public const int LearnMax = 40;         // symbol examples kept per class
    }

    public sealed class PopupRow
    {
        public string Kind = "unparsed";   // xp | cash | unparsed | other
        public int? Amount;
        public string Reason;
        public bool Uncertain;
        public string Hint;
        public double Y, H;
        public bool Flash;
        public double[] Glyph;
        public string Text;
        public OcrWord AmountWord;
    }

    public sealed class PopupTrack
    {
        public int Id;
        public string Kind, Reason, Role;
        public int Amount;
        public bool Uncertain;
        public readonly List<KeyValuePair<string, int>> Votes = new();
        public DateTime Born, LastSeen;
        public double Y;
        public bool Flash;
        public int? EventId;
    }

    public static class Popups
    {
        const RegexOptions I = RegexOptions.IgnoreCase;   // PowerShell's -match / -replace ignore case

        // Reasons that always go to one class, so the symbol only matters for the others.
        public static readonly Dictionary<string, string> ReasonRoles = new(StringComparer.OrdinalIgnoreCase)
        {
            ["KILL ASSIST"] = "infantry", ["TARGET SPOTTED REFRESHED"] = "recon", ["TACTICAL DEPLOYMENT"] = "pilot",
            ["KILL"] = "infantry", ["BUILDING COMPLETE"] = "support", ["SPOTTED TARGET DESTROYED"] = "recon",
            ["REVIVED TEAMMATE"] = "medic", ["REVIVED PLAYER ASSIST"] = "medic", ["BUILDING"] = "support",
            ["SUPPLIES DEPOSITED"] = "support",
            ["TARGET SPOTTED"] = "recon", ["SPOTTED VEHICLE DESTROYED"] = "recon",
            ["HEALED TEAMMATE"] = "medic", ["HELPED REVIVE TEAMMATE"] = "medic",
        };
        // Reasons shared by a few classes: the symbol decides between these.
        public static readonly Dictionary<string, string[]> ReasonChoices = new(StringComparer.OrdinalIgnoreCase)
        {
            ["PASSENGER SURVIVED"] = new[] { "driver", "pilot" }, ["SUPPLIES DELIVERED"] = new[] { "driver", "pilot" },
        };
        // Other XP reasons seen in matches; the symbol decides the class.
        static readonly string[] OtherXpReasons =
        {
            "APPLIED STIM", "BUILDABLE DESTROYED", "BUILDABLE DESTROYED ASSIST", "DESTROYED SUPPLY CRATE", "ARTILLERY KILL",
            "FOB SUPPLIED ASSIST", "FOB HACKED", "ROUND TRIP", "SHUTDOWN KILL", "HEADSHOT KILL", "REVENGE KILL",
            "VEHICLE DESTROYED", "VEHICLE DESTROYED ASSIST", "TRACKS DESTROYED", "MAGNET ACTIVATED", "DANGEROUS DUD",
            "SPAWN VEHICLE DELIVERED",
        };
        // Reasons that only ever pay cash. One of these read as XP is a misread "+$160" ("560") next to a
        // small icon, never real XP.
        public static readonly HashSet<string> CashOnlyReasons = new(StringComparer.OrdinalIgnoreCase)
        {
            "CONTROL ZONE ENTERED", "CONTROL ZONE PRESENCE", "HOTZONE PRESENCE", "VEHICLE REFUELLING", "AIR TIME BONUS",
            "WAITED TO BE REVIVED", "SUPPLIES DESTROYED",
        };
        // Every reason seen so far, used to clean up OCR spelling ("BUILDIN" -> "BUILDING"). The first ones
        // are in the PowerShell version's order, so ties resolve the same way.
        static readonly string[] KnownReasons =
        {
            "KILL ASSIST", "TARGET SPOTTED REFRESHED", "TACTICAL DEPLOYMENT", "KILL", "BUILDING COMPLETE", "SPOTTED TARGET DESTROYED",
            "REVIVED TEAMMATE", "REVIVED PLAYER ASSIST", "BUILDING", "SUPPLIES DEPOSITED", "PASSENGER SURVIVED", "SUPPLIES DELIVERED",
            "CONTROL ZONE ENTERED", "CONTROL ZONE PRESENCE", "HOTZONE PRESENCE", "VEHICLE REFUELLING", "AIR TIME BONUS",
            "WAITED TO BE REVIVED", "SUPPLIES DESTROYED",
            "TARGET SPOTTED", "SPOTTED VEHICLE DESTROYED", "HEALED TEAMMATE", "HELPED REVIVE TEAMMATE",
            "APPLIED STIM", "BUILDABLE DESTROYED", "BUILDABLE DESTROYED ASSIST", "DESTROYED SUPPLY CRATE", "ARTILLERY KILL",
            "FOB SUPPLIED ASSIST", "FOB HACKED", "ROUND TRIP", "SHUTDOWN KILL", "HEADSHOT KILL", "REVENGE KILL",
            "VEHICLE DESTROYED", "VEHICLE DESTROYED ASSIST", "TRACKS DESTROYED", "MAGNET ACTIVATED", "DANGEROUS DUD",
            "SPAWN VEHICLE DELIVERED",
        };

        // A reason known to give XP (so a number next to a class symbol can be read as XP without the "XP").
        public static bool IsXpReason(string reason) =>
            reason != null && (ReasonRoles.ContainsKey(reason) || ReasonChoices.ContainsKey(reason) || OtherXpReasons.Contains(reason, StringComparer.OrdinalIgnoreCase));
        // OCR's guess at a symbol when it reads it as a character after "XP".
        static readonly Dictionary<string, string> SymbolHints = new(StringComparer.OrdinalIgnoreCase) { ["A"] = "infantry", ["+"] = "medic", ["&"] = "support" };

        // ------------------------------------------------------------ areas
        // Default popup area: just under the cash boxes at the top right (fractions of the game window).
        public static Rectangle PopupRect(string setting)
        {
            var r = GameScreen.ParseRect(setting);
            if (!r.IsEmpty) return r;
            var g = GameScreen.GameRect();
            return new Rectangle(Num.R(g.X + g.Width * 0.805), Num.R(g.Y + g.Height * 0.045), Num.R(g.Width * 0.19), Num.R(g.Height * 0.21));
        }

        // The cash boxes at the very top right (this life's cash, banked cash; level on menus).
        public static Rectangle CashRect()
        {
            var g = GameScreen.GameRect();
            return new Rectangle(Num.R(g.X + g.Width * 0.78), g.Y, Num.R(g.Width * 0.21), Num.R(g.Height * 0.055));
        }

        // ------------------------------------------------------------ reading rows
        static readonly Dictionary<string, string> reasonCache = new();
        static readonly object cacheSync = new object();

        public static string ReasonName(string text)
        {
            var t = Regex.Replace(Regex.Replace(text.ToUpper(), "[^A-Z ]", "", I), @"\s+", " ").Trim();
            if (t.Length < 3) return null;
            lock (cacheSync) if (reasonCache.TryGetValue(t, out var hit)) return hit;
            // Compare without spaces: OCR often drops or adds them ("SUPPLIESJELKRED" -> SUPPLIES DELIVERED).
            var flat = t.Replace(" ", "");
            string best = null; int bestD = 99;
            foreach (var k in KnownReasons)
            {
                var kf = k.Replace(" ", "");
                if (Math.Abs(kf.Length - flat.Length) > Math.Max(3, Num.R(kf.Length * 0.35))) continue;
                int d = PixelMath.EditDistance(flat, kf);
                if (d < bestD) { bestD = d; best = k; }
            }
            var name = best != null && bestD <= Math.Max(1, Num.R(best.Replace(" ", "").Length * 0.3)) ? best : t;
            lock (cacheSync) if (reasonCache.Count < 2000) reasonCache[t] = name;
            return name;
        }

        // "250" -> 250, "8" -> 8, "2O" -> 20, "e"/"a" (a lone misread 8) -> 8. null if not a number.
        public static int? PopupNumber(string text)
        {
            var t = Regex.Replace(text ?? "", @"[,\.\s]", "", I);
            if (t.Equals("e", StringComparison.OrdinalIgnoreCase) || t.Equals("a", StringComparison.OrdinalIgnoreCase)) return 8;
            t = Regex.Replace(t, "[Oo]", "0", I); t = Regex.Replace(t, "[Il|]", "1", I);
            t = Regex.Replace(t, "S", "5", I); t = Regex.Replace(t, "B", "8", I);
            return Regex.IsMatch(t, @"^\d{1,7}$") ? int.Parse(t) : null;
        }

        static string Join(IEnumerable<OcrWord> ws, string sep = " ") => string.Join(sep, ws.Select(w => w.Text));

        sealed class RowLine { public double Mid, H; public List<OcrWord> Words = new(); }

        // Groups OCR words into popup rows and parses each one.
        public static List<PopupRow> Rows(Bitmap bmp, List<OcrWord> words)
        {
            var lines = new List<RowLine>();
            foreach (var w in words.OrderBy(w => w.Y + w.H / 2))
            {
                double mid = w.Y + w.H / 2;
                var line = lines.FirstOrDefault(l => Math.Abs(mid - l.Mid) < Math.Max(w.H, l.H) * 0.6);
                if (line != null) line.Words.Add(w); else { line = new RowLine { Mid = mid, H = w.H }; line.Words.Add(w); lines.Add(line); }
            }
            var rows = new List<PopupRow>();
            foreach (var line in lines)
            {
                var ws = line.Words.OrderBy(w => w.X).ToList();
                var text = Join(ws);
                double h = ws.Max(w => w.H);
                var row = new PopupRow { Y = ws.Min(w => w.Y), H = h, Text = text };
                // No digits: a prompt, or a row still fading in. "/" or several numbers: the Wardog Level
                // screen showing through. Either way not a popup to read, but it shows the row is there.
                if (!Regex.IsMatch(text, @"\d") || Regex.IsMatch(text, @"\d\s*/") || ws.Count(w => Regex.IsMatch(w.Text, @"^\D?\d[\d,]{1,}", I)) >= 2)
                {
                    row.Kind = "other"; rows.Add(row); continue;
                }

                // XP: "250XP", "250 XP", "8xp"
                int xi = ws.FindIndex(w => Regex.IsMatch(w.Text, "xp", I));
                if (xi >= 0)
                {
                    var tok = Regex.Replace(ws[xi].Text, "xp.*$", "", I);
                    int amtIdx = xi;
                    if (tok.Length == 0 && xi > 0) { tok = ws[xi - 1].Text; amtIdx = xi - 1; }
                    var n = PopupNumber(Regex.Replace(tok, @"^[+*]", "", I));
                    var reason = ReasonName(Join(ws.Take(amtIdx)));
                    if (n != null && !string.IsNullOrEmpty(reason))
                    {
                        row.Kind = "xp"; row.Amount = n; row.Reason = reason; row.AmountWord = ws[xi];
                        var after = Join(ws.Skip(xi + 1), "");
                        var tail = Regex.Replace(ws[xi].Text, "^.*?xp", "", I) + after;
                        if (tail.Length > 0)
                        {
                            var tt = tail.Trim();
                            if (tt.Length > 0 && SymbolHints.TryGetValue(tt[0].ToString(), out var hint)) row.Hint = hint;
                        }
                    }
                }
                else
                {
                    // Cash: "+$160", "-$20", "*$250" (OCR reads + as * or a bullet)
                    int di = ws.FindIndex(w => w.Text.Contains('$'));
                    if (di >= 0)
                    {
                        var parts = ws[di].Text.Split('$', 2);
                        var sign = parts[0]; int amtIdx = di;
                        if (sign.Length == 0 && di > 0 && Regex.IsMatch(ws[di - 1].Text, "^[+\\-*•~]$", I)) { sign = ws[di - 1].Text; amtIdx = di - 1; }
                        var n = PopupNumber(Regex.Replace(parts.Length > 1 ? parts[1] : "", @"[^\dOoIlSB,\.].*$", "", I));
                        var reason = ReasonName(Join(ws.Take(amtIdx)));
                        if (n != null && !string.IsNullOrEmpty(reason))
                        {
                            row.Kind = "cash"; row.Amount = Regex.IsMatch(sign, "[-~]") ? -n : n; row.Reason = reason; row.AmountWord = ws[di];
                        }
                    }
                    else
                    {
                        // A signed amount with its "$" misread as a digit ("+$160" -> "+560", "+$40" -> "+940").
                        var last = ws[^1].Text;
                        var m = Regex.Match(last, "^(?<s>[+\\-*•~'])(?<n>[\\dSO,]{2,})$", I);
                        if (m.Success && ws.Count >= 2)
                        {
                            var digits = m.Groups["n"].Value.Replace(",", "");
                            var n = PopupNumber(digits.Substring(1));
                            var reason = ReasonName(Join(ws.Take(ws.Count - 1)));
                            if (n != null && !string.IsNullOrEmpty(reason))
                            {
                                row.Kind = "cash"; row.Amount = Regex.IsMatch(m.Groups["s"].Value, "[-~]") ? -n : n;
                                row.Reason = reason; row.Uncertain = true; row.AmountWord = ws[^1];
                            }
                        }
                    }
                }

                // The word holding the amount: as parsed, or for an unreadable row the last word with digits.
                var a = row.AmountWord ?? ws.LastOrDefault(w => Regex.IsMatch(w.Text, @"\d"));
                if (a != null)
                {
                    var box = new Rectangle(Num.R(a.X - 0.2 * h), Num.R(a.Y - 0.2 * h), Num.R(a.W + 0.4 * h), Num.R(a.H + 0.4 * h));
                    row.Flash = PixelMath.WhiteFraction(bmp, box, PopupTuning.WhiteMin, PopupTuning.WhiteSpread) > PopupTuning.Flash;
                    // A white class symbol right of the amount means XP (cash rows have none, or a coloured marker).
                    var sym = new Rectangle(Num.R(a.X + a.W + 0.6 * h), Num.R(a.Y - 0.35 * h), Num.R(2.4 * h), Num.R(1.7 * h));
                    var glyph = PixelMath.Glyph(bmp, sym, PopupTuning.GlyphSize, PopupTuning.WhiteMin, PopupTuning.WhiteSpread);
                    if (glyph != null && Symbols.LooksLikeSymbol(glyph)) row.Glyph = glyph;
                    // OCR lost the "XP" ("KILL 2505P*", "BUILDING 8"), but the symbol is there: read it as XP.
                    // Only for reasons known to give XP: a garbled reason next to a small icon is just as often
                    // a cash row whose "$" was misread ("CONTROL ZONE PRESENCE +$160" -> "ZNE PRE 560").
                    if (row.Glyph != null && row.Kind != "xp" && !text.Contains('$'))
                    {
                        var tok = Regex.Replace(a.Text, "^[+*•]", "", I);
                        string num = null;
                        var m1 = Regex.Match(tok, @"^(?<n>\d{1,4}?)[5S]?[XxPpF]{1,2}\W*$", I);
                        if (m1.Success) num = m1.Groups["n"].Value;
                        else { var m2 = Regex.Match(tok, @"^(?<n>\d{1,4})\W*$", I); if (m2.Success) num = m2.Groups["n"].Value; }
                        var reason = ReasonName(Join(ws.Where(w => w.X < a.X)));
                        if (!string.IsNullOrEmpty(num) && IsXpReason(reason))
                        {
                            row.Kind = "xp"; row.Amount = int.Parse(num); row.Reason = reason; row.AmountWord = a; row.Uncertain = false;
                        }
                    }
                    // ...and a "cash" row with a class symbol is really an XP row with a misread amount.
                    if (row.Glyph != null && row.Kind == "cash" && row.Uncertain) row.Kind = "unparsed";
                }
                // Reasons that only pay cash are never XP, however the amount was read.
                if (row.Kind == "xp" && CashOnlyReasons.Contains(row.Reason)) row.Kind = "unparsed";
                rows.Add(row);
            }
            return rows;
        }

        // Whether any popup text is showing. Uses the looser text test: some popups (kills) aren't pure white,
        // so the strict change check can't see them.
        public static bool AnyShowing(Bitmap bmp) =>
            PixelMath.Sum(PixelMath.WhiteGrid(bmp, 24, 16, PopupTuning.WhiteMin, PopupTuning.WhiteSpread)) >= 20;

        // Reads the popup rows in a capture of the popup area. To keep OCR cheap it only reads the band of
        // rows that have text in them (usually one to three popups, not the whole area).
        public static List<PopupRow> ReadArea(Bitmap bmp)
        {
            const int gh = 16;
            var grid = PixelMath.WhiteGrid(bmp, 1, gh, PopupTuning.WhiteMin, PopupTuning.WhiteSpread);
            var withText = Enumerable.Range(0, gh).Where(i => grid[i] >= 4).ToList();
            if (withText.Count == 0) return new List<PopupRow>();
            double cell = bmp.Height / (double)gh;
            int top = Num.R(Math.Max(0, (withText[0] - 1) * cell));
            int bottom = Num.R(Math.Min(bmp.Height, (withText[^1] + 2) * cell));
            if (bottom - top < 8) return new List<PopupRow>();
            using var band = bmp.Clone(new Rectangle(0, top, bmp.Width, bottom - top), PixelFormat.Format24bppRgb);
            var rows = Rows(band, Ocr.Read(band, PopupTuning.OcrScale));
            foreach (var r in rows) r.Y += top;   // back to popup-area coordinates
            return rows;
        }

        // ------------------------------------------------------------ the cash boxes
        static readonly Regex CashAmount = new Regex(@"(?<s>-?)\s*\$\s*(?<n>\d{1,3}(?:[,\.]\d{3})*)(?![\d,\.]*\d)");

        // Reads the cash shown at the top right while playing: this life's cash (resets on death, negative
        // after buying gear) and banked cash (live). null when they can't be read. Menus and the results
        // screen show them in boxes next to the Wardog level; those are skipped (OCR rarely reads the boxes,
        // and the results screen's first box is the match's cash, not this life's).
        public static (long Life, long Banked)? ReadCashHud(Bitmap bmp)
        {
            var words = Ocr.Read(bmp, 3).OrderBy(w => w.X).ToList();
            var text = Join(words);
            var amounts = new List<long>();
            foreach (Match m in CashAmount.Matches(text))
            {
                var n = PopupNumber(m.Groups["n"].Value);
                if (n != null) amounts.Add(m.Groups["s"].Value.Length > 0 ? -n.Value : n.Value);
            }
            var tail = words.LastOrDefault()?.Text;
            if (!string.IsNullOrEmpty(tail) && !tail.Contains('$') && Regex.IsMatch(tail, @"^\d{1,3}$")) return null;   // Wardog level box: a menu
            if (amounts.Count != 2 || amounts[1] < 0) return null;
            return (amounts[0], amounts[1]);
        }
    }

    // ---------------------------------------------------------------- class symbols
    // Templates of each class's symbol: learned from this screen (symbols.json) once there are a few
    // examples, else rendered from the tracker's own drawings.
    public static class Symbols
    {
        static readonly object sync = new object();
        static string path;
        static Dictionary<string, (int N, double[] Sum)> bank = new();
        static Dictionary<string, double[]> drawn = new();

        sealed class Saved { public int N { get; set; } public double[] Sum { get; set; } }

        // drawnGlyphs: each role's drawing as a glyph (rendered by the UI layer, which owns the drawings).
        public static void Init(string dataDir, Dictionary<string, double[]> drawnGlyphs)
        {
            lock (sync)
            {
                path = Path.Combine(dataDir, "symbols.json");
                drawn = drawnGlyphs;
                bank = new();
                try
                {
                    var saved = Json.Read<Dictionary<string, Saved>>(path);
                    if (saved != null) foreach (var kv in saved) if (kv.Value?.Sum != null) bank[kv.Key] = (kv.Value.N, kv.Value.Sum.ToArray());
                }
                catch { }
            }
        }

        static void Save()
        {
            var o = bank.ToDictionary(kv => kv.Key, kv => new Saved { N = kv.Value.N, Sum = kv.Value.Sum.Select(v => Math.Round(v, 3)).ToArray() });
            try { System.IO.File.WriteAllText(path, System.Text.Json.JsonSerializer.Serialize(o)); } catch { }
        }

        public static double[] Template(string role)
        {
            lock (sync)
            {
                if (bank.TryGetValue(role, out var b) && b.N >= 3) return b.Sum.Select(v => v / b.N).ToArray();
                return drawn.GetValueOrDefault(role);
            }
        }

        // Remembers what a class's symbol looks like on this screen (from rows whose reason names the class).
        public static void AddExample(string role, double[] glyph)
        {
            if (glyph == null || string.IsNullOrEmpty(role)) return;
            lock (sync)
            {
                if (!bank.TryGetValue(role, out var b)) b = (0, new double[glyph.Length]);
                if (b.N >= PopupTuning.LearnMax) return;
                for (int i = 0; i < glyph.Length; i++) b.Sum[i] += glyph[i];
                b.N++;
                bank[role] = b;
                if (b.N == 3 || b.N % 10 == 0) Save();
            }
        }

        // True when white pixels right of an amount look like one of the class symbols (not sky or snow).
        public static bool LooksLikeSymbol(double[] glyph) =>
            Roles.Order.Any(r => PixelMath.Similarity(glyph, Template(r)) >= 0.5);

        // Which class an XP row went to: by reason when that's certain, else by its symbol.
        public static string RoleFor(PopupRow row)
        {
            if (Popups.ReasonRoles.TryGetValue(row.Reason, out var role))
            {
                AddExample(role, row.Glyph);
                return role;
            }
            bool narrowed = Popups.ReasonChoices.TryGetValue(row.Reason, out var narrowedTo);
            var choices = narrowed ? narrowedTo : Roles.Order;
            bool hintOk = row.Hint != null && choices.Contains(row.Hint, StringComparer.OrdinalIgnoreCase);
            if (row.Glyph == null) return hintOk ? row.Hint : null;
            var best = choices.Select(r => (Role: r, S: PixelMath.Similarity(row.Glyph, Template(r)))).OrderByDescending(x => x.S).First();
            if (best.S < 0.55 && hintOk) return row.Hint;
            // When the reason already narrows it to two or three classes, the closer symbol is enough.
            if (best.S < (narrowed ? 0.25 : 0.45)) return null;
            return best.Role;
        }
    }

    // ---------------------------------------------------------------- following rows between polls
    public sealed class PopupTracker
    {
        public readonly List<PopupTrack> Tracks = new();
        int nextId = 1;

        public void Reset() => Tracks.Clear();

        // Keeps followed rows alive while the popup area hasn't changed (no OCR this poll).
        public void Seen(DateTime now) { foreach (var t in Tracks) t.LastSeen = now; }

        public bool NearTrack(PopupRow row) => Tracks.Any(t => Math.Abs(t.Y - row.Y) < 0.8 * row.H);

        static bool SameRow(PopupTrack t, PopupRow r)
        {
            if (t.Kind != r.Kind) return false;
            if (!string.Equals(t.Reason, r.Reason, StringComparison.OrdinalIgnoreCase) && PixelMath.EditDistance(t.Reason, r.Reason) > 3) return false;
            if (r.Uncertain || t.Amount == r.Amount) return true;
            var a = Math.Abs((long)t.Amount).ToString(); var b = Math.Abs((long)(r.Amount ?? 0)).ToString();
            int d = PixelMath.EditDistance(a, b);
            // one misread digit is still the same row; two, when the frame was too faint to show the symbol
            return d <= 1 || (r.Kind == "xp" && r.Glyph == null && a.Length == b.Length && d <= 2);
        }

        // Readings are voted on: a cash reading with a proper "$" outweighs one where "$" was misread.
        static bool Vote(PopupTrack t, PopupRow r)
        {
            var k = (r.Amount ?? 0).ToString();
            int w = r.Uncertain ? 1 : 3;
            int i = t.Votes.FindIndex(v => v.Key == k);
            if (i >= 0) t.Votes[i] = new(k, t.Votes[i].Value + w); else t.Votes.Add(new(k, w));
            if (!r.Uncertain) t.Uncertain = false;
            int top = t.Votes.Max(v => v.Value);
            // Ties keep the current amount, so a row doesn't flip back and forth.
            var best = t.Votes.Any(v => v.Value == top && v.Key == t.Amount.ToString()) ? t.Amount.ToString() : t.Votes.First(v => v.Value == top).Key;
            bool changed = int.Parse(best) != t.Amount;
            t.Amount = int.Parse(best);
            return changed;
        }

        // Matches this poll's rows (top to bottom) with the rows already being followed.
        // New rows join at the bottom and old ones leave from the top, so this finds how many left from the
        // top (s) such that the remaining tracks line up with the first rows; anything after that is new.
        public (List<PopupTrack> New, List<PopupTrack> Changed) Update(List<PopupRow> allRows, DateTime now)
        {
            var rows = allRows.Where(r => r.Kind == "xp" || r.Kind == "cash").OrderBy(r => r.Y).ToList();
            // Any text where a followed row is (even an unreadable frame of it) means it's still on screen.
            foreach (var t in Tracks)
                if (allRows.Any(r => Math.Abs(r.Y - t.Y) < 0.8 * r.H)) t.LastSeen = now;
            Tracks.RemoveAll(t => (now - t.LastSeen).TotalSeconds > PopupTuning.RowGone || (now - t.Born).TotalSeconds > PopupTuning.RowMaxAge);
            var tracks = Tracks.OrderBy(t => t.Y).ToList();
            int m = tracks.Count, n = rows.Count;

            var valid = new List<int>();
            for (int sh = 0; sh <= m; sh++)
            {
                int k = Math.Min(m - sh, n), bad = 0;
                for (int i = 0; i < k; i++) if (!SameRow(tracks[sh + i], rows[i])) bad++;
                if (bad == 0 || (k >= 3 && bad == 1)) valid.Add(sh);
            }
            int? s = null;
            if (valid.Count > 0)
            {
                s = valid[0];
                // The same rows can line up two ways when one left and an identical one arrived: prefer the
                // shift when the top row has been up longer than rows normally stay, or the bottom row is
                // newly highlighted. Only a shift by exactly one row that still lines up rows counts (a shift
                // that compares nothing always "fits").
                int sv = s.Value;
                int? next = valid.Where(v => v == sv + 1 && Math.Min(m - v, n) >= 1).Select(v => (int?)v).FirstOrDefault();
                if (next != null && sv < m)
                {
                    bool old = (now - tracks[sv].Born).TotalSeconds > PopupTuning.RowLife;
                    var lastRow = n > 0 ? rows[n - 1] : null;
                    var lastTrack = m - sv - 1 < n && m - sv - 1 >= 0 ? tracks[m - 1] : null;
                    bool flash = lastRow != null && lastRow.Flash && lastTrack != null && !lastTrack.Flash && (now - lastTrack.Born).TotalSeconds > 1.0;
                    if (old || flash) s = next;
                }
            }

            var fresh = new List<PopupRow>(); var changed = new List<PopupTrack>();
            if (s != null)
            {
                int sv = s.Value, k = Math.Min(m - sv, n);
                for (int i = 0; i < k; i++)
                {
                    var t = tracks[sv + i]; var r = rows[i];
                    t.Y = r.Y; t.LastSeen = now; t.Flash = r.Flash;
                    if (Vote(t, r)) changed.Add(t);
                }
                for (int i = 0; i < sv; i++) Tracks.Remove(tracks[i]);
                if (n > k) fresh.AddRange(rows.Skip(k));
            }
            else
            {
                // Nothing lines up (several misreads at once): only rows unlike any followed row are new.
                var used = new HashSet<int>();
                foreach (var r in rows)
                {
                    var t = tracks.FirstOrDefault(x => !used.Contains(x.Id) && Math.Abs(x.Y - r.Y) <= 2.5 * r.H && SameRow(x, r));
                    if (t != null) { used.Add(t.Id); t.Y = r.Y; t.LastSeen = now; t.Flash = r.Flash; if (Vote(t, r)) changed.Add(t); }
                    else fresh.Add(r);
                }
            }
            var added = new List<PopupTrack>();
            foreach (var r in fresh)
            {
                var t = new PopupTrack { Id = nextId++, Kind = r.Kind, Reason = r.Reason, Amount = r.Amount ?? 0, Uncertain = r.Uncertain, Born = now, LastSeen = now, Y = r.Y, Flash = r.Flash };
                Vote(t, r);
                if (r.Kind == "xp") t.Role = Symbols.RoleFor(r);
                Tracks.Add(t);
                added.Add(t);
            }
            return (added, changed);
        }
    }
}
