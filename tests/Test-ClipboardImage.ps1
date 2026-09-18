[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

$mainScript = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..\ClipboardImage.ps1')).Path
$tempDirectory = Join-Path $env:TEMP 'ClipboardImage'

function Set-TestClipboardImage([System.Drawing.Color]$Color) {
    $bitmap = New-Object System.Drawing.Bitmap 32, 24
    $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
    try {
        $graphics.Clear($Color)
        [System.Windows.Forms.Clipboard]::SetImage($bitmap)
    } finally {
        $graphics.Dispose()
        $bitmap.Dispose()
    }
}

function Get-DropFiles {
    if (-not [System.Windows.Forms.Clipboard]::ContainsFileDropList()) { return @() }
    return @([System.Windows.Forms.Clipboard]::GetFileDropList())
}

& powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -File $mainScript -Action Stop | Out-Null
Remove-Item -LiteralPath (Join-Path $tempDirectory '.stock.txt') -Force -ErrorAction SilentlyContinue

$process = Start-Process -FilePath powershell.exe -WindowStyle Hidden -PassThru -ArgumentList @(
    '-NoProfile', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden', '-STA', '-File', ('"{0}"' -f $mainScript)
)

try {
    $statePath = Join-Path $tempDirectory '.resident.json'
    $deadline = (Get-Date).AddSeconds(8)
    while (-not (Test-Path -LiteralPath $statePath)) {
        if ((Get-Date) -gt $deadline) { throw '常駐プロセスの起動確認がタイムアウトしました。' }
        Start-Sleep -Milliseconds 100
    }
    $state = Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json

    if (-not ('ClipboardImage.TestNativeMethods' -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
namespace ClipboardImage {
    public static class TestNativeMethods {
        [DllImport("user32.dll")]
        public static extern bool PostThreadMessage(uint idThread, uint Msg, UIntPtr wParam, IntPtr lParam);
    }
}
'@
    }

    Set-TestClipboardImage ([System.Drawing.Color]::Crimson)
    $stockMessage = New-Object UIntPtr ([uint32]2)
    $publishMessage = New-Object UIntPtr ([uint32]1)
    $null = [ClipboardImage.TestNativeMethods]::PostThreadMessage([uint32]$state.ThreadId, 0x0312, $stockMessage, [IntPtr]::Zero)
    Start-Sleep -Milliseconds 500

    Set-TestClipboardImage ([System.Drawing.Color]::RoyalBlue)
    $null = [ClipboardImage.TestNativeMethods]::PostThreadMessage([uint32]$state.ThreadId, 0x0312, $stockMessage, [IntPtr]::Zero)
    Start-Sleep -Milliseconds 500

    $null = [ClipboardImage.TestNativeMethods]::PostThreadMessage([uint32]$state.ThreadId, 0x0312, $publishMessage, [IntPtr]::Zero)
    Start-Sleep -Milliseconds 700
    $files = @(Get-DropFiles)
    if ($files.Count -ne 2) { throw "2ファイルを期待しましたが $($files.Count) ファイルでした。" }
    foreach ($file in $files) {
        if (-not (Test-Path -LiteralPath $file)) { throw "生成ファイルがありません: $file" }
        $image = [System.Drawing.Image]::FromFile($file)
        try {
            if ($image.Width -ne 32 -or $image.Height -ne 24) { throw "PNG寸法が不正です: $file" }
        } finally { $image.Dispose() }
    }
    if (-not [System.Windows.Forms.Clipboard]::ContainsImage()) { throw '画像形式がFileDropListと併存していません。' }
    if (Test-Path -LiteralPath (Join-Path $tempDirectory '.stock.txt')) { throw '公開後にストックが消費されていません。' }

    Set-TestClipboardImage ([System.Drawing.Color]::ForestGreen)
    $openPath = @(& powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -File $mainScript -Action Open -SuppressExplorer)
    if (-not (Test-Path -LiteralPath $openPath[-1])) { throw 'Open動作のPNGが生成されませんでした。' }

    foreach ($number in 1..7) {
        Copy-Item -LiteralPath $openPath[-1] -Destination (Join-Path $tempDirectory ('clip-cleanup-{0}.png' -f $number)) -Force
        Start-Sleep -Milliseconds 20
    }
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -File $mainScript -Action Cleanup -MaxAgeHours 87600 -MaxFiles 5
    $remaining = @(Get-ChildItem -LiteralPath $tempDirectory -Filter 'clip-*.png' -File)
    if ($remaining.Count -gt 5) { throw "最大枚数整理後も $($remaining.Count) ファイル残っています。" }

    $oldFile = $remaining | Select-Object -First 1
    $oldFile.LastWriteTime = (Get-Date).AddHours(-25)
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -File $mainScript -Action Cleanup -MaxAgeHours 24 -MaxFiles 100
    if (Test-Path -LiteralPath $oldFile.FullName) { throw '24時間超のPNGが削除されませんでした。' }

    [pscustomobject]@{
        ResidentMessageLoop = 'OK'
        StockAndPublish = 'OK (2 files)'
        BitmapAndFileDrop = 'OK'
        OpenPathGeneration = 'OK'
        RetentionCleanup = 'OK'
        Files = $files -join '; '
    }
} finally {
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -File $mainScript -Action Stop | Out-Null
    if (-not $process.HasExited) { $process.WaitForExit(3000) | Out-Null }
    if (-not $process.HasExited) { $process.Kill() }
}
