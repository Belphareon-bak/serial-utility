#Requires -Version 5.1
<#
.SYNOPSIS
    MediaTool GUI - okno pro hromadné přejmenování, deduplikaci a třídění médií.

.DESCRIPTION
    Nadstavba nad media-tool.ps1. Veškerá logika (rozbor názvů, hledání duplicit,
    sestavení plánu, bezpečný přesun) je v tom skriptu; tohle je jen okno.

    Rozvržení stojí na TableLayoutPanel/FlowLayoutPanel, ne na pevných
    souřadnicích - přežije jinou velikost okna i jiné DPI.

    Spouštěj přes MediaTool.exe nebo MediaTool.cmd (dvojklik), případně:
        powershell -NoProfile -ExecutionPolicy Bypass -STA -File .\media-tool-gui.ps1
#>
param(
    [switch]$SelfTest,
    [string]$TestPath,
    [string]$TestLib,
    [int]$TestMode = 0,
    [string]$TestTheme,
    [string]$TestShot
)

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName Microsoft.VisualBasic
[System.Windows.Forms.Application]::EnableVisualStyles()

# tmavý pruh okna (Win10 2004+ / Win11); když to nejde, nevadí
try {
    Add-Type -Namespace MT -Name Dwm -MemberDefinition @'
[DllImport("dwmapi.dll")]
public static extern int DwmSetWindowAttribute(IntPtr hwnd, int attr, ref int val, int size);
'@ -ErrorAction Stop
} catch { }

# ------------------------------------------------------------------- engine

$EnginePath = Join-Path $PSScriptRoot 'media-tool.ps1'
if (-not (Test-Path -LiteralPath $EnginePath)) {
    [System.Windows.Forms.MessageBox]::Show(
        "Chybí media-tool.ps1 vedle GUI:`n$EnginePath", 'MediaTool', 'OK', 'Error') | Out-Null
    return
}
. $EnginePath -LoadOnly

$ErrorActionPreference = 'Stop'

$script:Plan         = $null
$script:DupBytes     = 0
$script:SettingsPath = Join-Path $PSScriptRoot 'settings.json'

# --------------------------------------------------------------- nastavení

function New-DefaultSettings {
    [pscustomobject]@{
        Motiv          = 'Tmavý'
        Pismo          = 9
        Zebra          = $true
        Zdroj          = (Join-Path $env:USERPROFILE 'Downloads')
        Knihovna       = (Join-Path $env:USERPROFILE 'Videos\Knihovna')
        SeriesTemplate = '{show} - S{season}E{episode} - {title}'
        MovieTemplate  = '{title} ({year})'
        KeepTags       = $false
        Recurse        = $false
        NoSubs         = $false
        FullHash       = $false
        Flat           = $false
        MinVideoKB     = 100
        DuplicityAkce  = 'Přesunout do _Duplicity'
        TrvaleMazani   = $false
        DropWords      = 'chmeli, jdm, ffi, rarbg, yify, yts, evo, ntb'
        ShowAliases    = '^game[ ._]?of[ ._]?thrones = Game of Thrones'
        PanelOtevren   = $true
    }
}

function Import-Settings {
    if (-not (Test-Path -LiteralPath $script:SettingsPath)) { return (New-DefaultSettings) }
    try {
        $nactene = Get-Content -LiteralPath $script:SettingsPath -Raw -Encoding UTF8 | ConvertFrom-Json
        $vychozi = New-DefaultSettings
        foreach ($p in $vychozi.PSObject.Properties) {
            if (-not $nactene.PSObject.Properties[$p.Name]) {
                $nactene | Add-Member -NotePropertyName $p.Name -NotePropertyValue $p.Value
            }
        }
        return $nactene
    } catch { return (New-DefaultSettings) }
}

function Export-Settings {
    try {
        Read-Form
        $script:Nastaveni | ConvertTo-Json | Set-Content -LiteralPath $script:SettingsPath -Encoding UTF8
        return $true
    } catch {
        return $false
    }
}

$script:Nastaveni = Import-Settings

# --------------------------------------------------------------- barvy

function Get-Paleta {
    <# paleta podle VS Code Dark+ / Light+ #>
    if ($script:Nastaveni.Motiv -eq 'Tmavý') {
        [pscustomobject]@{
            Tmavy      = $true
            Pozadi     = [System.Drawing.Color]::FromArgb(0x1E, 0x1E, 0x1E)  # editor
            Panel      = [System.Drawing.Color]::FromArgb(0x25, 0x25, 0x26)  # side bar
            Lista      = [System.Drawing.Color]::FromArgb(0x33, 0x33, 0x33)  # title bar
            Pole       = [System.Drawing.Color]::FromArgb(0x3C, 0x3C, 0x3C)  # input
            PoleRam    = [System.Drawing.Color]::FromArgb(0x3C, 0x3C, 0x3C)
            Text       = [System.Drawing.Color]::FromArgb(0xCC, 0xCC, 0xCC)
            TextSlab   = [System.Drawing.Color]::FromArgb(0x85, 0x85, 0x85)
            Ramecek    = [System.Drawing.Color]::FromArgb(0x3E, 0x3E, 0x42)
            Akcent     = [System.Drawing.Color]::FromArgb(0x0E, 0x63, 0x9C)  # button
            AkcentSvit = [System.Drawing.Color]::FromArgb(0x11, 0x77, 0xBB)  # button hover
            AkcentText = [System.Drawing.Color]::White
            Vyber      = [System.Drawing.Color]::FromArgb(0x09, 0x47, 0x71)  # list active
            VyberText  = [System.Drawing.Color]::White
            Zebra      = [System.Drawing.Color]::FromArgb(0x23, 0x23, 0x23)
            Chyba      = [System.Drawing.Color]::FromArgb(0xF4, 0x87, 0x71)
        }
    } else {
        [pscustomobject]@{
            Tmavy      = $false
            Pozadi     = [System.Drawing.Color]::White
            Panel      = [System.Drawing.Color]::FromArgb(0xF3, 0xF3, 0xF3)
            Lista      = [System.Drawing.Color]::FromArgb(0xEC, 0xEC, 0xEC)
            Pole       = [System.Drawing.Color]::White
            PoleRam    = [System.Drawing.Color]::FromArgb(0xCE, 0xCE, 0xCE)
            Text       = [System.Drawing.Color]::FromArgb(0x33, 0x33, 0x33)
            TextSlab   = [System.Drawing.Color]::FromArgb(0x6E, 0x6E, 0x6E)
            Ramecek    = [System.Drawing.Color]::FromArgb(0xD4, 0xD4, 0xD4)
            Akcent     = [System.Drawing.Color]::FromArgb(0x00, 0x7A, 0xCC)
            AkcentSvit = [System.Drawing.Color]::FromArgb(0x00, 0x66, 0xB8)
            AkcentText = [System.Drawing.Color]::White
            Vyber      = [System.Drawing.Color]::FromArgb(0xAD, 0xD6, 0xFF)
            VyberText  = [System.Drawing.Color]::FromArgb(0x00, 0x00, 0x00)
            Zebra      = [System.Drawing.Color]::FromArgb(0xF8, 0xF8, 0xF8)
            Chyba      = [System.Drawing.Color]::FromArgb(0xA1, 0x26, 0x0D)
        }
    }
}

