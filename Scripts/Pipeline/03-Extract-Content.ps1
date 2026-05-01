#Requires -Version 5.1
<#
.SYNOPSIS
    STEP 3 — Extracts text from every file in the DB using the appropriate method:
    DOCX/PPTX/XLSX (XML), PDF (text layer or GhostScript+OCR), images (Tesseract OCR),
    EML/MSG (email body). Stores results in FileContent + FTS5 index.
    Skips files already extracted unless -Force is set.
    READ-ONLY — never modifies your files.
#>

param(
    [string]$RootPath    = "",
    [string]$DbPath      = "",
    [int]$MaxOcrPages    = 10,
    [int]$MaxWorkers     = 4,     # parallel OCR jobs (set to CPU count - 1)
    [switch]$Force
)

. "$PSScriptRoot\..\lib\Config.ps1"
. "$PSScriptRoot\..\lib\Database.ps1"
. "$PSScriptRoot\..\lib\TextExtractor.ps1"
if ($RootPath) { $script:RootPath = $RootPath }
if ($DbPath)   { $script:DbPath   = $DbPath }

Import-Module PSSQLite -ErrorAction Stop
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

# Fetch all files needing extraction
$query = if ($Force) {
    "SELECT FileID, OriginalPath, Extension FROM Files ORDER BY SizeBytes ASC"
} else {
    "SELECT f.FileID, f.OriginalPath, f.Extension FROM Files f
     LEFT JOIN FileContent fc ON fc.FileID = f.FileID
     WHERE fc.FileID IS NULL
     ORDER BY f.SizeBytes ASC"
}
$pendingFiles = Invoke-SqliteQuery -DataSource $script:DbPath -Query $query

$total   = $pendingFiles.Count
$current = 0
$success = 0; $failed = 0; $skipped = 0

Write-Host "Extracting content from $total files..." -ForegroundColor Cyan
Write-Host "(OCR-capable: Tesseract=$((Test-Path $TesseractExe)), GhostScript=$((Test-Path $GsExe)))" -ForegroundColor Gray
Write-Host ""

foreach ($row in $pendingFiles) {
    $current++

    if (-not (Test-Path $row.OriginalPath)) {
        $skipped++
        continue
    }

    $fileObj = Get-Item $row.OriginalPath -ErrorAction SilentlyContinue
    if (-not $fileObj) { $skipped++; continue }

    Write-Progress -Activity "Extracting content" `
        -Status "$current / $total — $($fileObj.Name)" `
        -PercentComplete ([int](($current / $total) * 100))

    try {
        $extracted = Get-TextFromFile `
            -File          $fileObj `
            -iTextSharpDll $iTextSharpDll `
            -TesseractExe  $TesseractExe `
            -GsExe         $GsExe `
            -OcrTempDir    $OcrTempDir `
            -MaxOcrPages   $MaxOcrPages

        $contentRow = @{
            FileID           = $row.FileID
            ExtractedText    = $extracted.Text
            ExtractionMethod = $extracted.Method
            OcrConfidence    = $extracted.Confidence
            DetectedLanguage = $extracted.Language
            WordCount        = $extracted.WordCount
        }

        Set-FileContent -DbPath $script:DbPath -Row $contentRow
        Set-ProcessingStatus -DbPath $script:DbPath -FileID $row.FileID -Status "extracted"
        $success++

    } catch {
        Write-Host "  ERROR: $($fileObj.Name) — $_" -ForegroundColor Red
        # Store empty record so this file is not retried on next run
        Set-FileContent -DbPath $script:DbPath -Row @{
            FileID           = $row.FileID
            ExtractedText    = ""
            ExtractionMethod = "error"
            OcrConfidence    = 0
            DetectedLanguage = "unknown"
            WordCount        = 0
        }
        $failed++
    }
}

Write-Progress -Activity "Extracting content" -Completed

Write-Host ""
Write-Host "Extraction complete:" -ForegroundColor Green
Write-Host "  Success:  $success"
Write-Host "  Failed:   $failed  (stored as empty — check manually)"
Write-Host "  Skipped:  $skipped  (file not found on disk)"
Write-Host ""
Write-Host "Files with OCR confidence < $OcrConfidenceThreshold % are routed to _Inbox\To-Review." -ForegroundColor Gray
Write-Host ""
