# Live popup reader for the Wardogs XP Tracker.
#
# Watches the list of XP and cash popups under the game's top-right cash boxes and reports each new
# row once, as an event: XP (with the class it went to) or cash, the amount and the reason shown.
#
# What the popups look like (from recorded games):
#   "KILL  250XP <class symbol>"     XP rows end with the class symbol (Assault arrowhead, Medic cross,
#   "CONTROL ZONE PRESENCE  +$160"   Support wrench, Recon crosshair, Driver wheel, Pilot wings).
#   New rows fade in at the bottom (about 21 px apart at 1080p) and stay ~5 s; the newest amount
#   briefly sits on a white highlight. Cash rows have no class symbol.
#
# Keeping it cheap: each poll grabs only the popup area and compares a fingerprint of its white text
# with the previous one; OCR (the expensive part) only runs when the text changed.
#
# Needs GameReader.ps1 (Get-GameRect, Get-ScreenBitmap, Read-OcrWords, Get-EditDistance) and WPF
# loaded, plus $RoleIcons (the tracker's class symbol drawings) by the time a symbol is classified.

Add-Type -AssemblyName System.Drawing
Add-Type -ReferencedAssemblies System.Drawing -TypeDefinition @'
using System;
using System.Drawing;
using System.Drawing.Imaging;
using System.Runtime.InteropServices;

// Pixel helpers for the popups. White HUD text = bright and nearly grey.
public static class WdPopup {
    static byte[] Pixels(Bitmap bmp, out int stride) {
        var data = bmp.LockBits(new Rectangle(0, 0, bmp.Width, bmp.Height), ImageLockMode.ReadOnly, PixelFormat.Format24bppRgb);
        stride = data.Stride;
        var buf = new byte[stride * bmp.Height];
        Marshal.Copy(data.Scan0, buf, 0, buf.Length);
        bmp.UnlockBits(data);
        return buf;
    }

    static bool White(byte[] p, int i, int minV, int maxSpread) {
        int b = p[i], g = p[i + 1], r = p[i + 2];
        int mx = Math.Max(r, Math.Max(g, b)), mn = Math.Min(r, Math.Min(g, b));
        return mn >= minV && mx - mn <= maxSpread;
    }

    // White-text pixels per cell of a gw x gh grid: a fingerprint of the popup text that ignores
    // the moving game world behind it.
    public static int[] WhiteGrid(Bitmap bmp, int gw, int gh, int minV, int maxSpread) {
        int stride; var p = Pixels(bmp, out stride);
        var grid = new int[gw * gh];
        for (int y = 0; y < bmp.Height; y++) {
            int gy = y * gh / bmp.Height;
            for (int x = 0; x < bmp.Width; x++)
                if (White(p, y * stride + x * 3, minV, maxSpread)) grid[gy * gw + x * gw / bmp.Width]++;
        }
        return grid;
    }

    // 0 = same text layout, 1 = completely different.
    public static double GridDiff(int[] a, int[] b) {
        if (a == null || b == null || a.Length != b.Length) return 1;
        long d = 0, t = 0;
        for (int i = 0; i < a.Length; i++) { d += Math.Abs(a[i] - b[i]); t += a[i] + b[i]; }
        return t == 0 ? 0 : (double)d / t;
    }

    public static int Sum(int[] a) { int s = 0; if (a != null) foreach (var v in a) s += v; return s; }

    // Share of white pixels inside r (a highlighted amount sits on a solid white box).
    public static double WhiteFraction(Bitmap bmp, Rectangle r, int minV, int maxSpread) {
        r.Intersect(new Rectangle(0, 0, bmp.Width, bmp.Height));
        if (r.Width <= 0 || r.Height <= 0) return 0;
        int stride; var p = Pixels(bmp, out stride);
        int n = 0;
        for (int y = r.Top; y < r.Bottom; y++)
            for (int x = r.Left; x < r.Right; x++)
                if (White(p, y * stride + x * 3, minV, maxSpread)) n++;
        return (double)n / (r.Width * r.Height);
    }