function Get-ActionColor {
    param([string]$Akce)
    $p = Get-Paleta
    if ($p.Tmavy) {
        switch ($Akce) {
            'PRESUN'      { [System.Drawing.Color]::FromArgb(0x1B, 0x2E, 0x22) }
            'PREJMENOVAT' { [System.Drawing.Color]::FromArgb(0x1B, 0x27, 0x33) }
            'DUPLICITA'   { [System.Drawing.Color]::FromArgb(0x33, 0x28, 0x1A) }
            'KEKONTROLE'  { [System.Drawing.Color]::FromArgb(0x30, 0x2D, 0x1A) }
            'PRESKOCIT'   { [System.Drawing.Color]::FromArgb(0x24, 0x24, 0x24) }
            default       { $p.Pozadi }
        }
    } else {
        switch ($Akce) {
            'PRESUN'      { [System.Drawing.Color]::FromArgb(0xE8, 0xF5, 0xEA) }
            'PREJMENOVAT' { [System.Drawing.Color]::FromArgb(0xE7, 0xF1, 0xFB) }
            'DUPLICITA'   { [System.Drawing.Color]::FromArgb(0xFD, 0xF0, 0xDF) }
            'KEKONTROLE'  { [System.Drawing.Color]::FromArgb(0xFD, 0xFA, 0xE3) }
            'PRESKOCIT'   { [System.Drawing.Color]::FromArgb(0xF2, 0xF2, 0xF2) }
            default       { $p.Pozadi }
        }
    }
}

# ------------------------------------------------------ továrny na prvky

function New-Lbl {
    param([string]$Text, [switch]$Nadpis, [switch]$Slaby, [int]$Sirka = 0)
    $l = New-Object System.Windows.Forms.Label
    $l.Text     = $Text
    $l.AutoSize = ($Sirka -eq 0)
    if ($Sirka -gt 0) { $l.Width = $Sirka }
    $l.Margin   = New-Object System.Windows.Forms.Padding(0, 6, 8, 2)
    $l.TextAlign = 'MiddleLeft'
    if ($Nadpis) { $l.Tag = 'nadpis' } elseif ($Slaby) { $l.Tag = 'slaby' }
    return $l
}

function New-Txt {
    param([int]$Sirka = 300, [int]$Vyska = 0)
    $t = New-Object System.Windows.Forms.TextBox
    $t.Width  = $Sirka
    $t.Margin = New-Object System.Windows.Forms.Padding(0, 2, 0, 6)
    if ($Vyska -gt 0) { $t.Multiline = $true; $t.Height = $Vyska; $t.ScrollBars = 'Vertical' }
    return $t
}

function New-Chk {
    param([string]$Text, [string]$Role = '')
    $c = New-Object System.Windows.Forms.CheckBox
    $c.Text     = $Text
    $c.AutoSize = $true
    $c.Margin   = New-Object System.Windows.Forms.Padding(0, 3, 0, 3)
    if ($Role) { $c.Tag = $Role }
    return $c
}

function New-Btn {
    param([string]$Text, [string]$Role = 'secondary', [int]$Sirka = 0)
    $b = New-Object System.Windows.Forms.Button
    $b.Text      = $Text
    $b.AutoSize  = ($Sirka -eq 0)
    $b.AutoSizeMode = 'GrowAndShrink'
    if ($Sirka -gt 0) { $b.Width = $Sirka }
    $b.Height    = 30
    $b.Padding   = New-Object System.Windows.Forms.Padding(10, 0, 10, 0)
    $b.Margin    = New-Object System.Windows.Forms.Padding(0, 0, 8, 0)
    $b.FlatStyle = 'Flat'
    $b.Cursor    = [System.Windows.Forms.Cursors]::Hand
    $b.Tag       = $Role
    return $b
}

function New-Radek {
    # vodorovný proužek prvků vedle sebe
    param([object[]]$Prvky, [int]$Sirka = 306)
    $f = New-Object System.Windows.Forms.FlowLayoutPanel
    $f.FlowDirection = 'LeftToRight'
    $f.WrapContents  = $false
    $f.AutoSize      = $true
    $f.AutoSizeMode  = 'GrowAndShrink'
    $f.Width         = $Sirka
    $f.Margin        = New-Object System.Windows.Forms.Padding(0)
    $f.Controls.AddRange($Prvky)
    return $f
}

# --------------------------------------------------------------- motiv

function Set-ControlTheme {
    param([System.Windows.Forms.Control]$C, $P)

    if ($C -is [System.Windows.Forms.DataGridView]) {
        $C.EnableHeadersVisualStyles = $false
        $C.BackgroundColor = $P.Pozadi
        $C.GridColor       = $P.Ramecek
        $C.DefaultCellStyle.BackColor          = $P.Pozadi
        $C.DefaultCellStyle.ForeColor          = $P.Text
        $C.DefaultCellStyle.SelectionBackColor = $P.Vyber
        $C.DefaultCellStyle.SelectionForeColor = $P.VyberText
        $C.DefaultCellStyle.Padding            = New-Object System.Windows.Forms.Padding(4, 2, 4, 2)
        $C.ColumnHeadersDefaultCellStyle.BackColor = $P.Lista
        $C.ColumnHeadersDefaultCellStyle.ForeColor = $P.Text
        $C.ColumnHeadersDefaultCellStyle.Padding   = New-Object System.Windows.Forms.Padding(4, 0, 4, 0)
        $C.ColumnHeadersBorderStyle = 'Single'
        $C.RowTemplate.Height = 24
        if ($script:Nastaveni.Zebra) { $C.AlternatingRowsDefaultCellStyle.BackColor = $P.Zebra }
        else                         { $C.AlternatingRowsDefaultCellStyle.BackColor = $P.Pozadi }
    }
    elseif ($C -is [System.Windows.Forms.Button]) {
        $role = [string]$C.Tag
        $C.FlatStyle = 'Flat'
        $C.FlatAppearance.BorderSize = 1
        if ($role -eq 'primary') {
            $C.BackColor = $P.Akcent
            $C.ForeColor = $P.AkcentText
            $C.FlatAppearance.BorderColor      = $P.Akcent
            $C.FlatAppearance.MouseOverBackColor = $P.AkcentSvit
        } elseif ($role -eq 'danger') {
            $C.BackColor = $P.Pole
            $C.ForeColor = $P.Chyba
            $C.FlatAppearance.BorderColor      = $P.Ramecek
            $C.FlatAppearance.MouseOverBackColor = $P.Vyber
        } else {
            $C.BackColor = $P.Pole
            $C.ForeColor = $P.Text
            $C.FlatAppearance.BorderColor      = $P.Ramecek
            $C.FlatAppearance.MouseOverBackColor = $P.Vyber
        }
    }
    elseif ($C -is [System.Windows.Forms.TextBox]) {
        $C.BackColor   = $P.Pole
        $C.ForeColor   = $P.Text
        $C.BorderStyle = 'FixedSingle'
    }
    elseif ($C -is [System.Windows.Forms.ComboBox]) {
        $C.BackColor     = $P.Pole
        $C.ForeColor     = $P.Text
        $C.FlatStyle     = 'Flat'
    }
    elseif ($C -is [System.Windows.Forms.NumericUpDown]) {
        $C.BackColor   = $P.Pole
        $C.ForeColor   = $P.Text
        $C.BorderStyle = 'FixedSingle'
    }
    elseif ($C -is [System.Windows.Forms.ProgressBar]) {
        $C.ForeColor = $P.Akcent
    }
    elseif ($C -is [System.Windows.Forms.Label]) {
        $C.BackColor = [System.Drawing.Color]::Transparent
        switch ([string]$C.Tag) {
            'slaby'  { $C.ForeColor = $P.TextSlab }
            'nadpis' { $C.ForeColor = $P.Text }
            default  { $C.ForeColor = $P.Text }
        }
    }
    elseif ($C -is [System.Windows.Forms.CheckBox]) {
        $C.BackColor = [System.Drawing.Color]::Transparent
        if ([string]$C.Tag -eq 'danger') { $C.ForeColor = $P.Chyba } else { $C.ForeColor = $P.Text }
        $C.FlatStyle = 'Flat'
        $C.FlatAppearance.BorderColor = $P.Ramecek
    }
    elseif ($C -is [System.Windows.Forms.Panel] -or
            $C -is [System.Windows.Forms.TableLayoutPanel] -or
            $C -is [System.Windows.Forms.FlowLayoutPanel]) {
        if ($C -eq $side)          { $C.BackColor = $P.Panel }
        elseif ($C -eq $top)       { $C.BackColor = $P.Lista }
        elseif ($C -eq $bottom)    { $C.BackColor = $P.Lista }
        elseif ($C -eq $statusBar) { $C.BackColor = $P.Lista }
        else                       { $C.BackColor = [System.Drawing.Color]::Transparent }
        $C.ForeColor = $P.Text
    }

    foreach ($d in $C.Controls) { Set-ControlTheme $d $P }
}

