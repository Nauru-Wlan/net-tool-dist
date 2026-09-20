#Requires -Version 5.0
<#
    MacChanger.ps1
    Setzt eine zufaellige, lokal administrierte MAC-Adresse (LAN/WLAN-tauglich)
    fuer den aktiven Netzwerkadapter, merkt sich bereits verwendete Adressen,
    zeigt waehrend des Adapter-Neustarts einen Hinweis und prueft beim Start
    auf eine neuere Version (Auto-Update ueber GitHub) sowie eine gueltige
    Lizenz (ueber Google Apps Script).
#>
param(
    [switch]$SilentUpdateOnly
)

# =====================================================================
#  KONFIGURATION
# =====================================================================
$ScriptVersion     = "1.8.0"
$UpdateManifestUrl = "https://raw.githubusercontent.com/Nauru-Wlan/net-tool-dist/main/version.json"
$LicenseApiUrl     = "https://script.google.com/macros/s/AKfycbw0XvYlXlFoW7YwqrEaZhrmXVtBWdwK77b5K-sgLuY4RyweIoI2lU0V3Mohh9_868bM/exec"
# =====================================================================

# ---- Stiller Hintergrund-Update-Check (ueber Aufgabenplanung) ----
if ($SilentUpdateOnly) {
    try {
        $manifest = Invoke-RestMethod -Uri $UpdateManifestUrl -TimeoutSec 5 -ErrorAction Stop
        if ($manifest.version -and $manifest.url -and ([version]$manifest.version -gt [version]$ScriptVersion)) {
            $tempFile = Join-Path $env:TEMP "MacChanger_new.ps1"
            Invoke-WebRequest -Uri $manifest.url -OutFile $tempFile -TimeoutSec 15 -UseBasicParsing -ErrorAction Stop
            if ((Get-Item $tempFile).Length -ge 100) {
                Copy-Item -Path $tempFile -Destination $PSCommandPath -Force
                Remove-Item $tempFile -Force -ErrorAction SilentlyContinue
            }
        }
    } catch { }
    exit
}

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

# ---- Adminrechte sicherstellen (Registry-Aenderung erfordert das) ----
$currentPrincipal = New-Object Security.Principal.WindowsPrincipal(
    [Security.Principal.WindowsIdentity]::GetCurrent()
)
if (-not $currentPrincipal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Start-Process powershell -WindowStyle Hidden -ArgumentList `
        "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$PSCommandPath`"" -Verb RunAs
    exit
}

# =====================================================================
#  EINHEITLICHES DESIGN (passend zur Website)
#  Farben: Ultramarin, Goldstreifen, Weiss - angelehnt an die Nauru-Flagge.
#  Nur diese Werte aendern, wenn sich das Farbschema aendert.
# =====================================================================
$accentColor     = [System.Drawing.Color]::FromArgb(244, 194, 43)    # Gold
$textColor       = [System.Drawing.Color]::FromArgb(255, 255, 255)   # Weiss
$subTextColor    = [System.Drawing.Color]::FromArgb(205, 209, 234)   # gedaempftes Weiss auf Blau
$bgColor         = [System.Drawing.Color]::FromArgb(26, 47, 160)     # Ultramarin
$buttonTextColor = [System.Drawing.Color]::FromArgb(12, 18, 64)      # Tinte auf Gold
$inkColor        = [System.Drawing.Color]::FromArgb(12, 18, 64)      # Tinte
$paperColor      = [System.Drawing.Color]::FromArgb(251, 250, 246)   # Aufkleber-Papier
$mutedInkColor   = [System.Drawing.Color]::FromArgb(74, 81, 120)     # gedaempfte Tinte
$dashColor       = [System.Drawing.Color]::FromArgb(196, 199, 214)   # gestrichelte Linie
$trackColor      = [System.Drawing.Color]::FromArgb(58, 80, 184)     # Ladebalken-Hintergrund
$softButtonColor = [System.Drawing.Color]::FromArgb(48, 70, 178)     # Zweit-Button
$footerColor     = [System.Drawing.Color]::FromArgb(150, 162, 214)   # Marken-Fusszeile
$signalColor     = [System.Drawing.Color]::FromArgb(77, 232, 166)    # Status "ok" (nur als Text/Punkt)
$stepDimColor    = [System.Drawing.Color]::FromArgb(122, 138, 208)   # Schritt noch offen
$deepColor       = [System.Drawing.Color]::FromArgb(9, 18, 84)       # Konsolen-Flaeche
$depthColor      = [System.Drawing.Color]::FromArgb(165, 123, 6)     # Arcade-Kante unter dem Hauptbutton

function Set-RoundedRegion {
    param($Control, [int]$Radius = 10)
    $d  = $Radius * 2
    $w  = $Control.Width
    $h  = $Control.Height
    $gp = New-Object System.Drawing.Drawing2D.GraphicsPath
    $gp.AddArc(0, 0, $d, $d, 180, 90)
    $gp.AddArc($w - $d, 0, $d, $d, 270, 90)
    $gp.AddArc($w - $d, $h - $d, $d, $d, 0, 90)
    $gp.AddArc(0, $h - $d, $d, $d, 90, 90)
    $gp.CloseFigure()
    $Control.Region = New-Object System.Drawing.Region($gp)
}

# ---- 12-zackiger Stern (12 Hex-Ziffern einer MAC-Adresse) ----
function Get-StarPoints {
    param([double]$Cx, [double]$Cy, [double]$Ro, [double]$Ri)
    $pts = New-Object 'System.Drawing.PointF[]' 24
    for ($i = 0; $i -lt 24; $i++) {
        if ($i % 2 -eq 0) { $r = $Ro } else { $r = $Ri }
        $a = [Math]::PI * $i / 12 - [Math]::PI / 2
        $pts[$i] = [System.Drawing.PointF]::new([single]($Cx + $r * [Math]::Cos($a)), [single]($Cy + $r * [Math]::Sin($a)))
    }
    return , $pts
}

