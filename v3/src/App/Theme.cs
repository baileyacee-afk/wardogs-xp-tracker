using System;
using System.Windows.Media;

namespace Wardogs.App
{
    public static class Theme
    {
        public const string Gold = "#D8B45A", Green = "#5BD06E", Ink = "#EADFC4", Muted = "#9A8F78", Dim = "#6F6654", Red = "#E0705A", Warn = "#E0B05A", Line = "#4A3F28";

        public static SolidColorBrush Brush(string hex)
        {
            var b = new SolidColorBrush((Color)ColorConverter.ConvertFromString(hex));
            b.Freeze();
            return b;
        }

        public static readonly SolidColorBrush GoldB = Brush(Gold), GreenB = Brush(Green), InkB = Brush(Ink), MutedB = Brush(Muted), DimB = Brush(Dim), RedB = Brush(Red);

        // Fills %GOLD% etc. in a XAML template.
        public static string Fill(string xaml) => xaml
            .Replace("%GOLD%", Gold).Replace("%GREEN%", Green).Replace("%INK%", Ink).Replace("%MUTED%", Muted)
            .Replace("%DIM%", Dim).Replace("%LINE%", Line);

        public static string Cash(long amount) => amount < 0 ? $"-${Math.Abs(amount):N0}" : $"+${amount:N0}";

        public static string When(DateTimeOffset t)
        {
            var local = t.LocalDateTime;
            var day = local.Date == DateTime.Today ? "Today" : local.Date == DateTime.Today.AddDays(-1) ? "Yesterday" : local.ToString("MMM d");
            return $"{day} {local:h:mm tt}";
        }
    }
}
