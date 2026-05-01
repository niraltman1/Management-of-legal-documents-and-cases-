#Requires -Version 5.1
<#
.SYNOPSIS
    Creates the complete folder taxonomy under $RootPath.
    Safe to re-run — never deletes or overwrites existing files.
    Client and case folders are created dynamically by the pipeline; this
    script creates only the static, domain-level structure.
#>

param(
    [string]$RootPath = ""
)

. "$PSScriptRoot\..\lib\Config.ps1"
if ($RootPath) { $script:RootPath = $RootPath }

[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
Write-Host ""
Write-Host "יוצר מבנה תיקיות תחת: $script:RootPath" -ForegroundColor Cyan
Write-Host ""

$created = 0
$existed = 0

foreach ($rel in $FolderTree) {
    $full = Join-Path $script:RootPath $rel
    if (-not (Test-Path $full)) {
        New-Item -ItemType Directory -Path $full -Force | Out-Null
        Write-Host "  + $rel" -ForegroundColor Green
        $created++
    } else {
        $existed++
    }
}

# Drop a README in the _Inbox so the user knows what it is
$inboxReadme = Join-Path $script:RootPath "_Inbox\README.txt"
if (-not (Test-Path $inboxReadme)) {
    @"
תיקיית נחיתה — Inbox Landing Zone
====================================
כל קובץ חדש שמתקבל (מייל, USB, הורדה) יש להעביר לכאן תחילה.
הסקריפט יסרוק, יסווג ויציע שם ותיקייה מתאימה.

New files received (email, USB, download) should go here first.
The script will scan, classify, and suggest a proper name and folder.
"@ | Set-Content -Path $inboxReadme -Encoding UTF8
}

# Drop README in _Quarantine
$qReadme = Join-Path $script:RootPath "_Quarantine\README.txt"
if (-not (Test-Path $qReadme)) {
    @"
תיקיית הסגר — Quarantine
==========================
קבצים שזוהו ככפולים ועברו לכאן אוטומטית.
לא נמחק כאן כלום — תיקיה זו נשמרת 30 יום.
הפעל Restore-Quarantine.ps1 לשחזור כל קובץ.

Files identified as probable duplicates moved here automatically.
Nothing is deleted — this folder is kept for 30 days.
Run Restore-Quarantine.ps1 to restore any file.
"@ | Set-Content -Path $qReadme -Encoding UTF8
}

Write-Host ""
Write-Host "הושלם: $created תיקיות חדשות נוצרו, $existed כבר היו קיימות." -ForegroundColor Green
Write-Host ""