function Update-Theme {
    $p = Get-Paleta
    $form.BackColor = $p.Pozadi
    $form.ForeColor = $p.Text

    $velikost = [float]$script:Nastaveni.Pismo
    $form.Font = New-Object System.Drawing.Font('Segoe UI', $velikost)

    foreach ($c in $form.Controls) { Set-ControlTheme $c $p }

    $tucne = New-Object System.Drawing.Font('Segoe UI', $velikost, [System.Drawing.FontStyle]::Bold)
    foreach ($b in @($btnPreview, $btnApply)) { $b.Font = $tucne }
    foreach ($l in @($lblSecVzhled, $lblSecNazvy, $lblSecHledani, $lblSecDup, $lblSecSlovnik)) {
        $l.Font = New-Object System.Drawing.Font('Segoe UI', ($velikost + 0.5), [System.Drawing.FontStyle]::Bold)
    }

    try {
        $tmavy = 0
        if ($p.Tmavy) { $tmavy = 1 }
        [void][MT.Dwm]::DwmSetWindowAttribute($form.Handle, 20, [ref]$tmavy, 4)
    } catch { }

    foreach ($r in $grid.Rows) {
        $r.DefaultCellStyle.BackColor = Get-ActionColor ([string]$r.Cells['col_akce'].Value)
        if ([bool]$r.Cells['col_do'].ReadOnly) { $r.DefaultCellStyle.ForeColor = $p.TextSlab }
        else                                   { $r.DefaultCellStyle.ForeColor = $p.Text }
    }
    $form.Refresh()
}

# ------------------------------------------------------------------ logika

function Get-ModeCommand {
    if ($cmbMode.SelectedIndex -eq 0) { return 'rename' }
    if ($cmbMode.SelectedIndex -eq 2 -and [string]::IsNullOrWhiteSpace($txtLib.Text)) { return 'rename' }
    return 'sort'
}

function Set-Busy {
    param([bool]$On, [string]$Text = '')
    foreach ($c in @($btnPreview, $btnApply, $btnDelete, $btnUndo, $btnAll, $btnNone, $grid)) {
        $c.Enabled = -not $On
    }
    if ($Text) { $lblStatus.Text = $Text }
    if ($On) { $form.Cursor = [System.Windows.Forms.Cursors]::WaitCursor }
    else     { $form.Cursor = [System.Windows.Forms.Cursors]::Default }
    [System.Windows.Forms.Application]::DoEvents()
}

function Test-NetworkPath {
    param([string]$P)
    if ([string]::IsNullOrWhiteSpace($P)) { return $false }
    if ($P.StartsWith('\\')) { return $true }
    try {
        $root = [System.IO.Path]::GetPathRoot($P)
        $d = Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='$($root.TrimEnd('\'))'" -ErrorAction SilentlyContinue
        return ($d -and $d.DriveType -eq 4)
    } catch { return $false }
}

function Confirm-Folder {
    # existuje -> projde bez ptaní; neexistuje -> zeptá se, jestli ji vytvořit
    param([string]$Cesta, [string]$Popis = 'Vybraná složka')

    if ([string]::IsNullOrWhiteSpace($Cesta)) {
        [System.Windows.Forms.MessageBox]::Show("$Popis není vyplněná.", 'MediaTool', 'OK', 'Warning') | Out-Null
        return $false
    }
    if (Test-Path -LiteralPath $Cesta) { return $true }

    $odp = [System.Windows.Forms.MessageBox]::Show(
        "$Popis neexistuje:`n`n$Cesta`n`nMám ji vytvořit?", 'MediaTool', 'YesNo', 'Question')
    if ($odp -ne 'Yes') { return $false }
    try {
        New-Item -ItemType Directory -Path $Cesta -Force | Out-Null
        return $true
    } catch {
        [System.Windows.Forms.MessageBox]::Show(
            "Složku se nepodařilo vytvořit:`n`n$($_.Exception.Message)", 'MediaTool', 'OK', 'Error') | Out-Null
        return $false
    }
}

function Read-Form {
    $n = $script:Nastaveni
    $n.Motiv          = [string]$cmbTheme.SelectedItem
    $n.Pismo          = [int]$numFont.Value
    $n.Zebra          = [bool]$chkZebra.Checked
    $n.Zdroj          = $txtSrc.Text
    $n.Knihovna       = $txtLib.Text
    $n.SeriesTemplate = $txtSeries.Text
    $n.MovieTemplate  = $txtMovie.Text
    $n.KeepTags       = [bool]$chkKeepTags.Checked
    $n.Recurse        = [bool]$chkRecurse.Checked
    $n.NoSubs         = [bool]$chkNoSubs.Checked
    $n.FullHash       = [bool]$chkFullHash.Checked
    $n.Flat           = [bool]$chkFlat.Checked
    $n.MinVideoKB     = [int]$numMinKB.Value
    $n.DuplicityAkce  = [string]$cmbDup.SelectedItem
    $n.TrvaleMazani   = [bool]$chkTrvale.Checked
    $n.DropWords      = $txtDrop.Text
    $n.ShowAliases    = $txtAlias.Text
    $n.PanelOtevren   = [bool]$side.Visible
}

function Write-Form {
    $n = $script:Nastaveni
    $cmbTheme.SelectedItem = $n.Motiv
    if ($null -eq $cmbTheme.SelectedItem) { $cmbTheme.SelectedIndex = 0 }
    $numFont.Value       = [math]::Min([math]::Max([int]$n.Pismo, 8), 14)
    $chkZebra.Checked    = [bool]$n.Zebra
    $txtSrc.Text         = [string]$n.Zdroj
    $txtLib.Text         = [string]$n.Knihovna
    $txtSeries.Text      = [string]$n.SeriesTemplate
    $txtMovie.Text       = [string]$n.MovieTemplate
    $chkKeepTags.Checked = [bool]$n.KeepTags
    $chkRecurse.Checked  = [bool]$n.Recurse
    $chkNoSubs.Checked   = [bool]$n.NoSubs
    $chkFullHash.Checked = [bool]$n.FullHash
    $chkFlat.Checked     = [bool]$n.Flat
    $numMinKB.Value      = [math]::Min([math]::Max([int]$n.MinVideoKB, 0), 1000000)
    $cmbDup.SelectedItem = $n.DuplicityAkce
    if ($null -eq $cmbDup.SelectedItem) { $cmbDup.SelectedIndex = 0 }
    $chkTrvale.Checked   = [bool]$n.TrvaleMazani
    $txtDrop.Text        = [string]$n.DropWords
    $txtAlias.Text       = [string]$n.ShowAliases
}

