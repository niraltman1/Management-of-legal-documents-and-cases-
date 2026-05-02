#Requires -Version 5.1
<#
.SYNOPSIS
    STEP 2 — Scans all files under $RootPath and populates the Files table.
    Computes MD5 hash (streaming, handles large files).
    Skips files already in DB with unchanged DateModified (incremental re-scan).
    READ-ONLY — never modifies any of your files.
#>

param(
    [string]$RootPath     = "",
    [string]$DbPath       = "",
    [switch]$SkipHash,          # faster first pass — skip MD5
    [switch]$Force              # re-scan everything even if unchanged
)

. "$PSScriptRoot\..\lib\Config.ps1"
. "$PSScriptRoot\..\lib\Database.ps1"
if ($RootPath) { $script:RootPath = $RootPath }
if ($DbPath)   { $script:DbPath   = $DbPath }

Import-Module PSSQLite -ErrorAction Stop
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

Initialize-Database $script:DbPath

# ── Discover files ─────────────────────────────────────────────────────────────
$skipDirs = @("_Reports", ".git", "Scripts")
Write-Host "Scanning files under: $($script:RootPath)" -ForegroundColor Cyan

$allFiles = Get-ChildItem -Path $script:RootPath -Recurse -File -ErrorAction SilentlyContinue |
    Where-Object {
        $rel = $_.FullName.Substring($script:RootPath.Length).TrimStart('\')
        $firstSeg = ($rel -split '\\')[0]
        $firstSeg -notin $skipDirs
    }

$total   = $allFiles.Count
$current = 0
$newCount = 0; $updatedCount = 0; $skippedCount = 0

Write-Host "Found $total files. Processing..." -ForegroundColor Cyan
Write-Host ""

foreach ($file in $allFiles) {
    $current++
    Write-Progress -Activity "Scanning files" `
        -Status "$current / $total — $($file.Name)" `
        -PercentComplete ([int](($current / $total) * 100))

    # Check if already in DB and unchanged
    if (-not $Force) {
        $existing = Invoke-SqliteQuery -DataSource $script:DbPath `
            -Query "SELECT FileID, DateModified, MD5Hash FROM Files WHERE OriginalPath=@p" `
            -SqlParameters @{p=$file.FullName}

        if ($existing -and $existing.DateModified -eq $file.LastWriteTime.ToString("yyyy-MM-dd HH:mm:ss")) {
            $skippedCount++
            continue
        }
    }

    # Compute MD5 (streaming — safe for large files)
    $md5Hash = $null
    if (-not $SkipHash) {
        $md5Hash = Get-MD5Hash $file.FullName
    }

    $row = @{
        OriginalName = $file.Name
        OriginalPath = $file.FullName
        Extension    = $file.Extension.ToLower().TrimStart(".")
        SizeBytes    = $file.Length
        DateModified = $file.LastWriteTime.ToString("yyyy-MM-dd HH:mm:ss")
        DateCreated  = $file.CreationTime.ToString("yyyy-MM-dd HH:mm:ss")
        MD5Hash      = $md5Hash
        ScanDate     = (Get-Date -Format "yyyy-MM-dd HH:mm:ss")
    }

    Upsert-File -DbPath $script:DbPath -Row $row

    if ($existing) { $updatedCount++ } else { $newCount++ }
}

Write-Progress -Activity "Scanning files" -Completed

# Detect duplicates and populate Duplicates table
Write-Host "Detecting content-identical duplicates..." -ForegroundColor Cyan
$dupGroups = Get-DuplicateGroups $script:DbPath
$groupId   = 1

foreach ($group in $dupGroups) {
    $fileIds = $group.FileIDs -split ','

    # Clear old entries for this hash
    Invoke-SqliteQuery -DataSource $script:DbPath `
        -Query "DELETE FROM Duplicates WHERE GroupID IN (SELECT GroupID FROM Duplicates WHERE FileID=@id)" `
        -SqlParameters @{id=$fileIds[0]}

    # Determine recommended keep: file already in organized folder > junk location
    $files = foreach ($fid in $fileIds) {
        Invoke-SqliteQuery -DataSource $script:DbPath `
            -Query "SELECT FileID, OriginalPath, DateCreated FROM Files WHERE FileID=@id" `
            -SqlParameters @{id=$fid}
    }

    $junkPatterns = @('Desktop','Downloads','Temp','_Inbox','AppData')
    $sorted = $files | Sort-Object {
        $isJunk = $junkPatterns | Where-Object { $_.OriginalPath -like "*$_*" }
        if ($isJunk) { 1 } else { 0 }
    }, DateCreated

    $keepId = $sorted[0].FileID

    foreach ($f in $files) {
        $tier = if (($junkPatterns | Where-Object { $f.OriginalPath -like "*$_*" })) {
            "auto"    # safe to auto-quarantine
        } else {
            "review"  # both copies are in organized locations — user must decide
        }

        Invoke-SqliteQuery -DataSource $script:DbPath -Query @"
INSERT OR REPLACE INTO Duplicates (GroupID, FileID, IsRecommendedKeep, QuarantineTier, UserAction)
VALUES (@gid, @fid, @keep, @tier, 'REVIEW');
"@ -SqlParameters @{gid=$groupId; fid=$f.FileID; keep=(if ($f.FileID -eq $keepId) { 1 } else { 0 }); tier=$tier}
    }
    $groupId++
}

Write-Host ""
Write-Host "Scan complete:" -ForegroundColor Green
Write-Host "  New files:      $newCount"
Write-Host "  Updated:        $updatedCount"
Write-Host "  Skipped (unchanged): $skippedCount"
Write-Host "  Duplicate groups:    $($dupGroups.Count)"
Write-Host ""

# ── HELPER ────────────────────────────────────────────────────────────────────
function Get-MD5Hash {
    param([string]$FilePath)
    try {
        $md5    = [System.Security.Cryptography.MD5]::Create()
        $stream = [System.IO.File]::OpenRead($FilePath)
        $hash   = $md5.ComputeHash($stream)
        $stream.Close()
        return ([BitConverter]::ToString($hash) -replace '-','').ToLower()
    } catch {
        return "ERROR:$($_.Exception.Message.Substring(0,[Math]::Min(40,$_.Exception.Message.Length)))"
    }
}
