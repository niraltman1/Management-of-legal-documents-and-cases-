#Requires -Version 5.1
<#
.SYNOPSIS
    STEP 8 — Executes ONLY files marked UserAction = 'APPROVED' in FilePlan.
    For each approved file:
      1. Creates the destination folder if it doesn't exist
      2. Renames and moves the file
      3. Logs every action to ActionLog (fully reversible)
      4. Updates FilePlan.UserAction = 'DONE'
      5. Saves a manifest JSON before starting (emergency restore point)

    SAFETY RULES — hard-coded, not overridable:
      * Never touches PENDING or REJECTED files
      * Never deletes anything (duplicates are quarantined, not deleted)
      * Every action written to ActionLog before execution
      * Auto-quarantine only applies to Tier='auto' duplicates
#>

param(
    [string]$RootPath     = "",
    [string]$DbPath       = "",
    [string]$CsvPath      = "",    # optional: re-import updated CSV before applying
    [switch]$WhatIf             # dry-run: show what would happen without doing it
)

. "$PSScriptRoot\..\lib\Config.ps1"
. "$PSScriptRoot\..\lib\Database.ps1"
if ($RootPath) { $script:RootPath = $RootPath }
if ($DbPath)   { $script:DbPath   = $DbPath }

Import-Module PSSQLite -ErrorAction Stop
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

$stamp = Get-Date -Format "yyyyMMdd_HHmmss"

# ── Optional: re-import CSV approvals ─────────────────────────────────────────
if ($CsvPath -and (Test-Path $CsvPath)) {
    Write-Host "Importing approvals from CSV: $CsvPath" -ForegroundColor Cyan
    $csvRows = Import-Csv -Path $CsvPath -Encoding UTF8
    $approved = $csvRows | Where-Object { $_.UserAction -eq 'APPROVED' }
    foreach ($r in $approved) {
        Invoke-SqliteQuery -DataSource $script:DbPath -Query @"
UPDATE FilePlan SET UserAction='APPROVED', ReviewedDate=datetime('now')
WHERE FileID=(SELECT FileID FROM Files WHERE OriginalPath=@p);
"@ -SqlParameters @{p=$r.OriginalPath}
    }
    Write-Host "Imported $($approved.Count) approvals." -ForegroundColor Green
}

# ── Save pre-action manifest ───────────────────────────────────────────────────
$manifestPath = Join-Path $script:OutputPath "Manifest_$stamp.json"
$manifest = Invoke-SqliteQuery -DataSource $script:DbPath -Query @"
SELECT FileID, OriginalPath, CurrentPath FROM Files;
"@
$manifest | ConvertTo-Json -Depth 3 |
    Set-Content -Path $manifestPath -Encoding UTF8
Write-Host "Manifest saved: $manifestPath" -ForegroundColor Gray

# ── Fetch approved files ───────────────────────────────────────────────────────
$approved = Invoke-SqliteQuery -DataSource $script:DbPath -Query @"
SELECT fp.FileID, fp.SuggestedPath, fp.SuggestedName,
       f.OriginalPath, f.OriginalName
FROM FilePlan fp
JOIN Files f ON f.FileID = fp.FileID
WHERE fp.UserAction = 'APPROVED';
"@

if (-not $approved) {
    Write-Host "No files marked APPROVED. Nothing to do." -ForegroundColor Yellow
    Write-Host "Edit UserAction = 'APPROVED' in the CSV or HTML report, then re-run." -ForegroundColor Yellow
    return
}

Write-Host ""
Write-Host "Files to process: $($approved.Count)" -ForegroundColor Cyan
if ($WhatIf) { Write-Host "(WhatIf mode — no files will be moved)" -ForegroundColor Yellow }
Write-Host ""

$moved = 0; $failed = 0