    // White pixels inside r, cropped to their bounding box, centred in a square and sampled to
    // size x size coverage values: the outline of a class symbol, for comparing shapes.
    public static double[] Glyph(Bitmap bmp, Rectangle r, int size, int minV, int maxSpread) {
        r.Intersect(new Rectangle(0, 0, bmp.Width, bmp.Height));
        if (r.Width <= 0 || r.Height <= 0) return null;
        int stride; var p = Pixels(bmp, out stride);
        int x0 = int.MaxValue, y0 = int.MaxValue, x1 = -1, y1 = -1, count = 0;
        for (int y = r.Top; y < r.Bottom; y++)
            for (int x = r.Left; x < r.Right; x++)
                if (White(p, y * stride + x * 3, minV, maxSpread)) {
                    count++;
                    if (x < x0) x0 = x; if (x > x1) x1 = x; if (y < y0) y0 = y; if (y > y1) y1 = y;
                }
        if (count < 6) return null;
        int side = Math.Max(x1 - x0 + 1, y1 - y0 + 1);
        double cx = (x0 + x1 + 1) / 2.0, cy = (y0 + y1 + 1) / 2.0;
        var g = new double[size * size];
        const int sub = 4;
        for (int gy = 0; gy < size; gy++)
            for (int gx = 0; gx < size; gx++) {
                int hit = 0;
                for (int sy = 0; sy < sub; sy++)
                    for (int sx = 0; sx < sub; sx++) {
                        int px = (int)Math.Floor(cx - side / 2.0 + (gx + (sx + 0.5) / sub) * side / size);
                        int py = (int)Math.Floor(cy - side / 2.0 + (gy + (sy + 0.5) / sub) * side / size);
                        if (px >= r.Left && px < r.Right && py >= r.Top && py < r.Bottom && White(p, py * stride + px * 3, minV, maxSpread)) hit++;
                    }
                g[gy * size + gx] = (double)hit / (sub * sub);
            }
        return g;
    }

    // Letters to change to turn a into b (Levenshtein distance).
    public static int EditDistance(string a, string b) {
        var prev = new int[b.Length + 1]; var cur = new int[b.Length + 1];
        for (int j = 0; j <= b.Length; j++) prev[j] = j;
        for (int i = 1; i <= a.Length; i++) {
            cur[0] = i;
            for (int j = 1; j <= b.Length; j++)
                cur[j] = Math.Min(Math.Min(prev[j] + 1, cur[j - 1] + 1), prev[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1));
            var t = prev; prev = cur; cur = t;
        }
        return prev[b.Length];
    }

    // Cosine similarity of two glyphs, 0..1.
    public static double Similarity(double[] a, double[] b) {
        if (a == null || b == null || a.Length != b.Length) return 0;
        double ab = 0, aa = 0, bb = 0;
        for (int i = 0; i < a.Length; i++) { ab += a[i] * b[i]; aa += a[i] * a[i]; bb += b[i] * b[i]; }
        return (aa == 0 || bb == 0) ? 0 : ab / Math.Sqrt(aa * bb);
    }
}
'@

# ---------------------------------------------------------------- tuning
$PopupWhiteMin    = 185     # popup text pixels: every channel at least this bright...
$PopupWhiteSpread = 60      # ...and nearly grey
$PopupGateWhite   = 235     # the change check only looks at pure white (popup text), not light sky
$PopupGateSpread  = 20
$PopupGateDiff    = 0.05    # white-text fingerprint change that triggers OCR
$PopupForceOcr    = 1.5     # seconds: OCR anyway this often while popups are showing
$PopupMinOcrGap   = 0.5     # seconds: never OCR more often than this (rows stay up 5+ s)
$PopupOcrScale    = 3       # popup text is small: enlarge this much before OCR
$PopupRowGone     = 2.5     # seconds unseen (not even as garbled text) before a row counts as gone
$PopupRowLife     = 6       # seconds a row normally stays (kill rows can linger ~8 s); older ones are expected to leave
$PopupRowMaxAge   = 12      # no row stays longer than this; an "older" one is really a new identical row
$PopupFlash       = 0.5     # white share of the amount box that means "just added" highlight
$PopupGlyphSize   = 16
$PopupLearnMax    = 40      # symbol examples kept per class

