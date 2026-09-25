<#
.SYNOPSIS
    Testy jadra MediaToolu. Bez zavislosti - bezi ve Windows PowerShellu 5.1 i v pwsh 7.
.EXAMPLE
    .\tests\Test-MediaTool.ps1
#>
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
. (Join-Path $root 'media-tool.ps1') -LoadOnly 6>$null

$script:ok = 0; $script:fail = 0
function Assert-Eq($ocekavano, $skutecne, [string]$popis) {
    if ("$ocekavano" -ceq "$skutecne") { $script:ok++; Write-Host "  OK    $popis" -ForegroundColor Green }
    else { $script:fail++; Write-Host "  CHYBA $popis`n        ocekavano: $ocekavano`n        skutecne:  $skutecne" -ForegroundColor Red }
}
function New-TestDir { $d = Join-Path ([IO.Path]::GetTempPath()) ('mt-test-' + [guid]::NewGuid().ToString('N')); New-Item -ItemType Directory $d | Out-Null; $d }
function New-File([string]$Path, [int]$Bytes = 153600, [int]$Seed = 0) {
    New-Item -ItemType Directory -Force (Split-Path $Path -Parent) | Out-Null
    $b = New-Object byte[] $Bytes
    $rnd = if ($Seed) { New-Object Random $Seed } else { New-Object Random }
    $rnd.NextBytes($b); [IO.File]::WriteAllBytes($Path, $b)
}
function Get-NewName([string]$dir, [string]$name) {
    $p = Join-Path $dir $name; if (-not (Test-Path -LiteralPath $p)) { New-File $p 10 }
    Format-NameTemplate (ConvertFrom-MediaName ([IO.FileInfo]$p))
}

Write-Host "`n== Nazvy filmu a serialu"
$d = New-TestDir
@{
  'Mad Max Fury Road 2015 1080p BluRay x264.mkv'           = 'Mad Max Fury Road (2015).mkv'
  'Max 2015 BRRip.mkv'                                     = 'Max (2015).mkv'
  'Ray 2004 1080p BluRay x264 CZ.mkv'                      = 'Ray (2004).mkv'
  'Sub Zero 2005 DVDRip.mkv'                               = 'Sub Zero (2005).mkv'
  'The Limited 2019 WEB-DL.mkv'                            = 'The Limited (2019).mkv'
  'Charlottes Web 2006 1080p.mkv'                          = 'Charlottes Web (2006).mkv'
  'The.Martian.Extended.Cut.2015.1080p.Blu-ray.x265.DTS-DDR.mkv' = 'The Martian Extended Cut (2015).mkv'
  'Collateral.2004.1080p.BluRay.H264.DD.5.1.CZ.mkv'        = 'Collateral (2004).mkv'
  'Orel Eddie _ Eddie the Eagle (2016) Kom CZ 1920x800p.avi' = 'Orel Eddie Eddie the Eagle (2016).avi'
  'Dual Survival S01E01 Alaska 720p.mkv'                   = 'Dual Survival - S01E01 - Alaska.mkv'
  'Californication.S05E05.HDTV.XviD.CZ-dabing.avi'         = 'Californication - S05E05.avi'
  'cali.s6x01.unforgiven.cz.avi'                           = 'Californication - S06E01 - unforgiven.avi'
  'Game.of.Thrones.S03E09.The.Rains.of.Castamere.1080p.CZ.mkv' = 'Game of Thrones - S03E09 - The Rains of Castamere.mkv'
}.GetEnumerator() | Sort-Object Name | ForEach-Object { Assert-Eq $_.Value (Get-NewName $d $_.Name) $_.Name }

Write-Host "`n== Titulky si drzi jazyk"
Assert-Eq 'Collateral (2004).cs.srt' (Get-NewName $d 'Collateral.2004.1080p.BluRay.CZ.cz.srt') '.cz.srt -> .cs.srt'
Assert-Eq 'Collateral (2004).en.srt' (Get-NewName $d 'Collateral.2004.1080p.BluRay.CZ.en.srt') '.en.srt -> .en.srt'
Assert-Eq 'Collateral (2004).srt'    (Get-NewName $d 'Collateral.2004.1080p.srt')              'bez jazyka beze zmeny'
Remove-Item -Recurse -Force $d

