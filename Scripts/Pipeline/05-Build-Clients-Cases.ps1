#Requires -Version 5.1
<#
.SYNOPSIS
    STEP 5 — Builds the Clients and Cases tables from parsed identifiers.
    Creates per-client and per-case folder slugs.
    Links files to clients and cases in FileCaseLinks.
    Links hearing records to cases in Hearings.
    READ-ONLY on your files — only writes to the database.
#>

param(
    [string]$RootPath = "",
    [string]$DbPath   = ""
)

. "$PSScriptRoot\..\lib\Config.ps1"
. "$PSScriptRoot\..\lib\Database.ps1"
if ($RootPath) { $script:RootPath = $RootPath }
if ($DbPath)   { $script:DbPath   = $DbPath }

Import-Module PSSQLite -ErrorAction Stop
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

Write-Host "Building Clients and Cases from parsed data..." -ForegroundColor Cyan
Write-Host ""

# Fetch all parsed records that have at least a client name or case number
$parsed = Invoke-SqliteQuery -DataSource $script:DbPath -Query @"
SELECT pi.FileID, pi.ClientName, pi.ClientIDNumber, pi.CaseNumber, pi.CaseType,
       pi.ClientNameConfidence, pi.IDConfidence, pi.CaseNumberConfidence,
       fc.DetectedLanguage, f.OriginalPath
FROM ParsedIdentifiers pi
JOIN Files f ON f.FileID = pi.FileID
LEFT JOIN FileContent fc ON fc.FileID = pi.FileID
WHERE pi.ClientName IS NOT NULL OR pi.CaseNumber IS NOT NULL OR pi.ClientIDNumber IS NOT NULL
"@

$clientsCreated = 0; $casesCreated = 0; $linksCreated = 0

