using System.Collections.Generic;
using System.IO;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Markup;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using Wardogs.Core;
using Wardogs.Reading;

namespace Wardogs.App
{
    // Class symbols, drawn on a 24x24 grid in the spirit of the game's own (our drawings, not game art):
    // Assault arrowhead, Medic cross, Support wrench, Recon crosshair, Driver steering wheel, Pilot wings.
    // "C" is replaced with the color.
    public static class RoleIcons
    {
        public static readonly Dictionary<string, string> Shapes = new()
        {
            ["infantry"] = "<Path Data=\"M12,1.5 L22.5,22 L12,15 L1.5,22 Z\" Fill=\"C\"/>",
            ["medic"] = "<Path Data=\"M8.5,2 H15.5 V8.5 H22 V15.5 H15.5 V22 H8.5 V15.5 H2 V8.5 H8.5 Z\" Fill=\"C\"/>",
            ["support"] = "<Line X1=\"4.5\" Y1=\"19.5\" X2=\"12.5\" Y2=\"11.5\" Stroke=\"C\" StrokeThickness=\"5\" StrokeStartLineCap=\"Round\" StrokeEndLineCap=\"Round\"/>" +
                          "<Path Data=\"M18.5,3.7 A5,5 0 1 0 20.7,9.7\" Stroke=\"C\" StrokeThickness=\"4.2\" StrokeStartLineCap=\"Round\" StrokeEndLineCap=\"Round\"/>",
            ["recon"] = "<Ellipse Canvas.Left=\"3.5\" Canvas.Top=\"3.5\" Width=\"17\" Height=\"17\" Stroke=\"C\" StrokeThickness=\"2.4\"/>" +
                        "<Line X1=\"12\" Y1=\"1\" X2=\"12\" Y2=\"4.5\" Stroke=\"C\" StrokeThickness=\"2.6\"/><Line X1=\"12\" Y1=\"19.5\" X2=\"12\" Y2=\"23\" Stroke=\"C\" StrokeThickness=\"2.6\"/>" +
                        "<Line X1=\"1\" Y1=\"12\" X2=\"4.5\" Y2=\"12\" Stroke=\"C\" StrokeThickness=\"2.6\"/><Line X1=\"19.5\" Y1=\"12\" X2=\"23\" Y2=\"12\" Stroke=\"C\" StrokeThickness=\"2.6\"/>",
            ["driver"] = "<Ellipse Canvas.Left=\"2\" Canvas.Top=\"2\" Width=\"20\" Height=\"20\" Stroke=\"C\" StrokeThickness=\"3\"/>" +
                         "<Ellipse Canvas.Left=\"9\" Canvas.Top=\"10\" Width=\"6\" Height=\"6\" Fill=\"C\"/>" +
                         "<Line X1=\"3.5\" Y1=\"11\" X2=\"20.5\" Y2=\"11\" Stroke=\"C\" StrokeThickness=\"3\"/>" +
                         "<Line X1=\"12\" Y1=\"14\" X2=\"12\" Y2=\"21\" Stroke=\"C\" StrokeThickness=\"3\"/>",
            ["pilot"] = "<Path Data=\"M3,21 C5,13 12,6 22,2.5 C21,6 18.5,8.5 15.5,9.8 C18,9.8 19.5,9.5 20.5,9.2 C19,12.5 16,14.5 12.5,15 C14,15.4 15.2,15.5 16.2,15.4 C13,19 8,20.6 3,21 Z\" Fill=\"C\"/>",
        };

        const string Ns = "xmlns=\"http://schemas.microsoft.com/winfx/2006/xaml/presentation\" xmlns:x=\"http://schemas.microsoft.com/winfx/2006/xaml\"";

        // A class symbol as XAML (for building windows from markup).
        public static string Xaml(string role, double size, string color, string name = null, string margin = "0", bool withNs = false)
        {
            var n = name != null ? $" x:Name=\"{name}\"" : "";
            return $"<Viewbox{(withNs ? " " + Ns : "")}{n} Width=\"{size}\" Height=\"{size}\" Margin=\"{margin}\" VerticalAlignment=\"Center\"><Canvas Width=\"24\" Height=\"24\">{Shapes[role].Replace("\"C\"", $"\"{color}\"")}</Canvas></Viewbox>";
        }

        // Recolors every shape inside a class symbol.
        public static void SetColor(Viewbox icon, Brush brush)
        {
            if (icon?.Child is not Canvas canvas) return;
            foreach (var child in canvas.Children)
                if (child is System.Windows.Shapes.Shape s)
                {
                    if (s.Fill != null) s.Fill = brush;
                    if (s.Stroke != null) s.Stroke = brush;
                }
        }

        // Renders each drawing white on black and turns it into a glyph, the starting templates for
        // telling class symbols apart. Needs an STA thread (WPF rendering).
        public static Dictionary<string, double[]> DrawnGlyphs()
        {
            var result = new Dictionary<string, double[]>();
            const int px = 64;
            foreach (var role in Roles.Order)
            {
                var border = new Border { Background = Brushes.Black, Child = (UIElement)XamlReader.Parse(Xaml(role, px, "#FFFFFF", withNs: true).Replace(" Margin=\"0\" VerticalAlignment=\"Center\"", "")) };
                border.Measure(new Size(px, px)); border.Arrange(new Rect(0, 0, px, px));
                var rtb = new RenderTargetBitmap(px, px, 96, 96, PixelFormats.Pbgra32);
                rtb.Render(border);
                var enc = new PngBitmapEncoder();
                enc.Frames.Add(BitmapFrame.Create(rtb));
                using var ms = new MemoryStream();
                enc.Save(ms); ms.Position = 0;
                using var png = new System.Drawing.Bitmap(ms);
                using var bmp = png.Clone(new System.Drawing.Rectangle(0, 0, px, px), System.Drawing.Imaging.PixelFormat.Format24bppRgb);
                result[role] = PixelMath.Glyph(bmp, new System.Drawing.Rectangle(0, 0, px, px), PopupTuning.GlyphSize, 128, 255);
            }
            return result;
        }
    }
}