Write-Host "`n== Ruzne jazykove verze tehoz dilu nejsou duplicity"
$d = New-TestDir
New-File "$d/Californication.S05E05.HDTV.XviD.CZ-dabing.avi"
New-File "$d/Californication.S05E05.720p.WEB-DL.mkv" 204800
New-File "$d/Californication.S05E06.HDTV.XviD.avi"
New-File "$d/Californication.S05E06.720p.WEB-DL.mkv" 204800
$Path = @($d); $Recurse = $false; $Filter = $null; $NoSubs = $true
$items = Get-Items; [void](Add-Duplicates $items)
$cz = $items | Where-Object { $_.File.Name -like '*S05E05*CZ-dabing*' }
$e6 = $items | Where-Object { $_.File.Name -like '*S05E06.HDTV*' }
Assert-Eq '' $cz.DupOf 'cesky dabing neni duplicita anglicke verze'
Assert-Eq 'Californication.S05E06.720p.WEB-DL.mkv' $e6.DupOf 'dve verze bez jazykove znacky dal duplicita jsou'
Remove-Item -Recurse -Force $d

Write-Host "`n== Log se zapisuje po kazdem presunu (pad uprostred davky)"
$d = New-TestDir
1..4 | ForEach-Object { New-File "$d/src/f$_.mkv" }
$rows = 1..4 | ForEach-Object { [pscustomobject]@{ Akce = 'PRESUN'; Zdroj = "$d/src/f$_.mkv"; Cil = "$d/dst/f$_.mkv" } }
$log = "$d/logs/mediatool-test.csv"
try {
    Invoke-MoveBatch -Rows $rows -LogPath $log -OnProgress { param($n) if ($n -eq 2) { throw 'simulovany pad' } } | Out-Null
} catch { }
Assert-Eq 2 (@(Get-ChildItem "$d/dst").Count) 'pred padem se presunuly 2 soubory'
$radkuLogu = if (Test-Path $log) { @(Import-Csv $log).Count } else { 0 }
Assert-Eq 2 $radkuLogu 'log obsahuje prave tyto 2 presuny'
Remove-Item -Recurse -Force $d

Write-Host "`n== Chyba zapisu logu zastavi dalsi presuny"
$d = New-TestDir
1..2 | ForEach-Object { New-File "$d/src/f$_.mkv" }
$rows = 1..2 | ForEach-Object { [pscustomobject]@{ Akce = 'PRESUN'; Zdroj = "$d/src/f$_.mkv"; Cil = "$d/dst/f$_.mkv" } }
$log = "$d/logs/mediatool-failed.csv"
function Export-Csv { throw 'simulovana chyba zapisu logu' }
try { $res = Invoke-MoveBatch -Rows $rows -LogPath $log }
finally { Remove-Item Function:\Export-Csv }
Assert-Eq $true (Test-Path "$d/dst/f1.mkv") 'prvni presun probehl'
Assert-Eq $true (Test-Path "$d/src/f2.mkv") 'druhy presun se po chybe logu neprovede'
Assert-Eq 1 $res.Errors.Count 'chyba zapisu se ohlasi'
Assert-Eq $true ($res.Errors[0] -like '*ZAPIS LOGU SELHAL*') 'chyba upozorni na presun bez spolehliveho logu'
Remove-Item -Recurse -Force $d

Write-Host "`n== Castecne vraceni neoznaci davku za hotovou"
$d = New-TestDir
1..3 | ForEach-Object { New-File "$d/src/f$_.mkv" }
$rows = 1..3 | ForEach-Object { [pscustomobject]@{ Akce = 'PRESUN'; Zdroj = "$d/src/f$_.mkv"; Cil = "$d/dst/f$_.mkv" } }
$log = "$d/logs/mediatool-20990101-000000.csv"
Invoke-MoveBatch -Rows $rows -LogPath $log | Out-Null
'cizi soubor' | Set-Content "$d/src/f2.mkv"
$res = Invoke-UndoBatch -Log (Get-Item $log)
Assert-Eq 1 $res.Remaining 'jeden soubor se vratit nepodaril'
Assert-Eq $true (Test-Path $log) 'log NENI oznaceny .undone'
Assert-Eq "$d/dst/f2.mkv" (@(Import-Csv $log)[0].Cil) 'v logu zustal prave neuspesny soubor'
Remove-Item "$d/src/f2.mkv"
$res = Invoke-UndoBatch -Log (Get-Item $log)
Assert-Eq 0 $res.Remaining 'po odstraneni prekazky se vrati i zbytek'
Assert-Eq $true (Test-Path "$log.undone") 'teprve ted je davka .undone'
Assert-Eq 3 (@(Get-ChildItem "$d/src").Count) 'vsechny tri soubory jsou zpet'
Remove-Item -Recurse -Force $d