function New-StarPanel {
    param([int]$X, [int]$Y, [int]$Size = 36)
    $p = New-Object System.Windows.Forms.Panel
    $p.Location = New-Object System.Drawing.Point($X, $Y)
    $p.Size = New-Object System.Drawing.Size($Size, $Size)
    $p.BackColor = $bgColor
    $p.Add_Paint({
        param($s, $e)
        $e.Graphics.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
        $c   = $s.Width / 2.0
        $pts = Get-StarPoints -Cx $c -Cy $c -Ro ($c - 1) -Ri (($c - 1) * 0.55)
        $b   = New-Object System.Drawing.SolidBrush($script:accentColor)
        $e.Graphics.FillPolygon($b, $pts)
        $b.Dispose()
    })
    return $p
}

function New-AccentBar {
    param([System.Windows.Forms.Form]$TargetForm)
    $bar = New-Object System.Windows.Forms.Panel
    $bar.BackColor = $accentColor
    $bar.Dock = 'Top'
    $bar.Height = 8
    $TargetForm.Controls.Add($bar)
}

function New-BrandFooter {
    param([System.Windows.Forms.Form]$TargetForm)
    $footer = New-Object System.Windows.Forms.Label
    $footer.Text = "Nauru-Wlan"
    $footer.Font = New-Object System.Drawing.Font("Segoe UI", 8.5, [System.Drawing.FontStyle]::Bold)
    $footer.ForeColor = $footerColor
    $footer.TextAlign = [System.Drawing.ContentAlignment]::MiddleRight
    $footer.Dock = 'Bottom'
    $footer.Height = 26
    $footer.Padding = New-Object System.Windows.Forms.Padding(0, 0, 14, 0)
    $footer.Add_Paint({
        param($s, $e)
        $e.Graphics.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
        $tw  = [System.Windows.Forms.TextRenderer]::MeasureText($s.Text, $s.Font).Width
        $cx  = $s.Width - 14 - $tw - 8
        $cy  = $s.Height / 2.0
        $pts = Get-StarPoints -Cx $cx -Cy $cy -Ro 6.5 -Ri 3.6
        $b   = New-Object System.Drawing.SolidBrush($script:accentColor)
        $e.Graphics.FillPolygon($b, $pts)
        $b.Dispose()
    })
    $TargetForm.Controls.Add($footer)
}

function New-StyledButton {
    param([string]$Text, [int]$Width = 240, [int]$Height = 40)
    $btn = New-Object System.Windows.Forms.Button
    $btn.Text = $Text
    $btn.Size = New-Object System.Drawing.Size($Width, $Height)
    $btn.FlatStyle = 'Flat'
    $btn.FlatAppearance.BorderSize = 0
    $btn.FlatAppearance.MouseOverBackColor = [System.Drawing.Color]::FromArgb(255, 210, 77)
    $btn.FlatAppearance.MouseDownBackColor = [System.Drawing.Color]::FromArgb(226, 174, 30)
    $btn.BackColor = $accentColor
    $btn.ForeColor = $buttonTextColor
    $btn.Font = New-Object System.Drawing.Font("Segoe UI", 10.5, [System.Drawing.FontStyle]::Bold)
    $btn.Cursor = [System.Windows.Forms.Cursors]::Hand
    Set-RoundedRegion -Control $btn -Radius 9
    return $btn
}

function New-SecondaryButton {
    param([string]$Text, [int]$Width = 120, [int]$Height = 36)
    $btn = New-Object System.Windows.Forms.Button
    $btn.Text = $Text
    $btn.Size = New-Object System.Drawing.Size($Width, $Height)
    $btn.FlatStyle = 'Flat'
    $btn.FlatAppearance.BorderSize = 0
    $btn.FlatAppearance.MouseOverBackColor = [System.Drawing.Color]::FromArgb(64, 88, 196)
    $btn.FlatAppearance.MouseDownBackColor = [System.Drawing.Color]::FromArgb(40, 60, 160)
    $btn.BackColor = $softButtonColor
    $btn.ForeColor = $textColor
    $btn.Font = New-Object System.Drawing.Font("Segoe UI", 10)
    $btn.Cursor = [System.Windows.Forms.Cursors]::Hand
    Set-RoundedRegion -Control $btn -Radius 9
    return $btn
}

# ---- Goldener Ladebalken (ersetzt die gruene Windows-Standardleiste) ----
function New-GoldProgress {
    param([int]$X, [int]$Y, [int]$Width)
    $track = New-Object System.Windows.Forms.Panel
    $track.Location = New-Object System.Drawing.Point($X, $Y)
    $track.Size = New-Object System.Drawing.Size($Width, 8)
    $track.BackColor = $trackColor

    $bar = New-Object System.Windows.Forms.Panel
    $barWidth = [int]($Width * 0.28)
    $bar.Size = New-Object System.Drawing.Size($barWidth, 8)
    $bar.BackColor = $accentColor
    $bar.Left = -$barWidth
    $track.Controls.Add($bar)
    Set-RoundedRegion -Control $track -Radius 4

    $sw    = [System.Diagnostics.Stopwatch]::StartNew()
    $timer = New-Object System.Windows.Forms.Timer
    $timer.Interval = 30
    $timer.Add_Tick({
        if ($track.IsDisposed) { $timer.Stop(); return }
        if (-not $track.Visible) { return }
        $t = ($sw.ElapsedMilliseconds % 1500) / 1500.0
        $bar.Left = [int](-$bar.Width + ($track.Width + $bar.Width) * $t)
    }.GetNewClosure())
    $timer.Start()
    $track.Tag = $timer
    return $track
}

