# Durable intent files make a moved file discoverable even when CSV persistence fails.
# This file is loaded by media-tool.ps1 after Move-FileSafe is defined.

function Get-BatchRows {
    param([string]$LogPath)
    if (-not [IO.File]::Exists($LogPath)) { return }
    Import-Csv -LiteralPath $LogPath
}

function Save-BatchRows {
    param([string]$LogPath, [object[]]$Rows)
    $tmp = "$LogPath.$([guid]::NewGuid().ToString('N')).tmp"
    try {
        if ($Rows.Count -eq 0) {
            [IO.File]::WriteAllText($tmp, '"Cas","Akce","Zdroj","Cil","Hash"' + [Environment]::NewLine,
                [Text.UTF8Encoding]::new($false))
        } else {
            $Rows | Export-Csv -LiteralPath $tmp -NoTypeInformation -Encoding UTF8
        }
        $stream = [IO.File]::Open($tmp, [IO.FileMode]::Open, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
        try { $stream.Flush($true) } finally { $stream.Dispose() }
        if ([IO.File]::Exists($LogPath)) {
            $backup = "$LogPath.$([guid]::NewGuid().ToString('N')).bak"
            [IO.File]::Replace($tmp, $LogPath, $backup)
            if ([IO.File]::Exists($backup)) { [IO.File]::Delete($backup) }
        } else { [IO.File]::Move($tmp, $LogPath) }
    } finally {
        if ([IO.File]::Exists($tmp)) { [IO.File]::Delete($tmp) }
    }
}

function Write-PendingRecord {
    param([string]$Path, [object]$Record)
    $bytes = [Text.UTF8Encoding]::new($false).GetBytes(($Record | ConvertTo-Json -Compress -Depth 5))
    $stream = [IO.FileStream]::new($Path, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write,
        [IO.FileShare]::None, 4096, [IO.FileOptions]::WriteThrough)
    try {
        $stream.Write($bytes, 0, $bytes.Length)
        $stream.Flush($true)
    } finally { $stream.Dispose() }
}

function Read-PendingRecord {
    param([string]$Path)
    $record = Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($record.Version -ne 1 -or [string]::IsNullOrWhiteSpace($record.Hash) -or
        [string]::IsNullOrWhiteSpace($record.Source) -or [string]::IsNullOrWhiteSpace($record.Target) -or
        $record.Hash -notmatch '^[0-9A-Fa-f]{64}$') {
        throw "Neplatný záznam rozpracované operace: $Path"
    }
    return $record
}

function Test-RecordedHash {
    param([string]$Path, [string]$Hash)
    if (-not [IO.File]::Exists($Path)) { return $false }
    return ((Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash -eq $Hash)
}

function Remove-RecordedTemporaryCopy {
    param([object]$Record, [string]$PublishedPath)
    if ([string]::IsNullOrWhiteSpace($Record.TempPath)) { return }
    $expected = '^' + [regex]::Escape($PublishedPath) + '\.[0-9a-fA-F]{32}\.mtpart$'
    if ($Record.TempPath -cnotmatch $expected) {
        throw "Záměr obsahuje neplatnou cestu dočasné kopie: $($Record.TempPath)"
    }
    if ([IO.File]::Exists($Record.TempPath)) { [IO.File]::Delete($Record.TempPath) }
}

function Get-MoveState {
    param([string]$Source, [string]$Target)
    $sourceExists = [IO.File]::Exists($Source)
    $targetExists = [IO.File]::Exists($Target)
    if (Test-CaseOnlyRename $Source $Target) {
        $actual = @([IO.Directory]::EnumerateFiles((Split-Path $Target -Parent)) |
            ForEach-Object { [IO.Path]::GetFileName($_) })
        $targetExists = @($actual | Where-Object { $_ -ceq (Split-Path $Target -Leaf) }).Count -gt 0
        $sourceExists = @($actual | Where-Object { $_ -ceq (Split-Path $Source -Leaf) }).Count -gt 0
    }
    return [pscustomobject]@{ Source = $sourceExists; Target = $targetExists }
}

function Remove-BatchRow {
    param([object[]]$Rows, [string]$Source, [string]$Target, [string]$Hash)
    $index = -1
    for ($i = $Rows.Count - 1; $i -ge 0; $i--) {
        if ($Rows[$i].Zdroj -ceq $Source -and $Rows[$i].Cil -ceq $Target -and
            $Rows[$i].Hash -eq $Hash) { $index = $i; break }
    }
    if ($index -lt 0) { throw "Položka chybí v logu: $Source -> $Target" }
    $result = New-Object System.Collections.Generic.List[object]
    for ($i = 0; $i -lt $Rows.Count; $i++) { if ($i -ne $index) { $result.Add($Rows[$i]) } }
    return $result.ToArray()
}

function Resolve-PendingMove {
    param([string]$PendingPath)
    $record = Read-PendingRecord $PendingPath
    if ($null -eq $record.Row -or $record.Row.Zdroj -cne $record.Source -or
        $record.Row.Cil -cne $record.Target -or $record.Row.Hash -ne $record.Hash) {
        throw "Záměr přesunu má neúplný nebo rozporný řádek: $PendingPath"
    }
    $logPath = $PendingPath.Substring(0, $PendingPath.Length - '.intent.json'.Length)
    $rows = @(Get-BatchRows $logPath)
    $matchingPath = @($rows | Where-Object { $_.Zdroj -ceq $record.Source -and $_.Cil -ceq $record.Target })
    if (@($matchingPath | Where-Object { $_.Hash -ne $record.Hash }).Count -gt 0) {
        throw "Log obsahuje pro stejne cesty jiny SHA-256: $logPath"
    }
    $logged = $matchingPath.Count -gt 0
    $state = Get-MoveState $record.Source $record.Target
    if ($state.Target -and -not $state.Source -and (Test-RecordedHash $record.Target $record.Hash)) {
        Remove-RecordedTemporaryCopy $record $record.Target
        if (-not $logged) { Save-BatchRows $logPath @($rows + $record.Row) }
        [IO.File]::Delete($PendingPath)
        return
    }
    if ($state.Source -and -not $state.Target -and -not $logged -and
        (Test-RecordedHash $record.Source $record.Hash)) {
        Remove-RecordedTemporaryCopy $record $record.Target
        [IO.File]::Delete($PendingPath)
        return
    }
    throw "Nejednoznačný přesun; obě cesty ponechány k ruční kontrole: $($record.Source) -> $($record.Target)"
}

function Resolve-PendingUndo {
    param([string]$PendingPath)
    $record = Read-PendingRecord $PendingPath
    $logPath = $PendingPath.Substring(0, $PendingPath.Length - '.undo.json'.Length)
    $rows = @(Get-BatchRows $logPath)
    $matchingPath = @($rows | Where-Object { $_.Zdroj -ceq $record.Source -and $_.Cil -ceq $record.Target })
    if (@($matchingPath | Where-Object { $_.Hash -ne $record.Hash }).Count -gt 0) {
        throw "Log obsahuje pro stejne cesty jiny SHA-256: $logPath"
    }
    $logged = $matchingPath.Count -gt 0
    $state = Get-MoveState $record.Source $record.Target
    if ($state.Source -and -not $state.Target -and (Test-RecordedHash $record.Source $record.Hash)) {
        Remove-RecordedTemporaryCopy $record $record.Source
        if ($logged) { Save-BatchRows $logPath @(Remove-BatchRow $rows $record.Source $record.Target $record.Hash) }
        [IO.File]::Delete($PendingPath)
        return
    }
    if ($state.Target -and -not $state.Source -and $logged -and
        (Test-RecordedHash $record.Target $record.Hash)) {
        Remove-RecordedTemporaryCopy $record $record.Source
        [IO.File]::Delete($PendingPath)
        return
    }
    throw "Nejednoznačné vrácení; obě cesty ponechány k ruční kontrole: $($record.Target) -> $($record.Source)"
}

function Resolve-PendingDelete {
    param([string]$PendingPath)
    $record = Read-PendingRecord $PendingPath
    if ($null -eq $record.Row -or $record.Row.Zdroj -cne $record.Source -or
        $record.Row.Ponechat -cne $record.Target -or $record.Row.Hash -ne $record.Hash) {
        throw "Záměr mazání má neúplný nebo rozporný řádek: $PendingPath"
    }
    $logPath = $PendingPath.Substring(0, $PendingPath.Length - '.delete.json'.Length)
    $rows = @(Get-BatchRows $logPath)
    $logged = @($rows | Where-Object { $_.Zdroj -ceq $record.Source -and $_.Hash -eq $record.Hash }).Count -gt 0
    if (-not (Test-RecordedHash $record.Target $record.Hash)) {
        throw "Ponechaná kopie chybí nebo se změnila; mazání vyžaduje kontrolu: $($record.Source)"
    }
    if (-not [IO.File]::Exists($record.Source)) {
        if (-not $logged) { Save-BatchRows $logPath @($rows + $record.Row) }
        [IO.File]::Delete($PendingPath)
        return
    }
    if (-not $logged -and (Test-RecordedHash $record.Source $record.Hash)) {
        [IO.File]::Delete($PendingPath)
        return
    }
    throw "Nejednoznačný stav mazání; soubory ponechány k ruční kontrole: $($record.Source)"
}

function Enter-MediaToolLock {
    param([string]$LogDir)
    if (-not (Test-Path -LiteralPath $LogDir)) {
        New-Item -ItemType Directory -Path $LogDir -Force | Out-Null
    }
    return [IO.FileStream]::new((Join-Path $LogDir '.mediatool-operations.lock'),
        [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
}

function Resolve-PendingJournalsCore {
    param([string]$LogDir)
    if (-not (Test-Path -LiteralPath $LogDir)) { return }
    foreach ($pending in (Get-ChildItem -LiteralPath $LogDir -File -Filter 'mediatool-*.csv.intent.json' | Sort-Object Name)) {
        Resolve-PendingMove $pending.FullName
    }
    foreach ($pending in (Get-ChildItem -LiteralPath $LogDir -File -Filter 'mediatool-*.csv.undo.json' | Sort-Object Name)) {
        Resolve-PendingUndo $pending.FullName
    }
    foreach ($pending in (Get-ChildItem -LiteralPath $LogDir -File -Filter 'smazano-*.csv.delete.json' | Sort-Object Name)) {
        Resolve-PendingDelete $pending.FullName
    }
}

function Resolve-PendingJournals {
    param([string]$LogDir)
    $operationLock = Enter-MediaToolLock $LogDir
    try { Resolve-PendingJournalsCore $LogDir }
    finally { $operationLock.Dispose() }
}

function Invoke-MoveBatch {
    param([object[]]$Rows, [string]$LogPath, [scriptblock]$OnProgress)
    $done = New-Object System.Collections.Generic.List[object]
    $errors = New-Object System.Collections.Generic.List[string]
    $logDir = Split-Path $LogPath -Parent
    if (-not (Test-Path -LiteralPath $logDir)) { New-Item -ItemType Directory -Path $logDir -Force | Out-Null }
    $operationLock = Enter-MediaToolLock $logDir
    try {
    try { Resolve-PendingJournalsCore $logDir }
    catch {
        $errors.Add("Nejprve vyřeš rozpracovanou dávku: $($_.Exception.Message)")
        return [pscustomobject]@{ Done = $done; Errors = $errors }
    }
    $n = 0
    foreach ($r in $Rows) {
        $n++
        $pending = "$LogPath.intent.json"
        try {
            if (-not [IO.File]::Exists($r.Zdroj)) { throw "Zdroj chybí: $($r.Zdroj)" }
            if ([IO.File]::Exists($r.Cil) -and -not (Test-CaseOnlyRename $r.Zdroj $r.Cil)) {
                throw "Cíl už existuje: $($r.Cil)"
            }
            $hash = (Get-FileHash -LiteralPath $r.Zdroj -Algorithm SHA256).Hash
            $tempPath = "$($r.Cil).$([guid]::NewGuid().ToString('N')).mtpart"
            $row = [pscustomobject]@{
                Cas = (Get-Date).ToString('o'); Akce = $r.Akce; Zdroj = $r.Zdroj; Cil = $r.Cil; Hash = $hash
            }
            Write-PendingRecord $pending ([pscustomobject]@{
                Version = 1; Source = $r.Zdroj; Target = $r.Cil; Hash = $hash; Row = $row
                TempPath = $tempPath
            })
            Move-FileSafe -Source $r.Zdroj -Target $r.Cil -TempPath $tempPath
            $state = Get-MoveState $r.Zdroj $r.Cil
            if (-not $state.Target -or $state.Source -or -not (Test-RecordedHash $r.Cil $hash)) {
                throw "Přesun skončil nejednoznačně; záznam záměru zůstává: $pending"
            }
            $done.Add($row)
            $existing = @(Get-BatchRows $LogPath)
            Save-BatchRows $LogPath @($existing + $row)
            [IO.File]::Delete($pending)
        } catch {
            $errors.Add("$($r.Zdroj) -> $($r.Cil): $($_.Exception.Message); zkontroluj také $pending")
            break
        }
        if ($OnProgress) { & $OnProgress $n $Rows.Count $r }
    }
    return [pscustomobject]@{ Done = $done; Errors = $errors }
    } finally { $operationLock.Dispose() }
}

function Invoke-UndoBatch {
    param([System.IO.FileInfo]$Log, [scriptblock]$OnProgress)
    $errors = New-Object System.Collections.Generic.List[string]
    $ok = 0
    $operationLock = Enter-MediaToolLock $Log.DirectoryName
    try {
    try { Resolve-PendingJournalsCore $Log.DirectoryName }
    catch {
        $errors.Add("Nejdříve vyřeš rozpracovanou dávku: $($_.Exception.Message)")
        return [pscustomobject]@{ Restored = 0; Errors = $errors; Remaining = @(Get-BatchRows $Log.FullName).Count }
    }
    $latest = Get-ChildItem -LiteralPath $Log.DirectoryName -File -Filter 'mediatool-*.csv' |
        Sort-Object Name -Descending | Select-Object -First 1
    if ($latest -and $latest.FullName -cne $Log.FullName) {
        throw "Mezitím vznikla novější dávka; znovu vyber poslední log: $($latest.FullName)"
    }
    $active = @(Get-BatchRows $Log.FullName)
    if ($active.Count -eq 0) {
        Rename-Item -LiteralPath $Log.FullName -NewName ($Log.Name + '.undone')
        return [pscustomobject]@{ Restored = 0; Errors = $errors; Remaining = 0 }
    }
    $rows = @($active)
    [array]::Reverse($rows)
    $n = 0
    foreach ($r in $rows) {
        $n++
        if ([string]::IsNullOrWhiteSpace($r.Hash) -or $r.Hash -notmatch '^[0-9A-Fa-f]{64}$') {
            $errors.Add("Historický log nemá SHA-256; vrácení vyžaduje ruční ověření: $($r.Cil)")
            break
        }
        $pending = "$($Log.FullName).undo.json"
        $hadPending = $false
        try {
            $state = Get-MoveState $r.Zdroj $r.Cil
            if ($state.Source -or -not $state.Target -or -not (Test-RecordedHash $r.Cil $r.Hash)) {
                throw "Zdroj je obsazený, cíl chybí nebo neodpovídá původnímu SHA-256"
            }
            $tempPath = "$($r.Zdroj).$([guid]::NewGuid().ToString('N')).mtpart"
            Write-PendingRecord $pending ([pscustomobject]@{
                Version = 1; Source = $r.Zdroj; Target = $r.Cil; Hash = $r.Hash
                TempPath = $tempPath
            })
            $hadPending = $true
            Move-FileSafe -Source $r.Cil -Target $r.Zdroj -TempPath $tempPath
            $state = Get-MoveState $r.Zdroj $r.Cil
            if (-not $state.Source -or $state.Target -or -not (Test-RecordedHash $r.Zdroj $r.Hash)) {
                throw "Vrácení skončilo nejednoznačně; záznam záměru zůstává: $pending"
            }
            $remaining = @(Remove-BatchRow $active $r.Zdroj $r.Cil $r.Hash)
            Save-BatchRows $Log.FullName $remaining
            $active = $remaining
            [IO.File]::Delete($pending)
            $ok++
        } catch {
            $errors.Add("$($r.Cil) -> $($r.Zdroj): $($_.Exception.Message)")
            if ($hadPending -or [IO.File]::Exists($pending)) { break }
        }
        if ($OnProgress) { & $OnProgress $n $rows.Count $r }
    }
    if ($active.Count -eq 0 -and $errors.Count -eq 0) {
        Rename-Item -LiteralPath $Log.FullName -NewName ($Log.Name + '.undone')
    }
    return [pscustomobject]@{ Restored = $ok; Errors = $errors; Remaining = $active.Count }
    } finally { $operationLock.Dispose() }
}
