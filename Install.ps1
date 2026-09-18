[CmdletBinding()]
param([switch]$NoStart)

$ErrorActionPreference = 'Stop'
$sourceMainScript = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot 'ClipboardImage.ps1')).Path
$sourceUninstallScript = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot 'Uninstall.ps1')).Path
$sourceControlScript = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot 'Control.ps1')).Path
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
Copy-Item -LiteralPath $sourceControlScript -Destination (Join-Path $installDirectory 'Control.ps1') -Force

$startMenuDirectory = Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs\Clipboard Image Hotkeys'
if (-not (Test-Path -LiteralPath $startMenuDirectory)) {
    $null = New-Item -ItemType Directory -Path $startMenuDirectory
}
$shell = New-Object -ComObject WScript.Shell
$shortcut = $shell.CreateShortcut((Join-Path $startMenuDirectory 'Clipboard Image Hotkeys.lnk'))
$shortcut.TargetPath = $powerShell
$shortcut.Arguments = '-NoProfile -ExecutionPolicy Bypass -STA -File "{0}" -HideConsole' -f (Join-Path $installDirectory 'Control.ps1')
$shortcut.WorkingDirectory = $installDirectory
$shortcut.Description = 'Clipboard Image Hotkeys の起動・再起動・停止'
$shortcut.Save()

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
