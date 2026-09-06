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
$ScriptVersion     = "1.4.0"
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
#  EINHEITLICHES DESIGN (Farben/Schriften fuer alle Fenster)
# =====================================================================
$accentColor  = [System.Drawing.Color]::FromArgb(0, 120, 212)
$textColor    = [System.Drawing.Color]::FromArgb(40, 40, 40)
$subTextColor = [System.Drawing.Color]::FromArgb(110, 110, 110)
$bgColor      = [System.Drawing.Color]::White

function New-AccentBar {
    param([System.Windows.Forms.Form]$TargetForm)
    $bar = New-Object System.Windows.Forms.Panel
    $bar.BackColor = $accentColor
    $bar.Dock = 'Top'
    $bar.Height = 6
    $TargetForm.Controls.Add($bar)
}

function New-StyledButton {
    param([string]$Text, [int]$Width = 240, [int]$Height = 40)
    $btn = New-Object System.Windows.Forms.Button
    $btn.Text = $Text
    $btn.Size = New-Object System.Drawing.Size($Width, $Height)
    $btn.FlatStyle = 'Flat'
    $btn.FlatAppearance.BorderSize = 0
    $btn.BackColor = $accentColor
    $btn.ForeColor = [System.Drawing.Color]::White
    $btn.Font = New-Object System.Drawing.Font("Segoe UI", 10, [System.Drawing.FontStyle]::Bold)
    $btn.Cursor = [System.Windows.Forms.Cursors]::Hand
    return $btn
}

function New-SecondaryButton {
    param([string]$Text, [int]$Width = 120, [int]$Height = 36)
    $btn = New-Object System.Windows.Forms.Button
    $btn.Text = $Text
    $btn.Size = New-Object System.Drawing.Size($Width, $Height)
    $btn.FlatStyle = 'Flat'
    $btn.FlatAppearance.BorderColor = [System.Drawing.Color]::FromArgb(200, 200, 200)
    $btn.BackColor = [System.Drawing.Color]::White
    $btn.ForeColor = $textColor
    $btn.Font = New-Object System.Drawing.Font("Segoe UI", 9)
    $btn.Cursor = [System.Windows.Forms.Cursors]::Hand
    return $btn
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
    [System.Windows.Forms.MessageBox]::Show(
        $Message, $Title,
        [System.Windows.Forms.MessageBoxButtons]::OK,
        [System.Windows.Forms.MessageBoxIcon]::Error) | Out-Null
}

# ---- Speicherort fuer bereits verwendete MAC-Adressen (versteckt) ----
$dataDir  = Join-Path $env:LOCALAPPDATA "MacRandomizer"
$usedFile = Join-Path $dataDir "used_macs.dat"

if (-not (Test-Path $dataDir)) {
    New-Item -Path $dataDir -ItemType Directory -Force | Out-Null
    (Get-Item $dataDir).Attributes = 'Hidden'
}
if (-not (Test-Path $usedFile)) {
    New-Item -Path $usedFile -ItemType File -Force | Out-Null
    (Get-Item $usedFile).Attributes = 'Hidden'
}

$licenseFile = Join-Path $dataDir "license.dat"

# =====================================================================
#  LADEBILDSCHIRM (waehrend Update-/Lizenzpruefung im Hintergrund laeuft)
# =====================================================================
function New-SplashForm {
    $splash = New-Object System.Windows.Forms.Form
    $splash.Text = "MAC-Adressen-Wechsler"
    $splash.Size = New-Object System.Drawing.Size(360, 150)
    $splash.StartPosition = "CenterScreen"
    $splash.FormBorderStyle = 'FixedDialog'
    $splash.ControlBox = $false
    $splash.MaximizeBox = $false
    $splash.MinimizeBox = $false
    $splash.TopMost = $true
    $splash.BackColor = $bgColor
    if ($appIcon) { $splash.Icon = $appIcon }

    New-AccentBar -TargetForm $splash

    $splashLabel = New-Object System.Windows.Forms.Label
    $splashLabel.Text = "Wird gestartet ..."
    $splashLabel.Font = New-Object System.Drawing.Font("Segoe UI", 11)
    $splashLabel.ForeColor = $textColor
    $splashLabel.TextAlign = [System.Drawing.ContentAlignment]::MiddleCenter
    $splashLabel.Size = New-Object System.Drawing.Size(320, 40)
    $splashLabel.Location = New-Object System.Drawing.Point(20, 40)
    $splash.Controls.Add($splashLabel)

    $splashProgress = New-Object System.Windows.Forms.ProgressBar
    $splashProgress.Style = 'Marquee'
    $splashProgress.MarqueeAnimationSpeed = 30
    $splashProgress.Size = New-Object System.Drawing.Size(280, 12)
    $splashProgress.Location = New-Object System.Drawing.Point(40, 85)
    $splash.Controls.Add($splashProgress)

    return @{ Form = $splash; Label = $splashLabel }
}

