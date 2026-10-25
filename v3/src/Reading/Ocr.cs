using System;
using System.Collections.Generic;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Drawing.Imaging;
using System.Runtime.InteropServices;
using System.Runtime.InteropServices.WindowsRuntime;
using Windows.Graphics.Imaging;
using Windows.Media.Ocr;
using Wardogs.Core;

namespace Wardogs.Reading
{
    public sealed record OcrWord(string Text, double X, double Y, double W, double H)
    {
        public double CX => X + W / 2;
    }

    // Windows' built-in text recognition.
    public static class Ocr
    {
        static readonly object sync = new object();
        static OcrEngine engine;

        // Created once. English if it's installed, otherwise the user's own languages.
        static OcrEngine Engine
        {
            get
            {
                lock (sync)
                {
                    if (engine != null) return engine;
                    var lang = new Windows.Globalization.Language("en-US");
                    engine = OcrEngine.IsLanguageSupported(lang) ? OcrEngine.TryCreateFromLanguage(lang) : OcrEngine.TryCreateFromUserProfileLanguages();
                    if (engine == null)
                        throw new InvalidOperationException("Windows text recognition isn't installed. Open Settings > Time & language > Language & region, add English (United States), then restart the tracker.");
                    return engine;
                }
            }
        }

        // Every recognized word with its position in the original image's pixels.
        // Upscaling makes the small XP text much more reliable.
        public static List<OcrWord> Read(Bitmap bmp, double scale = 2.0)
        {
            double s = Math.Min(scale, OcrEngine.MaxImageDimension / (double)Math.Max(bmp.Width, bmp.Height));
            int w = Num.R(bmp.Width * s), h = Num.R(bmp.Height * s);
            byte[] buf;
            using (var big = new Bitmap(w, h, PixelFormat.Format32bppArgb))
            {
                using (var g = Graphics.FromImage(big))
                {
                    g.InterpolationMode = InterpolationMode.HighQualityBicubic;
                    g.DrawImage(bmp, 0, 0, w, h);
                }
                var data = big.LockBits(new Rectangle(0, 0, w, h), ImageLockMode.ReadOnly, PixelFormat.Format32bppArgb);
                buf = new byte[data.Stride * h];
                Marshal.Copy(data.Scan0, buf, 0, buf.Length);
                big.UnlockBits(data);
            }
            OcrResult result;
            using (var soft = new SoftwareBitmap(BitmapPixelFormat.Bgra8, w, h, BitmapAlphaMode.Straight))
            {
                soft.CopyFromBuffer(buf.AsBuffer());
                result = Engine.RecognizeAsync(soft).AsTask().GetAwaiter().GetResult();
            }
            var words = new List<OcrWord>();
            foreach (var line in result.Lines)
                foreach (var wd in line.Words)
                {
                    var b = wd.BoundingRect;
                    words.Add(new OcrWord(wd.Text, b.X / s, b.Y / s, b.Width / s, b.Height / s));
                }
            return words;
        }
    }
}