function Set-EngineOptions {
    Read-Form
    $n = $script:Nastaveni

    $script:Path           = @($txtSrc.Text.Trim())
    $script:Library        = $txtLib.Text.Trim()
    $script:Filter         = $txtFilter.Text.Trim()
    $script:Recurse        = [bool]$n.Recurse
    $script:NoSubs         = [bool]$n.NoSubs
    $script:KeepTags       = [bool]$n.KeepTags
    $script:FullHash       = [bool]$n.FullHash
    $script:Flat           = [bool]$n.Flat
    $script:MinVideoKB     = [int]$n.MinVideoKB
    $script:Command        = Get-ModeCommand
    $script:SeriesTemplate = $n.SeriesTemplate
    $script:MovieTemplate  = $n.MovieTemplate

    $script:DropWords = @(
        $n.DropWords -split '[,;\r\n]+' |
            ForEach-Object { $_.Trim().ToLowerInvariant() } | Where-Object { $_ })

    $aliasy = New-Object System.Collections.Generic.List[object]
    foreach ($radek in ($n.ShowAliases -split '[\r\n]+')) {
        if ($radek -match '^\s*(?<p>.+?)\s*=\s*(?<n>.+?)\s*$') {
            $aliasy.Add(@{ Pattern = $Matches['p']; Name = $Matches['n'] })
        }
    }
    $script:ShowAliases = $aliasy.ToArray()
}

function Show-Preview {
    if (-not (Test-Path -LiteralPath $txtSrc.Text.Trim())) {
        [System.Windows.Forms.MessageBox]::Show(
            "Zdrojová složka neexistuje:`n`n$($txtSrc.Text)", 'MediaTool', 'OK', 'Warning') | Out-Null
        return
    }
    if ($cmbMode.SelectedIndex -eq 1 -or
        ($cmbMode.SelectedIndex -eq 2 -and -not [string]::IsNullOrWhiteSpace($txtLib.Text))) {
        if (-not (Confirm-Folder $txtLib.Text.Trim() 'Cílová knihovna')) { return }
    }

    Set-Busy $true 'Prohledávám soubory...'
    $grid.Rows.Clear()
    try {
        Set-EngineOptions
        $mode  = $script:Command
        $items = Get-Items
        if ($items.Count -eq 0) {
            Set-Busy $false 'Ve zdrojové složce nejsou žádné mediální soubory.'
            $script:Plan = $null
            return
        }

        $lblStatus.Text = "Porovnávám $($items.Count) souborů..."
        [System.Windows.Forms.Application]::DoEvents()
        [void](Add-Duplicates $items)

        $plan = New-Plan $items
        if ($cmbMode.SelectedIndex -eq 2) {
            $plan = @($plan | Where-Object { $_.Akce -eq 'DUPLICITA' })
        }
        if ($script:Nastaveni.DuplicityAkce -like 'Nechat*') {
            foreach ($radek in $plan) { if ($radek.Akce -eq 'DUPLICITA') { $radek.Cil = '' } }
        }
        $script:Plan = $plan

        $sizes = @{}
        foreach ($i in $items) { $sizes[$i.File.FullName] = $i.File.Length }
        $p = Get-Paleta

        foreach ($radek in ($plan | Sort-Object Akce, Zdroj)) {
            $hasTarget = -not [string]::IsNullOrWhiteSpace($radek.Cil)
            if ($hasTarget -and $mode -eq 'sort') {
                $targetDir  = $Library
                $targetShow = $radek.Cil.Substring([math]::Min($Library.Length + 1, $radek.Cil.Length))
            } elseif ($hasTarget) {
                $targetDir  = Split-Path $radek.Cil -Parent
                $targetShow = Split-Path $radek.Cil -Leaf
            } else {
                $targetDir = ''; $targetShow = ''
            }

            $mb = 0
            if ($sizes.ContainsKey($radek.Zdroj)) { $mb = [math]::Round($sizes[$radek.Zdroj] / 1MB, 1) }
            $zaskrtnout = $hasTarget -or ($radek.Akce -eq 'DUPLICITA')

            $r = $grid.Rows[$grid.Rows.Add(
                $zaskrtnout, $radek.Akce, (Split-Path $radek.Zdroj -Leaf),
                $targetShow, $mb, $radek.Duvod, $radek.Zdroj, $targetDir)]

            $r.DefaultCellStyle.BackColor = Get-ActionColor $radek.Akce
            if (-not $hasTarget) {
                $r.Cells['col_new'].ReadOnly = $true
                if ($radek.Akce -ne 'DUPLICITA') {
                    $r.Cells['col_do'].ReadOnly   = $true
                    $r.DefaultCellStyle.ForeColor = $p.TextSlab
                }
            }
        }

        $souhrn = ($plan | Group-Object Akce | Sort-Object Name |
                   ForEach-Object { "$($_.Name): $($_.Count)" }) -join '   |   '
        $script:DupBytes = 0
        foreach ($radek in ($plan | Where-Object { $_.Akce -eq 'DUPLICITA' })) {
            if ($sizes.ContainsKey($radek.Zdroj)) { $script:DupBytes += $sizes[$radek.Zdroj] }
        }
        if ($script:DupBytes -gt 0) {
            $souhrn += ('   |   duplicity zabírají {0:N2} GB' -f ($script:DupBytes / 1GB))
        }
        $kProvedeni = @($plan | Where-Object { $_.Cil }).Count
        if ($kProvedeni -eq 0 -and $cmbMode.SelectedIndex -eq 0) {
            $souhrn = 'Všechno už je pojmenované podle konvence. Pro přesun přepni nahoře na ' +
                      '"Setřídit do knihovny", vyber cílovou složku a dej Náhled.'
        }
        Set-Busy $false $souhrn
    } catch {
        Set-Busy $false 'Chyba.'
        [System.Windows.Forms.MessageBox]::Show(
            "Náhled se nepodařil:`n`n$($_.Exception.Message)", 'MediaTool', 'OK', 'Error') | Out-Null
    }
}

function Get-CheckedRows {
    param([string]$JenAkce)
    $vysledek = New-Object System.Collections.Generic.List[object]
    foreach ($r in $grid.Rows) {
        if (-not [bool]$r.Cells['col_do'].Value) { continue }
        $akce = [string]$r.Cells['col_akce'].Value
        if ($JenAkce -and $akce -ne $JenAkce) { continue }
        $dir  = [string]$r.Cells['col_dir'].Value
        $name = [string]$r.Cells['col_new'].Value
        $cil  = ''
        if ($dir -and $name) { $cil = Join-Path $dir $name }
        $vysledek.Add([pscustomobject]@{
            Akce = $akce; Zdroj = [string]$r.Cells['col_src'].Value
            Cil  = $cil;  MB    = [double]$r.Cells['col_mb'].Value })
    }
    return $vysledek
}

function Invoke-Apply {
    if (-not $script:Plan) {
        [System.Windows.Forms.MessageBox]::Show('Nejdřív si nech ukázat náhled.', 'MediaTool', 'OK', 'Information') | Out-Null
        return
    }
    $todo = @((Get-CheckedRows) | Where-Object { $_.Cil })
    if ($todo.Count -eq 0) {
        [System.Windows.Forms.MessageBox]::Show(
            "Není zaškrtnutý žádný řádek, který by se dal přesunout.`n" +
            'Duplicity bez cíle se řeší tlačítkem "Smazat duplicity".',
            'MediaTool', 'OK', 'Information') | Out-Null
        return
    }

    $odp = [System.Windows.Forms.MessageBox]::Show(
        "Provést $($todo.Count) operací?`n`nNic se nemaže. Vrátit to půjde tlačítkem " +
        '"Vrátit poslední dávku".', 'MediaTool', 'YesNo', 'Question')
    if ($odp -ne 'Yes') { return }

    Set-Busy $true 'Pracuji...'
    $pb.Value = 0; $pb.Maximum = $todo.Count; $pb.Visible = $true

    # Invoke-MoveBatch (jadro) zapisuje log po kazdem presunu - kdyz se okno zavre
    # nebo pocitac vypne uprostred davky, jde to, co uz se presunulo, vratit.
    $log = Join-Path $LogDir ('mediatool-{0:yyyyMMdd-HHmmss}.csv' -f (Get-Date))
    $res = Invoke-MoveBatch -Rows $todo -LogPath $log -OnProgress {
        param($n, $total, $r)
        $pb.Value = $n
        $lblStatus.Text = "$n / $total - $(Split-Path $r.Zdroj -Leaf)"
        [System.Windows.Forms.Application]::DoEvents()
    }
    $done  = $res.Done
    $chyby = $res.Errors

    $pb.Visible = $false
    Set-Busy $false "Hotovo: $($done.Count) souborů, chyb: $($chyby.Count)."
    if ($chyby.Count -gt 0) {
        [System.Windows.Forms.MessageBox]::Show(
            "Část souborů se nepodařila:`n`n" + (($chyby | Select-Object -First 15) -join "`n"),
            'MediaTool', 'OK', 'Warning') | Out-Null
    }
    Show-Preview
}