# Reasons that always go to one class, so the symbol only matters for the others.
$ReasonRoles = @{
    'KILL' = 'infantry'; 'KILL ASSIST' = 'infantry'
    'REVIVED TEAMMATE' = 'medic'; 'REVIVED PLAYER ASSIST' = 'medic'
    'BUILDING' = 'support'; 'BUILDING COMPLETE' = 'support'; 'SUPPLIES DEPOSITED' = 'support'
    'SPOTTED TARGET DESTROYED' = 'recon'; 'TARGET SPOTTED REFRESHED' = 'recon'
    'TACTICAL DEPLOYMENT' = 'pilot'
}
# Reasons shared by a few classes: the symbol decides between these.
$ReasonChoices = @{ 'SUPPLIES DELIVERED' = @('driver', 'pilot'); 'PASSENGER SURVIVED' = @('driver', 'pilot') }
# Every reason seen so far, used to clean up OCR spelling ("BUILDIN" -> "BUILDING").
$KnownReasons = @($ReasonRoles.Keys) + @($ReasonChoices.Keys) + @(
    'CONTROL ZONE ENTERED', 'CONTROL ZONE PRESENCE', 'HOTZONE PRESENCE', 'VEHICLE REFUELLING', 'AIR TIME BONUS',
    'WAITED TO BE REVIVED', 'SUPPLIES DESTROYED')

# OCR's guess at a symbol when it reads it as a character after "XP".
$SymbolHints = @{ 'A' = 'infantry'; '+' = 'medic'; '&' = 'support' }

# ---------------------------------------------------------------- areas
# Default popup area: right of centre-right, just under the cash boxes (fractions of the game window).
function Get-PopupRect {
    if ($Settings.PopupRect) {
        $p = $Settings.PopupRect -split ',' | ForEach-Object { [int]$_ }
        return New-Object System.Drawing.Rectangle $p[0], $p[1], $p[2], $p[3]
    }
    $g = Get-GameRect
    New-Object System.Drawing.Rectangle ([int]($g.X + $g.Width * 0.805)), ([int]($g.Y + $g.Height * 0.045)), ([int]($g.Width * 0.19)), ([int]($g.Height * 0.21))
}

# The cash boxes at the very top right (match cash on the results screen, banked cash, level).
function Get-CashRect {
    $g = Get-GameRect
    New-Object System.Drawing.Rectangle ([int]($g.X + $g.Width * 0.78)), $g.Y, ([int]($g.Width * 0.21)), ([int]($g.Height * 0.055))
}

# ---------------------------------------------------------------- reading rows
$script:ReasonCache = @{}
function ConvertTo-ReasonName([string]$Text) {
    $t = ($Text.ToUpper() -replace '[^A-Z ]', '' -replace '\s+', ' ').Trim()
    if ($t.Length -lt 3) { return $null }
    if ($script:ReasonCache.ContainsKey($t)) { return $script:ReasonCache[$t] }
    # Compare without spaces: OCR often drops or adds them ("SUPPLIESJELKRED" -> SUPPLIES DELIVERED).
    $flat = $t -replace ' ', ''
    $best = $null; $bestD = 99
    foreach ($k in $KnownReasons) {
        $kf = $k -replace ' ', ''
        if ([Math]::Abs($kf.Length - $flat.Length) -gt [Math]::Max(3, [int]($kf.Length * 0.35))) { continue }
        $d = [WdPopup]::EditDistance($flat, $kf)
        if ($d -lt $bestD) { $bestD = $d; $best = $k }
    }
    $name = if ($best -and $bestD -le [Math]::Max(1, [int](($best -replace ' ', '').Length * 0.3))) { $best } else { $t }
    if ($script:ReasonCache.Count -lt 2000) { $script:ReasonCache[$t] = $name }
    $name
}

# "250" -> 250, "8" -> 8, "2O" -> 20, "e"/"a" (a lone misread 8) -> 8. $null if not a number.
function ConvertTo-PopupNumber([string]$Text) {
    $t = $Text -replace '[,\.\s]', ''
    if ($t -eq 'e' -or $t -eq 'a') { return 8 }
    $t = $t -replace '[Oo]', '0' -replace '[Il|]', '1' -replace 'S', '5' -replace 'B', '8'
    if ($t -match '^\d{1,7}$') { [int]$t } else { $null }
}

