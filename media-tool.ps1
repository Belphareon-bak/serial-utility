#Requires -Version 5.1
<#
.SYNOPSIS
    MediaTool - hromadne prejmenovani, deduplikace a setrideni medialnich souboru.

.DESCRIPTION
    Sjednoti nazvy serialu a filmu na jednotnou konvenci, najde duplicity
    (i ty, ktere se jmenuji uplne jinak) a setridi soubory do knihovny.

    Nic nemaze. Duplicity presouva do slozky _Duplicity.
    Bez prepinace -Apply pouze ukazuje, co by udelal.

    Umi Synology pres SMB (namapovany disk i UNC cesta):
      - preskakuje @eaDir, #recycle, #snapshot
      - presun mezi svazky dela jako kopie + overeni velikosti + smazani zdroje
      - hlida delku cilove cesty a znaky, ktere SMB/DSM nema rad

.PARAMETER Command
    scan   - analyza, ukaze navrhovane nazvy (vychozi)
    dupes  - jen hledani duplicit
    rename - prejmenuje soubory na miste
    sort   - prejmenuje a presune do knihovny (-Library)
    undo   - vrati posledni provedenou davku

.EXAMPLE
    .\media-tool.ps1 scan -Filter Bluey
.EXAMPLE
    .\media-tool.ps1 dupes
.EXAMPLE
    .\media-tool.ps1 sort -Library "Z:\video" -Apply
.EXAMPLE
    .\media-tool.ps1 undo -Apply
#>
[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [ValidateSet('scan', 'dupes', 'rename', 'sort', 'undo')]
    [string]$Command = 'scan',

    [string[]]$Path = @("$env:USERPROFILE\Downloads"),
    [switch]$Recurse,
    [string]$Filter,

    [string]$Library = "$env:USERPROFILE\Videos\Knihovna",
    [switch]$Flat,

    [switch]$Apply,
    [switch]$FullHash,
    [switch]$KeepTags,
    [switch]$NoSubs,

    [string]$SeriesTemplate = '{show} - S{season}E{episode} - {title}',
    [string]$MovieTemplate  = '{title} ({year})',

    # video mensi nez tohle se povazuje za nedokoncene stazeni
    [int]$MinVideoKB = 100,

    [string]$LogDir,

    # jen nacte funkce a skonci - pouziva GUI, viz media-tool-gui.ps1
    [switch]$LoadOnly
)

$ErrorActionPreference = 'Stop'
if ([string]::IsNullOrWhiteSpace($LogDir)) {
    $base = $PSScriptRoot
    if ([string]::IsNullOrWhiteSpace($base)) { $base = (Get-Location).Path }
    $LogDir = Join-Path $base 'logs'
}

# ---------------------------------------------------------------- konfigurace

$VideoExt = @('.mkv', '.mp4', '.avi', '.mov', '.m4v', '.webm', '.wmv', '.flv',
              '.ts', '.m2ts', '.mpg', '.mpeg', '.divx', '.iso')
$SubExt   = @('.srt', '.sub', '.ass', '.ssa', '.vtt', '.idx')

# slozky, ktere se nikdy neprochazi (Synology / Windows sluzebni)
$SkipDirs = @('@eaDir', '#recycle', '#snapshot', '$RECYCLE.BIN',
              'System Volume Information', '.git', '_Duplicity', '_Kekontrole')

# Technicke tagy se deli na dve skupiny.
#
# JEDNOZNACNE nejsou zaroven beznymi slovy, takze se vyhazuji z cele delky nazvu.
$TagPatternStrict = '^(?:' + (@(
    '\d{3,4}p', '4k', 'uhd',
    'web-?dl', 'webrip', 'bluray', 'blu-?ray', 'bdrip', 'brrip', 'bdremux',
    'hdtv', 'dvdrip', 'dvd', 'remux', 'hdr', 'hdr10', 'sdr',
    'x264', 'x265', 'h\.?264', 'h\.?265', 'hevc', 'avc', 'xvid', 'divx',
    'aac', 'aac2', 'ac3', 'eac3', 'dts', 'dtshd', 'ddp?\d?(?:\.\d)?', '\d\.\d',
    'atmos', 'truehd', 'flac', 'mp3',
    'hmax', 'amzn', 'dsnp', 'atvp', 'pcok',
    'repack', 'remastered',
    'cze', 'slo', 'eng', 'czech', 'cesky', 'ceske',
    'czsken', 'czskeng', 'dabing', 'dabbing',
    'titulky', 'cztit', 'subs', 'subbed', 'hardsub',
    'cz', 'sk', 'en', 'dab', 'tit', 'forced'
) -join '|') + ')$'