foreach ($file in $approved) {
    $src  = $file.OriginalPath
    $dst  = $file.SuggestedPath
    $name = $file.SuggestedName

    Write-Host "  $($file.OriginalName)" -ForegroundColor White
    Write-Host "  → $dst" -ForegroundColor Gray

    if (-not (Test-Path $src)) {
        Write-Host "  SKIP: source not found" -ForegroundColor Yellow
        continue
    }

    if ($WhatIf) { $moved++; continue }

    try {
        # Create destination folder
        $destDir = [System.IO.Path]::GetDirectoryName($dst)
        if (-not (Test-Path $destDir)) {
            New-Item -ItemType Directory -Path $destDir -Force | Out-Null
        }

        # Create criminal case חומר-חקירה subfolders if needed
        $caseType = (Invoke-SqliteQuery -DataSource $script:DbPath `
            -Query "SELECT pi.CaseType FROM ParsedIdentifiers pi WHERE pi.FileID=@fid" `
            -SqlParameters @{fid=$file.FileID}).CaseType
        if ($caseType -eq "criminal" -and $destDir -match '\\Cases\\') {
            foreach ($sub in $CriminalExtraFolders) {
                $crimDir = Join-Path (Split-Path $destDir -Parent) $sub
                if (-not (Test-Path $crimDir)) {
                    New-Item -ItemType Directory -Path $crimDir -Force | Out-Null
                }
            }
        }

        # Log BEFORE moving (so restore is possible even if move fails mid-way)
        Invoke-SqliteQuery -DataSource $script:DbPath -Query @"
INSERT INTO ActionLog (FileID, ActionTime, ActionType, OldPath, NewPath, OldName, NewName)
VALUES (@fid, datetime('now'), 'rename-move', @op, @np, @on, @nn);
"@ -SqlParameters @{
    fid=$file.FileID; op=$src; np=$dst
    on=$file.OriginalName; nn=$name
}

        # Move + rename
        Move-Item -Path $src -Destination $dst -ErrorAction Stop

        # Update DB
        Invoke-SqliteQuery -DataSource $script:DbPath -Query @"
UPDATE Files     SET CurrentPath=@dst, ProcessingStatus='done' WHERE FileID=@fid;
UPDATE FilePlan  SET UserAction='DONE', ReviewedDate=datetime('now') WHERE FileID=@fid;
"@ -SqlParameters @{dst=$dst; fid=$file.FileID}

        $moved++
        Write-Host "  OK" -ForegroundColor Green

    } catch {
        Write-Host "  FAIL: $_" -ForegroundColor Red
        $failed++
    }
}

# ── Auto-quarantine Tier='auto' duplicates ────────────────────────────────────
$autoDups = Invoke-SqliteQuery -DataSource $script:DbPath -Query @"
SELECT d.FileID, f.OriginalPath, f.OriginalName
FROM Duplicates d
JOIN Files f ON f.FileID = d.FileID
WHERE d.QuarantineTier='auto' AND d.IsRecommendedKeep=0
  AND d.UserAction='REVIEW'
  AND f.CurrentPath = f.OriginalPath;
"@

if ($autoDups) {
    Write-Host ""
    Write-Host "Auto-quarantining $($autoDups.Count) duplicate files from junk locations..." -ForegroundColor Cyan
    $qDate = Join-Path $script:QuarantinePath (Get-Date -Format "yyyy-MM-dd")
    if (-not $WhatIf -and -not (Test-Path $qDate)) {
        New-Item -ItemType Directory -Path $qDate -Force | Out-Null
    }
    foreach ($dup in $autoDups) {
        if (-not (Test-Path $dup.OriginalPath)) { continue }
        $qDest = Join-Path $qDate $dup.OriginalName
        if (Test-Path $qDest) {
            $hash  = ([System.IO.Path]::GetRandomFileName())[0..3] -join ''
            $qDest = Join-Path $qDate "$([System.IO.Path]::GetFileNameWithoutExtension($dup.OriginalName))_$hash$([System.IO.Path]::GetExtension($dup.OriginalName))"
        }
        if (-not $WhatIf) {
            Invoke-SqliteQuery -DataSource $script:DbPath -Query @"
INSERT INTO ActionLog (FileID,ActionTime,ActionType,OldPath,NewPath,OldName,NewName)
VALUES (@fid,datetime('now'),'quarantine',@op,@np,@on,@on);
"@ -SqlParameters @{fid=$dup.FileID; op=$dup.OriginalPath; np=$qDest; on=$dup.OriginalName}
            Move-Item -Path $dup.OriginalPath -Destination $qDest -ErrorAction SilentlyContinue
            Invoke-SqliteQuery -DataSource $script:DbPath -Query @"
UPDATE Duplicates SET UserAction='QUARANTINED' WHERE FileID=@fid;
UPDATE Files SET CurrentPath=@qd WHERE FileID=@fid;
"@ -SqlParameters @{fid=$dup.FileID; qd=$qDest}
        }
        Write-Host "  Quarantined: $($dup.OriginalName)" -ForegroundColor Gray
    }
}

Write-Host ""
Write-Host "Complete: $moved moved/renamed, $failed failed." -ForegroundColor Green
if ($WhatIf) { Write-Host "(WhatIf — nothing was changed)" -ForegroundColor Yellow }
Write-Host "Manifest for restore: $manifestPath" -ForegroundColor Gray
Write-Host ""
