#Requires -Version 5.1
<#
.SYNOPSIS
    Checks and installs all prerequisites for the Legal File Organizer.
    Run this ONCE before first use. Requires internet access.
    Run as Administrator for Chocolatey installs.
#>

$ErrorActionPreference = "Stop"
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

Write-Host ""
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "  Legal File Organizer — Prerequisites" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host ""

$issues = @()

# ── 1. PowerShell version ──────────────────────────────────────────────────────
Write-Host "[1/5] PowerShell version..." -NoNewline
if ($PSVersionTable.PSVersion.Major -ge 5) {
    Write-Host " OK ($($PSVersionTable.PSVersion))" -ForegroundColor Green
} else {
    Write-Host " FAIL (need 5.1+)" -ForegroundColor Red
    $issues += "PowerShell 5.1 or later required."
}

# ── 2. PSSQLite module ────────────────────────────────────────────────────────
Write-Host "[2/5] PSSQLite module..." -NoNewline
if (Get-Module -ListAvailable -Name PSSQLite) {
    Write-Host " OK" -ForegroundColor Green
} else {
    Write-Host " Installing..." -ForegroundColor Yellow
    try {
        Install-Module PSSQLite -Scope CurrentUser -Force -AllowClobber
        Write-Host "       Installed." -ForegroundColor Green
    } catch {
        Write-Host "       FAIL: $_" -ForegroundColor Red
        $issues += "PSSQLite install failed. Run: Install-Module PSSQLite -Scope CurrentUser"
    }
}

# ── 3. Tesseract OCR ──────────────────────────────────────────────────────────
Write-Host "[3/5] Tesseract OCR (Hebrew)..." -NoNewline
$tesseractPaths = @(
    "C:\Program Files\Tesseract-OCR\tesseract.exe",
    "C:\Program Files (x86)\Tesseract-OCR\tesseract.exe"
)
$tesseractExe = $tesseractPaths | Where-Object { Test-Path $_ } | Select-Object -First 1

if ($tesseractExe) {
    $hebData = Join-Path (Split-Path $tesseractExe) "tessdata\heb.traineddata"
    if (Test-Path $hebData) {
        Write-Host " OK ($tesseractExe)" -ForegroundColor Green
    } else {
        Write-Host " Tesseract found but Hebrew language pack missing." -ForegroundColor Yellow
        Write-Host "       Download heb.traineddata from:" -ForegroundColor Yellow
        Write-Host "       https://github.com/tesseract-ocr/tessdata/raw/main/heb.traineddata"
        Write-Host "       and place in: $(Split-Path $tesseractExe)\tessdata\"
        $issues += "Hebrew language pack missing for Tesseract."
    }
} else {
    Write-Host " Not found." -ForegroundColor Yellow
    Write-Host "       Install via Chocolatey (run as Admin):" -ForegroundColor Yellow
    Write-Host "       choco install tesseract" -ForegroundColor White
    Write-Host "       Then download heb.traineddata to the tessdata folder." -ForegroundColor White
    $issues += "Tesseract OCR not installed. Run: choco install tesseract"
}

# ── 4. GhostScript ────────────────────────────────────────────────────────────
Write-Host "[4/5] GhostScript (PDF to image)..." -NoNewline
$gsFound = Get-Command gswin64c.exe -ErrorAction SilentlyContinue
if (-not $gsFound) {
    $gsFound = Get-ChildItem "C:\Program Files\gs" -Filter "gswin64c.exe" -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1
}
if ($gsFound) {
    Write-Host " OK" -ForegroundColor Green
} else {
    Write-Host " Not found." -ForegroundColor Yellow
    Write-Host "       Install via Chocolatey (run as Admin):" -ForegroundColor Yellow
    Write-Host "       choco install ghostscript" -ForegroundColor White
    $issues += "GhostScript not installed (needed for scanned PDF OCR). Run: choco install ghostscript"
}

# ── 5. iTextSharp DLL ─────────────────────────────────────────────────────────
Write-Host "[5/5] iTextSharp (PDF text extraction)..." -NoNewline
$depsDir = Join-Path $PSScriptRoot "..\lib\deps"
$dll     = Join-Path $depsDir "itextsharp.dll"
if (Test-Path $dll) {
    Write-Host " OK" -ForegroundColor Green
} else {
    Write-Host " מוריד אוטומטית..." -ForegroundColor Yellow
    try {
        if (-not (Test-Path $depsDir)) { New-Item -ItemType Directory -Path $depsDir -Force | Out-Null }
        $nupkg = Join-Path $env:TEMP "itextsharp_5513.nupkg"
        (New-Object System.Net.WebClient).DownloadFile(
            "https://www.nuget.org/api/v2/package/iTextSharp/5.5.13.3", $nupkg)
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        $zip   = [System.IO.Compression.ZipFile]::OpenRead($nupkg)
        $entry = $zip.Entries | Where-Object { $_.FullName -eq "lib/net40/itextsharp.dll" }
        [System.IO.Compression.ZipFileExtensions]::ExtractToFile($entry, $dll, $true)
        $zip.Dispose()
        Remove-Item $nupkg -Force -ErrorAction SilentlyContinue
        Write-Host "       OK — הותקן ($([math]::Round((Get-Item $dll).Length/1MB,1)) MB)" -ForegroundColor Green
    } catch {
        Write-Host "       FAIL — $($_.Exception.Message)" -ForegroundColor Red
        Write-Host "       הרץ ידנית: .\Scripts\Setup\Download-Dependencies.ps1" -ForegroundColor Yellow
        $issues += "itextsharp.dll: הורדה אוטומטית נכשלה. הרץ .\Scripts\Setup\Download-Dependencies.ps1"
    }
}

# ── Summary ───────────────────────────────────────────────────────────────────
Write-Host ""
if ($issues.Count -eq 0) {
    Write-Host "All prerequisites satisfied. You are ready to run the organizer." -ForegroundColor Green
} else {
    Write-Host "Action required — $($issues.Count) issue(s):" -ForegroundColor Yellow
    $issues | ForEach-Object { Write-Host "  * $_" -ForegroundColor Yellow }
    Write-Host ""
    Write-Host "Note: Tesseract and GhostScript are optional but required for OCR" -ForegroundColor Gray
    Write-Host "      of scanned documents and images. Text-based PDFs and DOCX" -ForegroundColor Gray
    Write-Host "      files will work without them." -ForegroundColor Gray
}
Write-Host ""