# ---- MAC-Aufkleber (wie auf einem Router, inkl. Barcode aus der Adresse) ----
function New-StickerPanel {
    param([int]$X, [int]$Y, [int]$Width = 376, [string]$HeadLeft = "", [string]$HeadRight = "", [string]$MacHex = "")

    $panel = New-Object System.Windows.Forms.Panel
    $panel.Location = New-Object System.Drawing.Point($X, $Y)
    $panel.Size = New-Object System.Drawing.Size($Width, 132)
    $panel.BackColor = $paperColor
    $panel.Tag = $MacHex

    $left = New-Object System.Windows.Forms.Label
    $left.Text = $HeadLeft
    $left.Font = New-Object System.Drawing.Font("Segoe UI", 9, [System.Drawing.FontStyle]::Bold)
    $left.ForeColor = $mutedInkColor
    $left.AutoSize = $false
    $left.Size = New-Object System.Drawing.Size(([int](($Width - 32) * 0.55)), 20)
    $left.Location = New-Object System.Drawing.Point(16, 10)
    $panel.Controls.Add($left)

    $right = New-Object System.Windows.Forms.Label
    $right.Text = $HeadRight
    $right.Font = New-Object System.Drawing.Font("Segoe UI", 9, [System.Drawing.FontStyle]::Bold)
    $right.ForeColor = $mutedInkColor
    $right.AutoSize = $false
    $right.TextAlign = [System.Drawing.ContentAlignment]::MiddleRight
    $rw = [int](($Width - 32) * 0.4)
    $right.Size = New-Object System.Drawing.Size($rw, 20)
    $right.Location = New-Object System.Drawing.Point(($Width - 16 - $rw), 10)
    $panel.Controls.Add($right)

    $macLabel = New-Object System.Windows.Forms.Label
    $macLabel.Font = New-Object System.Drawing.Font("Consolas", 19, [System.Drawing.FontStyle]::Bold)
    $macLabel.ForeColor = $inkColor
    $macLabel.AutoSize = $false
    $macLabel.TextAlign = [System.Drawing.ContentAlignment]::MiddleLeft
    $macLabel.Size = New-Object System.Drawing.Size(($Width - 32), 38)
    $macLabel.Location = New-Object System.Drawing.Point(16, 44)
    $panel.Controls.Add($macLabel)

    $panel.Add_Paint({
        param($s, $e)
        $g = $e.Graphics

        # gestrichelte Trennlinie unter der Kopfzeile
        $pen = New-Object System.Drawing.Pen($script:dashColor, 1)
        $pen.DashStyle = [System.Drawing.Drawing2D.DashStyle]::Dash
        $g.DrawLine($pen, 16, 36, ($s.Width - 16), 36)
        $pen.Dispose()

        # HUD-Ecken (kleine goldene Winkel in den vier Ecken)
        $hud = New-Object System.Drawing.Pen($script:accentColor, 2)
        $wd = $s.Width; $ht = $s.Height; $q = 7; $e2 = 11
        $P = { param($x, $y) New-Object System.Drawing.Point($x, $y) }
        $g.DrawLines($hud, [System.Drawing.Point[]]@((& $P $q ($q + $e2)), (& $P $q $q), (& $P ($q + $e2) $q)))
        $g.DrawLines($hud, [System.Drawing.Point[]]@((& $P ($wd - $q - $e2) $q), (& $P ($wd - $q) $q), (& $P ($wd - $q) ($q + $e2))))
        $g.DrawLines($hud, [System.Drawing.Point[]]@((& $P $q ($ht - $q - $e2)), (& $P $q ($ht - $q)), (& $P ($q + $e2) ($ht - $q))))
        $g.DrawLines($hud, [System.Drawing.Point[]]@((& $P ($wd - $q - $e2) ($ht - $q)), (& $P ($wd - $q) ($ht - $q)), (& $P ($wd - $q) ($ht - $q - $e2))))
        $hud.Dispose()

        # Barcode aus den 12 Hex-Ziffern
        $hex = [string]$s.Tag
        if ($hex.Length -eq 12) {
            $seq = New-Object 'System.Collections.Generic.List[int]'
            foreach ($v in 2, 1, 1, 2) { $seq.Add($v) }
            foreach ($ch in $hex.ToCharArray()) {
                $val = [Convert]::ToInt32([string]$ch, 16)
                for ($b = 3; $b -ge 0; $b--) {
                    if ((($val -shr $b) -band 1) -eq 1) { $seq.Add(3); $seq.Add(1) }
                    else { $seq.Add(1); $seq.Add(2) }
                }
            }
            foreach ($v in 1, 1, 2) { $seq.Add($v) }

            $total = 0
            foreach ($v in $seq) { $total += $v }
            $scale = ($s.Width - 32) / [double]$total
            $brush = New-Object System.Drawing.SolidBrush($script:inkColor)
            $x = 0.0
            for ($i = 0; $i -lt $seq.Count; $i++) {
                $w = $seq[$i] * $scale
                if ($i % 2 -eq 0) {
                    $g.FillRectangle($brush, [single](16 + $x), [single]92, [single]$w, [single]26)
                }
                $x += $w
            }
            $brush.Dispose()
        }
    })

    Set-RoundedRegion -Control $panel -Radius 12
    $sticker = @{ Panel = $panel; Left = $left; Right = $right; Mac = $macLabel }
    Set-StickerMac -Sticker $sticker -MacHex $MacHex
    return $sticker
}

