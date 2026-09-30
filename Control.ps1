[CmdletBinding()]
param(
    [ValidateSet('Gui', 'Start', 'Restart', 'Stop', 'Status')]
    [string]$Action = 'Gui',
    [switch]$HideConsole
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

function Initialize-ControlNativeMethods {
    if ('ClipboardImageControl.NativeMethods' -as [type]) { return }
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;

namespace ClipboardImageControl {
    public static class NativeMethods {
        [DllImport("kernel32.dll")]
        public static extern IntPtr GetConsoleWindow();

        [DllImport("user32.dll")]
        [return: MarshalAs(UnmanagedType.Bool)]
        public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);

        [DllImport("user32.dll")]
        [return: MarshalAs(UnmanagedType.Bool)]
        public static extern bool SetForegroundWindow(IntPtr hWnd);
    }
}
'@
}

function Show-ControlError {
    param(
        [string]$Title,
        [string]$Message
    )
    try {
        Add-Type -AssemblyName System.Windows.Forms -ErrorAction Stop
        [System.Windows.Forms.MessageBox]::Show(
            $Message,
            $Title,
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Error
        ) | Out-Null
    } catch {
        try {
            $shell = New-Object -ComObject WScript.Shell
            $null = $shell.Popup($Message, 0, $Title, 16)
        } catch {
            [Console]::Error.WriteLine('{0}: {1}' -f $Title, $Message)
        }
    }
}

function Get-UtilityState {
    $result = [ordered]@{
        Running = $false
        ProcessId = $null
        StartedAt = $null
        InputMode = $null
    }
    if (-not (Test-Path -LiteralPath $stateFile)) { return [pscustomobject]$result }

    try {
        $state = Get-Content -LiteralPath $stateFile -Raw -Encoding UTF8 | ConvertFrom-Json
        $process = Get-Process -Id $state.ProcessId -ErrorAction SilentlyContinue
        if ($null -ne $process) {
            $stateStartedAt = [DateTimeOffset]::Parse([string]$state.StartedAt).LocalDateTime
            if ([math]::Abs(($process.StartTime - $stateStartedAt).TotalMinutes) -lt 2) {
                $result.Running = $true
                $result.ProcessId = $process.Id
                $result.StartedAt = $state.StartedAt
                $result.InputMode = $state.InputMode
            }
        }
    } catch {}
    return [pscustomobject]$result
}

function Start-Utility {
    if ((Get-UtilityState).Running) { return }
    $stateDirectory = Split-Path -Parent $stateFile
    if (-not (Test-Path -LiteralPath $stateDirectory)) {
        $null = New-Item -ItemType Directory -Path $stateDirectory
    }
    Remove-Item -LiteralPath $stateFile -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $startErrorFile -Force -ErrorAction SilentlyContinue
    $process = Start-Process -FilePath $powerShell -WindowStyle Hidden -PassThru -ArgumentList @(
        '-NoProfile', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden', '-STA', '-File', ('"{0}"' -f $mainScript),
        '-StartupErrorFile', ('"{0}"' -f $startErrorFile)
    )
    $deadline = (Get-Date).AddSeconds(5)
    while (-not (Get-UtilityState).Running -and (Get-Date) -lt $deadline) {
        if ($process.HasExited) { break }
        Start-Sleep -Milliseconds 100
    }
    if (-not (Get-UtilityState).Running) {
        $detail = ''
        if ($process.HasExited) {
            $process.WaitForExit()
            if (Test-Path -LiteralPath $startErrorFile) {
                $capturedError = Get-Content -LiteralPath $startErrorFile -Raw -ErrorAction SilentlyContinue
                if ($null -ne $capturedError) { $detail = $capturedError.Trim() }
            }
            if ([string]::IsNullOrWhiteSpace($detail)) {
                $detail = '常駐プロセスは終了コード {0} で終了しました。' -f $process.ExitCode
            }
        } else {
            $detail = '常駐プロセスは起動していますが、5秒以内に稼働状態を確認できませんでした。'
        }
        throw "Clipboard Image Hotkeysを起動できませんでした。`r`n`r`n$detail"
    }
}

function Stop-Utility {
    $state = Get-UtilityState
    if ($state.Running) {
        & $powerShell -NoProfile -ExecutionPolicy Bypass -STA -File $mainScript -Action Stop | Out-Null
        $deadline = (Get-Date).AddSeconds(5)
        while ((Get-UtilityState).Running -and (Get-Date) -lt $deadline) {
            Start-Sleep -Milliseconds 100
        }
    }
    if (-not (Get-UtilityState).Running) {
        Remove-Item -LiteralPath $stateFile -Force -ErrorAction SilentlyContinue
    } else {
        throw 'Clipboard Image Hotkeysを5秒以内に停止できませんでした。'
    }
}

function Restart-Utility {
    Stop-Utility
    Start-Utility
}