# DVOJZNACNE jsou zaroven bezna slova a objevuji se v nazvech filmu i serialu:
# "Mad Max", "Ray", "Blu", "Sub Zero", "Dual Survival", "Complete Unknown",
# "The Limited", "En attendant Godot", "Mr. Holland's Opus".
# Vyhazuji se proto JEN z casti za rokem nebo za SxxEyy, kde uz nazev byt nemuze.
# Pred rokem zustavaji - radeji v nazvu jeden zbytecny tag nez utrzeny nazev.
$TagPatternLoose = '^(?:' + (@(
    'hd', 'sd', 'web', 'dl', 'blu', 'ray', 'dv', 'nf', 'max', 'hulu', 'opus',
    'proper', 'internal', 'extended', 'uncut', 'unrated', 'limited',
    'multi', 'dual', 'complete', 'ws', 'rip', 'sub'
) -join '|') + ')$'

# rip skupiny a vlastni smeti - sem si pridavej dalsi
$DropWords = @('chmeli', 'jdm', 'ffi', 'rarbg', 'yify', 'yts', 'evo', 'ntb')

# sjednoceni nazvu serialu, aby nevznikly dve slozky pro jednu vec.
# Pattern se testuje na rozebrany nazev serialu (bez ohledu na velikost pismen).
$ShowAliases = @(
    @{ Pattern = '^game[ ._]?of[ ._]?thrones'; Name = 'Game of Thrones' }
)

# ------------------------------------------------------------------- pomocne

function Write-Head {
    param([string]$Text)
    Write-Host ''
    Write-Host ('== ' + $Text) -ForegroundColor Cyan
}

function Test-SkippedPath {
    param([string]$FullName)
    foreach ($d in $SkipDirs) {
        if ($FullName -like "*\$d\*") { return $true }
    }
    return $false
}

function Remove-Tags {
    # vyhodi z textu technicke tagy, rip skupiny a zbytky zavorek.
    # -Trailing zapina i dvojznacne tagy - pouziva se jen na cast za rokem nebo
    # za SxxEyy, kde uz nazev dila byt nemuze.
    param([string]$Text, [switch]$Trailing)
    if ([string]::IsNullOrWhiteSpace($Text)) { return '' }
    $tagRx = if ($Trailing) { $TagPatternStrict + '|' + $TagPatternLoose } else { $TagPatternStrict }

    $t = $Text -replace '~[A-Za-z0-9]+', ' '
    $t = $t -replace '\[[^\]]*\]', ' '
    # (31) na zacatku je smeti z prohlizece, ale (1) na konci rozlisuje ruzne soubory
    $t = $t -replace '^\s*\(\d+\)\s*', ' '
    $t = $t -replace '\([A-Za-z]{2,10}\d*\)', ' '

    $keep = New-Object System.Collections.Generic.List[string]
    foreach ($tok in ($t -split '\s+')) {
        if ([string]::IsNullOrWhiteSpace($tok)) { continue }
        if ($tok -eq '-') { $keep.Add('-'); continue }   # pomlcka mezi slovy zustava
        $bare = $tok.Trim('.', '(', ')', '[', ']', '-', '_')
        if ([string]::IsNullOrWhiteSpace($bare)) { continue }
        if ($DropWords -contains $bare.ToLowerInvariant()) { continue }
        if ($bare -match $tagRx) { continue }

        # slozene tokeny typu x264-CZ_SK_EN nebo WEB-DL
        $parts = $bare -split '[-_]'
        if ($parts.Count -gt 1) {
            $allTags = $true
            foreach ($p in $parts) {
                if ([string]::IsNullOrWhiteSpace($p)) { continue }
                if ($p -notmatch $tagRx -and $DropWords -notcontains $p.ToLowerInvariant()) {
                    $allTags = $false
                    break
                }
            }
            if ($allTags) { continue }
        }
        $keep.Add($bare)
    }

    # Pojistka: kdyz v puvodnim textu byla pismena a po vyhazeni tagu nezbylo
    # zadne, byl odstranen samotny nazev. V takovem pripade se nemeni nic.
    # V koncove casti (-Trailing) pojistka neplati - tam je prazdny vysledek
    # spravna odpoved, protoze za SxxEyy nebo za rokem byva jen technicky balast.
    $vysledek = ($keep -join ' ')
    if (-not $Trailing -and $t -match '\p{L}' -and $vysledek -notmatch '\p{L}') {
        return $t.Trim()
    }
    return $vysledek
}

