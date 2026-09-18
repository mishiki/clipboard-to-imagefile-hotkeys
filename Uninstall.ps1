[CmdletBinding()]
param([switch]$KeepTemporaryFiles)

$ErrorActionPreference = 'Stop'
$installDirectory = Join-Path $env:LOCALAPPDATA 'ClipboardImageHotkeys'
$installedMainScript = Join-Path $installDirectory 'ClipboardImage.ps1'
$localMainScript = Join-Path $PSScriptRoot 'ClipboardImage.ps1'
$mainScript = if (Test-Path -LiteralPath $installedMainScript) { $installedMainScript } else { $localMainScript }
$runKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
Remove-ItemProperty -Path $runKey -Name 'ClipboardImageHotkeys' -ErrorAction SilentlyContinue
$startMenuDirectory = Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs\Clipboard Image Hotkeys'
if (Test-Path -LiteralPath $startMenuDirectory) {
    Remove-Item -LiteralPath $startMenuDirectory -Recurse -Force
}

& powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -File $mainScript -Action Stop | Out-Null
Start-Sleep -Milliseconds 300

if (-not $KeepTemporaryFiles) {
    $tempDirectory = Join-Path $env:TEMP 'ClipboardImage'
    if (Test-Path -LiteralPath $tempDirectory) {
        Remove-Item -LiteralPath $tempDirectory -Recurse -Force
    }
}

if (Test-Path -LiteralPath $installDirectory) {
    Remove-Item -LiteralPath $installDirectory -Recurse -Force
}

Write-Host 'ClipboardImageHotkeysをアンインストールしました。'
