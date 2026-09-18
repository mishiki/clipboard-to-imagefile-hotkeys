[CmdletBinding()]
param([switch]$NoStart)

$ErrorActionPreference = 'Stop'
$sourceMainScript = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot 'ClipboardImage.ps1')).Path
$sourceUninstallScript = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot 'Uninstall.ps1')).Path
$installDirectory = Join-Path $env:LOCALAPPDATA 'ClipboardImageHotkeys'
$mainScript = Join-Path $installDirectory 'ClipboardImage.ps1'
$powerShell = Join-Path $PSHOME 'powershell.exe'
if (-not (Test-Path -LiteralPath $powerShell)) { $powerShell = 'powershell.exe' }

& $powerShell -NoProfile -ExecutionPolicy Bypass -STA -File $sourceMainScript -Action Stop | Out-Null
Start-Sleep -Milliseconds 300
if (-not (Test-Path -LiteralPath $installDirectory)) {
    $null = New-Item -ItemType Directory -Path $installDirectory
}
Copy-Item -LiteralPath $sourceMainScript -Destination $mainScript -Force
Copy-Item -LiteralPath $sourceUninstallScript -Destination (Join-Path $installDirectory 'Uninstall.ps1') -Force

$command = '"{0}" -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -STA -File "{1}"' -f $powerShell, $mainScript

$runKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
Set-ItemProperty -Path $runKey -Name 'ClipboardImageHotkeys' -Value $command

if (-not $NoStart) {
    Start-Process -FilePath $powerShell -WindowStyle Hidden -ArgumentList @(
        '-NoProfile', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden', '-STA', '-File', ('"{0}"' -f $mainScript)
    )
}

Write-Host 'ClipboardImageHotkeysをスタートアップに登録しました。'
Write-Host $mainScript