function Format-Title {
    # uklidi zbytkovou interpunkci, poradova cisla a nedovrene zavorky
    param([string]$Text)
    if ([string]::IsNullOrWhiteSpace($Text)) { return '' }
    $t = $Text
    $t = $t -replace '^\s*\d{1,2}\s*[.)]\s+', ''
    $open  = ([regex]::Matches($t, '\(')).Count
    $close = ([regex]::Matches($t, '\)')).Count
    if ($open -gt $close) { $t = $t.Substring(0, $t.IndexOf('(')) }
    $t = $t -replace '\s+', ' '
    # zavorky se zamerne netrimuji - resi je az Remove-Tags, jinak by z "(31) "
    # zbylo "31)" a poradove cislo by se stalo nazvem filmu
    $t = $t.Trim(' ', "`t", '.', ',', '-', '_', '+')
    return $t
}

function Get-CleanSegment {
    # poradi je dulezite: nejdriv useknout nedovrenou zavorku a poradove cislo,
    # teprve pak vyhazovat tagy (jinak zmizi zavorka, podle ktere se seka)
    param([string]$Text, [switch]$Trailing)
    return (Format-Title (Remove-Tags (Format-Title $Text) -Trailing:$Trailing))
}

function Resolve-ShowAlias {
    param([string]$Show)
    foreach ($a in $ShowAliases) {
        if ($Show -match $a.Pattern) { return $a.Name }
    }
    return $Show
}

function New-SafeName {
    # nazev bezpecny pro NTFS i SMB/Synology
    param([string]$Name)
    $n = $Name -replace '[<>:"/\\|?*]', ''
    $n = $n -replace '[\x00-\x1F]', ''
    $n = $n -replace '\s+', ' '
    $n = $n.Trim()
    $n = $n.TrimEnd('.', ' ')
    if ([string]::IsNullOrWhiteSpace($n)) { $n = 'bez nazvu' }
    return $n
}

function ConvertFrom-MediaName {
    # rozebere nazev souboru na serial/dil/titul nebo film/rok
    param([System.IO.FileInfo]$File)

    $base = [System.IO.Path]::GetFileNameWithoutExtension($File.Name)
    $copy = 0

    # kopie typu " (1)" - jen pokud existuje i original bez cisla.
    # Kdyz original neexistuje, je cislo soucasti nazvu (ctyri ruzne
    # "Deleted Scene (1..4)") a musi se do noveho nazvu vratit.
    $keepSuffix = ''
    if ($base -match '^(?<b>.*?)\s*\((?<n>\d{1,2})\)$') {
        $cand = Join-Path $File.DirectoryName ($Matches['b'] + $File.Extension)
        if (Test-Path -LiteralPath $cand) {
            $copy = [int]$Matches['n']
            $base = $Matches['b']
        } else {
            $keepSuffix = ' (' + $Matches['n'] + ')'
        }
    }

    # oddelovace -> mezery. Rozhoduje se podle PUVODNIHO nazvu:
    # tecka je oddelovac, kdyz jich je vic nez mezer (scene nazvy);
    # pomlcka jen kdyz v nazvu neni ani jedna mezera.
    $spaces  = ([regex]::Matches($base, ' ')).Count
    $dots    = ([regex]::Matches($base, '\.')).Count
    $hyphens = ([regex]::Matches($base, '-')).Count

    # oddelovac je ten znak, kterym je nazev opravdu clenen - jinak by se
    # z "Hora.Mama-tata" stalo "Hora Mama tata" a z "Top-Gear---Afrika" nic
    $work = $base
    if ($dots -gt $spaces -and $dots -ge $hyphens) {
        $ph   = [string][char]1
        $work = $work -replace '(?<=\d)\.(?=\d)', $ph      # DD5.1 zustava
        $work = $work -replace '\.', ' '
        $work = $work -replace $ph, '.'
    } elseif ($hyphens -gt $spaces) {
        $work = $work -replace '-', ' '
    }
    $work = $work -replace '[+_]', ' '
    $work = $work -replace '\s+', ' '

    $item = [pscustomobject]@{
        File    = $File
        Kind    = 'Neznamy'
        Show    = ''
        Season  = $null
        Episode = $null
        Title   = ''
        Year    = $null
        Copy    = $copy
        Suffix  = $keepSuffix
        Review  = $false
        Note    = ''
        Hash    = ''
        DupOf   = ''
        NewName = ''
        IsSub   = ($SubExt -contains $File.Extension.ToLowerInvariant())
    }

    # --- serial: SxxEyy nebo 1x02
    $m = [regex]::Match($work, '(?<![A-Za-z0-9])[Ss](?<s>\d{1,2})[\s._-]*[Ee](?<e>\d{1,3})(?![0-9])')
    if (-not $m.Success) {
        $m = [regex]::Match($work, '(?<![A-Za-z0-9])(?<s>\d{1,2})x(?<e>\d{2,3})(?![0-9])')
    }
    if ($m.Success) {
        $item.Kind    = 'Serial'
        $item.Season  = [int]$m.Groups['s'].Value
        $item.Episode = [int]$m.Groups['e'].Value
        $item.Show    = Resolve-ShowAlias (Get-CleanSegment $work.Substring(0, $m.Index))
        $item.Title   = Get-CleanSegment $work.Substring($m.Index + $m.Length) -Trailing
        if ([string]::IsNullOrWhiteSpace($item.Show)) {
            $item.Show   = 'Neznamy serial'
            $item.Review = $true
        }
        return $item
    }

    # --- film: posledni ctyrcisli rok
    # (?![xX]\d) odfiltruje rozliseni - v "1920x800p" neni 1920 rok
    $years = [regex]::Matches($work, '(?<![0-9])(?<y>19\d{2}|20\d{2})(?![0-9])(?![xX]\d)')
    if ($years.Count -gt 0) {
        $last = $years[$years.Count - 1]
        $item.Kind  = 'Film'
        $item.Year  = [int]$last.Groups['y'].Value
        $item.Title = Get-CleanSegment $work.Substring(0, $last.Index)
        # "(31) 2022 Black Panther ..." - pred rokem je jen poradove cislo
        if ($item.Title -notmatch '\p{L}') {
            # rok byl na zacatku nazvu - zkus text za nim
            $item.Title  = Get-CleanSegment $work.Substring($last.Index + 4) -Trailing
            $item.Review = $true
            if ([string]::IsNullOrWhiteSpace($item.Title)) {
                $item.Title = Get-CleanSegment $work
            }
        }
        return $item
    }

    # --- bez roku i bez cisla dilu
    $item.Kind   = 'Film'
    $item.Title  = Get-CleanSegment $work
    $item.Review = $true
    $item.Note   = 'chybi rok - overit rucne'
    return $item
}

