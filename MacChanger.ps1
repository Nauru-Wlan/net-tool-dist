#Requires -Version 5.0
<#
    MacChanger.ps1
    Setzt eine zufaellige, lokal administrierte MAC-Adresse (LAN/WLAN-tauglich)
    fuer den aktiven Netzwerkadapter, merkt sich bereits verwendete Adressen,
    zeigt waehrend des Adapter-Neustarts einen Hinweis und prueft beim Start
    auf eine neuere Version (Auto-Update ueber GitHub).
#>

# =====================================================================
#  KONFIGURATION
# =====================================================================
$ScriptVersion     = "1.0.0"
$UpdateManifestUrl = "https://raw.githubusercontent.com/Nauru-Wlan/net_tool_dist/main/version.json"
# =====================================================================

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

    # Grosses Hinweisfenster einblenden, solange die Verbindung getrennt ist
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
        $tempFile = Join-Path $env:TEMP "MacChanger_new.ps1"
        Invoke-WebRequest -Uri $manifest.url -OutFile $tempFile -TimeoutSec 15 -UseBasicParsing -ErrorAction Stop

        if ((Get-Item $tempFile).Length -lt 100) { return $false }

        Copy-Item -Path $tempFile -Destination $PSCommandPath -Force
        Remove-Item $tempFile -Force -ErrorAction SilentlyContinue

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

# =====================================================================
#  HAUPTFENSTER
# =====================================================================
$form = New-Object System.Windows.Forms.Form
$form.Text = "MAC-Adressen-Wechsler v$ScriptVersion"
$form.Size = New-Object System.Drawing.Size(380, 190)
$form.StartPosition = "CenterScreen"
$form.FormBorderStyle = 'FixedDialog'
$form.MaximizeBox = $false
$form.MinimizeBox = $false

$label = New-Object System.Windows.Forms.Label
$label.Text = "Klicke auf den Button, um fuer den aktiven`nNetzwerkadapter eine neue, zufaellige`nMAC-Adresse einzustellen."
$label.AutoSize = $false
$label.Size = New-Object System.Drawing.Size(340, 60)
$label.Location = New-Object System.Drawing.Point(20, 15)
$form.Controls.Add($label)

$button = New-Object System.Windows.Forms.Button
$button.Text = "Neue MAC-Adresse einstellen"
$button.Size = New-Object System.Drawing.Size(240, 40)
$button.Location = New-Object System.Drawing.Point(70, 90)
$form.Controls.Add($button)

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
        $mac = New-RandomMac
        $ok  = Set-AdapterMac -Adapter $adapter -Mac $mac -NoticeForm $noticeForm

        if ($ok) {
            Add-UsedMac $mac
            [System.Windows.Forms.MessageBox]::Show(
                "Neue MAC-Adresse wurde eingestellt fuer:`n$($adapter.Name)",
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

    $button.Enabled = $true
    $button.Text = "Neue MAC-Adresse einstellen"
})

[void]$form.ShowDialog()
