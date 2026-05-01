#Requires -Version 5.1
<#
.SYNOPSIS
    Restores files from _Quarantine or reverses any rename/move from ActionLog.
    Run with -ListOnly to see what can be restored without doing anything.
    Run with -All to restore every quarantined file.
    Run with -FileID <id> to restore a specific file.
    Run with -ManifestFile <path> to restore ALL files to the state captured in the manifest.
#>

param(
    [string]$DbPath       = "",
    [switch]$ListOnly,
    [switch]$All,
    [int]$FileID          = 0,
    [string]$ManifestFile = ""
)

. "$PSScriptRoot\..\lib\Config.ps1"
. "$PSScriptRoot\..\lib\Database.ps1"
if ($DbPath) { $script:DbPath = $DbPath }

Import-Module PSSQLite -ErrorAction Stop
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

# ── Manifest restore (full rollback) ──────────────────────────────────────────
if ($ManifestFile) {
    if (-not (Test-Path $ManifestFile)) {
        Write-Error "Manifest not found: $ManifestFile"; return
    }
    $manifest = Get-Content $ManifestFile -Encoding UTF8 | ConvertFrom-Json
    Write-Host "Restoring from manifest: $ManifestFile" -ForegroundColor Yellow
    Write-Host "This will move $($manifest.Count) files back to original locations." -ForegroundColor Yellow

    if (-not $ListOnly) {
        $confirm = Read-Host "Type YES to confirm"
        if ($confirm -ne "YES") { Write-Host "Cancelled."; return }
    }

    $ok = 0; $fail = 0
    foreach ($row in $manifest) {
        $current = $row.CurrentPath
        $original = $row.OriginalPath
        if ($current -eq $original) { continue }
        if ($ListOnly) { Write-Host "  $current → $original"; continue }
        if (-not (Test-Path $current)) {
            Write-Host "  SKIP (not found): $current" -ForegroundColor Yellow; continue
        }
        try {
            $dir = [System.IO.Path]::GetDirectoryName($original)
            if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
            Move-Item -Path $current -Destination $original -ErrorAction Stop
            Invoke-SqliteQuery -DataSource $script:DbPath -Query @"
UPDATE Files SET CurrentPath=@op WHERE FileID=@fid;
"@ -SqlParameters @{op=$original; fid=$row.FileID}
            $ok++
        } catch { Write-Host "  FAIL: $current — $_" -ForegroundColor Red; $fail++ }
    }
    Write-Host "Restored: $ok, Failed: $fail" -ForegroundColor Green
    return
}

# ── ActionLog restore ──────────────────────────────────────────────────────────
$query = if ($FileID -gt 0) {
    "SELECT * FROM ActionLog WHERE FileID=$FileID ORDER BY LogID DESC"
} else {
    "SELECT * FROM ActionLog WHERE ActionType IN ('rename-move','quarantine') ORDER BY LogID DESC"
}

$logs = Invoke-SqliteQuery -DataSource $script:DbPath -Query $query

if (-not $logs) {
    Write-Host "No actions found in log." -ForegroundColor Yellow; return
}

Write-Host ""
Write-Host "Actions in log: $($logs.Count)" -ForegroundColor Cyan
Write-Host ""

if ($ListOnly) {
    $logs | ForEach-Object {
        Write-Host "  [Log $($_.LogID)] FileID=$($_.FileID) | $($_.ActionType)"
        Write-Host "    FROM: $($_.OldPath)"
        Write-Host "    TO:   $($_.NewPath)"
        Write-Host ""
    }
    return
}

$toRestore = if ($All) { $logs } elseif ($FileID -gt 0) { $logs } else {
    # Interactive selection
    $logs | ForEach-Object {
        Write-Host "  [Log $($_.LogID)] $($_.OldName) → $($_.NewName)"
        Write-Host "    TO RESTORE: $($_.OldPath)"
    }
    $ids = Read-Host "Enter LogID(s) to restore (comma-separated), or ALL"
    if ($ids -eq "ALL") { $logs } else {
        $idList = $ids -split ',' | ForEach-Object { [int]$_.Trim() }
        $logs | Where-Object { $_.LogID -in $idList }
    }
}

$ok = 0; $fail = 0
foreach ($log in $toRestore) {
    $current  = $log.NewPath
    $original = $log.OldPath

    if (-not (Test-Path $current)) {
        Write-Host "  SKIP (not found): $current" -ForegroundColor Yellow; continue
    }
    try {
        $dir = [System.IO.Path]::GetDirectoryName($original)
        if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
        Move-Item -Path $current -Destination $original -ErrorAction Stop

        Invoke-SqliteQuery -DataSource $script:DbPath -Query @"
UPDATE Files SET CurrentPath=@op WHERE FileID=@fid;
INSERT INTO ActionLog (FileID,ActionTime,ActionType,OldPath,NewPath,OldName,NewName)
VALUES (@fid,datetime('now'),'restore',@cp,@op,@nn,@on);
"@ -SqlParameters @{op=$original; fid=$log.FileID; cp=$current; nn=$log.NewName; on=$log.OldName}

        Write-Host "  Restored: $($log.NewName) → $($log.OldName)" -ForegroundColor Green
        $ok++
    } catch {
        Write-Host "  FAIL: $current — $_" -ForegroundColor Red; $fail++
    }
}
Write-Host ""
Write-Host "Restored: $ok, Failed: $fail" -ForegroundColor Green
Write-Host ""