function Format-NameTemplate {
    param([pscustomobject]$Item)

    if ($Item.Kind -eq 'Serial') {
        $n = $SeriesTemplate
        $n = $n.Replace('{show}', $Item.Show)
        $n = $n.Replace('{season}', ('{0:00}' -f $Item.Season))
        $n = $n.Replace('{episode}', ('{0:00}' -f $Item.Episode))
        if ([string]::IsNullOrWhiteSpace($Item.Title)) {
            $n = $n -replace '\s*-\s*\{title\}\s*', ''
            $n = $n.Replace('{title}', '')
        } else {
            $n = $n.Replace('{title}', $Item.Title)
        }
    } else {
        $n = $MovieTemplate
        $n = $n.Replace('{title}', $Item.Title)
        if ($null -eq $Item.Year) {
            $n = $n -replace '\s*\(\{year\}\)\s*', ''
            $n = $n.Replace('{year}', '')
        } else {
            $n = $n.Replace('{year}', [string]$Item.Year)
        }
    }

    if ($KeepTags) {
        $orig = [System.IO.Path]::GetFileNameWithoutExtension($Item.File.Name)
        $tags = [regex]::Matches($orig, '(?i)(2160p|1080p|720p|480p|x265|x264|hevc|web-?dl|webrip|bluray|remux)')
        if ($tags.Count -gt 0) {
            $uniq = ($tags | ForEach-Object { $_.Value } | Select-Object -Unique) -join ' '
            $n = "$n [$uniq]"
        }
    }

    # cislo v zavorce uz muze byt soucasti nazvu - nepridavat ho podruhe
    $sfx = $Item.Suffix
    if ($sfx) {
        $num = $sfx.Trim(' ', '(', ')')
        if ($n -match ('[\s(]' + [regex]::Escape($num) + '\)?$')) { $sfx = '' }
    }
    return (New-SafeName ($n + $sfx)) + $Item.File.Extension.ToLowerInvariant()
}

