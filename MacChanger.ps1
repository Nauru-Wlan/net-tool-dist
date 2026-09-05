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
$ScriptVersion     = "1.2.0"
$UpdateManifestUrl = "https://raw.githubusercontent.com/Nauru-Wlan/net-tool-dist/main/version.json"
$LicenseApiUrl     = "https://script.google.com/macros/s/AKfycbw0XvYlXlFoW7YwqrEaZhrmXVtBWdwK77b5K-sgLuY4RyweIoI2lU0V3Mohh9_868bM/exec"
# =====================================================================

# ---- Stiller Hintergrund-Update-Check (ueber Aufgabenplanung) ----
# Laeuft ohne Adminrechte, ohne GUI, ohne Splash - prueft nur kurz und beendet sich.
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
    $splash.Size = New-Object System.Drawing.Size(340, 130)
    $splash.StartPosition = "CenterScreen"
    $splash.FormBorderStyle = 'FixedDialog'
    $splash.ControlBox = $false
    $splash.MaximizeBox = $false
    $splash.MinimizeBox = $false
    $splash.TopMost = $true
    if ($appIcon) { $splash.Icon = $appIcon }

    $splashLabel = New-Object System.Windows.Forms.Label
    $splashLabel.Text = "Wird gestartet ..."
    $splashLabel.Font = New-Object System.Drawing.Font("Segoe UI", 12)
    $splashLabel.TextAlign = [System.Drawing.ContentAlignment]::MiddleCenter
    $splashLabel.Dock = 'Fill'
    $splash.Controls.Add($splashLabel)

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

