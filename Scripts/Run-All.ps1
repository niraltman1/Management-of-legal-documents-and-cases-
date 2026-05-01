#Requires -Version 5.1
<#
.SYNOPSIS
    Orchestrates the full pipeline: steps 02 through 07.
    Does NOT run step 08 (Apply-Approved) — that requires explicit user confirmation.
    Safe to re-run: already-processed files are skipped automatically.
#>

param(
    [string]$RootPath  = "",
    [string]$DbPath    = "",
    [switch]$SkipHash,           # faster scan — skip MD5 (disables duplicate detection)
    [switch]$Force,              # re-process everything from scratch
    [int]$MaxOcrPages  = 10,
    [switch]$NoReport,           # skip HTML report generation
    [switch]$NoOpen              # don't auto-open report in browser
)

$ScriptDir = $PSScriptRoot
. "$ScriptDir\lib\Config.ps1"
if ($RootPath) { $script:RootPath = $RootPath }
if ($DbPath)   { $script:DbPath   = $DbPath }

[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

$start = Get-Date
Write-Host ""
Write-Host "=============================================" -ForegroundColor Cyan
Write-Host "  Legal File Organizer — Full Pipeline Run" -ForegroundColor Cyan
Write-Host "  Root: $($script:RootPath)" -ForegroundColor Cyan
Write-Host "  DB:   $($script:DbPath)" -ForegroundColor Cyan
Write-Host "=============================================" -ForegroundColor Cyan
Write-Host ""

function Run-Step {
    param([string]$Label, [string]$Script, [hashtable]$Params = @{})
    Write-Host "── $Label" -ForegroundColor Yellow
    $paramStr = $Params.GetEnumerator() |
        ForEach-Object { "-$($_.Key) '$($_.Value)'" }
    & "$ScriptDir\$Script" -RootPath $script:RootPath -DbPath $script:DbPath @Params
    if ($LASTEXITCODE -and $LASTEXITCODE -ne 0) {
        Write-Host "STEP FAILED (exit $LASTEXITCODE). Stopping." -ForegroundColor Red
        exit $LASTEXITCODE
    }
    Write-Host ""
}

Run-Step "02 — Scan files"        "Pipeline\02-Scan-Files.ps1" `
    @{ SkipHash = $SkipHash; Force = $Force }

Run-Step "03 — Extract content"   "Pipeline\03-Extract-Content.ps1" `
    @{ MaxOcrPages = $MaxOcrPages; Force = $Force }

Run-Step "04 — Parse identifiers" "Pipeline\04-Parse-Identifiers.ps1" `
    @{ Force = $Force }

Run-Step "05 — Build clients/cases" "Pipeline\05-Build-Clients-Cases.ps1" @{}

Run-Step "06 — Classify & plan"   "Pipeline\06-Classify-And-Plan.ps1" `
    @{ Force = $Force }

if (-not $NoReport) {
    Run-Step "07 — Generate report"   "Pipeline\07-Generate-Report.ps1" `
        @{ NoOpen = $NoOpen }
}

$elapsed = (Get-Date) - $start
Write-Host ""
Write-Host "Pipeline complete in $([int]$elapsed.TotalMinutes)m $($elapsed.Seconds)s" -ForegroundColor Green
Write-Host ""
Write-Host "Next steps:" -ForegroundColor Cyan
Write-Host "  1. Review the HTML report that just opened in your browser."
Write-Host "  2. Check the Action Plan tab — review proposed renames."
Write-Host "  3. Edit ActionPlan_*.csv: set UserAction = 'APPROVED' for files you want moved."
Write-Host "  4. Run: .\Scripts\Action\08-Apply-Approved.ps1 -CsvPath '<path to CSV>'"
Write-Host ""
