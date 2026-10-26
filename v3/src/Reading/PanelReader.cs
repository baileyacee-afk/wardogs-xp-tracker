using System;
using System.Collections.Generic;
using System.Drawing;
using System.Linq;
using System.Text.RegularExpressions;
using Wardogs.Core;

namespace Wardogs.Reading
{
    // Reads role levels and XP from the in-game "Wardog Level" panel (a 3 x 2 grid of roles).
    public sealed class PanelRead
    {
        public Dictionary<string, RoleProgress> Progress = new();
        public List<string> Order = new();       // roles in the order their labels were found
        public RectangleF? Bounds;               // area (image pixels) covering every word that was used
        public double GridCol, GridRow;          // column / row spacing of the role grid
        public int Count => Progress.Count;
        public string Keys(string sep = ", ") => string.Join(sep, Order);
    }

    // Decides, from a cheap pixel count, when the Wardog Level panel is worth an OCR read. The panel's
    // white text always covers about the same number of pixels (about 2,070 at 1080p; learned from the
    // first good read), while the game scene behind it almost never comes close, so even a quick hover
    // over the level box is caught without running OCR all the time.
    public static class PanelGate
    {
        public const int Burst = 800;   // this much white text at once: probably the panel, even before learning

        // white: strict white-text pixels in the panel box; changed: its layout changed since the last read;
        // since: seconds since the last read; open: the last read found the panel; learned: 0 until learned.
        public static bool ShouldRead(int white, bool changed, double since, bool open, int learned, out bool inRange)
        {
            inRange = learned > 0 && white >= 0.6 * learned && white <= 1.5 * learned;
            if (since < 0.9) return false;
            if (inRange) return !open || changed || since >= 2;          // open: re-read every 2 s
            if (learned == 0 && white >= Burst) return !open || changed || since >= 2;
            // Anything else might still be the panel (a different size, or covered): an ordinary look now and then.
            return white >= 30 && changed && since >= (learned > 0 ? 20 : 10);
        }

        // The learned count after a good read.
        public static int Learn(int learned, int white, bool inRange) => inRange ? (learned * 3 + white) / 4 : white;
    }

    public static class PanelReader
    {
        const RegexOptions I = RegexOptions.IgnoreCase;   // PowerShell's -match / -replace ignore case

        // On-screen label -> role id
        static readonly (string Label, string Role)[] GameRoles =
        {
            ("ASSAULT", "infantry"), ("MEDIC", "medic"), ("SUPPORT", "support"), ("RECON", "recon"), ("DRIVER", "driver"), ("PILOT", "pilot"),
        };

        // "130,627/" -> 130627, "145,400XP" -> 145400, "2O" -> 20. null if it isn't a number.
        public static int? GameNumber(string text)
        {
            var t = Regex.Replace(text, "xp$", "", I);
            t = Regex.Replace(t, @"[,./\s]", "", I);
            t = Regex.Replace(t, "[Oo]", "0", I); t = Regex.Replace(t, "[Il|]", "1", I);
            t = Regex.Replace(t, "S", "5", I); t = Regex.Replace(t, "B", "8", I);
            return Regex.IsMatch(t, @"^\d{1,9}$") ? int.Parse(t) : null;
        }

        // Which role a word names, allowing one OCR slip ("SUPP0RT", "PILOT|", "Recon"); null if none.
        public static string RoleFromLabel(string text)
        {
            var t = text.ToUpper().Replace("0", "O").Replace("1", "I").Replace("5", "S").Replace("8", "B");
            t = Regex.Replace(t, "[^A-Z]", "");
            if (t.Length < 4 || t.Length > 9) return null;
            foreach (var (label, role) in GameRoles) if (label == t) return role;
            foreach (var (label, role) in GameRoles)
                if (Math.Abs(label.Length - t.Length) <= 1 && PixelMath.EditDistance(t, label) <= 1) return role;
            return null;
        }

        sealed class Line { public double Mid, H; public List<OcrWord> Parts = new(); }