Write-Host "`n== Zmizely cil a cizi soubor na puvodni ceste"
$d = New-TestDir
New-File "$d/src/original.mkv" 300000 41
$row = [pscustomobject]@{ Akce = 'PRESUN'; Zdroj = "$d/src/original.mkv"; Cil = "$d/dst/original.mkv" }
$log = "$d/logs/mediatool-20990101-000001.csv"
Invoke-MoveBatch -Rows @($row) -LogPath $log | Out-Null
Move-Item "$d/dst/original.mkv" "$d/mimo.mkv"
New-File "$d/src/original.mkv" 300000 42
$foreignHash = (Get-FileHash "$d/src/original.mkv" -Algorithm SHA256).Hash
$res = Invoke-UndoBatch -Log (Get-Item $log)
Assert-Eq 1 $res.Remaining 'zmizely cil drzi davku otevrenou i kdyz zdrojova cesta existuje'
Assert-Eq $true (Test-Path $log) 'log neni oznacen .undone'
Assert-Eq $foreignHash (Get-FileHash "$d/src/original.mkv" -Algorithm SHA256).Hash 'cizi soubor zustal nedotcen'
Remove-Item -Recurse -Force $d

Write-Host "`n== Presun na jiny svazek overuje obsah"
$d = New-TestDir
$originalSameVolume = (Get-Command Test-SameVolume).ScriptBlock
function Test-SameVolume { $false }                       # vynuti cestu kopie + overeni
New-File "$d/a.mkv" 300000 7
Move-FileSafe -Source "$d/a.mkv" -Target "$d/cil/a.mkv"
Assert-Eq $false (Test-Path "$d/a.mkv") 'po overene kopii je zdroj smazany'
New-File "$d/b.mkv" 300000 8
$puvodni = (Get-FileHash "$d/b.mkv").Hash
function Copy-Item { param($LiteralPath, $Destination)       # kopie se poskodi uprostred
    Microsoft.PowerShell.Management\Copy-Item -LiteralPath $LiteralPath -Destination $Destination
    $fs = [IO.File]::Open($Destination, 'Open', 'ReadWrite'); $fs.Position = 150000; $fs.WriteByte(0x5A); $fs.Close() }
$chyba = $null; try { Move-FileSafe -Source "$d/b.mkv" -Target "$d/cil/b.mkv" } catch { $chyba = $_.Exception.Message }
Assert-Eq $true ($chyba -like '*SHA-256*') 'poskozena kopie se stejnou delkou je odhalena'
Assert-Eq $puvodni (Get-FileHash "$d/b.mkv").Hash 'zdroj zustal nedotceny'
Assert-Eq $false (Test-Path "$d/cil/b.mkv") 'poskozena kopie v cili nezustala'
New-File "$d/stale.mkv" 300000 9
New-File "$d/cil/stale.mkv.mtpart" 20 10
$staleHash = (Get-FileHash "$d/cil/stale.mkv.mtpart" -Algorithm SHA256).Hash
$chyba = $null; try { Move-FileSafe -Source "$d/stale.mkv" -Target "$d/cil/stale.mkv" } catch { $chyba = $_.Exception.Message }
Assert-Eq $true ($chyba -like '*docasna kopie uz existuje*') 'stara .mtpart zastavi presun'
Assert-Eq $staleHash (Get-FileHash "$d/cil/stale.mkv.mtpart" -Algorithm SHA256).Hash 'stara .mtpart zustane nedotcena'
Assert-Eq $true (Test-Path "$d/stale.mkv") 'zdroj zustane pri kolizi .mtpart'
Remove-Item Function:\Copy-Item
Set-Item Function:\Test-SameVolume $originalSameVolume
Remove-Item -Recurse -Force $d