# Groups OCR words into popup rows and parses each one.
# Row: @{ Kind = 'xp'|'cash'|'unparsed'; Amount; Reason; Uncertain; Hint; Y; H; Flash; Glyph; Text }
function Get-PopupRows([System.Drawing.Bitmap]$Bitmap, $Words) {
    $lines = @()
    foreach ($w in ($Words | Sort-Object { $_.Y + $_.H / 2 })) {
        $mid = $w.Y + $w.H / 2
        $line = $lines | Where-Object { [Math]::Abs($mid - $_.Mid) -lt [Math]::Max($w.H, $_.H) * 0.6 } | Select-Object -First 1
        if ($line) { $line.Words += $w } else { $lines += [pscustomobject]@{ Mid = $mid; H = $w.H; Words = @($w) } }
    }
    foreach ($line in $lines) {
        $ws = @($line.Words | Sort-Object X)
        $text = ($ws | ForEach-Object Text) -join ' '
        $h = ($ws | Measure-Object H -Maximum).Maximum
        $row = [ordered]@{ Kind = 'unparsed'; Amount = $null; Reason = $null; Uncertain = $false; Hint = $null
            Y = ($ws | Measure-Object Y -Minimum).Minimum; H = $h; Flash = $false; Glyph = $null; Text = $text; AmountWord = $null }
        # No digits: a prompt, or a row still fading in. "/" or several numbers: the Wardog Level
        # screen showing through. Either way not a popup to read, but it shows the row is there.
        if ($text -notmatch '\d' -or $text -match '\d\s*/' -or @($ws | Where-Object { $_.Text -match '^\D?\d[\d,]{1,}' }).Count -ge 2) {
            $row.Kind = 'other'; [pscustomobject]$row; continue
        }

        # XP: "250XP", "250 XP", "8xp"
        $xi = -1
        for ($i = 0; $i -lt $ws.Count; $i++) { if ($ws[$i].Text -match '(?i)xp') { $xi = $i; break } }
        if ($xi -ge 0) {
            $tok = $ws[$xi].Text -replace '(?i)xp.*$', ''
            $amtIdx = $xi
            if (-not $tok -and $xi -gt 0) { $tok = $ws[$xi - 1].Text; $amtIdx = $xi - 1 }
            $n = ConvertTo-PopupNumber ($tok -replace '^[+*]', '')
            $reason = ConvertTo-ReasonName ((($ws | Select-Object -First $amtIdx) | ForEach-Object Text) -join ' ')
            if ($null -ne $n -and $reason) {
                $row.Kind = 'xp'; $row.Amount = $n; $row.Reason = $reason; $row.AmountWord = $ws[$xi]
                $after = (($ws | Select-Object -Skip ($xi + 1)) | ForEach-Object Text) -join ''
                $tail = ($ws[$xi].Text -replace '^.*?(?i)xp', '') + $after
                if ($tail) { $row.Hint = $SymbolHints[[string]$tail.Trim()[0]] }
            }
        } else {
            # Cash: "+$160", "-$20", "*$250" (OCR reads + as * or a bullet)
            $di = -1
            for ($i = 0; $i -lt $ws.Count; $i++) { if ($ws[$i].Text -match '\$') { $di = $i; break } }
            if ($di -ge 0) {
                $parts = $ws[$di].Text -split '\$', 2
                $sign = $parts[0]; $amtIdx = $di
                if (-not $sign -and $di -gt 0 -and $ws[$di - 1].Text -match '^[+\-*\x2022~]$') { $sign = $ws[$di - 1].Text; $amtIdx = $di - 1 }
                $n = ConvertTo-PopupNumber ($parts[1] -replace '[^\dOoIlSB,\.].*$', '')
                $reason = ConvertTo-ReasonName ((($ws | Select-Object -First $amtIdx) | ForEach-Object Text) -join ' ')
                if ($null -ne $n -and $reason) {
                    $row.Kind = 'cash'; $row.Amount = if ($sign -match '[-~]') { -$n } else { $n }; $row.Reason = $reason; $row.AmountWord = $ws[$di]
                }
            } else {
                # A signed amount with its "$" misread as a digit ("+$160" -> "+560", "+$40" -> "+940").
                $last = $ws[-1].Text
                if ($last -match '^(?<s>[+\-*\x2022~''])(?<n>[\dSO,]{2,})$' -and $ws.Count -ge 2) {
                    $digits = $matches.n -replace ',', ''
                    $n = ConvertTo-PopupNumber $digits.Substring(1)
                    $reason = ConvertTo-ReasonName ((($ws | Select-Object -First ($ws.Count - 1)) | ForEach-Object Text) -join ' ')
                    if ($null -ne $n -and $reason) {
                        $row.Kind = 'cash'; $row.Amount = if ($matches.s -match '[-~]') { -$n } else { $n }
                        $row.Reason = $reason; $row.Uncertain = $true; $row.AmountWord = $ws[-1]
                    }
                }
            }
        }

        # The word holding the amount: as parsed, or for an unreadable row the last word with digits.
        $a = if ($row.AmountWord) { $row.AmountWord } else { $ws | Where-Object { $_.Text -match '\d' } | Select-Object -Last 1 }
        if ($a) {
            $box = New-Object System.Drawing.Rectangle ([int]($a.X - 0.2 * $h)), ([int]($a.Y - 0.2 * $h)), ([int]($a.W + 0.4 * $h)), ([int]($a.H + 0.4 * $h))
            $row.Flash = [WdPopup]::WhiteFraction($Bitmap, $box, $PopupWhiteMin, $PopupWhiteSpread) -gt $PopupFlash
            # A white class symbol right of the amount means XP (cash rows have none, or a coloured marker).
            $sym = New-Object System.Drawing.Rectangle ([int]($a.X + $a.W + 0.6 * $h)), ([int]($a.Y - 0.35 * $h)), ([int](2.4 * $h)), ([int](1.7 * $h))
            $glyph = [WdPopup]::Glyph($Bitmap, $sym, $PopupGlyphSize, $PopupWhiteMin, $PopupWhiteSpread)
            if ($glyph -and (Test-SymbolShape $glyph)) { $row.Glyph = $glyph }
            # OCR lost the "XP" ("KILL 2505P*", "BUILDING 8"), but the symbol is there: read it as XP.
            if ($row.Glyph -and $row.Kind -ne 'xp' -and $text -notmatch '\$') {
                $tok = $a.Text -replace '^[+*\x2022]', ''
                $num = if ($tok -match '^(?<n>\d{1,4}?)[5S]?[XxPpF]{1,2}\W*$') { $matches.n } elseif ($tok -match '^(?<n>\d{1,4})\W*$') { $matches.n } else { $null }
                $reason = ConvertTo-ReasonName ((($ws | Where-Object { $_.X -lt $a.X }) | ForEach-Object Text) -join ' ')
                if ($num -and $reason) { $row.Kind = 'xp'; $row.Amount = [int]$num; $row.Reason = $reason; $row.AmountWord = $a; $row.Uncertain = $false }
            }
            # ...and a "cash" row with a class symbol is really an XP row with a misread amount.
            if ($row.Glyph -and $row.Kind -eq 'cash' -and $row.Uncertain) { $row.Kind = 'unparsed' }
        }
        [pscustomobject]$row
    }
}