function Get-QuickHash {
    # MD5 z prvniho a posledniho MB + delka souboru - rychle i pres SMB
    param([System.IO.FileInfo]$File)
    $chunk = 1MB
    $md5 = [System.Security.Cryptography.MD5]::Create()
    $fs = $null
    try {
        $fs = [System.IO.File]::Open($File.FullName, 'Open', 'Read', 'ReadWrite')
        $buf = New-Object byte[] $chunk
        $n = $fs.Read($buf, 0, [int][math]::Min([long]$chunk, $File.Length))
        if ($n -gt 0) { [void]$md5.TransformBlock($buf, 0, $n, $buf, 0) }
        if ($File.Length -gt (2 * $chunk)) {
            [void]$fs.Seek([long](-1 * $chunk), [System.IO.SeekOrigin]::End)
            $n2 = $fs.Read($buf, 0, $chunk)
            if ($n2 -gt 0) { [void]$md5.TransformBlock($buf, 0, $n2, $buf, 0) }
        }
        $lenBytes = [BitConverter]::GetBytes($File.Length)
        [void]$md5.TransformFinalBlock($lenBytes, 0, $lenBytes.Length)
        return ([BitConverter]::ToString($md5.Hash) -replace '-', '')
    } catch {
        return 'ERR'
    } finally {
        if ($fs) { $fs.Dispose() }
        $md5.Dispose()
    }
}

function Move-FileSafe {
    # presun odolny vuci NAS: mezi svazky kopie + overeni + smazani zdroje
    param([string]$Source, [string]$Target)

    $dir = Split-Path $Target -Parent
    if (-not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
    if ($Target.Length -gt 240) {
        throw "cilova cesta je prilis dlouha ($($Target.Length) znaku)"
    }

    $srcRoot = [System.IO.Path]::GetPathRoot($Source)
    $dstRoot = [System.IO.Path]::GetPathRoot($Target)

    if ($srcRoot -eq $dstRoot) {
        Move-Item -LiteralPath $Source -Destination $Target
        return
    }

    # jiny svazek (lokalni disk -> Synology): kopie, overit, teprve pak smazat
    $tmp = "$Target.mtpart"
    if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Force }
    Copy-Item -LiteralPath $Source -Destination $tmp
    $a = (Get-Item -LiteralPath $Source).Length
    $b = (Get-Item -LiteralPath $tmp).Length
    if ($a -ne $b) {
        Remove-Item -LiteralPath $tmp -Force
        throw "kopie nesouhlasi velikosti ($a vs $b), zdroj ponechan"
    }
    Rename-Item -LiteralPath $tmp -NewName (Split-Path $Target -Leaf)
    Remove-Item -LiteralPath $Source -Force
}

function Get-UniqueTarget {
    param([string]$Target, [System.Collections.Generic.HashSet[string]]$Taken)
    $dir  = Split-Path $Target -Parent
    $name = [System.IO.Path]::GetFileNameWithoutExtension($Target)
    $ext  = [System.IO.Path]::GetExtension($Target)
    $try  = $Target
    $i = 2
    while ($Taken.Contains($try.ToLowerInvariant()) -or (Test-Path -LiteralPath $try)) {
        $try = Join-Path $dir ("$name ($i)$ext")
        $i++
        if ($i -gt 99) { break }
    }
    [void]$Taken.Add($try.ToLowerInvariant())
    return $try
}

# ---------------------------------------------------------------------- sber

function Get-Items {
    $exts = $VideoExt
    if (-not $NoSubs) { $exts = $VideoExt + $SubExt }

    $files = New-Object System.Collections.Generic.List[System.IO.FileInfo]
    foreach ($p in $Path) {
        if (-not (Test-Path -LiteralPath $p)) {
            Write-Warning "Cesta neexistuje: $p"
            continue
        }
        $gci = @{ LiteralPath = $p; File = $true; ErrorAction = 'SilentlyContinue' }
        if ($Recurse) { $gci['Recurse'] = $true }
        foreach ($f in (Get-ChildItem @gci)) {
            if (Test-SkippedPath $f.FullName) { continue }
            if ($exts -notcontains $f.Extension.ToLowerInvariant()) { continue }
            if ($Filter -and $f.Name -notlike "*$Filter*") { continue }
            $files.Add($f)
        }
    }

    $items = New-Object System.Collections.Generic.List[object]
    foreach ($f in $files) { $items.Add((ConvertFrom-MediaName $f)) }

    # doplneni chybejicich nazvu dilu z jine varianty tehoz dilu
    $titles = @{}
    foreach ($i in $items) {
        if ($i.Kind -ne 'Serial' -or [string]::IsNullOrWhiteSpace($i.Title)) { continue }
        $k = "$($i.Show.ToLowerInvariant())|$($i.Season)|$($i.Episode)"
        if (-not $titles.ContainsKey($k) -or $titles[$k].Length -lt $i.Title.Length) {
            $titles[$k] = $i.Title
        }
    }
    foreach ($i in $items) {
        if ($i.Kind -ne 'Serial' -or -not [string]::IsNullOrWhiteSpace($i.Title)) { continue }
        $k = "$($i.Show.ToLowerInvariant())|$($i.Season)|$($i.Episode)"
        if ($titles.ContainsKey($k)) {
            $i.Title = $titles[$k]
            $i.Note  = 'nazev dilu doplnen z jine varianty'
        }
    }

    foreach ($i in $items) { $i.NewName = Format-NameTemplate $i }
    return $items
}