function Set-StickerMac {
    param($Sticker, [string]$MacHex)
    $Sticker.Panel.Tag = $MacHex
    if ($MacHex.Length -eq 12) {
        $Sticker.Mac.Text = ($MacHex -replace '(..)(?!$)', '$1:')
    } else {
        $Sticker.Mac.Text = "--:--:--:--:--:--"
    }
    $Sticker.Panel.Invalidate()
}

# ---- Eigene Meldungsfenster (statt der weissen Windows-Standarddialoge) ----
function Show-ThemedMessage {
    param([string]$Title, [string]$Message, [string]$MacHex = "", [string]$ButtonText = "OK")

    $dlg = New-Object System.Windows.Forms.Form
    $dlg.Text = $Title
    $dlg.FormBorderStyle = 'FixedDialog'
    $dlg.StartPosition = "CenterScreen"
    $dlg.MaximizeBox = $false
    $dlg.MinimizeBox = $false
    $dlg.TopMost = $true
    $dlg.BackColor = $bgColor
    if ($appIcon) { $dlg.Icon = $appIcon }

    New-AccentBar -TargetForm $dlg

    $titleLabel = New-Object System.Windows.Forms.Label
    $titleLabel.Text = $Title
    $titleLabel.Font = New-Object System.Drawing.Font("Segoe UI", 14, [System.Drawing.FontStyle]::Bold)
    $titleLabel.ForeColor = $textColor
    $titleLabel.AutoSize = $false
    $titleLabel.Size = New-Object System.Drawing.Size(376, 32)
    $titleLabel.Location = New-Object System.Drawing.Point(24, 28)
    $dlg.Controls.Add($titleLabel)

    $msgFont = New-Object System.Drawing.Font("Segoe UI", 10)
    $flags   = [System.Windows.Forms.TextFormatFlags]::WordBreak
    $msgSize = [System.Windows.Forms.TextRenderer]::MeasureText($Message, $msgFont, (New-Object System.Drawing.Size(376, 0)), $flags)
    $msgHeight = $msgSize.Height + 8

    $msgLabel = New-Object System.Windows.Forms.Label
    $msgLabel.Text = $Message
    $msgLabel.Font = $msgFont
    $msgLabel.ForeColor = $subTextColor
    $msgLabel.AutoSize = $false
    $msgLabel.Size = New-Object System.Drawing.Size(376, $msgHeight)
    $msgLabel.Location = New-Object System.Drawing.Point(24, 66)
    $dlg.Controls.Add($msgLabel)

    $y = 66 + $msgHeight + 18

    if ($MacHex.Length -eq 12) {
        $st = New-StickerPanel -X 24 -Y $y -Width 376 -HeadLeft "Neue MAC-Adresse" -HeadRight "aktiv" -MacHex $MacHex
        $dlg.Controls.Add($st.Panel)
        $y += 132 + 22
    }

    $ok = New-StyledButton -Text $ButtonText -Width 376 -Height 42
    $ok.Location = New-Object System.Drawing.Point(24, $y)
    $ok.DialogResult = [System.Windows.Forms.DialogResult]::OK
    $dlg.Controls.Add($ok)
    $dlg.AcceptButton = $ok

    New-BrandFooter -TargetForm $dlg

    $dlg.ClientSize = New-Object System.Drawing.Size(424, ($y + 42 + 22 + 26))
    [void]$dlg.ShowDialog()
    $dlg.Dispose()
}

# ---- Icon aus shell32.dll laden (einheitliches Aussehen statt PowerShell-Symbol) ----
Add-Type @"
using System;
using System.Runtime.InteropServices;
public class IconExtractor {
    [DllImport("shell32.dll", CharSet = CharSet.Auto)]
    public static extern int ExtractIconEx(string lpszFile, int nIconIndex, IntPtr[] phiconLarge, IntPtr[] phiconSmall, int nIcons);
}
"@

function Get-AppIcon {
    try {
        $large = New-Object IntPtr[] 1
        $small = New-Object IntPtr[] 1
        [IconExtractor]::ExtractIconEx("$env:SystemRoot\System32\shell32.dll", 43, $large, $small, 1) | Out-Null
        if ($large[0] -ne [IntPtr]::Zero) {
            return [System.Drawing.Icon]::FromHandle($large[0])
        }
    } catch { }
    return $null
}
$appIcon = Get-AppIcon

function Show-FriendlyError {
    param([string]$Message, [string]$Title = "Fehler")
    Show-ThemedMessage -Title $Title -Message $Message
}

# ---- Speicherort fuer bereits verwendete MAC-Adressen (versteckt) ----
$dataDir  = Join-Path $env:LOCALAPPDATA "MacRandomizer"
$usedFile = Join-Path $dataDir "used_macs.dat"

if (-not (Test-Path $dataDir)) {
    New-Item -Path $dataDir -ItemType Directory -Force | Out-Null
    try { (Get-Item $dataDir -ErrorAction Stop).Attributes = 'Hidden' } catch { }
}
if (-not (Test-Path $usedFile)) {
    New-Item -Path $usedFile -ItemType File -Force | Out-Null
    try { (Get-Item $usedFile -ErrorAction Stop).Attributes = 'Hidden' } catch { }
}

$licenseFile = Join-Path $dataDir "license.dat"