# ---------------------------------------------------------------- class symbols
$script:SymbolBank = $null       # learned from this screen: role -> @{ N; Sum }
$script:SymbolDrawn = $null      # from the tracker's own drawings, until enough are learned

function Get-SymbolBankPath { Join-Path $DataDir 'symbols.json' }

function Initialize-SymbolBank {
    $script:SymbolBank = @{}
    try {
        if (Test-Path (Get-SymbolBankPath)) {
            $raw = Get-Content (Get-SymbolBankPath) -Raw | ConvertFrom-Json
            foreach ($p in $raw.PSObject.Properties) { $script:SymbolBank[$p.Name] = @{ N = [int]$p.Value.N; Sum = [double[]]@($p.Value.Sum) } }
        }
    } catch {}
}

function Save-SymbolBank {
    $out = [ordered]@{}
    foreach ($k in $script:SymbolBank.Keys) { $out[$k] = [ordered]@{ N = $script:SymbolBank[$k].N; Sum = @($script:SymbolBank[$k].Sum | ForEach-Object { [Math]::Round($_, 3) }) } }
    ConvertTo-Json -InputObject $out -Depth 4 -Compress | Set-Content (Get-SymbolBankPath) -Encoding utf8
}

# Renders the tracker's drawing of a class symbol and turns it into a glyph.
function New-DrawnGlyph([string]$Role, [int]$Px = 64) {
    $x = '<Viewbox xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" Width="{0}" Height="{0}"><Canvas Width="24" Height="24">{1}</Canvas></Viewbox>' -f $Px, $RoleIcons[$Role].Replace('"C"', '"#FFFFFF"')
    $border = New-Object System.Windows.Controls.Border
    $border.Background = [System.Windows.Media.Brushes]::Black
    $border.Child = [Windows.Markup.XamlReader]::Parse($x)
    $border.Measure((New-Object System.Windows.Size $Px, $Px)); $border.Arrange((New-Object System.Windows.Rect 0, 0, $Px, $Px))
    $rtb = New-Object System.Windows.Media.Imaging.RenderTargetBitmap $Px, $Px, 96, 96, ([System.Windows.Media.PixelFormats]::Pbgra32)
    $rtb.Render($border)
    $enc = New-Object System.Windows.Media.Imaging.PngBitmapEncoder
    $enc.Frames.Add([System.Windows.Media.Imaging.BitmapFrame]::Create($rtb))
    $ms = New-Object IO.MemoryStream; $enc.Save($ms); $ms.Position = 0
    $png = New-Object System.Drawing.Bitmap $ms
    $bmp = $png.Clone((New-Object System.Drawing.Rectangle 0, 0, $Px, $Px), [System.Drawing.Imaging.PixelFormat]::Format24bppRgb)
    $png.Dispose()
    try { [WdPopup]::Glyph($bmp, (New-Object System.Drawing.Rectangle 0, 0, $Px, $Px), $PopupGlyphSize, 128, 255) } finally { $bmp.Dispose() }
}