function Add-Duplicates {
    param([System.Collections.Generic.List[object]]$Items)

    # 1) shoda dat: stejna velikost -> rychly hash (-> volitelne plne SHA256)
    foreach ($g in ($Items | Where-Object { $_.File.Length -gt 0 } | Group-Object { $_.File.Length })) {
        if ($g.Count -lt 2) { continue }
        foreach ($i in $g.Group) {
            if (-not $i.Hash) { $i.Hash = Get-QuickHash $i.File }
        }
    }
    if ($FullHash) {
        foreach ($g in ($Items | Where-Object { $_.Hash -and $_.Hash -ne 'ERR' } | Group-Object Hash)) {
            if ($g.Count -lt 2) { continue }
            foreach ($i in $g.Group) {
                $i.Hash = (Get-FileHash -LiteralPath $i.File.FullName -Algorithm SHA256).Hash
            }
        }
    }

    $groups = New-Object System.Collections.Generic.List[object]
    $seen   = New-Object System.Collections.Generic.HashSet[string]

    foreach ($g in ($Items | Where-Object { $_.Hash -and $_.Hash -ne 'ERR' } | Group-Object Hash)) {
        if ($g.Count -lt 2) { continue }
        $keep = $g.Group |
            Sort-Object @{ E = { if ([string]::IsNullOrWhiteSpace($_.Title)) { 1 } else { 0 } } },
                        @{ E = { if ($_.Note -like 'nazev dilu doplnen*') { 1 } else { 0 } } },
                        @{ E = { $_.Copy } },
                        @{ E = { $_.File.Name.Length } } |
            Select-Object -First 1
        foreach ($i in $g.Group) {
            [void]$seen.Add($i.File.FullName)
            if ($i -ne $keep) { $i.DupOf = $keep.File.Name }
        }
        $groups.Add([pscustomobject]@{ Typ = 'shodna data'; Keep = $keep; All = $g.Group })
    }

    # 2) logicka duplicita: stejny dil serialu, ale jina data (jiny rip)
    foreach ($g in ($Items |
                    Where-Object { $_.Kind -eq 'Serial' -and -not $_.IsSub } |
                    Group-Object { "$($_.Show.ToLowerInvariant())|$($_.Season)|$($_.Episode)" })) {
        if ($g.Count -lt 2) { continue }
        $novy = @($g.Group | Where-Object { -not $seen.Contains($_.File.FullName) })
        if ($novy.Count -lt 1) { continue }
        $keep = $g.Group | Sort-Object @{ E = { $_.File.Length }; Descending = $true } | Select-Object -First 1
        foreach ($i in $g.Group) {
            if ($i -ne $keep -and -not $i.DupOf) { $i.DupOf = $keep.File.Name }
        }
        $groups.Add([pscustomobject]@{ Typ = 'stejny dil, jina data'; Keep = $keep; All = $g.Group })
    }

    return $groups
}

# ---------------------------------------------------------------------- plan