function Confirm-License {
    Add-Type -AssemblyName Microsoft.VisualBasic

    $storedKey = Get-StoredLicenseKey
    $hadStoredKeyBefore = [bool]$storedKey

    if (-not $storedKey) {
        $splash.Form.Hide()
        $storedKey = [Microsoft.VisualBasic.Interaction]::InputBox(
            "Bitte gib deinen Lizenzschluessel ein:", "Lizenz erforderlich", "")
        $splash.Form.Show()
        if ([string]::IsNullOrWhiteSpace($storedKey)) {
            $splash.Form.Hide()
            [System.Windows.Forms.MessageBox]::Show(
                "Ohne gueltigen Lizenzschluessel kann das Tool nicht gestartet werden.",
                "Lizenz erforderlich",
                [System.Windows.Forms.MessageBoxButtons]::OK,
                [System.Windows.Forms.MessageBoxIcon]::Error) | Out-Null
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
            [System.Windows.Forms.MessageBox]::Show(
                "Der eingegebene Lizenzschluessel ist ungueltig.",
                "Ungueltiger Schluessel",
                [System.Windows.Forms.MessageBoxButtons]::OK,
                [System.Windows.Forms.MessageBoxIcon]::Error) | Out-Null
            exit
        }
        "used_by_other_device" {
            $splash.Form.Hide()
            [System.Windows.Forms.MessageBox]::Show(
                "Dieser Lizenzschluessel wird bereits auf einem anderen Geraet verwendet.",
                "Lizenz bereits verwendet",
                [System.Windows.Forms.MessageBoxButtons]::OK,
                [System.Windows.Forms.MessageBoxIcon]::Error) | Out-Null
            exit
        }
        "offline" {
            if ($hadStoredKeyBefore) {
                return
            } else {
                $splash.Form.Hide()
                [System.Windows.Forms.MessageBox]::Show(
                    "Fuer die Erstaktivierung wird eine Internetverbindung benoetigt.",
                    "Keine Verbindung",
                    [System.Windows.Forms.MessageBoxButtons]::OK,
                    [System.Windows.Forms.MessageBoxIcon]::Error) | Out-Null
                exit
            }
        }
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

    $classGuid = "{4d36e972-e325-11ce-bfc1-08002be10318}"
    $classPath = "HKLM:\SYSTEM\CurrentControlSet\Control\Class\$classGuid"
    $subkeys   = Get-ChildItem $classPath -ErrorAction SilentlyContinue

    $target = $null
    foreach ($key in $subkeys) {
        $props = Get-ItemProperty -Path $key.PSPath -ErrorAction SilentlyContinue
        if ($props.NetCfgInstanceId -eq $Adapter.InterfaceGuid) {
            $target = $key.PSPath
            break
        }
    }
    if (-not $target) { return $false }

    Set-ItemProperty -Path $target -Name "NetworkAddress" -Value $Mac -Type String

    $NoticeForm.Show()
    $NoticeForm.Refresh()

    Disable-NetAdapter -Name $Adapter.Name -Confirm:$false -ErrorAction SilentlyContinue
    for ($i = 0; $i -lt 10; $i++) {
        Start-Sleep -Milliseconds 200
        [System.Windows.Forms.Application]::DoEvents()
    }
    Enable-NetAdapter -Name $Adapter.Name -Confirm:$false -ErrorAction SilentlyContinue
    for ($i = 0; $i -lt 10; $i++) {
        Start-Sleep -Milliseconds 200
        [System.Windows.Forms.Application]::DoEvents()
    }

    $NoticeForm.Hide()

    return $true
}

function New-NoticeForm {
    $notice = New-Object System.Windows.Forms.Form
    $notice.Text = "Bitte warten"
    $notice.Size = New-Object System.Drawing.Size(520, 260)
    $notice.StartPosition = "CenterScreen"
    $notice.FormBorderStyle = 'FixedDialog'
    $notice.ControlBox = $false
    $notice.MaximizeBox = $false
    $notice.MinimizeBox = $false
    $notice.TopMost = $true
    $notice.BackColor = [System.Drawing.Color]::FromArgb(230, 57, 70)
    if ($appIcon) { $notice.Icon = $appIcon }

    $noticeLabel = New-Object System.Windows.Forms.Label
    $noticeLabel.Text = "Ihre Netzwerkverbindung wird`nkurz getrennt ..."
    $noticeLabel.ForeColor = [System.Drawing.Color]::White
    $noticeLabel.Font = New-Object System.Drawing.Font("Segoe UI", 22, [System.Drawing.FontStyle]::Bold)
    $noticeLabel.TextAlign = [System.Drawing.ContentAlignment]::MiddleCenter
    $noticeLabel.Dock = 'Fill'
    $notice.Controls.Add($noticeLabel)

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
$form.Text = "MAC-Adressen-Wechsler v$ScriptVersion"
$form.Size = New-Object System.Drawing.Size(400, 260)
$form.StartPosition = "CenterScreen"
$form.FormBorderStyle = 'FixedDialog'
$form.MaximizeBox = $false
$form.MinimizeBox = $false
if ($appIcon) { $form.Icon = $appIcon }

$label = New-Object System.Windows.Forms.Label
$label.Text = "Klicke auf den Button, um fuer den aktiven`nNetzwerkadapter eine neue, zufaellige`nMAC-Adresse einzustellen."
$label.AutoSize = $false
$label.Size = New-Object System.Drawing.Size(360, 60)
$label.Location = New-Object System.Drawing.Point(20, 15)
$form.Controls.Add($label)

$button = New-Object System.Windows.Forms.Button
$button.Text = "Neue MAC-Adresse einstellen"
$button.Size = New-Object System.Drawing.Size(240, 40)
$button.Location = New-Object System.Drawing.Point(80, 85)
$form.Controls.Add($button)

$statusLabel = New-Object System.Windows.Forms.Label
$statusLabel.Text = "Adapter: wird ermittelt ...`nAktuelle MAC: wird ermittelt ..."
$statusLabel.AutoSize = $false
$statusLabel.Size = New-Object System.Drawing.Size(360, 50)
$statusLabel.Location = New-Object System.Drawing.Point(20, 140)
$statusLabel.Font = New-Object System.Drawing.Font("Segoe UI", 9)
$statusLabel.ForeColor = [System.Drawing.Color]::DimGray
$form.Controls.Add($statusLabel)

function Update-StatusLabel {
    $adapter = Get-ActiveAdapter
    if ($adapter) {
        $currentMac = Format-Mac ($adapter.MacAddress -replace '-', '')
        $statusLabel.Text = "Adapter: $($adapter.Name)`nAktuelle MAC: $currentMac"
    } else {
        $statusLabel.Text = "Adapter: kein aktiver Adapter gefunden"
    }
}

$noticeForm = New-NoticeForm

$button.Add_Click({
    $button.Enabled = $false
    $button.Text = "Wird eingestellt ..."
    $form.Refresh()

    $adapter = Get-ActiveAdapter
    if (-not $adapter) {
        [System.Windows.Forms.MessageBox]::Show(
            "Kein aktiver Netzwerkadapter gefunden.", "Fehler",
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Error) | Out-Null
    } else {
        $oldMac = $adapter.MacAddress -replace '-', ''
        $mac = New-RandomMac
        $ok  = Set-AdapterMac -Adapter $adapter -Mac $mac -NoticeForm $noticeForm

        if ($ok) {
            Add-UsedMac $mac
            [System.Windows.Forms.MessageBox]::Show(
                "Erfolg",
                "Erfolg",
                [System.Windows.Forms.MessageBoxButtons]::OK,
                [System.Windows.Forms.MessageBoxIcon]::Information) | Out-Null
        } else {
            [System.Windows.Forms.MessageBox]::Show(
                "MAC-Adresse konnte nicht geaendert werden`n(Registry-Eintrag fuer diesen Adapter nicht gefunden).",
                "Fehler",
                [System.Windows.Forms.MessageBoxButtons]::OK,
                [System.Windows.Forms.MessageBoxIcon]::Error) | Out-Null
        }
    }

    Update-StatusLabel
    $button.Enabled = $true
    $button.Text = "Neue MAC-Adresse einstellen"
})

$form.Add_Shown({ Update-StatusLabel })

[void]$form.ShowDialog()
