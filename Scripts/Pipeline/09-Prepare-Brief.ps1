#Requires -Version 5.1
<#
.SYNOPSIS
    STEP 9 — Prepares a hearing brief for each active case.
    Runs AI-powered cross-document analysis:
      - Detects chronological/factual contradictions between documents
      - Generates recommended cross-examination questions
      - Identifies the next required procedural document
      - Calculates deadlines from Rules_Engine
    Writes results to Procedural_Steps and Case_Brief tables.
    Requires: Ollama + law-il-E2B model (run Setup\02b-Install-Ollama.ps1 first).
#>

param(
    [string]$DbPath    = "",
    [string]$RootPath  = "",
    [int]$CaseID       = 0,   # 0 = process ALL active cases
    [switch]$Force,           # re-process already-analyzed cases
    [switch]$Quiet
)

$ScriptDir = $PSScriptRoot
. "$ScriptDir\..\lib\Config.ps1"
. "$ScriptDir\..\lib\Database.ps1"
. "$ScriptDir\..\Core\ProceduralEngine.ps1"

if ($DbPath)    { $script:DbPath    = $DbPath }
if ($RootPath)  { $script:RootPath  = $RootPath }

Import-Module PSSQLite -ErrorAction Stop
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

$start = Get-Date
Write-Host ""
Write-Host "══════════════════════════════════════════" -ForegroundColor Cyan
Write-Host "  STEP 9 — הכנת Brief לדיון (v3.0)" -ForegroundColor Cyan
Write-Host "══════════════════════════════════════════" -ForegroundColor Cyan
Write-Host ""

# Ensure v3.0 tables exist
Update-DatabaseSchema-v3 -DbPath $script:DbPath

# Check Ollama
if (-not (Test-OllamaAvailable)) {
    Write-Host "  ⚠ Ollama לא זמין." -ForegroundColor Yellow
    Write-Host "    כדי להפעיל ניתוח AI: הרץ .\Scripts\Setup\02b-Install-Ollama.ps1" -ForegroundColor Yellow
    Write-Host "    ניתוח פרוצדורלי יבוצע על בסיס חוקים בלבד (ללא AI)." -ForegroundColor Gray
    Write-Host ""
}

# Determine which cases to process
if ($CaseID -gt 0) {
    $cases = Invoke-SqliteQuery -DataSource $script:DbPath `
        -Query "SELECT CaseID, CaseNumber, CaseType FROM Cases WHERE CaseID=@cid" `
        -SqlParameters @{cid=$CaseID}
} else {
    $cases = Invoke-SqliteQuery -DataSource $script:DbPath `
        -Query "SELECT CaseID, CaseNumber, CaseType FROM Cases WHERE Status='active' ORDER BY CaseID"
}

if (-not $cases -or @($cases).Count -eq 0) {
    Write-Host "  אין תיקים פעילים לעיבוד." -ForegroundColor Yellow
    exit 0
}

$casesArr    = @($cases)
$totalCases  = $casesArr.Count
$doneCount   = 0
$totalSteps  = 0
$totalBriefs = 0

Write-Host "  מעבד $totalCases תיק(ים)..." -ForegroundColor Cyan
Write-Host ""

foreach ($c in $casesArr) {
    Write-Host "  ── תיק $($c.CaseNumber) ──" -ForegroundColor Yellow

    $result = Invoke-ProceduralAnalysis -DbPath $script:DbPath `
        -CaseID $c.CaseID -Force:$Force

    if ($result) {
        $totalSteps  += $result.DeadlinesCreated
        $totalBriefs += $result.BriefItemsCreated
        $doneCount++

        # Log progress
        $briefSummary = Invoke-SqliteQuery -DataSource $script:DbPath -Query @"
SELECT BriefType, COUNT(*) AS N
FROM Case_Brief WHERE CaseID=@cid GROUP BY BriefType
"@ -SqlParameters @{cid=$c.CaseID}

        if ($briefSummary) {
            foreach ($bs in @($briefSummary)) {
                $typeLabel = switch ($bs.BriefType) {
                    "contradiction"  { "סתירות" }
                    "question"       { "שאלות לחקירה נגדית" }
                    "next-document"  { "מסמך הבא מוצע" }
                    "timeline-event" { "אירועי ציר זמן" }
                    default          { $bs.BriefType }
                }
                Write-Host "    $typeLabel : $($bs.N)" -ForegroundColor Gray
            }
        }

        # Show overdue deadlines
        $overdue = Invoke-SqliteQuery -DataSource $script:DbPath -Query @"
SELECT StepName, ExpectedDate FROM Procedural_Steps
WHERE CaseID=@cid AND Status='missed'
ORDER BY ExpectedDate ASC LIMIT 3
"@ -SqlParameters @{cid=$c.CaseID}

        if ($overdue -and @($overdue).Count -gt 0) {
            Write-Host "    ⚠ מועדים שחלפו:" -ForegroundColor Red
            foreach ($od in @($overdue)) {
                Write-Host "      — $($od.StepName) ($($od.ExpectedDate))" -ForegroundColor Red
            }
        }

    } else {
        Write-Host "    דלג (כבר עובד או חסר מידע)" -ForegroundColor Gray
    }
    Write-Host ""
}

$elapsed = (Get-Date) - $start
Write-Host "══════════════════════════════════════════" -ForegroundColor Cyan
Write-Host "  סיכום Step 9:" -ForegroundColor Cyan
Write-Host "  תיקים שעובדו : $doneCount / $totalCases" -ForegroundColor White
Write-Host "  מועדי הגשה   : $totalSteps" -ForegroundColor White
Write-Host "  פריטי Brief  : $totalBriefs" -ForegroundColor White
Write-Host "  זמן ריצה     : $([int]$elapsed.TotalSeconds)s" -ForegroundColor White
Write-Host "══════════════════════════════════════════" -ForegroundColor Cyan
Write-Host ""
Write-Host "  הפק דוח HTML עדכני: .\Scripts\Pipeline\07-Generate-Report.ps1" -ForegroundColor Cyan
Write-Host "  (כרטיסיית Timeline + Brief יופיעו אוטומטית)" -ForegroundColor Gray
Write-Host ""