function Show-ControlWindow {
    Initialize-ControlNativeMethods
    if ($HideConsole) {
        $consoleWindow = [ClipboardImageControl.NativeMethods]::GetConsoleWindow()
        if ($consoleWindow -ne [IntPtr]::Zero) {
            $null = [ClipboardImageControl.NativeMethods]::ShowWindow($consoleWindow, 0)
        }
    }

    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing
    [System.Windows.Forms.Application]::EnableVisualStyles()

    $form = New-Object System.Windows.Forms.Form
    $form.Text = 'Clipboard Image Hotkeys'
    $form.ClientSize = New-Object System.Drawing.Size(460, 235)
    $form.StartPosition = 'CenterScreen'
    $form.FormBorderStyle = 'FixedDialog'
    $form.MaximizeBox = $false
    $form.MinimizeBox = $false
    $form.Font = New-Object System.Drawing.Font('Segoe UI', 10)

    $title = New-Object System.Windows.Forms.Label
    $title.Text = 'Clipboard Image Hotkeys'
    $title.Font = New-Object System.Drawing.Font('Segoe UI Semibold', 16)
    $title.AutoSize = $true
    $title.Location = New-Object System.Drawing.Point(24, 20)
    $form.Controls.Add($title)

    $status = New-Object System.Windows.Forms.Label
    $status.Font = New-Object System.Drawing.Font('Segoe UI Semibold', 13)
    $status.AutoSize = $true
    $status.Location = New-Object System.Drawing.Point(25, 64)
    $form.Controls.Add($status)

    $details = New-Object System.Windows.Forms.Label
    $details.AutoSize = $true
    $details.ForeColor = [System.Drawing.Color]::DimGray
    $details.Location = New-Object System.Drawing.Point(26, 96)
    $form.Controls.Add($details)

    $startButton = New-Object System.Windows.Forms.Button
    $startButton.Text = '起動'
    $startButton.Size = New-Object System.Drawing.Size(92, 38)
    $startButton.Location = New-Object System.Drawing.Point(25, 142)
    $form.Controls.Add($startButton)

    $restartButton = New-Object System.Windows.Forms.Button
    $restartButton.Text = '再起動'
    $restartButton.Size = New-Object System.Drawing.Size(92, 38)
    $restartButton.Location = New-Object System.Drawing.Point(126, 142)
    $form.Controls.Add($restartButton)

    $stopButton = New-Object System.Windows.Forms.Button
    $stopButton.Text = '停止'
    $stopButton.Size = New-Object System.Drawing.Size(92, 38)
    $stopButton.Location = New-Object System.Drawing.Point(227, 142)
    $form.Controls.Add($stopButton)

    $closeButton = New-Object System.Windows.Forms.Button
    $closeButton.Text = '閉じる'
    $closeButton.Size = New-Object System.Drawing.Size(92, 38)
    $closeButton.Location = New-Object System.Drawing.Point(343, 142)
    $form.Controls.Add($closeButton)

    function Update-WindowState {
        $current = Get-UtilityState
        if ($current.Running) {
            $status.Text = '● 稼働中'
            $status.ForeColor = [System.Drawing.Color]::ForestGreen
            $details.Text = 'PID {0}  /  {1}' -f $current.ProcessId, $current.InputMode
            $startButton.Enabled = $false
            $restartButton.Enabled = $true
            $stopButton.Enabled = $true
        } else {
            $status.Text = '● 停止中'
            $status.ForeColor = [System.Drawing.Color]::Firebrick
            $details.Text = 'ホットキーは現在無効です。'
            $startButton.Enabled = $true
            $restartButton.Enabled = $true
            $stopButton.Enabled = $false
        }
    }

    $startButton.Add_Click({
        try { Start-Utility; Update-WindowState }
        catch { [System.Windows.Forms.MessageBox]::Show($_.Exception.Message, '起動エラー') | Out-Null }
    })
    $restartButton.Add_Click({
        try { Restart-Utility; Update-WindowState }
        catch { [System.Windows.Forms.MessageBox]::Show($_.Exception.Message, '再起動エラー') | Out-Null }
    })
    $stopButton.Add_Click({
        try { Stop-Utility; Update-WindowState }
        catch { [System.Windows.Forms.MessageBox]::Show($_.Exception.Message, '停止エラー') | Out-Null }
    })
    $closeButton.Add_Click({ $form.Close() })
    $form.Add_Shown({
        Update-WindowState
        $null = [ClipboardImageControl.NativeMethods]::SetForegroundWindow($form.Handle)
        $form.Activate()
    })

    [void]$form.ShowDialog()
}

try {
    $mainScript = Join-Path $PSScriptRoot 'ClipboardImage.ps1'
    $powerShell = Join-Path $PSHOME 'powershell.exe'
    if (-not (Test-Path -LiteralPath $powerShell)) { $powerShell = 'powershell.exe' }
    $stateFile = Join-Path $env:TEMP 'ClipboardImage\.resident.json'
    $startErrorFile = Join-Path $env:TEMP 'ClipboardImage\.start-error.txt'

    switch ($Action) {
        'Gui'     { Show-ControlWindow }
        'Start'   { Start-Utility; Get-UtilityState }
        'Restart' { Restart-Utility; Get-UtilityState }
        'Stop'    { Stop-Utility; Get-UtilityState }
        'Status'  { Get-UtilityState }
    }
} catch {
    $message = $_.Exception.Message
    if ($Action -eq 'Gui') {
        Show-ControlError -Title 'Clipboard Image Hotkeys エラー' -Message $message
    } else {
        [Console]::Error.WriteLine($message)
    }
    exit 1
}
