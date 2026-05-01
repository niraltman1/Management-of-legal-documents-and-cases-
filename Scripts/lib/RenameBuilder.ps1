#Requires -Version 5.1
<#
.SYNOPSIS
    Builds safe, meaningful Hebrew filenames from parsed identifiers.
    Handles: Windows max path (260 chars), illegal characters, collision prevention.
#>

$WINDOWS_MAX_PATH = 259  # leave 1 char for null terminator

# Characters illegal in Windows filenames
$ILLEGAL_CHARS = '[\\/:*?"<>|]'

function Build-SuggestedName {
    <#
    .SYNOPSIS
        Returns a safe Hebrew filename and full destination path.
        Never modifies files — only constructs the proposed names.
    #>
    param(
        [System.IO.FileInfo]$File,
        [PSCustomObject]$ParsedIds,      # from IdentifierParser
        [PSCustomObject]$Classification, # from DocumentClassifier
        [string]$RootPath,
        [string]$DbPath                  # for collision checking
    )

    $ext = $File.Extension.ToLower()

    # ── Build name segments ────────────────────────────────────────────────────

    # 1. Date prefix (YYYY-MM-DD) — document date or file date
    $datePart = $ParsedIds.DocumentDate
    if (-not $datePart) {
        $datePart = $File.LastWriteTime.ToString("yyyy-MM-dd")
    }

    # 2. Client / subject part
    $subjectPart = $null
    switch ($Classification.Domain) {
        "Legal-Case" {
            # Use client last name only (first token)
            if ($ParsedIds.ClientName) {
                $subjectPart = ($ParsedIds.ClientName -split '[\s,]+')[0]
            } elseif ($ParsedIds.ClientIDNumber) {
                $subjectPart = "ID-$($ParsedIds.ClientIDNumber.Substring(0,5))"
            }
        }
        "Legal-Research" { $subjectPart = "מחקר" }
        "Medical"        { $subjectPart = Get-MedicalSubject $Classification.SubFolder }
        "Teaching"       { $subjectPart = Get-TeachingSubject $Classification.SubFolder }
        "Personal"       { $subjectPart = "אישי" }
        default          { $subjectPart = "לסיווג" }
    }

    # 3. Case/procedure number
    $casePart = $null
    if ($ParsedIds.CaseNumber) {
        $casePart = Sanitize-NameSegment $ParsedIds.CaseNumber
    }

    # 4. Document type (Hebrew)
    $docTypePart = $null
    if ($Classification.DocumentType -and $Classification.DocumentType -ne "מסמך לא מזוהה") {
        $docTypePart = Sanitize-NameSegment $Classification.DocumentType
    }

    # ── Assemble name ──────────────────────────────────────────────────────────
    $segments = @($datePart)
    if ($subjectPart)  { $segments += Sanitize-NameSegment $subjectPart }
    if ($casePart)     { $segments += $casePart }
    if ($docTypePart)  { $segments += $docTypePart }

    $baseName = ($segments | Where-Object { $_ }) -join "_"

    # Fallback: if we got nothing useful, use original stem + hash
    if ($baseName -eq $datePart -and -not $subjectPart) {
        $hash     = Get-ShortHash $File.FullName
        $baseName = "$datePart`_$hash"
    }

    # ── Destination path ───────────────────────────────────────────────────────
    $destFolder = Resolve-DestinationFolder $ParsedIds $Classification $RootPath
    $proposed   = Join-Path $destFolder "$baseName$ext"

    # ── Collision prevention ───────────────────────────────────────────────────
    $proposed = Resolve-Collision $proposed $File.FullName $DbPath

    # ── Windows max-path guard ─────────────────────────────────────────────────
    if ($proposed.Length -gt $WINDOWS_MAX_PATH) {
        $proposed = Truncate-Path $proposed $ext
    }

    return [PSCustomObject]@{
        SuggestedName   = [System.IO.Path]::GetFileName($proposed)
        SuggestedPath   = $proposed
        DestFolder      = $destFolder
        NamingReason    = Build-Reason $ParsedIds $Classification $segments
    }
}

# ── PRIVATE HELPERS ───────────────────────────────────────────────────────────

function Sanitize-NameSegment {
    param([string]$s)
    # Remove illegal Windows filename characters
    $s = $s -replace $ILLEGAL_CHARS, ''
    # Replace spaces with hyphens for readability
    $s = $s -replace '\s+', '-'
    # Remove leading/trailing hyphens or dots
    $s = $s.Trim('-').Trim('.')
    return $s
}

function Get-ShortHash {
    param([string]$Path)
    try {
        $md5   = [System.Security.Cryptography.MD5]::Create()
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($Path)
        $hash  = $md5.ComputeHash($bytes)
        return ([BitConverter]::ToString($hash[0..1]) -replace '-','').ToLower()
    } catch { return "xxxx" }
}