function Set-SplashStatus {
    param($Splash, [string]$Text)
    $Splash.Label.Text = $Text
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
    Set-Content -Path $licenseFile -Value $Key -NoNewline
    (Get-Item $licenseFile).Attributes = 'Hidden'
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
    $dlg.Size = New-Object System.Drawing.Size(420, 260)
    $dlg.StartPosition = "CenterScreen"
    $dlg.FormBorderStyle = 'FixedDialog'
    $dlg.MaximizeBox = $false
    $dlg.MinimizeBox = $false
    $dlg.BackColor = $bgColor
    if ($appIcon) { $dlg.Icon = $appIcon }

    New-AccentBar -TargetForm $dlg

    $title = New-Object System.Windows.Forms.Label
    $title.Text = "Lizenzschluessel eingeben"
    $title.Font = New-Object System.Drawing.Font("Segoe UI", 13, [System.Drawing.FontStyle]::Bold)
    $title.ForeColor = $textColor
    $title.Size = New-Object System.Drawing.Size(370, 30)
    $title.Location = New-Object System.Drawing.Point(20, 25)
    $dlg.Controls.Add($title)

    $sub = New-Object System.Windows.Forms.Label
    $sub.Text = "Den Schluessel hast du nach dem Kauf erhalten."
    $sub.Font = New-Object System.Drawing.Font("Segoe UI", 9)
    $sub.ForeColor = $subTextColor
    $sub.Size = New-Object System.Drawing.Size(370, 20)
    $sub.Location = New-Object System.Drawing.Point(20, 58)
    $dlg.Controls.Add($sub)

    $textBox = New-Object System.Windows.Forms.TextBox
    $textBox.Font = New-Object System.Drawing.Font("Segoe UI", 11)
    $textBox.Size = New-Object System.Drawing.Size(370, 30)
    $textBox.Location = New-Object System.Drawing.Point(20, 90)
    $dlg.Controls.Add($textBox)

    $okButton = New-StyledButton -Text "Aktivieren" -Width 170 -Height 38
    $okButton.Location = New-Object System.Drawing.Point(20, 150)
    $okButton.DialogResult = [System.Windows.Forms.DialogResult]::OK
    $dlg.Controls.Add($okButton)

    $cancelButton = New-SecondaryButton -Text "Abbrechen" -Width 120 -Height 38
    $cancelButton.Location = New-Object System.Drawing.Point(200, 150)
    $cancelButton.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
    $dlg.Controls.Add($cancelButton)

    $dlg.AcceptButton = $okButton
    $dlg.CancelButton = $cancelButton
    $textBox.Focus()

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

        $NoticeForm.Show()
        $NoticeForm.Refresh()

        Disable-NetAdapter -Name $Adapter.Name -Confirm:$false -ErrorAction Stop
        for ($i = 0; $i -lt 10; $i++) {
            Start-Sleep -Milliseconds 200
            [System.Windows.Forms.Application]::DoEvents()
        }
        Enable-NetAdapter -Name $Adapter.Name -Confirm:$false -ErrorAction Stop
        for ($i = 0; $i -lt 10; $i++) {
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
    $notice.Size = New-Object System.Drawing.Size(480, 230)
    $notice.StartPosition = "CenterScreen"
    $notice.FormBorderStyle = 'FixedDialog'
    $notice.ControlBox = $false
    $notice.MaximizeBox = $false
    $notice.MinimizeBox = $false
    $notice.TopMost = $true
    $notice.BackColor = $bgColor
    if ($appIcon) { $notice.Icon = $appIcon }

    New-AccentBar -TargetForm $notice

    $noticeLabel = New-Object System.Windows.Forms.Label
    $noticeLabel.Text = "Netzwerkverbindung wird kurz neu aufgebaut ..."
    $noticeLabel.ForeColor = $textColor
    $noticeLabel.Font = New-Object System.Drawing.Font("Segoe UI", 13, [System.Drawing.FontStyle]::Bold)
    $noticeLabel.TextAlign = [System.Drawing.ContentAlignment]::MiddleCenter
    $noticeLabel.Size = New-Object System.Drawing.Size(440, 50)
    $noticeLabel.Location = New-Object System.Drawing.Point(20, 45)
    $notice.Controls.Add($noticeLabel)

    $noticeProgress = New-Object System.Windows.Forms.ProgressBar
    $noticeProgress.Style = 'Marquee'
    $noticeProgress.MarqueeAnimationSpeed = 30
    $noticeProgress.Size = New-Object System.Drawing.Size(360, 14)
    $noticeProgress.Location = New-Object System.Drawing.Point(60, 105)
    $notice.Controls.Add($noticeProgress)

    $subLabel = New-Object System.Windows.Forms.Label
    $subLabel.Text = "Das dauert nur wenige Sekunden. Dieses Fenster schliesst sich automatisch."
    $subLabel.ForeColor = $subTextColor
    $subLabel.Font = New-Object System.Drawing.Font("Segoe UI", 9)
    $subLabel.TextAlign = [System.Drawing.ContentAlignment]::MiddleCenter
    $subLabel.Size = New-Object System.Drawing.Size(440, 30)
    $subLabel.Location = New-Object System.Drawing.Point(20, 140)
    $notice.Controls.Add($subLabel)

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
        [System.Windows.Forms.MessageBox]::Show(
            "Eine neue Version ($($manifest.version)) wurde installiert.`nDas Tool wird jetzt neu gestartet.",
            "Update installiert",
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Information) | Out-Null

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
$form.Size = New-Object System.Drawing.Size(420, 300)
$form.StartPosition = "CenterScreen"
$form.FormBorderStyle = 'FixedDialog'
$form.MaximizeBox = $false
$form.MinimizeBox = $false
$form.BackColor = $bgColor
if ($appIcon) { $form.Icon = $appIcon }

New-AccentBar -TargetForm $form

$label = New-Object System.Windows.Forms.Label
$label.Text = "Klicke auf den Button, um fuer den aktiven`nNetzwerkadapter eine neue, zufaellige`nMAC-Adresse einzustellen."
$label.Font = New-Object System.Drawing.Font("Segoe UI", 10)
$label.ForeColor = $textColor
$label.AutoSize = $false
$label.Size = New-Object System.Drawing.Size(370, 65)
$label.Location = New-Object System.Drawing.Point(20, 30)
$form.Controls.Add($label)

$button = New-StyledButton -Text "Neue MAC-Adresse einstellen" -Width 260 -Height 42
$button.Location = New-Object System.Drawing.Point(80, 105)
$form.Controls.Add($button)

$statusLabel = New-Object System.Windows.Forms.Label
$statusLabel.Text = "Adapter: wird ermittelt ...`nAktuelle MAC: wird ermittelt ..."
$statusLabel.Font = New-Object System.Drawing.Font("Segoe UI", 9)
$statusLabel.ForeColor = $subTextColor
$statusLabel.AutoSize = $false
$statusLabel.Size = New-Object System.Drawing.Size(370, 50)
$statusLabel.Location = New-Object System.Drawing.Point(20, 165)
$form.Controls.Add($statusLabel)

function Update-StatusLabel {
    try {
        $adapter = Get-ActiveAdapter
        if ($adapter) {
            $currentMac = Format-Mac ($adapter.MacAddress -replace '-', '')
            $statusLabel.Text = "Adapter: $($adapter.Name)`nAktuelle MAC: $currentMac"
        } else {
            $statusLabel.Text = "Adapter: kein aktiver Adapter gefunden"
        }
    } catch {
        $statusLabel.Text = "Adapterstatus konnte nicht ermittelt werden."
    }
}

$noticeForm = New-NoticeForm

$button.Add_Click({
    try {
        $button.Enabled = $false
        $button.Text = "Wird eingestellt ..."
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
                [System.Windows.Forms.MessageBox]::Show(
                    "Erfolg",
                    "Erfolg",
                    [System.Windows.Forms.MessageBoxButtons]::OK,
                    [System.Windows.Forms.MessageBoxIcon]::Information) | Out-Null
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
    $button.Enabled = $true
    $button.Text = "Neue MAC-Adresse einstellen"
})

$form.Add_Shown({ Update-StatusLabel })

[void]$form.ShowDialog()