Write-Host "`n== Skutecny mount point pres stejny koren cesty"
if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT -and
    (Test-Path -LiteralPath /dev/shm) -and
    -not (Test-SameVolume /tmp/mediatool-source.mkv /dev/shm/mediatool-target.mkv)) {
    $d = New-TestDir
    $other = Join-Path /dev/shm ('mt-test-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory $other | Out-Null
    try {
        New-File "$d/source.mkv" 300000 29
        $hash = (Get-FileHash "$d/source.mkv" -Algorithm SHA256).Hash
        $script:copyDestination = ''
        function Copy-Item { param($LiteralPath, $Destination)
            $script:copyDestination = $Destination
            Microsoft.PowerShell.Management\Copy-Item -LiteralPath $LiteralPath -Destination $Destination
        }
        Move-FileSafe -Source "$d/source.mkv" -Target "$other/target.mkv"
        Assert-Eq $true ($script:copyDestination -like '*.mtpart') 'pres mount point se pouzila docasna kopie'
        Assert-Eq $hash (Get-FileHash "$other/target.mkv" -Algorithm SHA256).Hash 'cil za mount pointem je shodny'
        Assert-Eq $false (Test-Path "$d/source.mkv") 'zdroj zmizel az po overeni'
    } finally {
        Remove-Item Function:\Copy-Item -ErrorAction SilentlyContinue
        Remove-Item -Recurse -Force $d, $other
    }
}

Write-Host "`n== Zmena jen velikosti pismen bez (2)"
if ([Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT) {
    $d = New-TestDir
    try {
        $source = Join-Path $d 'Film (2015).MKV'
        $target = Join-Path $d 'Film (2015).mkv'
        New-File $source 300000 31
        $taken = New-Object System.Collections.Generic.HashSet[string]
        $planned = Get-UniqueTarget $target $taken $source
        Assert-Eq $target $planned 'plan ponecha pozadovane jmeno bez (2)'
        Move-FileSafe -Source $source -Target $planned
        $name = (Get-ChildItem -LiteralPath $d -File | Select-Object -First 1).Name
        Assert-Eq 'Film (2015).mkv' $name 'prejmenovani opravdu zmenilo velikost pismen'
    } finally {
        Remove-Item -Recurse -Force $d
    }
}

Write-Host "`n== Kontrola pred smazanim duplicity"
$d = New-TestDir
New-File "$d/keep.mkv" 3MB 11; Copy-Item "$d/keep.mkv" "$d/dup.mkv"
Assert-Eq '' "$(Test-DuplicateDeletable "$d/dup.mkv" "$d/keep.mkv" 'shodna data')" 'shodna kopie smazat lze'
$fs = [IO.File]::Open("$d/dup.mkv", 'Open', 'ReadWrite'); $fs.Position = 1500000; $fs.WriteByte(0x00); $fs.Close()
Assert-Eq (Get-QuickHash (Get-Item "$d/keep.mkv")) (Get-QuickHash (Get-Item "$d/dup.mkv")) 'rychly otisk rozdil uprostred neodhali'
Assert-Eq $true ((Test-DuplicateDeletable "$d/dup.mkv" "$d/keep.mkv" 'shodna data') -like '*jiny obsah*') 'uplne porovnani ho odhali a smazani zastavi'
Remove-Item "$d/keep.mkv"
Assert-Eq $true ((Test-DuplicateDeletable "$d/dup.mkv" "$d/keep.mkv" 'stejny dil, jina data') -like '*chybi*') 'chybejici ponechana kopie zastavi smazani'
Assert-Eq $true ((Test-DuplicateDeletable "$d/dup.mkv" '' 'shodna data') -like '*neni znama*') 'bez udaje o ponechane kopii se nemaze'
Remove-Item -Recurse -Force $d

Write-Host ""
$barva = if ($script:fail) { 'Red' } else { 'Green' }
Write-Host ("Vysledek: {0} v poradku, {1} chyb" -f $script:ok, $script:fail) -ForegroundColor $barva
exit $script:fail