function Get-SymbolTemplate([string]$Role) {
    $b = $script:SymbolBank[$Role]
    if ($b -and $b.N -ge 3) { return [double[]]@($b.Sum | ForEach-Object { $_ / $b.N }) }
    if (-not $script:SymbolDrawn) { $script:SymbolDrawn = @{}; foreach ($r in $RoleOrder) { $script:SymbolDrawn[$r] = New-DrawnGlyph $r } }
    $script:SymbolDrawn[$Role]
}

# Remembers what a class's symbol looks like on this screen (from rows whose reason names the class).
function Add-SymbolExample([string]$Role, [double[]]$Glyph) {
    if (-not $Glyph -or -not $Role) { return }
    $b = $script:SymbolBank[$Role]
    if (-not $b) { $b = @{ N = 0; Sum = New-Object double[] ($Glyph.Length) }; $script:SymbolBank[$Role] = $b }
    if ($b.N -ge $PopupLearnMax) { return }
    for ($i = 0; $i -lt $Glyph.Length; $i++) { $b.Sum[$i] += $Glyph[$i] }
    $b.N++
    if ($b.N -eq 3 -or $b.N % 10 -eq 0) { Save-SymbolBank }
}

# True when white pixels right of an amount look like one of the class symbols (not sky or snow).
function Test-SymbolShape([double[]]$Glyph) {
    foreach ($r in $RoleOrder) { if ([WdPopup]::Similarity($Glyph, (Get-SymbolTemplate $r)) -ge 0.5) { return $true } }
    $false
}

# Which class an XP row went to: by reason when that's certain, else by its symbol.
function Get-PopupRole($Row) {
    if ($ReasonRoles.ContainsKey($Row.Reason)) {
        $role = $ReasonRoles[$Row.Reason]
        Add-SymbolExample $role $Row.Glyph
        return $role
    }
    $narrowed = $ReasonChoices.ContainsKey($Row.Reason)
    $choices = if ($narrowed) { $ReasonChoices[$Row.Reason] } else { $RoleOrder }
    if (-not $Row.Glyph) { if ($Row.Hint -and $choices -contains $Row.Hint) { return $Row.Hint }; return $null }
    $scores = foreach ($r in $choices) { [pscustomobject]@{ Role = $r; S = [WdPopup]::Similarity($Row.Glyph, (Get-SymbolTemplate $r)) } }
    $best = $scores | Sort-Object S -Descending | Select-Object -First 1
    if ($best.S -lt 0.55 -and $Row.Hint -and $choices -contains $Row.Hint) { return $Row.Hint }
    # When the reason already narrows it to two or three classes, the closer symbol is enough.
    if ($best.S -lt $(if ($narrowed) { 0.25 } else { 0.45 })) { return $null }
    $best.Role
}

# ---------------------------------------------------------------- following rows between polls
$script:PopTracks = New-Object System.Collections.Generic.List[object]
$script:PopNextId = 1

function Test-SameRow($Track, $Row) {
    if ($Track.Kind -ne $Row.Kind) { return $false }
    if ($Track.Reason -ne $Row.Reason -and [WdPopup]::EditDistance($Track.Reason, $Row.Reason) -gt 3) { return $false }
    if ($Row.Uncertain -or $Track.Amount -eq $Row.Amount) { return $true }
    $a = [string][Math]::Abs($Track.Amount); $b = [string][Math]::Abs($Row.Amount)
    $d = [WdPopup]::EditDistance($a, $b)
    # one misread digit is still the same row; two, when the frame was too faint to show the symbol
    $d -le 1 -or ($Row.Kind -eq 'xp' -and -not $Row.Glyph -and $a.Length -eq $b.Length -and $d -le 2)
}