        public static PanelRead Read(List<OcrWord> words)
        {
            var res = new PanelRead();
            // Role-name labels. (Our own window also shows role names, but it's hidden while we take screenshots.)
            var labels = words.Select(w => (Word: w, Role: RoleFromLabel(w.Text))).Where(x => x.Role != null).ToList();
            var usedLabels = new List<OcrWord>();

            foreach (var (label, role) in labels)
            {
                if (res.Progress.ContainsKey(role)) continue;

                // Words in this label's column: the nearest label above them (same column) is this one.
                double tol = label.W + 10;
                var mine = words.Where(w =>
                {
                    if (w.Y <= label.Y || Math.Abs(w.CX - label.CX) > tol) return false;
                    var owner = labels.Where(l => l.Word.Y < w.Y && Math.Abs(w.CX - l.Word.CX) <= l.Word.W + 10)
                                      .OrderByDescending(l => l.Word.Y).Select(l => l.Word).FirstOrDefault();
                    return ReferenceEquals(owner, label);
                }).OrderBy(w => w.Y).ToList();

                // OCR sometimes splits one number ("278,152 /" -> "278," "152/"). Rejoin pieces that sit on the
                // same line, left to right, so they aren't read as separate numbers in the wrong order.
                var lines = new List<Line>();
                foreach (var w in mine)
                {
                    double mid = w.Y + w.H / 2;
                    var line = lines.FirstOrDefault(l => Math.Abs(mid - l.Mid) < Math.Max(w.H, l.H) * 0.6);
                    if (line != null) line.Parts.Add(w); else { line = new Line { Mid = mid, H = w.H }; line.Parts.Add(w); lines.Add(line); }
                }
                var merged = lines.OrderBy(l => l.Mid).Select(l =>
                {
                    var parts = l.Parts.OrderBy(p => p.X).ToList();
                    double x1 = parts.Min(p => p.X), x2 = parts.Max(p => p.X + p.W);
                    return new OcrWord(string.Concat(parts.Select(p => p.Text)), x1, parts.Min(p => p.Y), x2 - x1, parts.Max(p => p.H));
                }).ToList();

                int? level = null; long? xp = null, next = null; var used = new List<OcrWord>();
                foreach (var w in merged)
                {
                    // OCR sometimes reads the "/" after the XP as a 1 ("51,813/" -> "51.8131"): a full group of
                    // three digits followed by one more character is that slash.
                    var text = w.Text;
                    var slash = Regex.Match(text, @"^(\d{1,3}(?:[,.]\d{3})+)[1lI|]$");
                    if (slash.Success) text = slash.Groups[1].Value + "/";
                    var n = GameNumber(text);
                    if (n == null) continue;
                    if (Regex.IsMatch(text, "xp$", I)) { if (next == null) { next = n; used.Add(w); } }
                    else if (level == null && xp == null && !Regex.IsMatch(text, "[,/]") && n <= 300) { level = n; used.Add(w); }
                    // The XP ("51,982 /") counts even when the level above it couldn't be read.
                    else if (xp == null && (level != null || Regex.IsMatch(text, "[,/]"))) { xp = n; used.Add(w); }
                }
                if (level == null && xp == null) continue;
                if (xp != null && next != null && xp > next) xp = null;   // misread, don't trust it
                res.Progress[role] = new RoleProgress { Level = level, Xp = xp, NextXp = next };
                res.Order.Add(role);
                usedLabels.Add(label);

                foreach (var w in new[] { label }.Concat(used))
                {
                    var r = new RectangleF((float)w.X, (float)w.Y, (float)w.W, (float)w.H);
                    res.Bounds = res.Bounds == null ? r : RectangleF.Union(res.Bounds.Value, r);
                }
            }

            // Measure the grid's column and row spacing from the labels that were read (or estimate it),
            // so a box around a partial read can be widened to the whole grid.
            if (usedLabels.Count > 0)
            {
                double maxW = usedLabels.Max(l => l.W), maxH = usedLabels.Max(l => l.H);
                static double? Gap(IEnumerable<double> values, double minGap)
                {
                    var v = values.OrderBy(x => x).ToList(); var d = new List<double>();
                    for (int i = 1; i < v.Count; i++) if (v[i] - v[i - 1] > minGap) d.Add(v[i] - v[i - 1]);
                    return d.Count > 0 ? d.Min() : null;
                }
                res.GridCol = Gap(usedLabels.Select(l => l.CX), maxW * 0.8) ?? 2.4 * maxW;
                res.GridRow = Gap(usedLabels.Select(l => l.Y), maxH * 2) ?? 1.1 * res.Bounds.Value.Height;
            }
            return res;
        }
    }
}
