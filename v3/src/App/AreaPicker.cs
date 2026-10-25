using System;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Markup;
using System.Windows.Shapes;
using Forms = System.Windows.Forms;

namespace Wardogs.App
{
    // Dims the game's screen; drag a box around where the XP/cash popups appear, then Enter (Esc cancels).
    public static class AreaPicker
    {
        public static System.Drawing.Rectangle? Pick(System.Drawing.Rectangle current, double scale)
        {
            var b = Forms.Screen.FromRectangle(current).Bounds;
            double s = scale;
            var w = (Window)XamlReader.Parse(Theme.Fill(@"
<Window xmlns=""http://schemas.microsoft.com/winfx/2006/xaml/presentation"" xmlns:x=""http://schemas.microsoft.com/winfx/2006/xaml""
        WindowStyle=""None"" AllowsTransparency=""True"" Background=""#80000000"" Topmost=""True"" ShowInTaskbar=""False"" Cursor=""Cross"">
  <Grid>
    <Canvas x:Name=""Board"" Background=""#01000000"">
      <Rectangle x:Name=""Sel"" Stroke=""%GOLD%"" StrokeThickness=""2"" Fill=""#2AD8B45A""/>
    </Canvas>
    <Border VerticalAlignment=""Top"" HorizontalAlignment=""Center"" Margin=""0,80,0,0"" Background=""#E614100A"" BorderBrush=""%LINE%"" BorderThickness=""1"" CornerRadius=""4"" Padding=""14,10"" Cursor=""Arrow"">
      <StackPanel>
        <TextBlock FontFamily=""Bahnschrift, Segoe UI"" FontSize=""15"" Foreground=""%INK%"" TextAlignment=""Center""
                   Text=""Drag a box around where the XP and cash popups appear (under the cash boxes, top right).&#x0a;Make it tall enough for a full stack of popups. Enter saves; Esc or right-click cancels.""/>
        <StackPanel Orientation=""Horizontal"" HorizontalAlignment=""Center"" Margin=""0,10,0,0"">
          <Button x:Name=""PickSave"" Content=""SAVE"" Padding=""16,4"" Margin=""0,0,8,0"" Foreground=""#15110A"" Background=""%GOLD%"" BorderThickness=""0"" FontFamily=""Bahnschrift, Segoe UI"" FontWeight=""SemiBold""/>
          <Button x:Name=""PickCancel"" Content=""CANCEL"" Padding=""12,4"" Foreground=""%INK%"" Background=""Transparent"" BorderBrush=""%LINE%"" FontFamily=""Bahnschrift, Segoe UI""/>
        </StackPanel>
      </StackPanel>
    </Border>
  </Grid>
</Window>"));
            w.Left = b.X / s; w.Top = b.Y / s; w.Width = b.Width / s; w.Height = b.Height / s;
            var sel = (Rectangle)w.FindName("Sel"); var board = (Canvas)w.FindName("Board");
            Point? start = null; double[] rect = null; System.Drawing.Rectangle? result = null;

            void Place(double x1, double y1, double x2, double y2)
            {
                double l = Math.Min(x1, x2), t = Math.Min(y1, y2);
                Canvas.SetLeft(sel, l); Canvas.SetTop(sel, t);
                sel.Width = Math.Abs(x2 - x1); sel.Height = Math.Abs(y2 - y1);
                rect = new[] { l, t, sel.Width, sel.Height };
            }
            void Save()
            {
                if (rect != null && rect[2] >= 40 && rect[3] >= 30)
                {
                    result = new System.Drawing.Rectangle((int)Math.Round(b.X + rect[0] * s), (int)Math.Round(b.Y + rect[1] * s), (int)Math.Round(rect[2] * s), (int)Math.Round(rect[3] * s));
                    w.Close();
                }
            }
            // Show the current area to start with.
            Place((current.X - b.X) / s, (current.Y - b.Y) / s, (current.Right - b.X) / s, (current.Bottom - b.Y) / s);
            board.MouseLeftButtonDown += (_, e) => { start = e.GetPosition(board); board.CaptureMouse(); };
            board.MouseMove += (_, e) => { if (start != null) { var p = e.GetPosition(board); Place(start.Value.X, start.Value.Y, p.X, p.Y); } };
            board.MouseLeftButtonUp += (_, _) => { start = null; board.ReleaseMouseCapture(); };
            ((Button)w.FindName("PickSave")).Click += (_, _) => Save();
            ((Button)w.FindName("PickCancel")).Click += (_, _) => w.Close();
            board.MouseRightButtonUp += (_, _) => w.Close();
            w.KeyDown += (_, e) => { if (e.Key == Key.Escape) w.Close(); if (e.Key == Key.Enter) Save(); };
            w.ContentRendered += (_, _) => { w.Activate(); w.Focus(); };
            w.ShowDialog();
            return result;
        }
    }
}