function New-Plan {
    param([System.Collections.Generic.List[object]]$Items)

    $plan  = New-Object System.Collections.Generic.List[object]
    $taken = New-Object System.Collections.Generic.HashSet[string]

    foreach ($i in $Items) {
        $src = $i.File.FullName

        # 160bajtove .mkv je stranka s chybou, ne video
        if ($i.File.Length -eq 0) {
            $plan.Add([pscustomobject]@{ Akce = 'PRESKOCIT'; Duvod = 'nulova velikost - poskozeny soubor'; Zdroj = $src; Cil = '' })
            continue
        }
        if (-not $i.IsSub -and $i.File.Length -lt ($MinVideoKB * 1KB)) {
            $plan.Add([pscustomobject]@{ Akce = 'PRESKOCIT'; Duvod = ('jen {0:N0} kB - nedokoncene stazeni?' -f ($i.File.Length / 1KB)); Zdroj = $src; Cil = '' })
            continue
        }

        if ($i.DupOf) {
            if ($Command -eq 'sort') {
                $t = Get-UniqueTarget (Join-Path (Join-Path $Library '_Duplicity') $i.File.Name) $taken
                $plan.Add([pscustomobject]@{ Akce = 'DUPLICITA'; Duvod = "kopie: $($i.DupOf)"; Zdroj = $src; Cil = $t })
            } else {
                $plan.Add([pscustomobject]@{ Akce = 'DUPLICITA'; Duvod = "kopie: $($i.DupOf)"; Zdroj = $src; Cil = '' })
            }
            continue
        }

        if ($Command -eq 'sort') {
            if ($i.Review) {
                $dir  = Join-Path $Library '_Kekontrole'
                $akce = 'KEKONTROLE'
            } else {
                $akce = 'PRESUN'
                if ($i.Kind -eq 'Serial') {
                    $dir = Join-Path (Join-Path (Join-Path $Library 'Serialy') (New-SafeName $i.Show)) ('Season {0:00}' -f $i.Season)
                } elseif ($Flat) {
                    $dir = Join-Path $Library 'Filmy'
                } else {
                    $dir = Join-Path (Join-Path $Library 'Filmy') ([System.IO.Path]::GetFileNameWithoutExtension($i.NewName))
                }
            }
            $t = Get-UniqueTarget (Join-Path $dir $i.NewName) $taken
            $plan.Add([pscustomobject]@{ Akce = $akce; Duvod = $i.Note; Zdroj = $src; Cil = $t })
            continue
        }

        # scan / rename
        if ($i.File.Name -ceq $i.NewName) {
            $plan.Add([pscustomobject]@{ Akce = 'BEZE ZMENY'; Duvod = ''; Zdroj = $src; Cil = '' })
            continue
        }
        $t = Get-UniqueTarget (Join-Path $i.File.DirectoryName $i.NewName) $taken
        $plan.Add([pscustomobject]@{ Akce = 'PREJMENOVAT'; Duvod = $i.Note; Zdroj = $src; Cil = $t })
    }

    return $plan
}

function Show-Plan {
    param([System.Collections.Generic.List[object]]$Plan)

    foreach ($g in ($Plan | Group-Object Akce | Sort-Object Name)) {
        Write-Head "$($g.Name)  ($($g.Count))"
        foreach ($p in $g.Group) {
            Write-Host "  $(Split-Path $p.Zdroj -Leaf)"
            if ($p.Cil) {
                if ($Command -eq 'sort') {
                    $to = $p.Cil.Substring([math]::Min($Library.Length + 1, $p.Cil.Length))
                } else {
                    $to = Split-Path $p.Cil -Leaf
                }
                Write-Host "    -> $to" -ForegroundColor Green
            }
            if ($p.Duvod) { Write-Host "       ($($p.Duvod))" -ForegroundColor DarkGray }
        }
    }
}

function Invoke-Plan {
    param([System.Collections.Generic.List[object]]$Plan)

    $todo = @($Plan | Where-Object { $_.Cil })
    if ($todo.Count -eq 0) {
        Write-Host "`nNeni co delat." -ForegroundColor Yellow
        return
    }

    if (-not (Test-Path -LiteralPath $LogDir)) { New-Item -ItemType Directory -Path $LogDir -Force | Out-Null }
    $log  = Join-Path $LogDir ('mediatool-{0:yyyyMMdd-HHmmss}.csv' -f (Get-Date))
    $done = New-Object System.Collections.Generic.List[object]

    $n = 0
    foreach ($p in $todo) {
        $n++
        Write-Progress -Activity 'MediaTool' -Status "$n / $($todo.Count): $(Split-Path $p.Zdroj -Leaf)" -PercentComplete (100 * $n / $todo.Count)
        try {
            Move-FileSafe -Source $p.Zdroj -Target $p.Cil
            $done.Add([pscustomobject]@{ Cas = (Get-Date).ToString('s'); Akce = $p.Akce; Zdroj = $p.Zdroj; Cil = $p.Cil })
        } catch {
            Write-Warning "$(Split-Path $p.Zdroj -Leaf): $($_.Exception.Message)"
        }
    }
    Write-Progress -Activity 'MediaTool' -Completed

    if ($done.Count -gt 0) {
        $done | Export-Csv -LiteralPath $log -NoTypeInformation -Encoding UTF8
        Write-Host "`nHotovo: $($done.Count) souboru. Log: $log" -ForegroundColor Green
        Write-Host 'Vratit zpet:  .\media-tool.ps1 undo -Apply' -ForegroundColor DarkGray
    }
}