function Invoke-DeleteDuplicates {
    $todo = @(Get-CheckedRows -JenAkce 'DUPLICITA')
    if ($todo.Count -eq 0) {
        [System.Windows.Forms.MessageBox]::Show(
            'Není zaškrtnutá žádná duplicita. Dej Náhled a vyber řádky s akcí DUPLICITA.',
            'MediaTool', 'OK', 'Information') | Out-Null
        return
    }

    $celkem = ($todo | Measure-Object -Property MB -Sum).Sum
    $trvale = [bool]$chkTrvale.Checked
    $vSiti  = @($todo | Where-Object { Test-NetworkPath $_.Zdroj }).Count

    if ($trvale) { $jak = 'TRVALE (bez Koše) - tohle už nepůjde vrátit' }
    else         { $jak = 'do Koše (dají se odtud obnovit)' }

    $zprava = "Smazat $($todo.Count) duplicitních souborů $jak" + "?`n`n" +
              ('Uvolní se {0:N2} GB.' -f ($celkem / 1024)) + "`n`n" +
              'Ponechané soubory se nemažou - jde jen o zaškrtnuté řádky DUPLICITA.'
    if ($vSiti -gt 0 -and -not $trvale) {
        $zprava += "`n`nPOZOR: $vSiti souborů je na síťovém disku, kde Koš neexistuje. " +
                   'Ty se smažou natrvalo.'
    }

    if ([System.Windows.Forms.MessageBox]::Show($zprava, 'Smazat duplicity', 'YesNo', 'Warning') -ne 'Yes') { return }
    if ($trvale) {
        if ([System.Windows.Forms.MessageBox]::Show(
            "Opravdu trvale smazat $($todo.Count) souborů? Poslední varování.",
            'Smazat duplicity', 'YesNo', 'Warning') -ne 'Yes') { return }
    }

    Set-Busy $true 'Mažu...'
    $pb.Value = 0; $pb.Maximum = $todo.Count; $pb.Visible = $true

    $smazano = New-Object System.Collections.Generic.List[object]
    $chyby   = New-Object System.Collections.Generic.List[string]
    $n = 0
    foreach ($t in $todo) {
        $n++
        # Nahled muze byt stary: tesne pred smazanim overit, ze ponechana kopie existuje
        # a u shodnych dat ma stejny obsah. Bez toho mohly zmizet vsechny kopie.
        $radekPlanu = @($script:Plan | Where-Object { $_.Akce -eq 'DUPLICITA' -and $_.Zdroj -eq $t.Zdroj }) |
                      Select-Object -First 1
        $proc = Test-DuplicateDeletable -Zdroj $t.Zdroj -Ponechat $radekPlanu.Ponechat -Typ $radekPlanu.Typ
        try {
            if ($proc) {
                $chyby.Add("$(Split-Path $t.Zdroj -Leaf): NESMAZANO - $proc")
            } elseif (Test-Path -LiteralPath $t.Zdroj) {
                if ($trvale) {
                    Remove-Item -LiteralPath $t.Zdroj -Force
                } else {
                    [Microsoft.VisualBasic.FileIO.FileSystem]::DeleteFile(
                        $t.Zdroj,
                        [Microsoft.VisualBasic.FileIO.UIOption]::OnlyErrorDialogs,
                        [Microsoft.VisualBasic.FileIO.RecycleOption]::SendToRecycleBin)
                }
                $smazano.Add([pscustomobject]@{
                    Cas = (Get-Date).ToString('s'); Zdroj = $t.Zdroj; MB = $t.MB
                    Zpusob = $(if ($trvale) { 'trvale' } else { 'kos' }) })
            }
        } catch { $chyby.Add("$(Split-Path $t.Zdroj -Leaf): $($_.Exception.Message)") }
        $pb.Value = $n
        $lblStatus.Text = "$n / $($todo.Count) - $(Split-Path $t.Zdroj -Leaf)"
        [System.Windows.Forms.Application]::DoEvents()
    }

    if ($smazano.Count -gt 0) {
        if (-not (Test-Path -LiteralPath $LogDir)) { New-Item -ItemType Directory -Path $LogDir -Force | Out-Null }
        $smazano | Export-Csv -LiteralPath (Join-Path $LogDir ('smazano-{0:yyyyMMdd-HHmmss}.csv' -f (Get-Date))) `
                   -NoTypeInformation -Encoding UTF8
    }

    $pb.Visible = $false
    $uvolneno = ($smazano | Measure-Object -Property MB -Sum).Sum
    Set-Busy $false ('Smazáno: {0} souborů, uvolněno {1:N2} GB, chyb: {2}.' -f `
                     $smazano.Count, ($uvolneno / 1024), $chyby.Count)
    if ($chyby.Count -gt 0) {
        [System.Windows.Forms.MessageBox]::Show(
            "Část se smazat nepodařila:`n`n" + (($chyby | Select-Object -First 15) -join "`n"),
            'MediaTool', 'OK', 'Warning') | Out-Null
    }
    Show-Preview
}

function Invoke-UndoLast {
    if (-not (Test-Path -LiteralPath $LogDir)) {
        [System.Windows.Forms.MessageBox]::Show('Zatím není co vracet.', 'MediaTool', 'OK', 'Information') | Out-Null
        return
    }
    $log = Get-ChildItem -LiteralPath $LogDir -Filter 'mediatool-*.csv' |
           Sort-Object Name -Descending | Select-Object -First 1
    if (-not $log) {
        [System.Windows.Forms.MessageBox]::Show('Zatím není co vracet.', 'MediaTool', 'OK', 'Information') | Out-Null
        return
    }

    $rows = @(Import-Csv -LiteralPath $log.FullName)
    if ([System.Windows.Forms.MessageBox]::Show(
        "Vrátit dávku $($log.Name)?`n`n$($rows.Count) souborů se přesune zpět na původní jména a místa." +
        "`n`n(Smazané duplicity tímhle vrátit nejde - ty hledej v Koši.)",
        'MediaTool', 'YesNo', 'Question') -ne 'Yes') { return }

    Set-Busy $true 'Vracím...'
    $pb.Value = 0; $pb.Maximum = $rows.Count; $pb.Visible = $true

    # Invoke-UndoBatch (jadro) oznaci davku za vracenou jen kdyz se vratilo vse.
    # Driv stacil jediny vraceny soubor a dalsi "Vratit" pak vzalo starsi davku.
    $res = Invoke-UndoBatch -Log $log -OnProgress {
        param($n, $total, $r)
        $pb.Value = $n
        [System.Windows.Forms.Application]::DoEvents()
    }
    $ok    = $res.Restored
    $chyby = $res.Errors

    $pb.Visible = $false
    Set-Busy $false "Vráceno: $ok souborů, chyb: $($chyby.Count)."
    if ($chyby.Count -gt 0) {
        [System.Windows.Forms.MessageBox]::Show(
            "Část se vrátit nepodařila:`n`n" + (($chyby | Select-Object -First 15) -join "`n") +
            "`n`nDávka zůstává otevřená - po odstranění překážky ji vrať znovu.",
            'MediaTool', 'OK', 'Warning') | Out-Null
    }
}