# =====================================================================
#  LADEBILDSCHIRM (waehrend Update-/Lizenzpruefung im Hintergrund laeuft)
# =====================================================================
function New-SplashForm {
    $splash = New-Object System.Windows.Forms.Form
    $splash.Text = "MAC-Adressen-Wechsler"
    $splash.StartPosition = "CenterScreen"
    $splash.FormBorderStyle = 'FixedDialog'
    $splash.ControlBox = $false
    $splash.MaximizeBox = $false
    $splash.MinimizeBox = $false
    $splash.TopMost = $true
    $splash.BackColor = $bgColor
    if ($appIcon) { $splash.Icon = $appIcon }

    New-AccentBar -TargetForm $splash

    $splash.Controls.Add((New-StarPanel -X 162 -Y 32 -Size 36))

    $splashLabel = New-Object System.Windows.Forms.Label
    $splashLabel.Text = "> Wird gestartet ..."
    $splashLabel.Font = New-Object System.Drawing.Font("Consolas", 11.5, [System.Drawing.FontStyle]::Bold)
    $splashLabel.ForeColor = $textColor
    $splashLabel.TextAlign = [System.Drawing.ContentAlignment]::MiddleCenter
    $splashLabel.Size = New-Object System.Drawing.Size(320, 30)
    $splashLabel.Location = New-Object System.Drawing.Point(20, 80)
    $splash.Controls.Add($splashLabel)

    $splash.Controls.Add((New-GoldProgress -X 40 -Y 126 -Width 280))

    New-BrandFooter -TargetForm $splash

    $splash.ClientSize = New-Object System.Drawing.Size(360, 190)
    return @{ Form = $splash; Label = $splashLabel }
}

function Set-SplashStatus {
    param($Splash, [string]$Text)
    $Splash.Label.Text = "> " + $Text
    $Splash.Form.Refresh()
    [System.Windows.Forms.Application]::DoEvents()
}

$splash = New-SplashForm
$splash.Form.Show()
Set-SplashStatus -Splash $splash -Text "Wird gestartet ..."

# =====================================================================
#  LIZENZ-FUNKTIONEN
# =====================================================================
function Get-StoredLicenseKey {
    if (Test-Path $licenseFile) { return (Get-Content $licenseFile -Raw).Trim() }
    return $null
}

function Set-StoredLicenseKey {
    param([string]$Key)
    Set-Content -Path $licenseFile -Value $Key -NoNewline -ErrorAction Stop
    try { (Get-Item $licenseFile -ErrorAction Stop).Attributes = 'Hidden' } catch { }
}

function Get-HardwareId {
    try {
        $uuid = (Get-CimInstance -ClassName Win32_ComputerSystemProduct -ErrorAction Stop).UUID
        $bios = (Get-CimInstance -ClassName Win32_BIOS -ErrorAction Stop).SerialNumber
        $raw  = "$uuid-$bios"
    } catch {
        $raw = $env:COMPUTERNAME
    }
    $sha   = [System.Security.Cryptography.SHA256]::Create()
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($raw)
    $hash  = $sha.ComputeHash($bytes)
    return ([BitConverter]::ToString($hash) -replace '-', '').Substring(0, 32)
}

function Test-LicenseOnline {
    param([string]$Key, [string]$Hwid)
    try {
        $url  = "$LicenseApiUrl`?key=$([uri]::EscapeDataString($Key))&hwid=$Hwid"
        $resp = Invoke-RestMethod -Uri $url -TimeoutSec 10 -ErrorAction Stop
        return $resp.status
    } catch {
        return "offline"
    }
}

function Show-LicenseDialog {
    $dlg = New-Object System.Windows.Forms.Form
    $dlg.Text = "Lizenz aktivieren"
    $dlg.StartPosition = "CenterScreen"
    $dlg.FormBorderStyle = 'FixedDialog'
    $dlg.MaximizeBox = $false
    $dlg.MinimizeBox = $false
    $dlg.BackColor = $bgColor
    if ($appIcon) { $dlg.Icon = $appIcon }

    New-AccentBar -TargetForm $dlg

    $title = New-Object System.Windows.Forms.Label
    $title.Text = "Lizenzschluessel eingeben"
    $title.Font = New-Object System.Drawing.Font("Segoe UI", 14, [System.Drawing.FontStyle]::Bold)
    $title.ForeColor = $textColor
    $title.Size = New-Object System.Drawing.Size(376, 32)
    $title.Location = New-Object System.Drawing.Point(24, 28)
    $dlg.Controls.Add($title)

    $sub = New-Object System.Windows.Forms.Label
    $sub.Text = "Den Schluessel hast du nach dem Kauf erhalten."
    $sub.Font = New-Object System.Drawing.Font("Segoe UI", 9.5)
    $sub.ForeColor = $subTextColor
    $sub.Size = New-Object System.Drawing.Size(376, 22)
    $sub.Location = New-Object System.Drawing.Point(24, 64)
    $dlg.Controls.Add($sub)

    # Eingabefeld auf "Papier": abgerundeter Rahmen, Textfeld ohne eigenen Rand
    $field = New-Object System.Windows.Forms.Panel
    $field.Size = New-Object System.Drawing.Size(376, 42)
    $field.Location = New-Object System.Drawing.Point(24, 100)
    $field.BackColor = $paperColor
    Set-RoundedRegion -Control $field -Radius 9
    $dlg.Controls.Add($field)

    $textBox = New-Object System.Windows.Forms.TextBox
    $textBox.Font = New-Object System.Drawing.Font("Consolas", 11.5)
    $textBox.Size = New-Object System.Drawing.Size(348, 26)
    $textBox.Location = New-Object System.Drawing.Point(14, 9)
    $textBox.BackColor = $paperColor
    $textBox.ForeColor = $inkColor
    $textBox.BorderStyle = 'None'
    $field.Controls.Add($textBox)

    $okButton = New-StyledButton -Text "Aktivieren" -Width 200 -Height 42
    $okButton.Location = New-Object System.Drawing.Point(24, 162)
    $okButton.DialogResult = [System.Windows.Forms.DialogResult]::OK
    $dlg.Controls.Add($okButton)

    $cancelButton = New-SecondaryButton -Text "Abbrechen" -Width 164 -Height 42
    $cancelButton.Location = New-Object System.Drawing.Point(236, 162)
    $cancelButton.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
    $dlg.Controls.Add($cancelButton)

    $dlg.AcceptButton = $okButton
    $dlg.CancelButton = $cancelButton
    $dlg.Add_Shown({ $textBox.Focus() })

    New-BrandFooter -TargetForm $dlg

    $dlg.ClientSize = New-Object System.Drawing.Size(424, 250)

    $result = $dlg.ShowDialog()
    if ($result -eq [System.Windows.Forms.DialogResult]::OK) {
        return $textBox.Text.Trim()
    }
    return $null
}

