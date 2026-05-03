#Requires -Version 5.1
<#
.SYNOPSIS
    Reviews the _Quarantine folder and lets you decide what to do with each file.
    Run with -ListOnly to see quarantine contents without making any changes.
    Run with -AutoPurge to permanently delete files older than $QuarantineDays.

    Files in _Quarantine are safe — they were placed there because an identical
    copy exists in your organized folder structure. Nothing is deleted without
    your explicit confirmation.
#>

param(
    [string]$DbPath     = "",
    [switch]$ListOnly,
    [switch]$AutoPurge  # permanently delete files older than $QuarantineDays
)

. "$PSScriptRoot\..\lib\Config.ps1"
. "$PSScriptRoot\..\lib\Database.ps1"
if ($DbPath) { $script:DbPath = $DbPath }

Import-Module PSSQLite -ErrorAction Stop
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

$quarantineRoot = $script:QuarantinePath

if (-not (Test-Path $quarantineRoot)) {
    Write-Host "תיקיית _Quarantine לא נמצאה: $quarantineRoot" -ForegroundColor Yellow
    Write-Host "לא בוצעה עדיין הסגרה אוטומטית." -ForegroundColor Gray
    return
}

# ── Inventory _Quarantine ──────────────────────────────────────────────────────
$allFiles = Get-ChildItem $quarantineRoot -Recurse -File
if (-not $allFiles) {
    Write-Host "תיקיית _Quarantine ריקה — אין מה לסקור." -ForegroundColor Green
    return
}

Write-Host ""
Write-Host "══════════════════════════════════════════" -ForegroundColor Yellow
Write-Host "  סקירת תיקיית _Quarantine" -ForegroundColor Yellow
Write-Host "  סה""כ קבצים: $($allFiles.Count)" -ForegroundColor Yellow
Write-Host "══════════════════════════════════════════" -ForegroundColor Yellow
Write-Host ""

# Match each quarantined file to its ActionLog entry
$cutoffDate = (Get-Date).AddDays(-$script:QuarantineDays)
$toDelete   = @()
$toKeep     = @()

foreach ($f in $allFiles) {
    $logEntry = Invoke-SqliteQuery -DataSource $script:DbPath -Query @"
SELECT al.LogID, al.FileID, al.ActionTime, al.OldPath,
       fi.OriginalName, fi.MD5Hash
FROM ActionLog al
JOIN Files fi ON fi.FileID = al.FileID
WHERE al.NewPath = @np AND al.ActionType = 'quarantine'
ORDER BY al.LogID DESC
LIMIT 1;
"@ -SqlParameters @{np=$f.FullName}

    $ageDays   = [int]((Get-Date) - $f.LastWriteTime).TotalDays
    $isOld     = $f.LastWriteTime -lt $cutoffDate
    $sizeMB    = [math]::Round($f.Length / 1MB, 2)

    Write-Host "  ── $($f.Name)" -ForegroundColor White
    if ($logEntry) {
        Write-Host "     מקור: $($logEntry.OldPath)" -ForegroundColor Gray
        Write-Host "     הוסגר: $($logEntry.ActionTime) ($ageDays ימים)" -ForegroundColor Gray
    } else {
        Write-Host "     (לא נמצא רשומה ב-ActionLog)" -ForegroundColor DarkYellow
    }
    Write-Host "     גודל: $sizeMB MB | ישן מ-$($script:QuarantineDays) יום: $(if($isOld){'כן — ניתן למחיקה'}else{'לא עדיין'})" `
        -ForegroundColor $(if ($isOld) { "DarkYellow" } else { "Gray" })
    Write-Host ""

    if ($isOld)   { $toDelete += $f } else { $toKeep += $f }
}

Write-Host "  ניתן למחיקה (ישנים מ-$($script:QuarantineDays) יום): $($toDelete.Count)" -ForegroundColor $(if($toDelete.Count -gt 0){"Yellow"}else{"Green"})
Write-Host "  עדיין בתוך תקופת ההמתנה: $($toKeep.Count)" -ForegroundColor Gray
Write-Host ""

if ($ListOnly) {
    Write-Host "  (מצב ListOnly — לא בוצעו שינויים)" -ForegroundColor Gray
    return
}

# ── AutoPurge mode ─────────────────────────────────────────────────────────────
if ($AutoPurge) {
    if ($toDelete.Count -eq 0) {
        Write-Host "אין קבצים ישנים מספיק למחיקה אוטומטית." -ForegroundColor Green
        return
    }

    Write-Host "מחיקה אוטומטית של $($toDelete.Count) קבצים ישנים..." -ForegroundColor Yellow
    $confirm = Read-Host "  הקלד YES לאישור"
    if ($confirm -ne "YES") { Write-Host "בוטל."; return }

    $deleted = 0; $failed = 0
    foreach ($f in $toDelete) {
        try {
            Remove-Item -Path $f.FullName -Force -ErrorAction Stop
            Invoke-SqliteQuery -DataSource $script:DbPath -Query @"
UPDATE ActionLog SET ActionType='purged' WHERE NewPath=@np AND ActionType='quarantine';
"@ -SqlParameters @{np=$f.FullName}
            $deleted++
            Write-Host "  מחוק: $($f.Name)" -ForegroundColor Gray
        } catch {
            Write-Host "  FAIL: $($f.Name) — $_" -ForegroundColor Red
            $failed++
        }
    }
    Write-Host ""
    Write-Host "מחוקו: $deleted | נכשלו: $failed" -ForegroundColor Green

    # Remove empty quarantine date folders
    Get-ChildItem $quarantineRoot -Directory |
        Where-Object { (Get-ChildItem $_.FullName -File).Count -eq 0 } |
        Remove-Item -Force -ErrorAction SilentlyContinue
    return
}

# ── Interactive mode ───────────────────────────────────────────────────────────
Write-Host "  [1]  שחזר קובץ ספציפי למיקומו המקורי"
Write-Host "  [2]  מחק קבצים ישנים (ישנים מ-$($script:QuarantineDays) יום)"
Write-Host "  [0]  יציאה בלי לעשות כלום"
Write-Host ""
$choice = Read-Host "  בחר אפשרות"

switch ($choice) {
    "1" {
        Write-Host ""
        $fname = Read-Host "  הזן שם קובץ (או חלק מהשם)"
        $match = $allFiles | Where-Object { $_.Name -like "*$fname*" }
        if (-not $match) {
            Write-Host "  לא נמצא קובץ עם השם: $fname" -ForegroundColor Red
        } else {
            $match | ForEach-Object { Write-Host "  $($_.FullName)" }
            if ($match.Count -eq 1) {
                & "$PSScriptRoot\Restore-Quarantine.ps1" -DbPath $script:DbPath
            } else {
                Write-Host "  נמצאו $($match.Count) קבצים. השתמש ב-Restore-Quarantine.ps1 -FileID <id> לשחזור ספציפי." -ForegroundColor Yellow
            }
        }
    }
    "2" {
        if ($toDelete.Count -eq 0) {
            Write-Host "  אין קבצים ישנים מספיק למחיקה." -ForegroundColor Gray
        } else {
            Write-Host "  עומד למחוק $($toDelete.Count) קבצים." -ForegroundColor Yellow
            $confirm = Read-Host "  הקלד YES לאישור"
            if ($confirm -eq "YES") {
                & "$PSScriptRoot\Review-Quarantine.ps1" -DbPath $script:DbPath -AutoPurge
            } else { Write-Host "  בוטל." }
        }
    }
    default { Write-Host "  יציאה." -ForegroundColor Gray }
}

Write-Host ""