function Select-Folder {
    param([System.Windows.Forms.TextBox]$Target, [string]$Popis)
    $d = New-Object System.Windows.Forms.FolderBrowserDialog
    $d.Description = $Popis
    $d.ShowNewFolderButton = $true
    if ($Target.Text -and (Test-Path -LiteralPath $Target.Text)) { $d.SelectedPath = $Target.Text }
    if ($d.ShowDialog() -eq 'OK') { $Target.Text = $d.SelectedPath }
    $d.Dispose()
}

# ==================================================================== okno

$form      = New-Object System.Windows.Forms.Form
$form.Text = 'MediaTool - úklid filmů a seriálů'
# Dpi, ne Font: při změně velikosti písma v nastavení by se jinak přeškálovalo
# celé okno a spodní lišta by utekla mimo obrazovku
$form.AutoScaleMode = 'Dpi'
$form.StartPosition = 'CenterScreen'

# okno se musí vejít i na menší obrazovku
$prac = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea
$form.Size = New-Object System.Drawing.Size(
    [math]::Min(1280, ($prac.Width - 80)),
    [math]::Min(800,  ($prac.Height - 80)))
$form.MinimumSize = New-Object System.Drawing.Size(
    [math]::Min(880, $prac.Width),
    [math]::Min(520, $prac.Height))

$IkonaPath = Join-Path $PSScriptRoot 'mediatool.ico'
if (Test-Path -LiteralPath $IkonaPath) {
    try { $form.Icon = New-Object System.Drawing.Icon($IkonaPath) } catch { }
}

# --- horní lišta: TableLayout, aby se pole roztahovala s oknem
$top = New-Object System.Windows.Forms.TableLayoutPanel
$top.Dock         = 'Top'
$top.AutoSize     = $true
$top.AutoSizeMode = 'GrowAndShrink'
$top.ColumnCount  = 3
$top.RowCount     = 3
$top.Padding      = New-Object System.Windows.Forms.Padding(14, 10, 14, 10)
[void]$top.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle('AutoSize')))
[void]$top.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle('Percent', 100)))
[void]$top.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle('AutoSize')))
for ($i = 0; $i -lt 3; $i++) {
    [void]$top.RowStyles.Add((New-Object System.Windows.Forms.RowStyle('AutoSize')))
}

$lblSrc = New-Lbl 'Zdrojová složka:'
$txtSrc = New-Object System.Windows.Forms.TextBox
$txtSrc.Dock   = 'Fill'
$txtSrc.Margin = New-Object System.Windows.Forms.Padding(6, 3, 6, 3)
$btnSrc = New-Btn 'Procházet...'

$lblLib = New-Lbl 'Knihovna (NAS):'
$txtLib = New-Object System.Windows.Forms.TextBox
$txtLib.Dock   = 'Fill'
$txtLib.Margin = New-Object System.Windows.Forms.Padding(6, 3, 6, 3)
$btnLib = New-Btn 'Procházet...'

$lblMode = New-Lbl 'Co udělat:'

$cmbMode = New-Object System.Windows.Forms.ComboBox
$cmbMode.Width = 240
$cmbMode.DropDownStyle = 'DropDownList'
$cmbMode.Margin = New-Object System.Windows.Forms.Padding(0, 2, 14, 2)
[void]$cmbMode.Items.Add('Přejmenovat na místě')
[void]$cmbMode.Items.Add('Setřídit do knihovny')
[void]$cmbMode.Items.Add('Najít duplicity')
$cmbMode.SelectedIndex = 0

$lblFilter = New-Lbl 'Filtr názvu:'
$txtFilter = New-Txt 150
$txtFilter.Margin = New-Object System.Windows.Forms.Padding(0, 2, 14, 2)
$btnPreview = New-Btn 'Náhled' 'primary' 120
$lblHint = New-Lbl 'Nový název jde přepsat přímo v tabulce.' -Slaby
$lblHint.Margin = New-Object System.Windows.Forms.Padding(16, 8, 0, 0)

$radekAkce = New-Radek @($cmbMode, $lblFilter, $txtFilter, $btnPreview, $lblHint) 700

$top.Controls.Add($lblSrc, 0, 0); $top.Controls.Add($txtSrc, 1, 0); $top.Controls.Add($btnSrc, 2, 0)
$top.Controls.Add($lblLib, 0, 1); $top.Controls.Add($txtLib, 1, 1); $top.Controls.Add($btnLib, 2, 1)
$top.Controls.Add($lblMode, 0, 2); $top.Controls.Add($radekAkce, 1, 2)
$top.SetColumnSpan($radekAkce, 2)

# --- postranní panel s nastavením
$side = New-Object System.Windows.Forms.FlowLayoutPanel
$side.Dock          = 'Right'
$side.Width         = 340
$side.FlowDirection = 'TopDown'
$side.WrapContents  = $false
$side.AutoScroll    = $true
$side.Padding       = New-Object System.Windows.Forms.Padding(16, 12, 16, 12)

$lblSecVzhled = New-Lbl 'VZHLED' -Nadpis
$cmbTheme = New-Object System.Windows.Forms.ComboBox
$cmbTheme.Width = 150; $cmbTheme.DropDownStyle = 'DropDownList'
$cmbTheme.Margin = New-Object System.Windows.Forms.Padding(0, 2, 0, 4)
[void]$cmbTheme.Items.Add('Světlý'); [void]$cmbTheme.Items.Add('Tmavý')
$numFont = New-Object System.Windows.Forms.NumericUpDown
$numFont.Width = 60; $numFont.Minimum = 8; $numFont.Maximum = 14
$numFont.Margin = New-Object System.Windows.Forms.Padding(0, 2, 0, 4)
$chkZebra = New-Chk 'Střídat barvu řádků'

$lblSecNazvy = New-Lbl 'POJMENOVÁNÍ' -Nadpis
$txtSeries = New-Txt 300
$txtMovie  = New-Txt 300
$lblSideHint = New-Lbl '{show} {season} {episode} {title} {year}' -Slaby
$chkKeepTags = New-Chk 'Ponechat tagy (1080p, x265)'

$lblSecHledani = New-Lbl 'PROHLEDÁVÁNÍ' -Nadpis
$chkRecurse  = New-Chk 'Včetně podsložek'
$chkNoSubs   = New-Chk 'Vynechat titulky'
$chkFullHash = New-Chk 'Přesné porovnání SHA256 (pomalé)'
$chkFlat     = New-Chk 'Filmy bez vlastní podsložky'
$numMinKB = New-Object System.Windows.Forms.NumericUpDown
$numMinKB.Width = 90; $numMinKB.Minimum = 0; $numMinKB.Maximum = 1000000; $numMinKB.Increment = 50
$numMinKB.Margin = New-Object System.Windows.Forms.Padding(0, 2, 0, 4)

$lblSecDup = New-Lbl 'DUPLICITY' -Nadpis
$cmbDup = New-Object System.Windows.Forms.ComboBox
$cmbDup.Width = 300; $cmbDup.DropDownStyle = 'DropDownList'
$cmbDup.Margin = New-Object System.Windows.Forms.Padding(0, 2, 0, 4)
[void]$cmbDup.Items.Add('Přesunout do _Duplicity')
[void]$cmbDup.Items.Add('Nechat na místě (jen ukázat)')
$chkTrvale = New-Chk 'Mazat trvale, ne do Koše' 'danger'