function Confirm-License {
    try {
        $storedKey = Get-StoredLicenseKey
        $hadStoredKeyBefore = [bool]$storedKey

        if (-not $storedKey) {
            $splash.Form.Hide()
            $storedKey = Show-LicenseDialog
            $splash.Form.Show()
            if ([string]::IsNullOrWhiteSpace($storedKey)) {
                $splash.Form.Hide()
                Show-FriendlyError -Title "Lizenz erforderlich" `
                    -Message "Ohne gueltigen Lizenzschluessel kann das Tool nicht gestartet werden."
                exit
            }
        }

        Set-SplashStatus -Splash $splash -Text "Lizenz wird geprueft ..."
        $hwid   = Get-HardwareId
        $status = Test-LicenseOnline -Key $storedKey -Hwid $hwid

        switch ($status) {
            "ok" {
                Set-StoredLicenseKey -Key $storedKey
                return
            }
            "invalid" {
                Remove-Item $licenseFile -ErrorAction SilentlyContinue
                $splash.Form.Hide()
                Show-FriendlyError -Title "Ungueltiger Schluessel" `
                    -Message "Der eingegebene Lizenzschluessel ist ungueltig."
                exit
            }
            "used_by_other_device" {
                $splash.Form.Hide()
                Show-FriendlyError -Title "Lizenz bereits verwendet" `
                    -Message "Dieser Lizenzschluessel wird bereits auf einem anderen Geraet verwendet."
                exit
            }
            "offline" {
                if ($hadStoredKeyBefore) {
                    return
                } else {
                    $splash.Form.Hide()
                    Show-FriendlyError -Title "Keine Verbindung" `
                        -Message "Fuer die Erstaktivierung wird eine Internetverbindung benoetigt."
                    exit
                }
            }
        }
    } catch {
        $splash.Form.Hide()
        Show-FriendlyError -Title "Unerwarteter Fehler" `
            -Message "Bei der Lizenzpruefung ist ein unerwarteter Fehler aufgetreten.`nBitte versuche es spaeter erneut."
        exit
    }
}

# =====================================================================
#  MAC-WECHSEL-FUNKTIONEN
# =====================================================================
function Get-UsedMacs {
    if (Test-Path $usedFile) { @(Get-Content $usedFile) } else { @() }
}

function Add-UsedMac {
    param([string]$Mac)
    Add-Content -Path $usedFile -Value $Mac
}

function New-RandomMac {
    $used = Get-UsedMacs
    do {
        $bytes = 1..6 | ForEach-Object { Get-Random -Minimum 0 -Maximum 256 }
        # Bit 1 setzen (lokal administriert), Bit 0 loeschen (Unicast) -> LAN+WLAN gueltig
        $bytes[0] = ($bytes[0] -band 0xFE) -bor 0x02
        $mac = ($bytes | ForEach-Object { "{0:X2}" -f $_ }) -join ""
    } while ($used -contains $mac)
    return $mac
}

function Format-Mac {
    param([string]$Mac)
    return ($Mac -replace '(..)(?!$)', '$1:')
}

function Get-ActiveAdapter {
    $route = Get-NetRoute -DestinationPrefix "0.0.0.0/0" -ErrorAction SilentlyContinue |
        Sort-Object -Property RouteMetric | Select-Object -First 1
    if ($route) {
        $a = Get-NetAdapter -InterfaceIndex $route.InterfaceIndex -ErrorAction SilentlyContinue
        if ($a) { return $a }
    }
    return Get-NetAdapter | Where-Object Status -eq 'Up' | Select-Object -First 1
}

# ---- Schritt-Anzeige im Wartefenster ([  ] offen, [..] laeuft, [ok] fertig) ----
function Set-NoticeStep {
    param([System.Windows.Forms.Form]$Form, [int]$Index, [string]$State)
    $lbl = $Form.Tag[$Index]
    switch ($State) {
        "todo" { $lbl.Text = "[  ] " + $lbl.Tag; $lbl.ForeColor = $script:stepDimColor }
        "run"  { $lbl.Text = "[..] " + $lbl.Tag; $lbl.ForeColor = $script:accentColor }
        "ok"   { $lbl.Text = "[ok] " + $lbl.Tag; $lbl.ForeColor = $script:signalColor }
    }
    $Form.Refresh()
    [System.Windows.Forms.Application]::DoEvents()
}