# Readings are voted on: a cash reading with a proper "$" outweighs one where "$" was misread.
function Add-Vote($Track, $Row) {
    $k = [string]$Row.Amount
    $w = if ($Row.Uncertain) { 1 } else { 3 }
    $Track.Votes[$k] = [int]$Track.Votes[$k] + $w
    if (-not $Row.Uncertain) { $Track.Uncertain = $false }
    $best = ($Track.Votes.GetEnumerator() | Sort-Object Value -Descending | Select-Object -First 1).Key
    $changed = [int]$best -ne $Track.Amount
    $Track.Amount = [int]$best
    $changed
}

# Matches this poll's rows (top to bottom) with the rows already being followed.
# New rows join at the bottom and old ones leave from the top, so this finds how many left from the
# top (s) such that the remaining tracks line up with the first rows; anything after that is new.
# Returns @{ New = rows-turned-tracks; Changed = tracks whose amount was corrected }.
function Update-PopupTracks($Rows, [datetime]$Now) {
    $rows = @($Rows | Where-Object { $_.Kind -eq 'xp' -or $_.Kind -eq 'cash' } | Sort-Object Y)
    # Any text where a followed row is (even an unreadable frame of it) means it's still on screen.
    foreach ($t in $script:PopTracks) {
        if ($Rows | Where-Object { [Math]::Abs($_.Y - $t.Y) -lt 0.8 * $_.H }) { $t.LastSeen = $Now }
    }
    foreach ($t in $script:PopTracks.ToArray()) {
        if (($Now - $t.LastSeen).TotalSeconds -gt $PopupRowGone -or ($Now - $t.Born).TotalSeconds -gt $PopupRowMaxAge) { [void]$script:PopTracks.Remove($t) }
    }
    $tracks = @($script:PopTracks.ToArray() | Sort-Object Y)
    $m = $tracks.Count; $n = $rows.Count

    $valid = @()
    for ($s = 0; $s -le $m; $s++) {
        $k = [Math]::Min($m - $s, $n); $bad = 0
        for ($i = 0; $i -lt $k; $i++) { if (-not (Test-SameRow $tracks[$s + $i] $rows[$i])) { $bad++ } }
        if ($bad -eq 0 -or ($k -ge 3 -and $bad -eq 1)) { $valid += $s }
    }
    $s = $null
    if ($valid.Count) {
        $s = $valid[0]
        # The same rows can line up two ways when one left and an identical one arrived: prefer the
        # shift when the top row has been up longer than rows normally stay, or the bottom row is
        # newly highlighted.
        # Only a shift by exactly one row that still lines up rows counts (a shift that compares
        # nothing always "fits").
        $next = $valid | Where-Object { $_ -eq $s + 1 -and [Math]::Min($m - $_, $n) -ge 1 } | Select-Object -First 1
        if ($null -ne $next -and $s -lt $m) {
            $old = ($Now - $tracks[$s].Born).TotalSeconds -gt $PopupRowLife
            $lastRow = if ($n) { $rows[$n - 1] } else { $null }
            $lastTrack = if ($m - $s - 1 -lt $n -and $m - $s - 1 -ge 0) { $tracks[$m - 1] } else { $null }
            $flash = $lastRow -and $lastRow.Flash -and $lastTrack -and -not $lastTrack.Flash -and ($Now - $lastTrack.Born).TotalSeconds -gt 1.0
            if ($old -or $flash) { $s = $next }
        }
    }

    $new = @(); $changed = @()
    if ($null -ne $s) {
        $k = [Math]::Min($m - $s, $n)
        for ($i = 0; $i -lt $k; $i++) {
            $t = $tracks[$s + $i]; $r = $rows[$i]
            $t.Y = $r.Y; $t.LastSeen = $Now; $t.Flash = $r.Flash
            if (Add-Vote $t $r) { $changed += $t }
        }
        for ($i = 0; $i -lt $s; $i++) { [void]$script:PopTracks.Remove($tracks[$i]) }
        $fresh = if ($n -gt $k) { $rows[$k..($n - 1)] } else { @() }
    } else {
        # Nothing lines up (several misreads at once): only rows unlike any followed row are new.
        $fresh = @(); $used = @{}
        foreach ($r in $rows) {
            $t = $tracks | Where-Object { -not $used[$_.Id] -and [Math]::Abs($_.Y - $r.Y) -le 2.5 * $r.H -and (Test-SameRow $_ $r) } | Select-Object -First 1
            if ($t) { $used[$t.Id] = $true; $t.Y = $r.Y; $t.LastSeen = $Now; $t.Flash = $r.Flash; if (Add-Vote $t $r) { $changed += $t } }
            else { $fresh += $r }
        }
    }
    foreach ($r in $fresh) {
        $t = [pscustomobject]@{ Id = $script:PopNextId++; Kind = $r.Kind; Reason = $r.Reason; Role = $null; Amount = $r.Amount
            Uncertain = $r.Uncertain; Votes = @{}; Born = $Now; LastSeen = $Now; Y = $r.Y; Flash = $r.Flash; EventId = $null }
        [void](Add-Vote $t $r)
        if ($r.Kind -eq 'xp') { $t.Role = Get-PopupRole $r }
        $script:PopTracks.Add($t)
        $new += $t
    }
    @{ New = $new; Changed = $changed }
}

