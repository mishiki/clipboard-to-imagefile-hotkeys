[CmdletBinding()]
param(
    [ValidateSet('Gui', 'Start', 'Restart', 'Stop', 'Status')]
    [string]$Action = 'Gui',
    [switch]$HideConsole
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$controlLogFile = Join-Path $env:LOCALAPPDATA 'ClipboardImageHotkeys\Control.log'

function Write-ControlLog {
    param([string]$Message)
    try {
        $timestamp = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss.fff')
        Add-Content -LiteralPath $controlLogFile -Value ('{0} PID={1} {2}' -f $timestamp, $PID, $Message) -Encoding UTF8
    } catch {}
}

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

        [DllImport("user32.dll", CharSet = CharSet.Unicode)]
        public static extern IntPtr FindWindow(string lpClassName, string lpWindowName);
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
    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing
    [System.Windows.Forms.Application]::EnableVisualStyles()

    try {
        Initialize-ControlNativeMethods
        $existingWindow = [ClipboardImageControl.NativeMethods]::FindWindow($null, 'Clipboard Image Hotkeys')
        if ($existingWindow -ne [IntPtr]::Zero) {
            $null = [ClipboardImageControl.NativeMethods]::ShowWindow($existingWindow, 5)
            $null = [ClipboardImageControl.NativeMethods]::SetForegroundWindow($existingWindow)
            Write-ControlLog 'Existing control window activated.'
            return
        }
    } catch {
        Write-ControlLog ('Existing-window check failed; continuing with a new window: {0}' -f $_.Exception.Message)
    }

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
    $status.Text = '● 状態確認中'
    $status.ForeColor = [System.Drawing.Color]::DimGray
    $form.Controls.Add($status)

    $details = New-Object System.Windows.Forms.Label
    $details.AutoSize = $true
    $details.ForeColor = [System.Drawing.Color]::DimGray
    $details.Location = New-Object System.Drawing.Point(26, 96)
    $details.Text = '常駐状態を確認しています。'
    $form.Controls.Add($details)

    $startButton = New-Object System.Windows.Forms.Button
    $startButton.Text = '起動'
    $startButton.Size = New-Object System.Drawing.Size(92, 38)
    $startButton.Location = New-Object System.Drawing.Point(25, 142)
    $startButton.Enabled = $false
    $form.Controls.Add($startButton)

    $restartButton = New-Object System.Windows.Forms.Button
    $restartButton.Text = '再起動'
    $restartButton.Size = New-Object System.Drawing.Size(92, 38)
    $restartButton.Location = New-Object System.Drawing.Point(126, 142)
    $restartButton.Enabled = $false
    $form.Controls.Add($restartButton)

    $stopButton = New-Object System.Windows.Forms.Button
    $stopButton.Text = '停止'
    $stopButton.Size = New-Object System.Drawing.Size(92, 38)
    $stopButton.Location = New-Object System.Drawing.Point(227, 142)
    $stopButton.Enabled = $false
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

    function Update-WindowStateSafely {
        try {
            Update-WindowState
        } catch {
            $status.Text = '● 状態取得エラー'
            $status.ForeColor = [System.Drawing.Color]::DarkOrange
            $details.Text = $_.Exception.Message
            $startButton.Enabled = $false
            $restartButton.Enabled = $false
            $stopButton.Enabled = $false
            Write-ControlLog ('State refresh failed: {0}' -f $_.Exception.Message)
        }
    }

    $startButton.Add_Click({
        try { Write-ControlLog 'Start clicked.'; Start-Utility; Update-WindowStateSafely }
        catch { Write-ControlLog ('Start failed: {0}' -f $_.Exception.Message); [System.Windows.Forms.MessageBox]::Show($_.Exception.Message, '起動エラー') | Out-Null }
    })
    $restartButton.Add_Click({
        try { Write-ControlLog 'Restart clicked.'; Restart-Utility; Update-WindowStateSafely }
        catch { Write-ControlLog ('Restart failed: {0}' -f $_.Exception.Message); [System.Windows.Forms.MessageBox]::Show($_.Exception.Message, '再起動エラー') | Out-Null }
    })
    $stopButton.Add_Click({
        try { Write-ControlLog 'Stop clicked.'; Stop-Utility; Update-WindowStateSafely }
        catch { Write-ControlLog ('Stop failed: {0}' -f $_.Exception.Message); [System.Windows.Forms.MessageBox]::Show($_.Exception.Message, '停止エラー') | Out-Null }
    })
    $closeButton.Add_Click({ $form.Close() })

    $startupTimer = New-Object System.Windows.Forms.Timer
    $startupTimer.Interval = 150
    $startupTimer.Add_Tick({
        param($sender, $eventArgs)
        $sender.Stop()
        try {
            if ($HideConsole) {
                Initialize-ControlNativeMethods
                $consoleWindow = [ClipboardImageControl.NativeMethods]::GetConsoleWindow()
                if ($consoleWindow -ne [IntPtr]::Zero) {
                    $null = [ClipboardImageControl.NativeMethods]::ShowWindow($consoleWindow, 0)
                }
            }
        } catch {
            Write-ControlLog ('Console hide failed; leaving it visible: {0}' -f $_.Exception.Message)
        }
        Update-WindowStateSafely
        try {
            Initialize-ControlNativeMethods
            $null = [ClipboardImageControl.NativeMethods]::SetForegroundWindow($form.Handle)
            $form.Activate()
        } catch {
            Write-ControlLog ('Window activation failed: {0}' -f $_.Exception.Message)
        }
    })

    $statusTimer = New-Object System.Windows.Forms.Timer
    $statusTimer.Interval = 2000
    $statusTimer.Add_Tick({ Update-WindowStateSafely })

    $form.Add_Shown({
        Write-ControlLog 'Control window shown.'
        $startupTimer.Start()
        $statusTimer.Start()
    })
    $form.Add_FormClosed({
        try { $startupTimer.Stop(); $statusTimer.Stop() } catch {}
    })

    [System.Windows.Forms.Application]::Run($form)
    $startupTimer.Dispose()
    $statusTimer.Dispose()
    Write-ControlLog 'Control window closed.'
}

try {
    Write-ControlLog ('Control started. Action={0}; HideConsole={1}' -f $Action, [bool]$HideConsole)
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
    Write-ControlLog ('Fatal error: {0}' -f $message)
    if ($Action -eq 'Gui') {
        Show-ControlError -Title 'Clipboard Image Hotkeys エラー' -Message $message
    } else {
        [Console]::Error.WriteLine($message)
    }
    exit 1
}
