#Requires -Version 5.1
<#
.SYNOPSIS
    STEP 6 — Classifies every file by domain and document type,
    then generates the rename/move plan (FilePlan table).
    All actions stay PENDING until user approves them in the CSV/HTML report.
    READ-ONLY — never modifies your files.
#>

param(
    [string]$RootPath = "",
    [string]$DbPath   = "",
    [switch]$Force
)

. "$PSScriptRoot\..\lib\Config.ps1"
. "$PSScriptRoot\..\lib\Database.ps1"
. "$PSScriptRoot\..\lib\DocumentClassifier.ps1"
. "$PSScriptRoot\..\lib\RenameBuilder.ps1"
if ($RootPath) { $script:RootPath = $RootPath }
if ($DbPath)   { $script:DbPath   = $DbPath }

Import-Module PSSQLite -ErrorAction Stop
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

$query = if ($Force) {
    "SELECT f.FileID, f.OriginalPath, f.OriginalName, f.Extension, f.SizeBytes,
            f.DateModified, fc.ExtractedText, fc.OcrConfidence,
            pi.ClientName, pi.ClientNameConfidence, pi.ClientIDNumber, pi.IDConfidence,
            pi.CaseNumber, pi.CaseNumberConfidence, pi.CaseType,
            pi.ReportNumber, pi.ProcedureNumber, pi.DocumentDate,
            pi.OverallConfidence
     FROM Files f
     LEFT JOIN FileContent fc ON fc.FileID = f.FileID
     LEFT JOIN ParsedIdentifiers pi ON pi.FileID = f.FileID"
} else {
    "SELECT f.FileID, f.OriginalPath, f.OriginalName, f.Extension, f.SizeBytes,
            f.DateModified, fc.ExtractedText, fc.OcrConfidence,
            pi.ClientName, pi.ClientNameConfidence, pi.ClientIDNumber, pi.IDConfidence,
            pi.CaseNumber, pi.CaseNumberConfidence, pi.CaseType,
            pi.ReportNumber, pi.ProcedureNumber, pi.DocumentDate,
            pi.OverallConfidence
     FROM Files f
     LEFT JOIN FileContent fc ON fc.FileID = f.FileID
     LEFT JOIN ParsedIdentifiers pi ON pi.FileID = f.FileID
     LEFT JOIN FilePlan fp ON fp.FileID = f.FileID
     WHERE fp.FileID IS NULL
       AND f.ProcessingStatus IN ('parsed','extracted')"
}

$rows    = Invoke-SqliteQuery -DataSource $script:DbPath -Query $query
$total   = $rows.Count
$current = 0

Write-Host "Classifying and planning $total files..." -ForegroundColor Cyan

# Dry-run snapshot table for this run
$runStamp = Get-Date -Format "yyyyMMdd_HHmmss"

