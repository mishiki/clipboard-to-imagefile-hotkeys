[CmdletBinding()]
param(
    [switch]$ReadCurrentClipboard,
    [string]$ScriptPath = (Join-Path $PSScriptRoot '..\ClipboardImage.ps1')
)

# Exercises in-memory data objects only. The optional live check is read-only.
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
$source = $ScriptPath
$tokens = $null
$parseErrors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($source, [ref]$tokens, [ref]$parseErrors)
if ($parseErrors.Count) { throw ($parseErrors | Out-String) }
foreach ($name in @('Invoke-ClipboardOperation', 'ConvertFrom-ClipboardDataObject', 'Get-ClipboardBitmap', 'Set-ClipboardFileDrop')) {
    $definition = $ast.Find({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name }, $true)
    if ($null -eq $definition) { throw "Missing function: $name" }
    . ([scriptblock]::Create($definition.Extent.Text))
}

function Assert-Pixels($Image, $Expected) {
    if ($Image.Width -ne $Expected.Width -or $Image.Height -ne $Expected.Height) { throw 'Image dimensions differ.' }
    for ($y = 0; $y -lt $Image.Height; $y++) {
        for ($x = 0; $x -lt $Image.Width; $x++) {
            if ($Image.GetPixel($x, $y).ToArgb() -ne $Expected.GetPixel($x, $y).ToArgb()) {
                throw "Pixel mismatch at $x,$y"
            }
        }
    }
}

$expected = New-Object System.Drawing.Bitmap 3, 1
$fallback = New-Object System.Drawing.Bitmap 3, 1
$encoded = New-Object System.IO.MemoryStream
try {
    $expected.SetPixel(0, 0, [System.Drawing.Color]::FromArgb(0, 0, 0, 0))
    $expected.SetPixel(1, 0, [System.Drawing.Color]::FromArgb(128, 120, 60, 30))
    $expected.SetPixel(2, 0, [System.Drawing.Color]::FromArgb(255, 10, 20, 30))
    $fallback.SetPixel(0, 0, [System.Drawing.Color]::Red)
    $expected.Save($encoded, [System.Drawing.Imaging.ImageFormat]::Png)
    $bytes = $encoded.ToArray()

    foreach ($kind in @('PngOnly', 'PngPreferred', 'Bytes', 'Malformed', 'BitmapOnly', 'Empty')) {
        $data = New-Object System.Windows.Forms.DataObject
        $stream = New-Object System.IO.MemoryStream
        try {
            if ($kind -in @('PngOnly', 'PngPreferred')) {
                $stream.Write($bytes, 0, $bytes.Length) # Deliberately at EOF.
                $data.SetData('PNG', $false, $stream)
            }
            if ($kind -eq 'Bytes') { $data.SetData('PNG', $false, $bytes) }
            if ($kind -eq 'Malformed') {
                $stream.WriteByte(1)
                $data.SetData('PNG', $false, $stream)
            }
            if ($kind -in @('PngPreferred', 'Malformed', 'BitmapOnly')) { $data.SetImage($fallback) }
            $actual = ConvertFrom-ClipboardDataObject $data
            $stream.Dispose() # Returned bitmap must be independent of the input.
            try {
                if ($kind -eq 'Empty') {
                    if ($null -ne $actual) { throw 'Empty clipboard returned an image.' }
                } elseif ($kind -in @('Malformed', 'BitmapOnly')) {
                    Assert-Pixels $actual $fallback
                } else {
                    Assert-Pixels $actual $expected
                    $roundtrip = New-Object System.IO.MemoryStream
                    try { $actual.Save($roundtrip, [System.Drawing.Imaging.ImageFormat]::Png) }
                    finally { $roundtrip.Dispose() }
                }
            } finally { if ($null -ne $actual) { $actual.Dispose() } }
            "PASS $kind"
        } finally { $stream.Dispose() }
    }

    # Intercept the write operation and inspect its data while streams are alive.
    function Invoke-ClipboardOperation {
        param([scriptblock]$Operation)
        if (-not $data.GetDataPresent('PNG', $false)) { throw 'Published data has no PNG.' }
        if (-not $data.ContainsFileDropList() -or -not $data.ContainsImage()) { throw 'Published data lost existing formats.' }
        $published = ConvertFrom-ClipboardDataObject $data
        try { Assert-Pixels $published $expected }
        finally { $published.Dispose() }
        $script:publishChecked = $true
    }
    $script:publishChecked = $false
    Set-ClipboardFileDrop -Paths @((Join-Path $env:TEMP 'clipboard-png-test.png')) -Bitmap $expected
    if (-not $script:publishChecked) { throw 'Publish path was not exercised.' }
    'PASS published PNG, Bitmap and FileDrop (no clipboard write)'

    if ($ReadCurrentClipboard) {
        $definition = $ast.Find({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Invoke-ClipboardOperation' }, $true)
        . ([scriptblock]::Create($definition.Extent.Text))
        $data = [System.Windows.Forms.Clipboard]::GetDataObject()
        $png = $data.GetData('PNG', $false)
        if ($null -eq $png) { throw 'Live clipboard has no PNG for comparison.' }
        $reference = [System.Drawing.Bitmap]::FromStream($png)
        $actual = Get-ClipboardBitmap
        try {
            Assert-Pixels $actual $reference
            $savedPath = Join-Path $env:TEMP ('clipboard-png-check-' + [guid]::NewGuid().ToString('N') + '.png')
            $actual.Save($savedPath, [System.Drawing.Imaging.ImageFormat]::Png)
            $saved = [System.Drawing.Bitmap]::FromFile($savedPath)
            try { Assert-Pixels $saved $reference }
            finally { $saved.Dispose(); Remove-Item -LiteralPath $savedPath }
            "PASS live PNG: $($actual.Width)x$($actual.Height), every ARGB pixel matches"
        } finally {
            $actual.Dispose()
            $reference.Dispose()
            $png.Dispose()
        }
    }
} finally {
    $encoded.Dispose()
    $expected.Dispose()
    $fallback.Dispose()
}
