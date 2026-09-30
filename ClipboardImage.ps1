[CmdletBinding()]
param(
    [ValidateSet('Run', 'Convert', 'Stock', 'Publish', 'Open', 'Cleanup', 'Status', 'Stop')]
    [string]$Action = 'Run',
    [int]$MaxAgeHours = 24,
    [int]$MaxFiles = 100,
    [switch]$SuppressExplorer,
    [switch]$NoWindow,
    [switch]$HideConsole,
    [string]$StartupErrorFile
)

trap {
    $errorText = ($_ | Out-String).Trim()
    if (-not [string]::IsNullOrWhiteSpace($StartupErrorFile)) {
        try {
            $errorDirectory = Split-Path -Parent $StartupErrorFile
            if ($errorDirectory -and -not (Test-Path -LiteralPath $errorDirectory)) {
                $null = New-Item -ItemType Directory -Path $errorDirectory
            }
            $errorText | Set-Content -LiteralPath $StartupErrorFile -Encoding UTF8
        } catch {}
    } else {
        [Console]::Error.WriteLine($errorText)
    }
    exit 1
}

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

if (-not ('ClipboardImage.NativeMethods' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;

namespace ClipboardImage {
    public static class NativeMethods {
        [StructLayout(LayoutKind.Sequential)]
        public struct POINT { public int X; public int Y; }

        [StructLayout(LayoutKind.Sequential)]
        public struct MSG {
            public IntPtr hwnd;
            public uint message;
            public UIntPtr wParam;
            public IntPtr lParam;
            public uint time;
            public POINT pt;
        }

        [DllImport("user32.dll", SetLastError = true)]
        public static extern bool RegisterHotKey(IntPtr hWnd, int id, uint fsModifiers, uint vk);

        [DllImport("user32.dll", SetLastError = true)]
        public static extern bool UnregisterHotKey(IntPtr hWnd, int id);

        [DllImport("user32.dll")]
        public static extern int GetMessage(out MSG lpMsg, IntPtr hWnd, uint min, uint max);

        [DllImport("user32.dll")]
        public static extern bool PostThreadMessage(uint idThread, uint Msg, UIntPtr wParam, IntPtr lParam);

        [DllImport("kernel32.dll")]
        public static extern uint GetCurrentThreadId();

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

    public static class KeyboardHook {
        private const int WH_KEYBOARD_LL = 13;
        private const int WM_KEYDOWN = 0x0100;
        private const int WM_KEYUP = 0x0101;
        private const int WM_SYSKEYDOWN = 0x0104;
        private const int WM_SYSKEYUP = 0x0105;
        private const uint WM_APP_HOTKEY = 0x8001;
        private const int VK_SHIFT = 0x10;
        private const int VK_CONTROL = 0x11;
        private const int VK_MENU = 0x12;
        private const int VK_LWIN = 0x5B;
        private const int VK_RWIN = 0x5C;

        [StructLayout(LayoutKind.Sequential)]
        private struct KBDLLHOOKSTRUCT {
            public uint vkCode;
            public uint scanCode;
            public uint flags;
            public uint time;
            public UIntPtr dwExtraInfo;
        }

        private delegate IntPtr HookProc(int nCode, IntPtr wParam, IntPtr lParam);
        private static HookProc callback;
        private static IntPtr hook = IntPtr.Zero;
        private static uint ownerThread;
        private static readonly bool[] down = new bool[256];

        [DllImport("user32.dll", SetLastError = true)]
        private static extern IntPtr SetWindowsHookEx(int idHook, HookProc callback, IntPtr module, uint threadId);

        [DllImport("user32.dll")]
        private static extern bool UnhookWindowsHookEx(IntPtr hook);

        [DllImport("user32.dll")]
        private static extern IntPtr CallNextHookEx(IntPtr hook, int code, IntPtr wParam, IntPtr lParam);

        [DllImport("user32.dll")]
        private static extern short GetAsyncKeyState(int key);

        [DllImport("user32.dll")]
        private static extern bool PostThreadMessage(uint threadId, uint message, UIntPtr wParam, IntPtr lParam);

        public static bool Install(uint threadId) {
            ownerThread = threadId;
            callback = Callback;
            hook = SetWindowsHookEx(WH_KEYBOARD_LL, callback, IntPtr.Zero, 0);
            return hook != IntPtr.Zero;
        }

        public static void Uninstall() {
            if (hook != IntPtr.Zero) UnhookWindowsHookEx(hook);
            hook = IntPtr.Zero;
            callback = null;
        }

        private static IntPtr Callback(int code, IntPtr wParam, IntPtr lParam) {
            if (code >= 0) {
                int message = wParam.ToInt32();
                KBDLLHOOKSTRUCT data = Marshal.PtrToStructure<KBDLLHOOKSTRUCT>(lParam);
                int key = (int)data.vkCode;
                if (key >= 0 && key < down.Length) {
                    if (message == WM_KEYUP || message == WM_SYSKEYUP) {
                        down[key] = false;
                    } else if ((message == WM_KEYDOWN || message == WM_SYSKEYDOWN) && !down[key]) {
                        down[key] = true;
                        bool shift = (GetAsyncKeyState(VK_SHIFT) & 0x8000) != 0;
                        bool control = (GetAsyncKeyState(VK_CONTROL) & 0x8000) != 0;
                        bool alt = (GetAsyncKeyState(VK_MENU) & 0x8000) != 0;
                        bool win = (GetAsyncKeyState(VK_LWIN) & 0x8000) != 0 || (GetAsyncKeyState(VK_RWIN) & 0x8000) != 0;
                        int id = 0;
                        if (key == 0x56 && control && shift && alt && !win) id = 1;
                        else if (shift && win && key == 0x42) id = 2;
                        else if (shift && win && key == 0x4F) id = 3;
                        else if (shift && win && key == 0x51) id = 4;
                        if (id != 0) PostThreadMessage(ownerThread, WM_APP_HOTKEY, (UIntPtr)(uint)id, IntPtr.Zero);
                    }
                }
            }
            return CallNextHookEx(hook, code, wParam, lParam);
        }
    }
}
'@
}

$script:TempDirectory = Join-Path $env:TEMP 'ClipboardImage'
$script:StockFile = Join-Path $script:TempDirectory '.stock.txt'
$script:StateFile = Join-Path $script:TempDirectory '.resident.json'
$script:LogFile = Join-Path $script:TempDirectory 'ClipboardImage.log'
$script:ControlLogFile = Join-Path $env:LOCALAPPDATA 'ClipboardImageHotkeys\Control.log'
$script:StartErrorFile = Join-Path $script:TempDirectory '.start-error.txt'
$script:MainScriptPath = $PSCommandPath
$script:PowerShellExecutable = Join-Path $PSHOME 'powershell.exe'
if (-not (Test-Path -LiteralPath $script:PowerShellExecutable)) {
    $script:PowerShellExecutable = 'powershell.exe'
}

function Initialize-Storage {
    if (-not (Test-Path -LiteralPath $script:TempDirectory)) {
        $null = New-Item -ItemType Directory -Path $script:TempDirectory
    }
}

function Write-UtilityLog {
    param([string]$Message)
    Initialize-Storage
    $line = '{0} {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss.fff'), $Message
    Add-Content -LiteralPath $script:LogFile -Value $line -Encoding UTF8
}

function Write-ControlLog {
    param([string]$Message)
    try {
        $timestamp = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss.fff')
        Add-Content -LiteralPath $script:ControlLogFile -Value ('{0} PID={1} {2}' -f $timestamp, $PID, $Message) -Encoding UTF8
    } catch {}
}

function Show-ControlError {
    param(
        [string]$Title,
        [string]$Message
    )
    try {
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

function Hide-ConsoleWindow {
    $consoleWindow = [ClipboardImage.NativeMethods]::GetConsoleWindow()
    if ($consoleWindow -ne [IntPtr]::Zero) {
        $null = [ClipboardImage.NativeMethods]::ShowWindow($consoleWindow, 0)
    }
}

function Get-UtilityState {
    $result = [ordered]@{
        Running = $false
        ProcessId = $null
        StartedAt = $null
        InputMode = $null
    }
    if (-not (Test-Path -LiteralPath $script:StateFile)) { return [pscustomobject]$result }

    try {
        $state = Get-Content -LiteralPath $script:StateFile -Raw -Encoding UTF8 | ConvertFrom-Json
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
    Initialize-Storage
    Remove-Item -LiteralPath $script:StateFile -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $script:StartErrorFile -Force -ErrorAction SilentlyContinue
    $process = Start-Process -FilePath $script:PowerShellExecutable -PassThru -ArgumentList @(
        '-NoProfile', '-ExecutionPolicy', 'Bypass', '-STA', '-File', ('"{0}"' -f $script:MainScriptPath),
        '-NoWindow', '-HideConsole', '-StartupErrorFile', ('"{0}"' -f $script:StartErrorFile)
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
            if (Test-Path -LiteralPath $script:StartErrorFile) {
                $capturedError = Get-Content -LiteralPath $script:StartErrorFile -Raw -ErrorAction SilentlyContinue
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
        & $script:PowerShellExecutable -NoProfile -ExecutionPolicy Bypass -STA -File $script:MainScriptPath -Action Stop | Out-Null
        $deadline = (Get-Date).AddSeconds(5)
        while ((Get-UtilityState).Running -and (Get-Date) -lt $deadline) {
            Start-Sleep -Milliseconds 100
        }
    }
    if (-not (Get-UtilityState).Running) {
        Remove-Item -LiteralPath $script:StateFile -Force -ErrorAction SilentlyContinue
    } else {
        throw 'Clipboard Image Hotkeysを5秒以内に停止できませんでした。'
    }
}

function Restart-Utility {
    Stop-Utility
    Start-Utility
}

function Show-ControlWindow {
    [System.Windows.Forms.Application]::EnableVisualStyles()

    $existingWindow = [ClipboardImage.NativeMethods]::FindWindow($null, 'Clipboard Image Hotkeys')
    if ($existingWindow -ne [IntPtr]::Zero) {
        $null = [ClipboardImage.NativeMethods]::ShowWindow($existingWindow, 5)
        $null = [ClipboardImage.NativeMethods]::SetForegroundWindow($existingWindow)
        Write-ControlLog 'Existing control window activated.'
        return
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
                Hide-ConsoleWindow
            }
        } catch {
            Write-ControlLog ('Console hide failed; leaving it visible: {0}' -f $_.Exception.Message)
        }
        Update-WindowStateSafely
        try {
            $null = [ClipboardImage.NativeMethods]::SetForegroundWindow($form.Handle)
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

function Invoke-ClipboardOperation {
    param([scriptblock]$Operation)
    $lastError = $null
    foreach ($attempt in 1..10) {
        try { return & $Operation }
        catch {
            $lastError = $_
            Start-Sleep -Milliseconds 60
        }
    }
    throw $lastError
}

function Get-ClipboardBitmap {
    $image = Invoke-ClipboardOperation {
        if (-not [System.Windows.Forms.Clipboard]::ContainsImage()) { return $null }
        [System.Windows.Forms.Clipboard]::GetImage()
    }
    if ($null -eq $image) { return $null }
    try { return New-Object System.Drawing.Bitmap $image }
    finally { $image.Dispose() }
}

function Save-BitmapTemporary {
    param([System.Drawing.Bitmap]$Bitmap)
    Initialize-Storage
    $name = 'clip-{0}-{1}.png' -f (Get-Date -Format 'yyyyMMdd-HHmmss-fff'), ([Guid]::NewGuid().ToString('N').Substring(0, 6))
    $path = Join-Path $script:TempDirectory $name
    $Bitmap.Save($path, [System.Drawing.Imaging.ImageFormat]::Png)
    return $path
}

function Set-ClipboardFileDrop {
    param(
        [string[]]$Paths,
        [System.Drawing.Bitmap]$Bitmap
    )
    $files = New-Object System.Collections.Specialized.StringCollection
    foreach ($path in $Paths) { $null = $files.Add([System.IO.Path]::GetFullPath($path)) }
    $data = New-Object System.Windows.Forms.DataObject
    $data.SetFileDropList($files)
    if ($null -ne $Bitmap) { $data.SetImage($Bitmap) }
    Invoke-ClipboardOperation { [System.Windows.Forms.Clipboard]::SetDataObject($data, $true) }
}

function Get-StockPaths {
    if (-not (Test-Path -LiteralPath $script:StockFile)) { return @() }
    return @(
        Get-Content -LiteralPath $script:StockFile -Encoding UTF8 |
            Where-Object { $_ -and (Test-Path -LiteralPath $_ -PathType Leaf) } |
            Select-Object -Unique
    )
}

function Set-StockPaths {
    param([string[]]$Paths)
    Initialize-Storage
    if ($Paths.Count -eq 0) {
        Remove-Item -LiteralPath $script:StockFile -Force -ErrorAction SilentlyContinue
    } else {
        Set-Content -LiteralPath $script:StockFile -Value $Paths -Encoding UTF8
    }
}

function Invoke-Cleanup {
    Initialize-Storage
    $cutoff = (Get-Date).AddHours(-1 * $MaxAgeHours)
    $files = @(Get-ChildItem -LiteralPath $script:TempDirectory -Filter 'clip-*.png' -File | Sort-Object LastWriteTime -Descending)
    $remove = @($files | Where-Object { $_.LastWriteTime -lt $cutoff })
    if ($files.Count -gt $MaxFiles) { $remove += $files | Select-Object -Skip $MaxFiles }
    foreach ($file in @($remove | Sort-Object FullName -Unique)) {
        Remove-Item -LiteralPath $file.FullName -Force -ErrorAction SilentlyContinue
    }
    Set-StockPaths @(Get-StockPaths)
}

function Save-CurrentClipboardImage {
    $bitmap = Get-ClipboardBitmap
    if ($null -eq $bitmap) { throw 'Clipboardに画像がありません。' }
    try { return Save-BitmapTemporary -Bitmap $bitmap }
    finally { $bitmap.Dispose() }
}

function Invoke-Convert {
    $bitmap = Get-ClipboardBitmap
    if ($null -eq $bitmap) { throw 'Clipboardに画像がありません。' }
    try {
        $path = Save-BitmapTemporary -Bitmap $bitmap
        Set-ClipboardFileDrop -Paths @($path) -Bitmap $bitmap
        Write-UtilityLog "Converted: $path"
        return $path
    } finally { $bitmap.Dispose() }
}

function Invoke-Stock {
    $path = Save-CurrentClipboardImage
    $paths = @(Get-StockPaths) + @($path)
    Set-StockPaths $paths
    Write-UtilityLog ('Stocked ({0}): {1}' -f $paths.Count, $path)
    return $path
}

function Invoke-Publish {
    $paths = @(Get-StockPaths)
    if ($paths.Count -eq 0) { return Invoke-Convert }
    $bitmap = Get-ClipboardBitmap
    try {
        Set-ClipboardFileDrop -Paths $paths -Bitmap $bitmap
        Set-StockPaths @()
        Write-UtilityLog ('Published stock: {0} file(s)' -f $paths.Count)
        return $paths
    } finally { if ($null -ne $bitmap) { $bitmap.Dispose() } }
}

function Invoke-Open {
    $path = Save-CurrentClipboardImage
    if (-not $SuppressExplorer) {
        Start-Process -FilePath 'explorer.exe' -ArgumentList ('/select,"{0}"' -f $path)
    }
    Write-UtilityLog "Opened: $path"
    return $path
}

function Invoke-ActionSafely {
    param([scriptblock]$Operation, [string]$Name)
    try {
        $null = & $Operation
        Invoke-Cleanup
    } catch {
        Write-UtilityLog ("$Name failed: " + $_.Exception.Message)
        [System.Media.SystemSounds]::Exclamation.Play()
    }
}

function Stop-Resident {
    if (-not (Test-Path -LiteralPath $script:StateFile)) { return $false }
    try {
        $state = Get-Content -LiteralPath $script:StateFile -Raw -Encoding UTF8 | ConvertFrom-Json
        $process = Get-Process -Id $state.ProcessId -ErrorAction SilentlyContinue
        if ($null -eq $process) {
            Remove-Item -LiteralPath $script:StateFile -Force -ErrorAction SilentlyContinue
            return $false
        }
        $stateStartedAt = [DateTimeOffset]::Parse([string]$state.StartedAt).LocalDateTime
        if ([math]::Abs(($process.StartTime - $stateStartedAt).TotalMinutes) -ge 2) {
            Remove-Item -LiteralPath $script:StateFile -Force -ErrorAction SilentlyContinue
            return $false
        }
        return [ClipboardImage.NativeMethods]::PostThreadMessage([uint32]$state.ThreadId, 0x0012, [UIntPtr]::Zero, [IntPtr]::Zero)
    } catch { return $false }
}

function Start-Resident {
    if ([Threading.Thread]::CurrentThread.ApartmentState -ne 'STA') {
        throw '常駐実行にはSTAが必要です。powershell.exe -STA -File ClipboardImage.ps1 -NoWindow で起動してください。'
    }

    $created = $false
    $mutex = New-Object Threading.Mutex($true, 'Local\ClipboardImageHotkeys', [ref]$created)
    if (-not $created) { $mutex.Dispose(); throw 'ClipboardImageは既に実行中です。' }

    $hotkeys = @(
        @{ Id = 1; Key = 0x56; Modifiers = [uint32](0x0001 -bor 0x0002 -bor 0x0004 -bor 0x4000); Display = 'Ctrl+Shift+Alt+V'; Name = 'Publish' },
        @{ Id = 2; Key = 0x42; Modifiers = [uint32](0x0004 -bor 0x0008 -bor 0x4000); Display = 'Win+Shift+B'; Name = 'Stock' },
        @{ Id = 3; Key = 0x4F; Modifiers = [uint32](0x0004 -bor 0x0008 -bor 0x4000); Display = 'Win+Shift+O'; Name = 'Open' },
        @{ Id = 4; Key = 0x51; Modifiers = [uint32](0x0004 -bor 0x0008 -bor 0x4000); Display = 'Win+Shift+Q'; Name = 'Quit' }
    )
    $registered = New-Object System.Collections.Generic.List[int]
    $hookInstalled = $false
    try {
        $registrationFailed = $false
        foreach ($hotkey in $hotkeys) {
            if (-not [ClipboardImage.NativeMethods]::RegisterHotKey([IntPtr]::Zero, $hotkey.Id, $hotkey.Modifiers, $hotkey.Key)) {
                $registrationFailed = $true
                Write-UtilityLog ('RegisterHotKey conflict: {0}' -f $hotkey.Display)
                break
            }
            $registered.Add($hotkey.Id)
        }

        $inputMode = 'RegisterHotKey'
        if ($registrationFailed) {
            foreach ($id in $registered) { $null = [ClipboardImage.NativeMethods]::UnregisterHotKey([IntPtr]::Zero, $id) }
            $registered.Clear()
            $hookInstalled = [ClipboardImage.KeyboardHook]::Install([ClipboardImage.NativeMethods]::GetCurrentThreadId())
            if (-not $hookInstalled) { throw 'グローバルホットキーとキーボードフックの両方を登録できませんでした。' }
            $inputMode = 'KeyboardHookFallback'
        }

        Initialize-Storage
        $state = [ordered]@{
            ProcessId = $PID
            ThreadId = [ClipboardImage.NativeMethods]::GetCurrentThreadId()
            StartedAt = (Get-Date).ToString('o')
            ScriptPath = $PSCommandPath
            InputMode = $inputMode
        }
        $state | ConvertTo-Json | Set-Content -LiteralPath $script:StateFile -Encoding UTF8
        Invoke-Cleanup
        Write-UtilityLog 'Resident started.'

        $message = New-Object ClipboardImage.NativeMethods+MSG
        while ([ClipboardImage.NativeMethods]::GetMessage([ref]$message, [IntPtr]::Zero, 0, 0) -gt 0) {
            if ($message.message -ne 0x0312 -and $message.message -ne 0x8001) { continue }
            switch ([int]$message.wParam.ToUInt64()) {
                1 { Invoke-ActionSafely { Invoke-Publish } 'Publish' }
                2 { Invoke-ActionSafely { Invoke-Stock } 'Stock' }
                3 { Invoke-ActionSafely { Invoke-Open } 'Open' }
                4 { break }
            }
            if ([int]$message.wParam.ToUInt64() -eq 4) { break }
        }
    } finally {
        foreach ($id in $registered) { $null = [ClipboardImage.NativeMethods]::UnregisterHotKey([IntPtr]::Zero, $id) }
        if ($hookInstalled) { [ClipboardImage.KeyboardHook]::Uninstall() }
        Remove-Item -LiteralPath $script:StateFile -Force -ErrorAction SilentlyContinue
        Write-UtilityLog 'Resident stopped.'
        $mutex.ReleaseMutex()
        $mutex.Dispose()
    }
}

Initialize-Storage
switch ($Action) {
    'Run'     {
        if ($NoWindow) {
            if ((Get-UtilityState).Running) {
                Write-ControlLog ('Resident already running; showing control window. HideConsole={0}' -f [bool]$HideConsole)
                Show-ControlWindow
            } else {
                if ($HideConsole) { Hide-ConsoleWindow }
                Start-Resident
            }
        } else {
            try {
                Write-ControlLog ('Control started from main script. HideConsole={0}' -f [bool]$HideConsole)
                Show-ControlWindow
            } catch {
                Write-ControlLog ('Fatal control error: {0}' -f $_.Exception.Message)
                Show-ControlError -Title 'Clipboard Image Hotkeys エラー' -Message $_.Exception.Message
                exit 1
            }
        }
    }
    'Convert' { Invoke-Convert }
    'Stock'   { Invoke-Stock; Invoke-Cleanup }
    'Publish' { Invoke-Publish; Invoke-Cleanup }
    'Open'    { Invoke-Open; Invoke-Cleanup }
    'Cleanup' { Invoke-Cleanup }
    'Status'  {
        $running = $false
        if (Test-Path -LiteralPath $script:StateFile) {
            try {
                $state = Get-Content -LiteralPath $script:StateFile -Raw -Encoding UTF8 | ConvertFrom-Json
                $process = Get-Process -Id $state.ProcessId -ErrorAction SilentlyContinue
                if ($null -ne $process) {
                    $stateStartedAt = [DateTimeOffset]::Parse([string]$state.StartedAt).LocalDateTime
                    $running = [math]::Abs(($process.StartTime - $stateStartedAt).TotalMinutes) -lt 2
                }
            } catch {}
        }
        [pscustomobject]@{
            Running = $running
            StockCount = @(Get-StockPaths).Count
            PngCount = @(Get-ChildItem -LiteralPath $script:TempDirectory -Filter 'clip-*.png' -File).Count
            TempDirectory = $script:TempDirectory
        }
    }
    'Stop'    { Stop-Resident }
}