function Resolve-Collision {
    <#
    .SYNOPSIS
        If the proposed path already exists on disk OR in the DB plan,
        appends a short 4-char hash to make it unique.
    #>
    param([string]$ProposedPath, [string]$OriginalPath, [string]$DbPath)

    # Check disk
    if ((Test-Path $ProposedPath) -and $ProposedPath -ne $OriginalPath) {
        $dir  = [System.IO.Path]::GetDirectoryName($ProposedPath)
        $stem = [System.IO.Path]::GetFileNameWithoutExtension($ProposedPath)
        $ext  = [System.IO.Path]::GetExtension($ProposedPath)
        $hash = Get-ShortHash $OriginalPath
        return Join-Path $dir "$stem`_$hash$ext"
    }

    # Check DB for another file already planned to this path
    if ($DbPath -and (Test-Path $DbPath)) {
        try {
            $existing = Invoke-SqliteQuery -DataSource $DbPath `
                -Query "SELECT COUNT(*) as C FROM FilePlan WHERE SuggestedPath=@p AND UserAction<>'REJECTED'" `
                -SqlParameters @{p=$ProposedPath}
            if ($existing.C -gt 0) {
                $dir  = [System.IO.Path]::GetDirectoryName($ProposedPath)
                $stem = [System.IO.Path]::GetFileNameWithoutExtension($ProposedPath)
                $ext  = [System.IO.Path]::GetExtension($ProposedPath)
                $hash = Get-ShortHash $OriginalPath
                return Join-Path $dir "$stem`_$hash$ext"
            }
        } catch { }
    }

    return $ProposedPath
}

function Truncate-Path {
    param([string]$FullPath, [string]$Ext)
    $dir       = [System.IO.Path]::GetDirectoryName($FullPath)
    $stem      = [System.IO.Path]::GetFileNameWithoutExtension($FullPath)
    $maxStem   = $WINDOWS_MAX_PATH - $dir.Length - $Ext.Length - 1
    if ($maxStem -lt 8) { $maxStem = 8 }
    $stem      = $stem.Substring(0, [Math]::Min($stem.Length, $maxStem))
    return Join-Path $dir "$stem$Ext"
}

function Resolve-DestinationFolder {
    param([PSCustomObject]$ParsedIds, [PSCustomObject]$Classification, [string]$RootPath)

    $domain = $Classification.Domain

    switch ($domain) {
        "Legal-Case" {
            # Client folder → case subfolder → document-role subfolder
            $clientSlug = Build-ClientSlug $ParsedIds
            $caseSlug   = Build-CaseSlug   $ParsedIds
            $roleFolder = $Classification.SubFolder  # e.g. "Pleadings"
            $path = Join-Path $RootPath "Legal\Clients\$clientSlug\Cases\$caseSlug\$roleFolder"
            return $path
        }
        "Legal-Research" {
            return Join-Path $RootPath $Classification.SubFolder
        }
        "Medical" {
            return Join-Path $RootPath $Classification.SubFolder
        }
        "Teaching" {
            return Join-Path $RootPath $Classification.SubFolder
        }
        "Personal" {
            return Join-Path $RootPath "Personal\Finance"
        }
        default {
            return Join-Path $RootPath "_Inbox\To-Review"
        }
    }
}

function Build-ClientSlug {
    param([PSCustomObject]$ParsedIds)
    if ($ParsedIds.ClientName) {
        $safe = Sanitize-NameSegment $ParsedIds.ClientName
        if ($ParsedIds.ClientIDNumber) {
            return "$safe`_$($ParsedIds.ClientIDNumber)"
        }
        return $safe
    }
    if ($ParsedIds.ClientIDNumber) { return "ID-$($ParsedIds.ClientIDNumber)" }
    return "לקוח-לא-זוהה"
}

function Build-CaseSlug {
    param([PSCustomObject]$ParsedIds)
    if ($ParsedIds.CaseNumber) {
        return Sanitize-NameSegment $ParsedIds.CaseNumber
    }
    return "תיק-לא-זוהה"
}

function Get-MedicalSubject {
    param([string]$SubFolder)
    $parts = $SubFolder -split '[/\\]'
    # Return the last meaningful segment
    $last = $parts | Where-Object { $_ -and $_ -notmatch '^(Medical|Courses|Year)$' } | Select-Object -Last 1
    return if ($last) { $last } else { "רפואה" }
}

function Get-TeachingSubject {
    param([string]$SubFolder)
    if ($SubFolder -match 'Car-Accident') { return "תאונות-דרכים" }
    if ($SubFolder -match 'Security')     { return "אבטחה" }
    return "הוראה"
}

function Build-Reason {
    param([PSCustomObject]$ParsedIds, [PSCustomObject]$Classification, [string[]]$Segments)
    $parts = @()
    if ($ParsedIds.CaseNumber)   { $parts += "מספר תיק: $($ParsedIds.CaseNumber)" }
    if ($ParsedIds.ClientName)   { $parts += "לקוח: $($ParsedIds.ClientName)" }
    if ($Classification.DocumentType -ne "מסמך לא מזוהה") {
        $parts += "סוג: $($Classification.DocumentType)"
    }
    $parts += "תחום: $($Classification.Domain)"
    return $parts -join " | "
}
