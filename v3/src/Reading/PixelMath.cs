using System;
using System.Drawing;
using System.Drawing.Imaging;
using System.Runtime.InteropServices;

namespace Wardogs.Reading
{
    // Pixel helpers for the popups and panels. White HUD text = bright and nearly grey.
    public static class PixelMath
    {
        static byte[] Pixels(Bitmap bmp, out int stride)
        {
            var data = bmp.LockBits(new Rectangle(0, 0, bmp.Width, bmp.Height), ImageLockMode.ReadOnly, PixelFormat.Format24bppRgb);
            stride = data.Stride;
            var buf = new byte[stride * bmp.Height];
            Marshal.Copy(data.Scan0, buf, 0, buf.Length);
            bmp.UnlockBits(data);
            return buf;
        }

        static bool White(byte[] p, int i, int minV, int maxSpread)
        {
            int b = p[i], g = p[i + 1], r = p[i + 2];
            int mx = Math.Max(r, Math.Max(g, b)), mn = Math.Min(r, Math.Min(g, b));
            return mn >= minV && mx - mn <= maxSpread;
        }

        // White-text pixels per cell of a gw x gh grid: a fingerprint of the text that ignores the
        // moving game world behind it.
        public static int[] WhiteGrid(Bitmap bmp, int gw, int gh, int minV, int maxSpread)
        {
            var p = Pixels(bmp, out int stride);
            var grid = new int[gw * gh];
            for (int y = 0; y < bmp.Height; y++)
            {
                int gy = y * gh / bmp.Height;
                for (int x = 0; x < bmp.Width; x++)
                    if (White(p, y * stride + x * 3, minV, maxSpread)) grid[gy * gw + x * gw / bmp.Width]++;
            }
            return grid;
        }

        // 0 = same text layout, 1 = completely different.
        public static double GridDiff(int[] a, int[] b)
        {
            if (a == null || b == null || a.Length != b.Length) return 1;
            long d = 0, t = 0;
            for (int i = 0; i < a.Length; i++) { d += Math.Abs(a[i] - b[i]); t += a[i] + b[i]; }
            return t == 0 ? 0 : (double)d / t;
        }

        public static int Sum(int[] a) { int s = 0; if (a != null) foreach (var v in a) s += v; return s; }

        // Share of white pixels inside r (a highlighted amount sits on a solid white box).
        public static double WhiteFraction(Bitmap bmp, Rectangle r, int minV, int maxSpread)
        {
            r.Intersect(new Rectangle(0, 0, bmp.Width, bmp.Height));
            if (r.Width <= 0 || r.Height <= 0) return 0;
            var p = Pixels(bmp, out int stride);
            int n = 0;
            for (int y = r.Top; y < r.Bottom; y++)
                for (int x = r.Left; x < r.Right; x++)
                    if (White(p, y * stride + x * 3, minV, maxSpread)) n++;
            return (double)n / (r.Width * r.Height);
        }

        // White pixels inside r, cropped to their bounding box, centred in a square and sampled to
        // size x size coverage values: the outline of a class symbol, for comparing shapes.
        public static double[] Glyph(Bitmap bmp, Rectangle r, int size, int minV, int maxSpread)
        {
            r.Intersect(new Rectangle(0, 0, bmp.Width, bmp.Height));
            if (r.Width <= 0 || r.Height <= 0) return null;
            var p = Pixels(bmp, out int stride);
            int x0 = int.MaxValue, y0 = int.MaxValue, x1 = -1, y1 = -1, count = 0;
            for (int y = r.Top; y < r.Bottom; y++)
                for (int x = r.Left; x < r.Right; x++)
                    if (White(p, y * stride + x * 3, minV, maxSpread))
                    {
                        count++;
                        if (x < x0) x0 = x; if (x > x1) x1 = x; if (y < y0) y0 = y; if (y > y1) y1 = y;
                    }
            if (count < 6) return null;
            int side = Math.Max(x1 - x0 + 1, y1 - y0 + 1);
            double cx = (x0 + x1 + 1) / 2.0, cy = (y0 + y1 + 1) / 2.0;
            var g = new double[size * size];
            const int sub = 4;
            for (int gy = 0; gy < size; gy++)
                for (int gx = 0; gx < size; gx++)
                {
                    int hit = 0;
                    for (int sy = 0; sy < sub; sy++)
                        for (int sx = 0; sx < sub; sx++)
                        {
                            int px = (int)Math.Floor(cx - side / 2.0 + (gx + (sx + 0.5) / sub) * side / size);
                            int py = (int)Math.Floor(cy - side / 2.0 + (gy + (sy + 0.5) / sub) * side / size);
                            if (px >= r.Left && px < r.Right && py >= r.Top && py < r.Bottom && White(p, py * stride + px * 3, minV, maxSpread)) hit++;
                        }
                    g[gy * size + gx] = (double)hit / (sub * sub);
                }
            return g;
        }

        // Letters to change to turn a into b (Levenshtein distance).
        public static int EditDistance(string a, string b)
        {
            a ??= ""; b ??= "";
            var prev = new int[b.Length + 1]; var cur = new int[b.Length + 1];
            for (int j = 0; j <= b.Length; j++) prev[j] = j;
            for (int i = 1; i <= a.Length; i++)
            {
                cur[0] = i;
                for (int j = 1; j <= b.Length; j++)
                    cur[j] = Math.Min(Math.Min(prev[j] + 1, cur[j - 1] + 1), prev[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1));
                var t = prev; prev = cur; cur = t;
            }
            return prev[b.Length];
        }

        // Cosine similarity of two glyphs, 0..1.
        public static double Similarity(double[] a, double[] b)
        {
            if (a == null || b == null || a.Length != b.Length) return 0;
            double ab = 0, aa = 0, bb = 0;
            for (int i = 0; i < a.Length; i++) { ab += a[i] * b[i]; aa += a[i] * a[i]; bb += b[i] * b[i]; }
            return (aa == 0 || bb == 0) ? 0 : ab / Math.Sqrt(aa * bb);
        }

        // True when a capture is (nearly) all black, which is what exclusive fullscreen and some HDR setups give.
        public static bool IsBlank(Bitmap bmp)
        {
            int step = Math.Max(1, (int)Math.Round(Math.Min(bmp.Width, bmp.Height) / 24.0, MidpointRounding.ToEven));
            for (int y = 0; y < bmp.Height; y += step)
                for (int x = 0; x < bmp.Width; x += step)
                    if (bmp.GetPixel(x, y).GetBrightness() > 0.06) return false;
            return true;
        }
    }
}
