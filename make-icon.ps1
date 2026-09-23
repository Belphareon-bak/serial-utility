#Requires -Version 5.1
<#
.SYNOPSIS
    Vygeneruje mediatool.ico - modrá složka s přehrávacím trojúhelníkem.

.DESCRIPTION
    Nakreslí ikonu ve velikosti 256x256, zmenší na běžné velikosti a poskládá
    z nich .ico (každá velikost uložená jako PNG - Windows Vista a novější to umí).
    Pouštěj jen když chceš ikonu překreslit; jinak stačí hotový mediatool.ico.
#>
param([string]$Vystup = (Join-Path $PSScriptRoot 'mediatool.ico'))

Add-Type -AssemblyName System.Drawing

function New-RoundedPath {
    param([single]$X, [single]$Y, [single]$W, [single]$H, [single]$R)
    $p = New-Object System.Drawing.Drawing2D.GraphicsPath
    $d = $R * 2
    $p.AddArc($X, $Y, $d, $d, 180, 90)
    $p.AddArc(($X + $W - $d), $Y, $d, $d, 270, 90)
    $p.AddArc(($X + $W - $d), ($Y + $H - $d), $d, $d, 0, 90)
    $p.AddArc($X, ($Y + $H - $d), $d, $d, 90, 90)
    $p.CloseFigure()
    return $p
}

function New-IconBitmap {
    param([int]$S)

    $bmp = New-Object System.Drawing.Bitmap($S, $S, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.SmoothingMode     = 'AntiAlias'
    $g.InterpolationMode = 'HighQualityBicubic'
    $g.Clear([System.Drawing.Color]::Transparent)

    $k = $S / 256.0   # měřítko, kreslí se v souřadnicích 256x256

    # pozadí: zaoblený čtverec s modrým přechodem (VS Code blue)
    $pozadi = New-RoundedPath (8 * $k) (8 * $k) (240 * $k) (240 * $k) (48 * $k)
    $stetec = New-Object System.Drawing.Drawing2D.LinearGradientBrush(
        (New-Object System.Drawing.Point(0, 0)),
        (New-Object System.Drawing.Point($S, $S)),
        [System.Drawing.Color]::FromArgb(0x11, 0x77, 0xBB),
        [System.Drawing.Color]::FromArgb(0x0A, 0x4A, 0x78))
    $g.FillPath($stetec, $pozadi)
    $stetec.Dispose(); $pozadi.Dispose()

    # složka: záložka + tělo
    $bily = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(0xF5, 0xF9, 0xFC))
    $zalozka = New-RoundedPath (52 * $k) (74 * $k) (70 * $k) (26 * $k) (8 * $k)
    $g.FillPath($bily, $zalozka)
    $zalozka.Dispose()
    $telo = New-RoundedPath (52 * $k) (90 * $k) (152 * $k) (96 * $k) (14 * $k)
    $g.FillPath($bily, $telo)
    $telo.Dispose()
    $bily.Dispose()

    # přehrávací trojúhelník ve složce
    $modry = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(0x0E, 0x63, 0x9C))
    $body = @(
        (New-Object System.Drawing.PointF((112 * $k), (112 * $k))),
        (New-Object System.Drawing.PointF((160 * $k), (138 * $k))),
        (New-Object System.Drawing.PointF((112 * $k), (164 * $k)))
    )
    $g.FillPolygon($modry, $body)
    $modry.Dispose()

    $g.Dispose()
    return $bmp
}

function Get-DibBytes {
    <#
        Převede bitmapu na DIB podobu, jakou čeká ICO: hlavička, obrázek
        zdola nahoru a maska. Záměrně ne PNG - System.Drawing.Icon si s PNG
        položkami neporadí a okno by pak zůstalo bez ikony.
    #>
    param([System.Drawing.Bitmap]$Bmp)

    $S = $Bmp.Width
    $rect = New-Object System.Drawing.Rectangle(0, 0, $S, $S)
    $data = $Bmp.LockBits($rect, [System.Drawing.Imaging.ImageLockMode]::ReadOnly,
                          [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $stride = $data.Stride
    $buf = New-Object byte[] ($stride * $S)
    [System.Runtime.InteropServices.Marshal]::Copy($data.Scan0, $buf, 0, $buf.Length)
    $Bmp.UnlockBits($data)

    $ms = New-Object System.IO.MemoryStream
    $w  = New-Object System.IO.BinaryWriter($ms)

    # BITMAPINFOHEADER - výška je dvojnásobná (obrázek + maska)
    $w.Write([uint32]40)
    $w.Write([int32]$S)
    $w.Write([int32]($S * 2))
    $w.Write([uint16]1)
    $w.Write([uint16]32)
    $w.Write([uint32]0)
    $w.Write([uint32]($S * $S * 4))
    $w.Write([int32]0); $w.Write([int32]0)
    $w.Write([uint32]0); $w.Write([uint32]0)

    # obrazová data zdola nahoru
    for ($y = $S - 1; $y -ge 0; $y--) { $w.Write($buf, ($y * $stride), ($S * 4)) }

    # AND maska: průhlednost řeší alfa kanál, takže samé nuly
    $maskRow = [int][math]::Floor(($S + 31) / 32) * 4
    $nuly = New-Object byte[] $maskRow
    for ($y = 0; $y -lt $S; $y++) { $w.Write($nuly, 0, $maskRow) }

    $w.Flush()
    $bytes = $ms.ToArray()
    $w.Dispose(); $ms.Dispose()
    # čárka je nutná, jinak PowerShell pole rozbalí na jednotlivé bajty
    return ,$bytes
}

# --- poskládání .ico
$velikosti = @(16, 24, 32, 48, 64, 128, 256)
$obrazky = @()
foreach ($s in $velikosti) {
    $bmp = New-IconBitmap $s
    $obrazky += ,@{ Size = $s; Data = (Get-DibBytes $bmp) }
    $bmp.Dispose()
}

$out = New-Object System.IO.MemoryStream
$w = New-Object System.IO.BinaryWriter($out)

# ICONDIR
$w.Write([uint16]0)                        # rezervováno
$w.Write([uint16]1)                        # typ 1 = ikona
$w.Write([uint16]$obrazky.Count)

# ICONDIRENTRY (16 B na položku), data jdou za všemi hlavičkami
$offset = 6 + (16 * $obrazky.Count)
foreach ($o in $obrazky) {
    $rozmer = $o.Size
    if ($rozmer -ge 256) { $rozmer = 0 }   # 256 se v ICO zapisuje jako 0
    $w.Write([byte]$rozmer)                # šířka
    $w.Write([byte]$rozmer)                # výška
    $w.Write([byte]0)                      # počet barev palety
    $w.Write([byte]0)                      # rezervováno
    $w.Write([uint16]1)                    # roviny
    $w.Write([uint16]32)                   # bitů na pixel
    $w.Write([uint32]$o.Data.Length)
    $w.Write([uint32]$offset)
    $offset += $o.Data.Length
}
foreach ($o in $obrazky) { $w.Write($o.Data) }

$w.Flush()
[System.IO.File]::WriteAllBytes($Vystup, $out.ToArray())
$w.Dispose(); $out.Dispose()

"Ikona vytvorena: $Vystup ($([math]::Round((Get-Item $Vystup).Length / 1KB, 1)) kB, $($obrazky.Count) velikosti)"