foreach ($row in $parsed) {

    # ── Resolve or create Client ───────────────────────────────────────────────
    $clientId = $null

    if ($row.ClientIDNumber -and $row.IDConfidence -ge 70) {
        # Best key: Luhn-validated ת.ז.
        $existing = Invoke-SqliteQuery -DataSource $script:DbPath `
            -Query "SELECT ClientID FROM Clients WHERE IDNumber=@id" `
            -SqlParameters @{id=$row.ClientIDNumber}
        if ($existing) {
            $clientId = $existing.ClientID
            # Update name if we now have one
            if ($row.ClientName -and $row.ClientNameConfidence -ge 60) {
                $parts    = $row.ClientName -split '[\s,]+', 2
                $lastName = $parts[0]; $firstName = if ($parts.Count -gt 1) { $parts[1] } else { "" }
                Invoke-SqliteQuery -DataSource $script:DbPath -Query @"
UPDATE Clients SET LastName=@ln, FirstName=@fn WHERE ClientID=@id AND (LastName IS NULL OR LastName='');
"@ -SqlParameters @{ln=$lastName; fn=$firstName; id=$clientId}
            }
        } else {
            $parts    = ($row.ClientName ?? "") -split '[\s,]+', 2
            $lastName = $parts[0]; $firstName = if ($parts.Count -gt 1) { $parts[1] } else { "" }
            $slug     = ($lastName + "_" + $firstName + "_" + $row.ClientIDNumber).Trim("_")
            $folderPath = Join-Path $script:RootPath "Legal\Clients\$slug"
            Invoke-SqliteQuery -DataSource $script:DbPath -Query @"
INSERT OR IGNORE INTO Clients (LastName, FirstName, IDNumber, FolderPath, CreatedDate)
VALUES (@ln, @fn, @id, @fp, datetime('now'));
"@ -SqlParameters @{ln=$lastName; fn=$firstName; id=$row.ClientIDNumber; fp=$folderPath}
            $clientId = (Invoke-SqliteQuery -DataSource $script:DbPath `
                -Query "SELECT last_insert_rowid() AS id").id
            $clientsCreated++
        }

    } elseif ($row.ClientName -and $row.ClientNameConfidence -ge 60) {
        # Name only (less reliable — match on name)
        $lastName = ($row.ClientName -split '[\s,]+')[0]
        $existing = Invoke-SqliteQuery -DataSource $script:DbPath `
            -Query "SELECT ClientID FROM Clients WHERE LastName=@ln AND IDNumber IS NULL" `
            -SqlParameters @{ln=$lastName}
        if ($existing) {
            $clientId = $existing.ClientID
        } else {
            $slug       = $row.ClientName -replace '\s+', '_'
            $folderPath = Join-Path $script:RootPath "Legal\Clients\$slug"
            Invoke-SqliteQuery -DataSource $script:DbPath -Query @"
INSERT OR IGNORE INTO Clients (LastName, FirstName, FolderPath, CreatedDate)
VALUES (@ln, '', @fp, datetime('now'));
"@ -SqlParameters @{ln=$lastName; fp=$folderPath}
            $clientId = (Invoke-SqliteQuery -DataSource $script:DbPath `
                -Query "SELECT last_insert_rowid() AS id").id
            $clientsCreated++
        }
    }

    # ── Resolve or create Case ─────────────────────────────────────────────────
    $caseId = $null

    if ($row.CaseNumber -and $row.CaseNumberConfidence -ge 45) {
        $existing = Invoke-SqliteQuery -DataSource $script:DbPath `
            -Query "SELECT CaseID FROM Cases WHERE CaseNumber=@cn" `
            -SqlParameters @{cn=$row.CaseNumber}
        if ($existing) {
            $caseId = $existing.CaseID
        } else {
            $caseSlug   = $row.CaseNumber -replace '[^\w\-]', '-'
            $clientSlug = if ($clientId) {
                (Invoke-SqliteQuery -DataSource $script:DbPath `
                    -Query "SELECT FolderPath FROM Clients WHERE ClientID=@id" `
                    -SqlParameters @{id=$clientId}).FolderPath
            } else { Join-Path $script:RootPath "Legal\Clients\לא-ידוע" }

            $caseFolderPath = Join-Path $clientSlug "Cases\$caseSlug"
            $isCriminal     = ($row.CaseType -eq "criminal") ? 1 : 0

            Invoke-SqliteQuery -DataSource $script:DbPath -Query @"
INSERT OR IGNORE INTO Cases (ClientID, CaseNumber, CaseType, FolderPath,
    HasInvestigationMaterials, Status)
VALUES (@cid, @cn, @ct, @fp, @crim, 'active');
"@ -SqlParameters @{
    cid=$clientId; cn=$row.CaseNumber; ct=$row.CaseType
    fp=$caseFolderPath; crim=$isCriminal
}
            $caseId = (Invoke-SqliteQuery -DataSource $script:DbPath `
                -Query "SELECT last_insert_rowid() AS id").id
            $casesCreated++
        }
    }

    # ── Link file → client and case ───────────────────────────────────────────
    if ($clientId) {
        Invoke-SqliteQuery -DataSource $script:DbPath -Query @"
INSERT OR IGNORE INTO FileClientLinks (FileID, ClientID, LinkSource)
VALUES (@fid, @cid, 'id-number-or-name');
"@ -SqlParameters @{fid=$row.FileID; cid=$clientId}
        $linksCreated++
    }

    if ($caseId) {
        Invoke-SqliteQuery -DataSource $script:DbPath -Query @"
INSERT OR IGNORE INTO FileCaseLinks (FileID, CaseID, LinkSource)
VALUES (@fid, @cid, 'case-number-match');
"@ -SqlParameters @{fid=$row.FileID; cid=$caseId}
    }
}

# Link orphaned hearings to cases where we can match case number
$hearings = Invoke-SqliteQuery -DataSource $script:DbPath `
    -Query "SELECT h.HearingID, h.SourceFileID FROM Hearings h WHERE h.CaseID IS NULL"
foreach ($h in $hearings) {
    $caseNum = (Invoke-SqliteQuery -DataSource $script:DbPath `
        -Query "SELECT CaseNumber FROM ParsedIdentifiers WHERE FileID=@fid" `
        -SqlParameters @{fid=$h.SourceFileID}).CaseNumber
    if ($caseNum) {
        $caseId = (Invoke-SqliteQuery -DataSource $script:DbPath `
            -Query "SELECT CaseID FROM Cases WHERE CaseNumber=@cn" `
            -SqlParameters @{cn=$caseNum}).CaseID
        if ($caseId) {
            Invoke-SqliteQuery -DataSource $script:DbPath `
                -Query "UPDATE Hearings SET CaseID=@cid WHERE HearingID=@hid" `
                -SqlParameters @{cid=$caseId; hid=$h.HearingID}
        }
    }
}

Write-Host "Clients created:  $clientsCreated" -ForegroundColor Green
Write-Host "Cases created:    $casesCreated"    -ForegroundColor Green
Write-Host "File links added: $linksCreated"    -ForegroundColor Green
Write-Host ""