$lblSecSlovnik = New-Lbl 'SLOVNÍK' -Nadpis
$txtDrop  = New-Txt 300 52
$txtAlias = New-Txt 300 52

$btnSaveCfg  = New-Btn 'Uložit nastavení' 'primary' 145
$btnResetCfg = New-Btn 'Výchozí' 'secondary' 145

$side.Controls.AddRange(@(
    $lblSecVzhled,
    (New-Radek @((New-Lbl 'Motiv' -Sirka 70), $cmbTheme)),
    (New-Radek @((New-Lbl 'Písmo' -Sirka 70), $numFont)),
    $chkZebra,

    $lblSecNazvy,
    (New-Lbl 'Seriál' -Slaby), $txtSeries,
    (New-Lbl 'Film' -Slaby), $txtMovie,
    $lblSideHint, $chkKeepTags,

    $lblSecHledani,
    $chkRecurse, $chkNoSubs, $chkFullHash, $chkFlat,
    (New-Lbl 'Video menší než (kB) je odpad' -Slaby), $numMinKB,

    $lblSecDup, $cmbDup, $chkTrvale,

    $lblSecSlovnik,
    (New-Lbl 'Rip skupiny k vyhození (čárkou)' -Slaby), $txtDrop,
    (New-Lbl 'Sloučení seriálů (regex = Název)' -Slaby), $txtAlias,
    (New-Radek @($btnSaveCfg, $btnResetCfg))
))

# --- tabulka
$grid = New-Object System.Windows.Forms.DataGridView
$grid.Dock = 'Fill'
$grid.AllowUserToAddRows    = $false
$grid.AllowUserToDeleteRows = $false
$grid.AllowUserToResizeRows = $false
$grid.RowHeadersVisible     = $false
$grid.SelectionMode         = 'FullRowSelect'
$grid.AutoSizeColumnsMode   = 'None'
$grid.BorderStyle           = 'None'
$grid.CellBorderStyle       = 'SingleHorizontal'

function Add-Col {
    param([string]$Name, [string]$Header, [int]$Width, [bool]$ReadOnly = $true,
          [string]$Kind = 'text', [string]$Fill = '')
    if ($Kind -eq 'check') { $c = New-Object System.Windows.Forms.DataGridViewCheckBoxColumn }
    else                   { $c = New-Object System.Windows.Forms.DataGridViewTextBoxColumn }
    $c.Name = $Name; $c.HeaderText = $Header; $c.Width = $Width; $c.ReadOnly = $ReadOnly
    if ($Fill) { $c.AutoSizeMode = 'Fill'; $c.FillWeight = [int]$Fill }
    [void]$grid.Columns.Add($c)
    return $c
}

# sloupce s názvy se roztahují podle šířky okna, ostatní drží pevnou šířku
[void](Add-Col 'col_do'   'Provést'       64  $false 'check')
[void](Add-Col 'col_akce' 'Akce'          110 $true)
[void](Add-Col 'col_orig' 'Původní název' 300 $true  'text' '50')
[void](Add-Col 'col_new'  'Nový název'    300 $false 'text' '50')
$colMb = Add-Col 'col_mb' 'MB'            70  $true
$colMb.DefaultCellStyle.Alignment = 'MiddleRight'
[void](Add-Col 'col_pozn' 'Poznámka'      190 $true)
$colSrc = Add-Col 'col_src' 'src' 10 $true; $colSrc.Visible = $false
$colDir = Add-Col 'col_dir' 'dir' 10 $true; $colDir.Visible = $false

# --- spodní lišta
$bottom = New-Object System.Windows.Forms.TableLayoutPanel
$bottom.Dock         = 'Bottom'
$bottom.AutoSize     = $true
$bottom.AutoSizeMode = 'GrowAndShrink'
$bottom.ColumnCount  = 2
$bottom.RowCount     = 2
$bottom.Padding      = New-Object System.Windows.Forms.Padding(14, 10, 14, 10)
[void]$bottom.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle('Percent', 100)))
[void]$bottom.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle('AutoSize')))
[void]$bottom.RowStyles.Add((New-Object System.Windows.Forms.RowStyle('AutoSize')))
[void]$bottom.RowStyles.Add((New-Object System.Windows.Forms.RowStyle('AutoSize')))

$btnAll      = New-Btn 'Označit vše'
$btnNone     = New-Btn 'Odznačit vše'
$btnApply    = New-Btn 'Provést vybrané' 'primary' 150
$btnDelete   = New-Btn 'Smazat duplicity' 'danger' 150
$btnUndo     = New-Btn 'Vrátit poslední dávku' 'secondary' 165
$btnSettings = New-Btn 'Nastavení' 'secondary' 130

$flowBtn = New-Object System.Windows.Forms.FlowLayoutPanel
$flowBtn.FlowDirection = 'LeftToRight'
$flowBtn.WrapContents  = $true
$flowBtn.AutoSize      = $true
$flowBtn.AutoSizeMode  = 'GrowAndShrink'
$flowBtn.Dock          = 'Fill'
$flowBtn.Margin        = New-Object System.Windows.Forms.Padding(0)
$flowBtn.Controls.AddRange(@($btnAll, $btnNone, $btnApply, $btnDelete, $btnUndo))

$btnSettings.Anchor = 'Right'
$btnSettings.Margin = New-Object System.Windows.Forms.Padding(8, 0, 0, 0)

$bottom.Controls.Add($flowBtn, 0, 0)
$bottom.Controls.Add($btnSettings, 1, 0)

# --- stavový pruh úplně dole, ve vlastním panelu
# (v TableLayoutu se druhý řádek ořezával, tohle je spolehlivější)
$statusBar = New-Object System.Windows.Forms.Panel
$statusBar.Dock    = 'Bottom'
$statusBar.Height  = 30
$statusBar.Padding = New-Object System.Windows.Forms.Padding(14, 0, 14, 6)

$pb = New-Object System.Windows.Forms.ProgressBar
$pb.Dock    = 'Right'
$pb.Width   = 240
$pb.Style   = 'Continuous'
$pb.Margin  = New-Object System.Windows.Forms.Padding(8, 0, 0, 0)
$pb.Visible = $false

$lblStatus = New-Object System.Windows.Forms.Label
$lblStatus.Text      = 'Vyber složku a dej Náhled. Dokud nezmáčkneš Provést, nic se nezmění.'
$lblStatus.Dock      = 'Fill'
$lblStatus.AutoSize  = $false
$lblStatus.TextAlign = 'MiddleLeft'
$lblStatus.AutoEllipsis = $true

$statusBar.Controls.AddRange(@($lblStatus, $pb))

# Fill musí do kolekce jako první, aby dostal zbytek místa;
# co je v kolekci později, ukotví se dřív - proto je stavový pruh úplně vespod
$form.Controls.AddRange(@($grid, $side, $top, $bottom, $statusBar))

# ------------------------------------------------------------------ události

$btnSrc.Add_Click({ Select-Folder $txtSrc 'Odkud brát soubory' })
$btnLib.Add_Click({ Select-Folder $txtLib 'Kam třídit (klidně síťový disk nebo \\NAS\slozka)' })
$btnPreview.Add_Click({ Show-Preview })
$btnApply.Add_Click({ Invoke-Apply })
$btnDelete.Add_Click({ Invoke-DeleteDuplicates })
$btnUndo.Add_Click({ Invoke-UndoLast })

$btnSettings.Add_Click({
    $side.Visible = -not $side.Visible
    if ($side.Visible) { $btnSettings.Text = 'Skrýt nastavení' } else { $btnSettings.Text = 'Nastavení' }
})