function Invoke-Undo {
    if (-not (Test-Path -LiteralPath $LogDir)) { Write-Host 'Zadny log k vraceni.'; return }
    $log = Get-ChildItem -LiteralPath $LogDir -Filter 'mediatool-*.csv' | Sort-Object Name -Descending | Select-Object -First 1
    if (-not $log) { Write-Host 'Zadny log k vraceni.'; return }

    $rows = @(Import-Csv -LiteralPath $log.FullName)
    [array]::Reverse($rows)
    Write-Head "Vraceni davky $($log.Name) - $($rows.Count) souboru"

    foreach ($r in $rows) {
        if (-not (Test-Path -LiteralPath $r.Cil)) {
            Write-Warning "chybi (uz presunuto jinam?): $($r.Cil)"
            continue
        }
        Write-Host "  $(Split-Path $r.Cil -Leaf)"
        Write-Host "    -> $($r.Zdroj)" -ForegroundColor Green
        if ($Apply) {
            try { Move-FileSafe -Source $r.Cil -Target $r.Zdroj }
            catch { Write-Warning $_.Exception.Message }
        }
    }
    if ($Apply) {
        Rename-Item -LiteralPath $log.FullName -NewName ($log.Name + '.undone')
        Write-Host "`nVraceno." -ForegroundColor Green
    } else {
        Write-Host "`n(nahled - pro provedeni pridej -Apply)" -ForegroundColor Yellow
    }
}

# --------------------------------------------------------------------- start

# GUI si skript nacte pres dot-source s -LoadOnly: chce jen funkce, nic nespousti.
# Nastaveni si pak prepise primo do promennych z param bloku vyse.
if ($LoadOnly) { return }

Write-Host ''
Write-Host "MediaTool - $Command" -ForegroundColor White
Write-Host ('Zdroj:    ' + ($Path -join '; '))
if ($Command -eq 'sort') { Write-Host "Knihovna: $Library" }
if ($Filter) { Write-Host "Filtr:    *$Filter*" }

if ($Command -eq 'undo') { Invoke-Undo; return }

$items = Get-Items
if ($items.Count -eq 0) {
    Write-Host "`nZadne medialni soubory nenalezeny." -ForegroundColor Yellow
    return
}
Write-Host "Souboru:  $($items.Count)"

$dupGroups = Add-Duplicates $items

if ($Command -eq 'dupes') {
    if ($dupGroups.Count -eq 0) {
        Write-Host "`nZadne duplicity." -ForegroundColor Green
        return
    }
    $waste = 0
    foreach ($g in $dupGroups) {
        Write-Head $g.Typ
        foreach ($i in ($g.All | Sort-Object { $_.File.Name })) {
            if ($i -eq $g.Keep) {
                $mark = '  PONECHAT '
                $col  = 'Green'
            } else {
                $mark = '  duplicita'
                $col  = 'Yellow'
                $waste += $i.File.Length
            }
            Write-Host ('{0} {1,8:N0} MB  {2}' -f $mark, ($i.File.Length / 1MB), $i.File.Name) -ForegroundColor $col
        }
    }
    Write-Host ("`nZbytecne zabrano: {0:N2} GB" -f ($waste / 1GB)) -ForegroundColor Magenta
    Write-Host 'Presun duplicit do knihovny\_Duplicity:  .\media-tool.ps1 sort -Library <cesta> -Apply' -ForegroundColor DarkGray
    return
}

$plan = New-Plan $items
Show-Plan $plan

$stats = $plan | Group-Object Akce | ForEach-Object { "$($_.Name)=$($_.Count)" }
Write-Host ''
Write-Host ('Souhrn: ' + ($stats -join ', ')) -ForegroundColor White

if ($Command -eq 'scan') {
    if (-not (Test-Path -LiteralPath $LogDir)) { New-Item -ItemType Directory -Path $LogDir -Force | Out-Null }
    $rep = Join-Path $LogDir ('scan-{0:yyyyMMdd-HHmmss}.csv' -f (Get-Date))
    $plan | Export-Csv -LiteralPath $rep -NoTypeInformation -Encoding UTF8
    Write-Host "Report: $rep" -ForegroundColor DarkGray
    Write-Host 'Dalsi krok:  .\media-tool.ps1 rename   nebo   .\media-tool.ps1 sort -Library <cesta>' -ForegroundColor DarkGray
    return
}

if ($Apply) {
    Invoke-Plan $plan
} else {
    Write-Host "`n(nahled - nic se nezmenilo. Pro provedeni pridej -Apply)" -ForegroundColor Yellow
}