function Set-AdapterMac {
    param($Adapter, [string]$Mac, [System.Windows.Forms.Form]$NoticeForm)

    try {
        $classGuid = "{4d36e972-e325-11ce-bfc1-08002be10318}"
        $classPath = "HKLM:\SYSTEM\CurrentControlSet\Control\Class\$classGuid"
        $subkeys   = Get-ChildItem $classPath -ErrorAction Stop

        $target = $null
        foreach ($key in $subkeys) {
            $props = Get-ItemProperty -Path $key.PSPath -ErrorAction SilentlyContinue
            if ($props.NetCfgInstanceId -eq $Adapter.InterfaceGuid) {
                $target = $key.PSPath
                break
            }
        }
        if (-not $target) {
            return @{ Success = $false; Error = "Registry-Eintrag fuer diesen Adapter wurde nicht gefunden." }
        }

        Set-ItemProperty -Path $target -Name "NetworkAddress" -Value $Mac -Type String -ErrorAction Stop

        for ($k = 0; $k -lt 4; $k++) { Set-NoticeStep -Form $NoticeForm -Index $k -State "todo" }
        $NoticeForm.Show()
        $NoticeForm.Refresh()
        Set-NoticeStep -Form $NoticeForm -Index 0 -State "ok"

        Set-NoticeStep -Form $NoticeForm -Index 1 -State "run"
        Disable-NetAdapter -Name $Adapter.Name -Confirm:$false -ErrorAction Stop
        for ($i = 0; $i -lt 10; $i++) {
            Start-Sleep -Milliseconds 200
            [System.Windows.Forms.Application]::DoEvents()
        }
        Set-NoticeStep -Form $NoticeForm -Index 1 -State "ok"

        Set-NoticeStep -Form $NoticeForm -Index 2 -State "run"
        Enable-NetAdapter -Name $Adapter.Name -Confirm:$false -ErrorAction Stop
        for ($i = 0; $i -lt 10; $i++) {
            Start-Sleep -Milliseconds 200
            [System.Windows.Forms.Application]::DoEvents()
        }
        Set-NoticeStep -Form $NoticeForm -Index 2 -State "ok"
        Set-NoticeStep -Form $NoticeForm -Index 3 -State "ok"
        for ($i = 0; $i -lt 2; $i++) {
            Start-Sleep -Milliseconds 200
            [System.Windows.Forms.Application]::DoEvents()
        }

        $NoticeForm.Hide()
        return @{ Success = $true; Error = $null }
    } catch {
        $NoticeForm.Hide()
        return @{ Success = $false; Error = $_.Exception.Message }
    }
}

function New-NoticeForm {
    $notice = New-Object System.Windows.Forms.Form
    $notice.Text = "Bitte kurz warten"
    $notice.StartPosition = "CenterScreen"
    $notice.FormBorderStyle = 'FixedDialog'
    $notice.ControlBox = $false
    $notice.MaximizeBox = $false
    $notice.MinimizeBox = $false
    $notice.TopMost = $true
    $notice.BackColor = $bgColor
    if ($appIcon) { $notice.Icon = $appIcon }

    New-AccentBar -TargetForm $notice

    $notice.Controls.Add((New-StarPanel -X 202 -Y 26 -Size 36))

    $noticeLabel = New-Object System.Windows.Forms.Label
    $noticeLabel.Text = "Verbindung wird neu aufgebaut"
    $noticeLabel.ForeColor = $textColor
    $noticeLabel.Font = New-Object System.Drawing.Font("Segoe UI", 13, [System.Drawing.FontStyle]::Bold)
    $noticeLabel.TextAlign = [System.Drawing.ContentAlignment]::MiddleCenter
    $noticeLabel.Size = New-Object System.Drawing.Size(400, 32)
    $noticeLabel.Location = New-Object System.Drawing.Point(20, 70)
    $notice.Controls.Add($noticeLabel)

    # Konsolen-Flaeche mit den vier Schritten
    $console = New-Object System.Windows.Forms.Panel
    $console.Size = New-Object System.Drawing.Size(360, 108)
    $console.Location = New-Object System.Drawing.Point(40, 112)
    $console.BackColor = $deepColor
    Set-RoundedRegion -Control $console -Radius 6
    $notice.Controls.Add($console)

    $texts = @("Adresse in Registry schreiben", "Adapter trennen", "Adapter starten", "Neue Adresse aktiv")
    $labels = @()
    for ($k = 0; $k -lt 4; $k++) {
        $l = New-Object System.Windows.Forms.Label
        $l.Tag = $texts[$k]
        $l.Text = "[  ] " + $texts[$k]
        $l.Font = New-Object System.Drawing.Font("Consolas", 10.5)
        $l.ForeColor = $stepDimColor
        $l.AutoSize = $false
        $l.Size = New-Object System.Drawing.Size(330, 22)
        $l.Location = New-Object System.Drawing.Point(16, (10 + $k * 24))
        $console.Controls.Add($l)
        $labels += $l
    }
    $notice.Tag = $labels

    $notice.Controls.Add((New-GoldProgress -X 60 -Y 236 -Width 320))

    New-BrandFooter -TargetForm $notice

    $notice.ClientSize = New-Object System.Drawing.Size(440, 290)
    return $notice
}

# =====================================================================
#  AUTO-UPDATE
# =====================================================================
function Test-AndApplyUpdate {
    Set-SplashStatus -Splash $splash -Text "Suche nach Updates ..."
    try {
        $manifest = Invoke-RestMethod -Uri $UpdateManifestUrl -TimeoutSec 5 -ErrorAction Stop
    } catch {
        return $false
    }

    if (-not $manifest.version -or -not $manifest.url) { return $false }

    if ([version]$manifest.version -le [version]$ScriptVersion) {
        return $false
    }

    try {
        Set-SplashStatus -Splash $splash -Text "Update wird installiert ..."
        $tempFile = Join-Path $env:TEMP "MacChanger_new.ps1"
        Invoke-WebRequest -Uri $manifest.url -OutFile $tempFile -TimeoutSec 15 -UseBasicParsing -ErrorAction Stop

        if ((Get-Item $tempFile).Length -lt 100) { return $false }

        Copy-Item -Path $tempFile -Destination $PSCommandPath -Force
        Remove-Item $tempFile -Force -ErrorAction SilentlyContinue

        $splash.Form.Hide()
        Show-ThemedMessage -Title "Update installiert" `
            -Message "Eine neue Version ($($manifest.version)) wurde installiert.`nDas Tool wird jetzt neu gestartet."

        Start-Process powershell -WindowStyle Hidden -ArgumentList `
            "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$PSCommandPath`""
        return $true
    } catch {
        return $false
    }
}