foreach ($row in $rows) {
    $current++
    Write-Progress -Activity "Classifying" `
        -Status "$current / $total — $($row.OriginalName)" `
        -PercentComplete ([int](($current / $total) * 100))

    # Build ParsedIds object
    $parsedIds = [PSCustomObject]@{
        ClientName           = $row.ClientName
        ClientNameConfidence = $row.ClientNameConfidence ?? 0
        ClientIDNumber       = $row.ClientIDNumber
        IDConfidence         = $row.IDConfidence ?? 0
        CaseNumber           = $row.CaseNumber
        CaseNumberConfidence = $row.CaseNumberConfidence ?? 0
        CaseType             = $row.CaseType ?? "unknown"
        ReportNumber         = $row.ReportNumber
        ProcedureNumber      = $row.ProcedureNumber
        DocumentDate         = $row.DocumentDate
        OverallConfidence    = $row.OverallConfidence ?? 0
    }

    # Classify
    $text = $row.ExtractedText ?? ""
    $classification = Get-DocumentClassification `
        -Text      $text `
        -FilePath  $row.OriginalPath `
        -ParsedIds $parsedIds `
        -RootPath  $script:RootPath

    # Update DocTypeConfidence in ParsedIdentifiers
    Invoke-SqliteQuery -DataSource $script:DbPath -Query @"
UPDATE ParsedIdentifiers SET
    DocumentType = @dt, DocumentTypeSlug = @dts, DocTypeConfidence = @conf,
    OverallConfidence = @oc
WHERE FileID = @fid;
"@ -SqlParameters @{
    dt   = $classification.DocumentType
    dts  = $classification.DocumentTypeSlug
    conf = $classification.ConfidenceBonus
    oc   = [int](($parsedIds.OverallConfidence + $classification.ConfidenceBonus) / 2)
    fid  = $row.FileID
}

    # Low confidence → route to review regardless of classification
    $ocrConf = $row.OcrConfidence ?? 100
    if ($ocrConf -lt $OcrConfidenceThreshold -and $row.ExtractedText) {
        $classification.Domain    = "Unknown"
        $classification.SubFolder = "_Inbox\To-Review"
    }

    # Build filename + destination
    $fileObj = [System.IO.FileInfo]::new($row.OriginalPath)
    $plan    = Build-SuggestedName `
        -File           $fileObj `
        -ParsedIds      $parsedIds `
        -Classification $classification `
        -RootPath       $script:RootPath `
        -DbPath         $script:DbPath

    # Insert into FilePlan
    Invoke-SqliteQuery -DataSource $script:DbPath -Query @"
INSERT OR REPLACE INTO FilePlan (FileID, SuggestedPath, SuggestedName, NamingReason, UserAction)
VALUES (@fid, @sp, @sn, @nr, 'PENDING');
"@ -SqlParameters @{
    fid = $row.FileID
    sp  = $plan.SuggestedPath
    sn  = $plan.SuggestedName
    nr  = $plan.NamingReason
}

    # Dry-run snapshot
    Invoke-SqliteQuery -DataSource $script:DbPath -Query @"
INSERT OR REPLACE INTO DryRunSnapshot (RunStamp, FileID, OriginalPath, ProposedPath, ProposedName, ActionType)
VALUES (@rs, @fid, @op, @pp, @pn, 'rename-move');
"@ -SqlParameters @{
    rs  = $runStamp; fid = $row.FileID
    op  = $row.OriginalPath; pp = $plan.SuggestedPath; pn = $plan.SuggestedName
}

    # Update domain on Files table
    Invoke-SqliteQuery -DataSource $script:DbPath -Query @"
UPDATE Files SET Domain=@d, ProcessingStatus='planned' WHERE FileID=@fid;
"@ -SqlParameters @{d=$classification.Domain; fid=$row.FileID}
}

Write-Progress -Activity "Classifying" -Completed

# Export action plan CSV for user review
$csvPath = Join-Path $script:OutputPath "ActionPlan_$runStamp.csv"
$plan = Invoke-SqliteQuery -DataSource $script:DbPath -Query @"
SELECT f.OriginalName, f.OriginalPath, fp.SuggestedName, fp.SuggestedPath,
       fp.NamingReason, fp.UserAction,
       pi.CaseNumber, pi.ClientName, pi.DocumentType, pi.OverallConfidence
FROM FilePlan fp
JOIN Files f ON f.FileID = fp.FileID
LEFT JOIN ParsedIdentifiers pi ON pi.FileID = fp.FileID
WHERE fp.UserAction = 'PENDING'
ORDER BY f.OriginalPath;
"@
$plan | Export-Csv -Path $csvPath -Encoding UTF8 -NoTypeInformation

Write-Host ""
Write-Host "Classification complete." -ForegroundColor Green
Write-Host "Action plan saved to: $csvPath" -ForegroundColor Cyan
Write-Host "Review the plan, set UserAction = 'APPROVED' for files you want renamed/moved," -ForegroundColor Yellow
Write-Host "then run 08-Apply-Approved.ps1" -ForegroundColor Yellow
Write-Host ""
