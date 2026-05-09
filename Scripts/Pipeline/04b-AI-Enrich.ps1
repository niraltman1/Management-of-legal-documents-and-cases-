#Requires -Version 5.1
<#
.SYNOPSIS
    AI enrichment pass — runs law-il-E2B on low-confidence files.
    Only touches files where OverallConfidence < 75 or DocumentType IS NULL.
    AI results are merged back only when they improve confidence.
    Requires Ollama with law-il-E2B installed (run 02b-Install-Ollama.ps1 first).
#>

param(
    [string]$RootPath = "",
    [string]$DbPath   = "",
    [int]$ConfidenceThreshold = 75   # Files below this get AI pass
)

$ScriptDir = $PSScriptRoot | Split-Path -Parent   # Scripts\
. "$ScriptDir\lib\Config.ps1"
. "$ScriptDir\lib\Database.ps1"
. "$ScriptDir\lib\LegalAI.ps1"

if ($RootPath) { $script:RootPath = $RootPath }
if ($DbPath)   { $script:DbPath   = $DbPath }

[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

Write-Host ""
Write-Host "══ 04b — AI Enrichment Pass ══" -ForegroundColor Magenta
Write-Host "  Model: $script:OllamaModel" -ForegroundColor Gray
Write-Host "  Threshold: OverallConfidence < $ConfidenceThreshold" -ForegroundColor Gray
Write-Host ""

# Guard: bail if Ollama not available
if (-not (Test-OllamaAvailable)) {
    Write-Host "  Ollama לא זמין או המודל לא מותקן — דולג על שלב AI." -ForegroundColor Yellow
    Write-Host "  כדי להתקין: .\Scripts\Setup\02b-Install-Ollama.ps1" -ForegroundColor Gray
    Write-Host ""
    exit 0
}

# Fetch candidate files
$candidates = Invoke-SqliteQuery -DataSource $script:DbPath -Query @"
SELECT pi.FileID, pi.OverallConfidence, pi.ClientIDNumber,
       pi.ClientName, pi.CaseNumber, pi.DocumentType,
       fc.ExtractedText
FROM ParsedIdentifiers pi
JOIN FileContent fc ON fc.FileID = pi.FileID
WHERE (pi.OverallConfidence < $ConfidenceThreshold OR pi.DocumentType IS NULL)
  AND fc.ExtractedText IS NOT NULL
  AND pi.AIEnriched = 0
ORDER BY pi.OverallConfidence ASC;
"@

if (-not $candidates) {
    Write-Host "  אין קבצים לעיבוד AI (כולם מעל סף הביטחון)." -ForegroundColor Green
    Write-Host ""
    exit 0
}

$total   = @($candidates).Count
$enriched = 0
$skipped  = 0

Write-Host "  מעבד $total קבצים עם AI..." -ForegroundColor Cyan
Write-Host ""

foreach ($row in @($candidates)) {
    $fid  = $row.FileID
    $text = $row.ExtractedText

    Write-Host "  [FileID $fid] conf=$($row.OverallConfidence) → " -NoNewline -ForegroundColor Gray

    $ai = Invoke-LegalAI -Text $text

    if (-not $ai) {
        Write-Host "timeout/error — skipped" -ForegroundColor DarkGray
        $skipped++
        continue
    }

    # Only apply AI result if it's more confident
    if ($ai.Confidence -le $row.OverallConfidence) {
        Write-Host "AI conf=$($ai.Confidence) — no improvement — skipped" -ForegroundColor DarkGray
        $skipped++
        continue
    }

    # Never override a Luhn-validated ת.ז. with AI guess
    $newIDNumber = $row.ClientIDNumber   # preserve original

    # Build update query — merge AI fields with existing data
    $updateParams = @{
        fid         = $fid
        confidence  = $ai.Confidence
    }

    $setClauses = @("OverallConfidence=@confidence", "AIEnriched=1")

    if ($ai.ClientName -and -not $row.ClientName) {
        $setClauses  += "ClientName=@clientName"
        $updateParams['clientName'] = $ai.ClientName
    }
    if ($ai.CaseNumber -and -not $row.CaseNumber) {
        $setClauses  += "CaseNumber=@caseNumber"
        $updateParams['caseNumber'] = $ai.CaseNumber
    }
    if ($ai.DocumentType) {
        $setClauses  += "DocumentType=@docType"
        $updateParams['docType'] = $ai.DocumentType
    }
    if ($ai.CaseType -and $ai.CaseType -ne "unknown") {
        $setClauses  += "CaseType=@caseType"
        $updateParams['caseType'] = $ai.CaseType
    }
    if ($ai.DocumentDate) {
        $setClauses  += "DocumentDate=@docDate"
        $updateParams['docDate'] = $ai.DocumentDate
    }

    $setStr = $setClauses -join ", "
    Invoke-SqliteQuery -DataSource $script:DbPath `
        -Query "UPDATE ParsedIdentifiers SET $setStr WHERE FileID=@fid" `
        -SqlParameters $updateParams

    # Log to ActionLog
    Invoke-SqliteQuery -DataSource $script:DbPath -Query @"
INSERT INTO ActionLog (FileID, ActionTime, ActionType, OldPath, NewPath, OldName, NewName)
VALUES (@fid, @ts, 'ai-enriched', '', '', 'conf=$($row.OverallConfidence)', 'conf=$($ai.Confidence)');
"@ -SqlParameters @{ fid=$fid; ts=(Get-Date -Format "o") }

    Write-Host "OK (AI conf=$($ai.Confidence), docType=$($ai.DocumentType))" -ForegroundColor Green
    $enriched++
}

Write-Host ""
Write-Host "  AI enrichment complete:" -ForegroundColor Cyan
Write-Host "    עשוי: $enriched | דולג: $skipped | סך הכל: $total" -ForegroundColor White
Write-Host ""