if (Test-AndApplyUpdate) {
    exit
}

Confirm-License

Set-SplashStatus -Splash $splash -Text "Bereit."
$splash.Form.Close()

# =====================================================================
#  HAUPTFENSTER
# =====================================================================
$form = New-Object System.Windows.Forms.Form
$form.Text = "MAC-Adressen-Wechsler"
$form.StartPosition = "CenterScreen"
$form.FormBorderStyle = 'FixedDialog'
$form.MaximizeBox = $false
$form.MinimizeBox = $false
$form.BackColor = $bgColor
if ($appIcon) { $form.Icon = $appIcon }

New-AccentBar -TargetForm $form

$titleMain = New-Object System.Windows.Forms.Label
$titleMain.Text = "Neue MAC-Adresse"
$titleMain.Font = New-Object System.Drawing.Font("Segoe UI", 17, [System.Drawing.FontStyle]::Bold)
$titleMain.ForeColor = $textColor
$titleMain.AutoSize = $false
$titleMain.Size = New-Object System.Drawing.Size(376, 36)
$titleMain.Location = New-Object System.Drawing.Point(24, 26)
$form.Controls.Add($titleMain)

$label = New-Object System.Windows.Forms.Label
$label.Text = "Ein Klick setzt fuer den aktiven Netzwerkadapter eine frische, zufaellige Adresse."
$label.Font = New-Object System.Drawing.Font("Segoe UI", 10)
$label.ForeColor = $subTextColor
$label.AutoSize = $false
$label.Size = New-Object System.Drawing.Size(376, 44)
$label.Location = New-Object System.Drawing.Point(24, 64)
$form.Controls.Add($label)

$sticker = New-StickerPanel -X 24 -Y 118 -Width 376 -HeadLeft "wird ermittelt ..." -HeadRight "Aktuelle Adresse" -MacHex ""
$form.Controls.Add($sticker.Panel)

# Arcade-Kante: dunkle Flaeche unter dem Button, der beim Druecken absinkt
$btnShadow = New-Object System.Windows.Forms.Panel
$btnShadow.Size = New-Object System.Drawing.Size(376, 46)
$btnShadow.Location = New-Object System.Drawing.Point(24, 277)
$btnShadow.BackColor = $depthColor
Set-RoundedRegion -Control $btnShadow -Radius 9
$form.Controls.Add($btnShadow)

$button = New-StyledButton -Text "Neue MAC-Adresse einstellen" -Width 376 -Height 46
$button.Location = New-Object System.Drawing.Point(24, 272)
$form.Controls.Add($button)
$button.BringToFront()
$button.Add_MouseDown({ $button.Top = 275 })
$button.Add_MouseUp({ $button.Top = 272 })

$consoleLine = New-Object System.Windows.Forms.Label
$consoleLine.Text = "> bereit"
$consoleLine.Font = New-Object System.Drawing.Font("Consolas", 9.5)
$consoleLine.ForeColor = $subTextColor
$consoleLine.AutoSize = $false
$consoleLine.Size = New-Object System.Drawing.Size(376, 22)
$consoleLine.Location = New-Object System.Drawing.Point(24, 340)
$form.Controls.Add($consoleLine)

New-BrandFooter -TargetForm $form

$form.ClientSize = New-Object System.Drawing.Size(424, 402)

function Update-StatusLabel {
    try {
        $adapter = Get-ActiveAdapter
        if ($adapter) {
            $sticker.Left.Text = [string]$adapter.Name
            $consoleLine.Text = "> bereit. Adapter: " + [string]$adapter.Name
            $hex = ([string]$adapter.MacAddress) -replace '[-:]', ''
            Set-StickerMac -Sticker $sticker -MacHex $hex
        } else {
            $sticker.Left.Text = "kein aktiver Adapter gefunden"
            $consoleLine.Text = "> kein aktiver Adapter"
            Set-StickerMac -Sticker $sticker -MacHex ""
        }
    } catch {
        $sticker.Left.Text = "Adapterstatus nicht ermittelbar"
        Set-StickerMac -Sticker $sticker -MacHex ""
    }
}

$noticeForm = New-NoticeForm

$button.Add_Click({
    try {
        $button.Enabled = $false
        $button.Text = "Wird eingestellt ..."
        $consoleLine.Text = "> Adresse wird gesetzt ..."
        $form.Refresh()

        $adapter = Get-ActiveAdapter
        if (-not $adapter) {
            Show-FriendlyError -Message "Kein aktiver Netzwerkadapter gefunden.`nBitte pruefe deine Internetverbindung und versuche es erneut."
        } else {
            $mac = New-RandomMac
            $result = Set-AdapterMac -Adapter $adapter -Mac $mac -NoticeForm $noticeForm

            if ($result.Success) {
                Add-UsedMac $mac
                $form.Hide()
                Show-ThemedMessage -Title "Erfolg" `
                    -Message "Die neue Adresse ist gesetzt. Die Verbindung braucht eventuell noch ein paar Sekunden zum Aufbauen." `
                    -MacHex $mac
                $form.Close()
                return
            } else {
                Show-FriendlyError -Message "Die MAC-Adresse konnte nicht geaendert werden.`n`nBitte versuche es erneut. Falls das Problem bestehen bleibt, starte den PC neu."
            }
        }
    } catch {
        Show-FriendlyError -Message "Es ist ein unerwarteter Fehler aufgetreten.`nBitte versuche es erneut oder starte den PC neu."
    }

    Update-StatusLabel
    $button.Top = 272
    $button.Enabled = $true
    $button.Text = "Neue MAC-Adresse einstellen"
})

$form.Add_Shown({ Update-StatusLabel })

[void]$form.ShowDialog()