$btnSaveCfg.Add_Click({
    if (Export-Settings) { $lblStatus.Text = "Nastavení uloženo do $($script:SettingsPath)" }
    else { $lblStatus.Text = 'Nastavení se nepodařilo uložit.' }
})

$btnResetCfg.Add_Click({
    if ([System.Windows.Forms.MessageBox]::Show(
        'Vrátit všechna nastavení na výchozí?', 'MediaTool', 'YesNo', 'Question') -ne 'Yes') { return }
    $script:Nastaveni = New-DefaultSettings
    Write-Form
    Update-Theme
})

$cmbTheme.Add_SelectedIndexChanged({ $script:Nastaveni.Motiv = [string]$cmbTheme.SelectedItem; Update-Theme })
$numFont.Add_ValueChanged({ $script:Nastaveni.Pismo = [int]$numFont.Value; Update-Theme })
$chkZebra.Add_CheckedChanged({ $script:Nastaveni.Zebra = [bool]$chkZebra.Checked; Update-Theme })

$btnAll.Add_Click({
    foreach ($r in $grid.Rows) { if (-not $r.Cells['col_do'].ReadOnly) { $r.Cells['col_do'].Value = $true } }
})
$btnNone.Add_Click({
    foreach ($r in $grid.Rows) { if (-not $r.Cells['col_do'].ReadOnly) { $r.Cells['col_do'].Value = $false } }
})

$grid.Add_CurrentCellDirtyStateChanged({
    if ($grid.IsCurrentCellDirty) {
        $grid.CommitEdit([System.Windows.Forms.DataGridViewDataErrorContexts]::Commit)
    }
})

$grid.Add_CellDoubleClick({
    param($s, $e)
    if ($e.RowIndex -lt 0) { return }
    $src = [string]$grid.Rows[$e.RowIndex].Cells['col_src'].Value
    if ($src -and (Test-Path -LiteralPath $src)) { Start-Process explorer.exe "/select,`"$src`"" }
})

$cmbMode.Add_SelectedIndexChanged({
    $jeSort = $cmbMode.SelectedIndex -ne 0
    $txtLib.Enabled  = $jeSort
    $btnLib.Enabled  = $jeSort
    $chkFlat.Enabled = $cmbMode.SelectedIndex -eq 1
    $btnDelete.Enabled = $cmbMode.SelectedIndex -eq 2
    if ($grid.Rows.Count -gt 0) {
        $grid.Rows.Clear()
        $script:Plan = $null
        $lblStatus.Text = 'Režim se změnil - dej Náhled.'
    }
})

$form.Add_FormClosing({ [void](Export-Settings) })

# ------------------------------------------------------------------- start

Write-Form
if ($TestTheme) { $script:Nastaveni.Motiv = $TestTheme; $cmbTheme.SelectedItem = $TestTheme }
$side.Visible      = [bool]$script:Nastaveni.PanelOtevren
if ($side.Visible) { $btnSettings.Text = 'Skrýt nastavení' }
$txtLib.Enabled    = $false
$btnLib.Enabled    = $false
$chkFlat.Enabled   = $false
$btnDelete.Enabled = $false
Update-Theme

if ($SelfTest) {
    "SelfTest OK - motiv: $($script:Nastaveni.Motiv), sloupcu: $($grid.Columns.Count), " +
    "prvku v panelu: $($side.Controls.Count), panel viditelny: $($side.Visible), " +
    "ikona: $(if ($form.Icon) { 'ano' } else { 'ne' })"

    "--- okno: Size=$($form.Size.Width)x$($form.Size.Height) Client=$($form.ClientSize.Width)x$($form.ClientSize.Height) " +
    "pracovni plocha=$($prac.Width)x$($prac.Height) AutoScaleDim=$($form.AutoScaleDimensions) Mode=$($form.AutoScaleMode)"
    "--- lišty: top.H=$($top.Height) bottom.Top=$($bottom.Top) bottom.H=$($bottom.Height) side.W=$($side.Width)"

    $puvodni = $script:SettingsPath
    $script:SettingsPath = Join-Path $env:TEMP ('mt-settings-test-{0}.json' -f $PID)
    $ulozeno = Export-Settings
    $zpet = Import-Settings
    "--- nastaveni ulozeno: $ulozeno; zpet: motiv=$($zpet.Motiv) pismo=$($zpet.Pismo) minKB=$($zpet.MinVideoKB)"
    Remove-Item -LiteralPath $script:SettingsPath -Force -ErrorAction SilentlyContinue
    $script:SettingsPath = $puvodni

    # kontrola rozvrzeni pri nekolika sirkach okna - nic nesmi utect za hranu
    foreach ($sirka in @(900, 1280, 1600)) {
        $form.Width = $sirka
        $form.PerformLayout()
        [System.Windows.Forms.Application]::DoEvents()
        $klient = $form.ClientSize.Width
        $pretece = @()
        foreach ($c in @($txtSrc, $btnSrc, $txtLib, $btnLib, $btnPreview, $btnSettings, $btnUndo)) {
            $abs = $c.PointToScreen([System.Drawing.Point]::new(0, 0))
            $formAbs = $form.PointToScreen([System.Drawing.Point]::new(0, 0))
            $pravyOkraj = ($abs.X - $formAbs.X) + $c.Width
            if ($pravyOkraj -gt $klient -or $c.Width -le 0) { $pretece += "$($c.Text ) ($pravyOkraj>$klient)" }
        }
        if ($pretece.Count -eq 0) { "--- sirka $sirka (klient $klient): vsechny prvky uvnitr OK" }
        else { "--- sirka $sirka (klient $klient): PRETEKA -> $($pretece -join ', ')" }
    }

    if ($TestPath) {
        $txtSrc.Text = $TestPath
        if ($TestLib) { $txtLib.Text = $TestLib }
        $cmbMode.SelectedIndex = $TestMode
        Show-Preview
        "--- status: $($lblStatus.Text)"
        foreach ($r in $grid.Rows) {
            '{0} {1,-12} {2,-52} -> {3}' -f `
                $(if ([bool]$r.Cells['col_do'].Value) { '[x]' } else { '[ ]' }),
                $r.Cells['col_akce'].Value, $r.Cells['col_orig'].Value, $r.Cells['col_new'].Value
        }
    }
    if ($TestShot) {
        # okno vykreslí samo sebe - žádné dohadování se souřadnicemi na obrazovce
        $form.Width = [math]::Min(1280, ($prac.Width - 80))
        $form.Show()
        [System.Windows.Forms.Application]::DoEvents()
        Start-Sleep -Milliseconds 400
        [System.Windows.Forms.Application]::DoEvents()
        # bitmapa musí být na celé okno - DrawToBitmap kreslí i titulkový pruh,
        # při velikosti klienta by se spodní lišta ořízla
        $bmp = New-Object System.Drawing.Bitmap($form.Width, $form.Height)
        $form.DrawToBitmap($bmp, (New-Object System.Drawing.Rectangle(0, 0, $form.Width, $form.Height)))
        $bmp.Save($TestShot, [System.Drawing.Imaging.ImageFormat]::Png)
        $bmp.Dispose()
        "--- po zobrazeni: klient=$($form.ClientSize.Width)x$($form.ClientSize.Height) " +
        "bottom=$($bottom.Top)..$($bottom.Bottom) status=$($statusBar.Top)..$($statusBar.Bottom) " +
        "grid=$($grid.Top)..$($grid.Bottom) side=$($side.Left)..$($side.Right) viditelny=$($side.Visible)"
        $form.Hide()
        "--- snimek okna: $TestShot ($($form.ClientSize.Width)x$($form.ClientSize.Height))"
    }

    $form.Dispose()
    return
}

[void]$form.ShowDialog()
$form.Dispose()
