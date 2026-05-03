#Requires -Version 5.1
<#
.SYNOPSIS
    Downloads itextsharp.dll from NuGet and places it in Scripts\lib\deps\.
    Run this once before using the pipeline.
    Requires internet access — run on your Windows PC.
#>

[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$ErrorActionPreference = "Stop"

$depsDir = Join-Path $PSScriptRoot "..\lib\deps"
if (-not (Test-Path $depsDir)) {
    New-Item -ItemType Directory -Path $depsDir -Force | Out-Null
}

$dllPath = Join-Path $depsDir "itextsharp.dll"

if (Test-Path $dllPath) {
    Write-Host "itextsharp.dll כבר קיים: $dllPath" -ForegroundColor Green
    Write-Host "אין צורך בהורדה מחדש." -ForegroundColor Gray
    exit 0
}

Write-Host "מוריד iTextSharp 5.5.13.3 מ-NuGet..." -ForegroundColor Cyan

$nupkgUrl  = "https://www.nuget.org/api/v2/package/iTextSharp/5.5.13.3"
$nupkgPath = Join-Path $env:TEMP "itextsharp_5513.nupkg"

try {
    # Download
    $wc = New-Object System.Net.WebClient
    $wc.DownloadFile($nupkgUrl, $nupkgPath)
    Write-Host "  הורד: $([math]::Round((Get-Item $nupkgPath).Length/1MB,1)) MB" -ForegroundColor Gray

    # Extract the DLL from the ZIP-structured .nupkg
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $zip   = [System.IO.Compression.ZipFile]::OpenRead($nupkgPath)
    $entry = $zip.Entries | Where-Object { $_.FullName -eq "lib/net40/itextsharp.dll" }

    if (-not $entry) {
        $zip.Dispose()
        throw "לא נמצא lib/net40/itextsharp.dll בחבילת NuGet"
    }

    [System.IO.Compression.ZipFileExtensions]::ExtractToFile($entry, $dllPath, $true)
    $zip.Dispose()

    # Verify
    $size = [math]::Round((Get-Item $dllPath).Length / 1MB, 1)
    Write-Host ""
    Write-Host "  הותקן בהצלחה: $dllPath ($size MB)" -ForegroundColor Green
    Write-Host ""
    Write-Host "כעת תוכל להריץ: .\Scripts\START-HERE.ps1" -ForegroundColor Cyan

} catch {
    Write-Host ""
    Write-Host "שגיאה בהורדה אוטומטית: $_" -ForegroundColor Red
    Write-Host ""
    Write-Host "הורדה ידנית:" -ForegroundColor Yellow
    Write-Host "  1. עבור ל: https://www.nuget.org/packages/iTextSharp/5.5.13.3" -ForegroundColor White
    Write-Host "  2. לחץ 'Download package'" -ForegroundColor White
    Write-Host "  3. שנה סיומת .nupkg → .zip ופתח" -ForegroundColor White
    Write-Host "  4. העתק lib\net40\itextsharp.dll → $dllPath" -ForegroundColor White
    exit 1
} finally {
    if (Test-Path $nupkgPath) { Remove-Item $nupkgPath -Force -ErrorAction SilentlyContinue }
}