# Whether any popup text is showing. Uses the looser text test: some popups (kills) aren't pure white,
# so the strict change check can't see them.
function Test-PopupsShowing([System.Drawing.Bitmap]$Bitmap) {
    [WdPopup]::Sum([WdPopup]::WhiteGrid($Bitmap, 24, 16, $PopupWhiteMin, $PopupWhiteSpread)) -ge 20
}

# Reads the popup rows in a capture of the popup area. To keep OCR cheap it only reads the band of
# rows that have text in them (usually one to three popups, not the whole area).
function Read-PopupArea([System.Drawing.Bitmap]$Bitmap) {
    $gh = 16
    $grid = [WdPopup]::WhiteGrid($Bitmap, 1, $gh, $PopupWhiteMin, $PopupWhiteSpread)
    $rowsWithText = @(0..($gh - 1) | Where-Object { $grid[$_] -ge 4 })
    if (-not $rowsWithText.Count) { return @() }
    $cell = $Bitmap.Height / $gh
    $top = [int][Math]::Max(0, ($rowsWithText[0] - 1) * $cell)
    $bottom = [int][Math]::Min($Bitmap.Height, ($rowsWithText[-1] + 2) * $cell)
    if ($bottom - $top -lt 8) { return @() }
    $band = $Bitmap.Clone((New-Object System.Drawing.Rectangle 0, $top, $Bitmap.Width, ($bottom - $top)), [System.Drawing.Imaging.PixelFormat]::Format24bppRgb)
    try {
        $rows = @(Get-PopupRows $band @(Read-OcrWords $band $PopupOcrScale))
        foreach ($r in $rows) { $r.Y += $top }   # back to popup-area coordinates
        $rows
    } finally { $band.Dispose() }
}

# Keeps followed rows alive while the popup area hasn't changed (no OCR this poll).
function Update-PopupTracksSeen([datetime]$Now) { foreach ($t in $script:PopTracks) { $t.LastSeen = $Now } }

function Reset-PopupTracks { $script:PopTracks.Clear() }

# ---------------------------------------------------------------- the cash boxes
# Reads the cash shown at the top right while playing: this life's cash (resets on death, negative
# after buying gear) and banked cash (live). Returns @{ Life; Banked }, or $null when they can't be
# read. Menus and the results screen show them in boxes next to the Wardog level; those are skipped
# (OCR rarely reads the boxes, and the results screen's first box is the match's cash, not this life's).
function Read-CashHud([System.Drawing.Bitmap]$Bitmap) {
    $words = @(Read-OcrWords $Bitmap 3 | Sort-Object X)
    $text = ($words | ForEach-Object Text) -join ' '
    $amounts = @([regex]::Matches($text, '(?<s>-?)\s*\$\s*(?<n>\d{1,3}(?:[,\.]\d{3})*)(?![\d,\.]*\d)') | ForEach-Object {
        $n = ConvertTo-PopupNumber $_.Groups['n'].Value
        if ($null -ne $n) { if ($_.Groups['s'].Value) { -$n } else { $n } }
    })
    $tail = ($words | Select-Object -Last 1).Text
    if ($tail -and $tail -notmatch '\$' -and $tail -match '^\d{1,3}$') { return $null }   # Wardog level box: a menu
    if ($amounts.Count -ne 2 -or $amounts[1] -lt 0) { return $null }
    @{ Life = [long]$amounts[0]; Banked = [long]$amounts[1] }
}
