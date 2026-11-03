# Builds the Microsoft Store package: store\out\WardogsXpTracker-<version>.msix, ready to upload in
# Partner Center (the Store signs it). Run from anywhere:  powershell -File v3\store\build-msix.ps1
# Needs the .NET SDK; Microsoft's packaging tool (MakeAppx) comes from NuGet the first time.
$ErrorActionPreference = 'Stop'
$store = $PSScriptRoot
$v3 = Split-Path $store
$out = Join-Path $store 'out'
$layout = Join-Path $out 'layout'
$dotnet = 'C:\Program Files\dotnet\dotnet.exe'

# ---- identity (from Partner Center) and version (from the csproj: 3.7.0 -> 3.7.0.0; the Store needs the last part 0)
$id = Get-Content (Join-Path $store 'identity.json') -Raw | ConvertFrom-Json
$csproj = [xml](Get-Content (Join-Path $v3 'src\WardogsXpTracker.csproj') -Raw)
$version = ($csproj.Project.PropertyGroup | Where-Object { $_.Version } | Select-Object -First 1).Version + '.0'
if ($id.Publisher -like '*PLACEHOLDER*') { Write-Warning 'identity.json still has PLACEHOLDER values: fine for a test build, not for uploading.' }

# ---- MakeAppx from the Microsoft.Windows.SDK.BuildTools NuGet package
$toolsVersion = '10.0.26100.4654'
$makeappx = Join-Path $env:USERPROFILE ".nuget\packages\microsoft.windows.sdk.buildtools\$toolsVersion\bin\10.0.26100.0\x64\makeappx.exe"
if (-not (Test-Path $makeappx)) {
    $tmp = Join-Path $env:TEMP 'wardogs-sdktools'
    New-Item -ItemType Directory -Force $tmp | Out-Null
    Set-Content (Join-Path $tmp 'tools.csproj') -Encoding utf8 "<Project Sdk=`"Microsoft.NET.Sdk`"><PropertyGroup><TargetFramework>net10.0</TargetFramework></PropertyGroup><ItemGroup><PackageReference Include=`"Microsoft.Windows.SDK.BuildTools`" Version=`"$toolsVersion`" /></ItemGroup></Project>"
    & $dotnet restore (Join-Path $tmp 'tools.csproj') -v q --nologo
    if (-not (Test-Path $makeappx)) { throw "MakeAppx not found at $makeappx" }
}

# ---- the app
if (Test-Path $layout) { Remove-Item -Recurse -Force $layout }
New-Item -ItemType Directory -Force (Join-Path $layout 'Assets') | Out-Null
& $dotnet publish (Join-Path $v3 'src\WardogsXpTracker.csproj') -c Release -o (Join-Path $out 'publish') -v q --nologo
if ($LASTEXITCODE -ne 0) { throw 'dotnet publish failed' }
Copy-Item (Join-Path $out 'publish\WardogsXpTracker.exe') $layout

# ---- logos: the tray's "XP" badge (same drawing as Tray.BadgeBitmap), centered on the tracker's dark brown
Add-Type -AssemblyName System.Drawing
function Save-Logo([int]$w, [int]$h, [string]$name) {
    $bmp = New-Object System.Drawing.Bitmap $w, $h
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.SmoothingMode = 'AntiAlias'; $g.TextRenderingHint = 'AntiAliasGridFit'
    $g.Clear([System.Drawing.Color]::FromArgb(20, 16, 10))
    $size = [Math]::Min($w, $h); $k = $size / 32.0
    $x0 = ($w - $size) / 2.0; $y0 = ($h - $size) / 2.0
    $gold = [System.Drawing.Color]::FromArgb(216, 180, 90)
    $pen = New-Object System.Drawing.Pen $gold, (2 * $k)
    $g.DrawRectangle($pen, [float]($x0 + $k), [float]($y0 + $k), [float](29 * $k), [float](29 * $k))
    $font = New-Object System.Drawing.Font 'Bahnschrift', ([float](15 * $k)), ([System.Drawing.FontStyle]::Bold), ([System.Drawing.GraphicsUnit]::Pixel)
    $fmt = New-Object System.Drawing.StringFormat; $fmt.Alignment = 'Center'; $fmt.LineAlignment = 'Center'
    $brush = New-Object System.Drawing.SolidBrush $gold
    $rect = New-Object System.Drawing.RectangleF ([float]$x0), ([float]($y0 + $k)), ([float]$size), ([float]$size)
    $g.DrawString('XP', $font, $brush, $rect, $fmt)
    $bmp.Save((Join-Path $layout "Assets\$name"), [System.Drawing.Imaging.ImageFormat]::Png)
    $g.Dispose(); $bmp.Dispose(); $pen.Dispose(); $font.Dispose(); $brush.Dispose()
}
Save-Logo 50 50 'StoreLogo.png'
Save-Logo 44 44 'Square44x44Logo.png'
Save-Logo 150 150 'Square150x150Logo.png'
Save-Logo 310 150 'Wide310x150Logo.png'

# ---- manifest
$manifest = (Get-Content (Join-Path $store 'AppxManifest.xml') -Raw).
    Replace('@NAME@', $id.Name).Replace('@PUBLISHER@', [Security.SecurityElement]::Escape($id.Publisher)).
    Replace('@PUBLISHERDISPLAYNAME@', [Security.SecurityElement]::Escape($id.PublisherDisplayName)).
    Replace('@DISPLAYNAME@', [Security.SecurityElement]::Escape($id.DisplayName)).Replace('@VERSION@', $version)
[IO.File]::WriteAllText((Join-Path $layout 'AppxManifest.xml'), $manifest, (New-Object Text.UTF8Encoding $false))

# ---- pack (MakeAppx also checks the manifest against the schema)
$msix = Join-Path $out "WardogsXpTracker-$version.msix"
& $makeappx pack /d $layout /p $msix /o
if ($LASTEXITCODE -ne 0) { throw 'MakeAppx failed' }
Write-Host "Built $msix"
