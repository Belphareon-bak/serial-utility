#Requires -Version 5.1
<#
.SYNOPSIS
    Sestaví MediaTool.exe - spouštěč s ikonou, který otevře GUI.

.DESCRIPTION
    Exe je záměrně jen tenký spouštěč: spustí media-tool-gui.ps1, který leží
    vedle něj. Logika tak zůstává v čitelných skriptech, které jde kdykoli
    upravit bez překládání, a exe dává ikonu a dvojklik bez okna konzole.

    Překládá se systémovým csc.exe z .NET Frameworku, nic se nestahuje.
#>
param(
    [string]$Vystup = (Join-Path $PSScriptRoot 'MediaTool.exe')
)

$ErrorActionPreference = 'Stop'

$csc = Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
if (-not (Test-Path -LiteralPath $csc)) {
    $csc = Join-Path $env:WINDIR 'Microsoft.NET\Framework\v4.0.30319\csc.exe'
}
if (-not (Test-Path -LiteralPath $csc)) { throw "csc.exe nenalezen - chybí .NET Framework 4." }

$ikona = Join-Path $PSScriptRoot 'mediatool.ico'
if (-not (Test-Path -LiteralPath $ikona)) {
    Write-Host 'mediatool.ico chybí, generuji...'
    & (Join-Path $PSScriptRoot 'make-icon.ps1') | Write-Host
}

$zdroj = @'
using System;
using System.Diagnostics;
using System.IO;
using System.Reflection;
using System.Windows.Forms;

static class MediaToolLauncher
{
    [STAThread]
    static void Main(string[] args)
    {
        string dir = Path.GetDirectoryName(Assembly.GetExecutingAssembly().Location);
        string script = Path.Combine(dir, "media-tool-gui.ps1");

        if (!File.Exists(script))
        {
            MessageBox.Show(
                "Vedle programu chybi media-tool-gui.ps1:\n\n" + script,
                "MediaTool", MessageBoxButtons.OK, MessageBoxIcon.Error);
            return;
        }

        string argy = "-NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File \"" + script + "\"";
        foreach (string a in args) { argy += " \"" + a + "\""; }

        var psi = new ProcessStartInfo("powershell.exe", argy);
        psi.UseShellExecute  = false;
        psi.CreateNoWindow   = true;
        psi.WorkingDirectory = dir;

        try
        {
            Process.Start(psi);
        }
        catch (Exception ex)
        {
            MessageBox.Show("Nepodarilo se spustit PowerShell:\n\n" + ex.Message,
                "MediaTool", MessageBoxButtons.OK, MessageBoxIcon.Error);
        }
    }
}
'@

$tmp = Join-Path $env:TEMP ('MediaToolLauncher-{0}.cs' -f $PID)
Set-Content -LiteralPath $tmp -Value $zdroj -Encoding UTF8

$argy = @(
    '/nologo'
    '/target:winexe'
    "/out:$Vystup"
    "/win32icon:$ikona"
    '/reference:System.Windows.Forms.dll'
    '/reference:System.dll'
    $tmp
)

$vystupPrekladu = & $csc @argy 2>&1
Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue

if ($LASTEXITCODE -ne 0) {
    $vystupPrekladu | Write-Host
    throw "Preklad selhal (kod $LASTEXITCODE)."
}

$info = Get-Item -LiteralPath $Vystup
"Hotovo: $($info.FullName) ($([math]::Round($info.Length / 1KB, 1)) kB)"
