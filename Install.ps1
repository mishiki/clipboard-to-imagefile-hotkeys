[CmdletBinding()]
param([switch]$NoStart)

$ErrorActionPreference = 'Stop'
$sourceMainScript = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot 'ClipboardImage.ps1')).Path
$sourceUninstallScript = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot 'Uninstall.ps1')).Path
$installDirectory = Join-Path $env:LOCALAPPDATA 'ClipboardImageHotkeys'
$mainScript = Join-Path $installDirectory 'ClipboardImage.ps1'
$powerShell = Join-Path $PSHOME 'powershell.exe'
if (-not (Test-Path -LiteralPath $powerShell)) { $powerShell = 'powershell.exe' }
$startupErrorFile = Join-Path $env:TEMP 'ClipboardImage\.startup-error.txt'

& $powerShell -NoProfile -ExecutionPolicy Bypass -STA -File $sourceMainScript -Action Stop | Out-Null
Start-Sleep -Milliseconds 300
if (-not (Test-Path -LiteralPath $installDirectory)) {
    $null = New-Item -ItemType Directory -Path $installDirectory
}
Copy-Item -LiteralPath $sourceMainScript -Destination $mainScript -Force
Copy-Item -LiteralPath $sourceUninstallScript -Destination (Join-Path $installDirectory 'Uninstall.ps1') -Force
Remove-Item -LiteralPath (Join-Path $installDirectory 'Control.ps1') -Force -ErrorAction SilentlyContinue

$startMenuDirectory = Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs\Clipboard Image Hotkeys'
if (-not (Test-Path -LiteralPath $startMenuDirectory)) {
    $null = New-Item -ItemType Directory -Path $startMenuDirectory
}
$shell = New-Object -ComObject WScript.Shell
$shortcut = $shell.CreateShortcut((Join-Path $startMenuDirectory 'Clipboard Image Hotkeys.lnk'))
$shortcut.TargetPath = $powerShell
$shortcut.Arguments = '-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -STA -File "{0}" -HideConsole' -f $mainScript
$shortcut.WorkingDirectory = $installDirectory
$shortcut.Description = 'Clipboard Image Hotkeys の起動・再起動・停止'
$shortcut.Save()

$startupDirectory = Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs\Startup'
$startupShortcutPath = Join-Path $startupDirectory 'Clipboard Image Hotkeys.lnk'
$startupShortcut = $shell.CreateShortcut($startupShortcutPath)
$startupShortcut.TargetPath = $powerShell
$startupShortcut.Arguments = '-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -STA -File "{0}" -NoWindow -HideConsole -StartupErrorFile "{1}"' -f $mainScript, $startupErrorFile
$startupShortcut.WorkingDirectory = $installDirectory
$startupShortcut.Description = 'Clipboard Image Hotkeys をログオン時に起動'
$startupShortcut.Save()

$runKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
Remove-ItemProperty -Path $runKey -Name 'ClipboardImageHotkeys' -ErrorAction SilentlyContinue

if (-not $NoStart) {
    Remove-Item -LiteralPath $startupErrorFile -Force -ErrorAction SilentlyContinue
    Start-Process -FilePath $powerShell -ArgumentList @(
        '-NoProfile', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden', '-STA', '-File', ('"{0}"' -f $mainScript),
        '-NoWindow', '-HideConsole', '-StartupErrorFile', ('"{0}"' -f $startupErrorFile)
    )
}

Write-Host 'ClipboardImageHotkeysをスタートアップに登録しました。'
Write-Host $mainScript
