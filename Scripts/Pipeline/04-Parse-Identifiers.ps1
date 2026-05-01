#Requires -Version 5.1
<#
.SYNOPSIS
    STEP 4 — Runs the 3-pass identifier extraction on every extracted text.
    Populates ParsedIdentifiers table with per-field confidence scores.
    READ-ONLY — never modifies your files.
#>

param(
    [string]$DbPath = "",
    [switch]$Force
)

. "$PSScriptRoot\..\lib\Config.ps1"
. "$PSScriptRoot\..\lib\Database.ps1"
. "$PSScriptRoot\..\lib\IdentifierParser.ps1"   # sources TextNormalization.ps1
if ($DbPath) { $script:DbPath = $DbPath }

Import-Module PSSQLite -ErrorAction Stop
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

$query = if ($Force) {
    "SELECT fc.FileID, fc.ExtractedText, fc.OcrConfidence FROM FileContent fc"
} else {
    "SELECT fc.FileID, fc.ExtractedText, fc.OcrConfidence
     FROM FileContent fc
     LEFT JOIN ParsedIdentifiers pi ON pi.FileID = fc.FileID
     WHERE pi.FileID IS NULL"
}

$rows    = Invoke-SqliteQuery -DataSource $script:DbPath -Query $query
$total   = $rows.Count
$current = 0

Write-Host "Parsing identifiers for $total files..." -ForegroundColor Cyan
Write-Host ""

foreach ($row in $rows) {
    $current++
    Write-Progress -Activity "Parsing identifiers" `
        -Status "$current / $total" `
        -PercentComplete ([int](($current / $total) * 100))

    $text = $row.ExtractedText
    if (-not $text) {
        # Store empty record
        Upsert-ParsedIdentifiers -DbPath $script:DbPath -Row @{
            FileID = $row.FileID; ClientName = $null; ClientNameConfidence = 0
            ClientIDNumber = $null; IDConfidence = 0; CaseNumber = $null
            CaseNumberConfidence = 0; CaseType = "unknown"; ReportNumber = $null
            ProcedureNumber = $null; DocumentDate = $null
            DocumentType = $null; DocumentTypeSlug = $null
            DocTypeConfidence = 0; OverallConfidence = 0
        }
        continue
    }

    # Normalize before parsing
    $normalized = Normalize-HebrewText $text
    $ids        = Get-ParsedIdentifiers $normalized

    # Penalize confidence if OCR quality was low
    $ocrPenalty = if ($row.OcrConfidence -lt 50) { 0.6 } elseif ($row.OcrConfidence -lt 70) { 0.8 } else { 1.0 }

    Upsert-ParsedIdentifiers -DbPath $script:DbPath -Row @{
        FileID               = $row.FileID
        ClientName           = $ids.ClientName
        ClientNameConfidence = [int]($ids.ClientNameConfidence * $ocrPenalty)
        ClientIDNumber       = $ids.ClientIDNumber
        IDConfidence         = [int]($ids.IDConfidence * $ocrPenalty)
        CaseNumber           = $ids.CaseNumber
        CaseNumberConfidence = [int]($ids.CaseNumberConfidence * $ocrPenalty)
        CaseType             = $ids.CaseType
        ReportNumber         = $ids.ReportNumber
        ProcedureNumber      = $ids.ProcedureNumber
        DocumentDate         = $ids.DocumentDate
        DocumentType         = $null    # set by DocumentClassifier in step 06
        DocumentTypeSlug     = $null
        DocTypeConfidence    = 0
        OverallConfidence    = [int]($ids.OverallConfidence * $ocrPenalty)
    }

    # Store contacts (judges, opposing lawyers, etc.)
    foreach ($contact in $ids.Contacts) {
        $existing = Invoke-SqliteQuery -DataSource $script:DbPath `
            -Query "SELECT ContactID FROM Contacts WHERE FullName=@n AND PersonType=@t" `
            -SqlParameters @{n=$contact.Name; t=$contact.PersonType}
        if (-not $existing) {
            Invoke-SqliteQuery -DataSource $script:DbPath -Query @"
INSERT OR IGNORE INTO Contacts (FullName, PersonType, FirstSeenFileID)
VALUES (@n, @t, @fid);
"@ -SqlParameters @{n=$contact.Name; t=$contact.PersonType; fid=$row.FileID}
        }
    }

    # Store hearing dates
    foreach ($hDate in $ids.HearingDates) {
        if ($hDate -match '\d') {
            Invoke-SqliteQuery -DataSource $script:DbPath -Query @"
INSERT OR IGNORE INTO Hearings (HearingDate, SourceFileID) VALUES (@d, @fid);
"@ -SqlParameters @{d=$hDate; fid=$row.FileID}
        }
    }

    Set-ProcessingStatus -DbPath $script:DbPath -FileID $row.FileID -Status "parsed"
}

Write-Progress -Activity "Parsing identifiers" -Completed
Write-Host ""
Write-Host "Parsing complete for $total files." -ForegroundColor Green
Write-Host ""
