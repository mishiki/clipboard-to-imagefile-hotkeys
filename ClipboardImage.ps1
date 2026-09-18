[CmdletBinding()]
param(
    [ValidateSet('Run', 'Convert', 'Stock', 'Publish', 'Open', 'Cleanup', 'Status', 'Stop')]
    [string]$Action = 'Run',
    [int]$MaxAgeHours = 24,
    [int]$MaxFiles = 100,
    [switch]$SuppressExplorer
)

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
        return [ClipboardImage.NativeMethods]::PostThreadMessage([uint32]$state.ThreadId, 0x0012, [UIntPtr]::Zero, [IntPtr]::Zero)
    } catch { return $false }
}

function Start-Resident {
    if ([Threading.Thread]::CurrentThread.ApartmentState -ne 'STA') {
        throw '常駐実行にはSTAが必要です。powershell.exe -STA -File ClipboardImage.ps1 で起動してください。'
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
    'Run'     { Start-Resident }
    'Convert' { Invoke-Convert }
    'Stock'   { Invoke-Stock; Invoke-Cleanup }
    'Publish' { Invoke-Publish; Invoke-Cleanup }
    'Open'    { Invoke-Open; Invoke-Cleanup }
    'Cleanup' { Invoke-Cleanup }
    'Status'  {
        [pscustomobject]@{
            Running = (Test-Path -LiteralPath $script:StateFile)
            StockCount = @(Get-StockPaths).Count
            PngCount = @(Get-ChildItem -LiteralPath $script:TempDirectory -Filter 'clip-*.png' -File).Count
            TempDirectory = $script:TempDirectory
        }
    }
    'Stop'    { Stop-Resident }
}
