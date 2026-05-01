#Requires -Version 5.1
<#
.SYNOPSIS
    Extracts Israeli legal identifiers from document text.
    Uses a 3-pass strategy: strict regex → fuzzy regex → heuristic context.
    Returns per-field confidence scores to prevent one weak field ruining classification.
    Must call Normalize-HebrewText (TextNormalization.ps1) on text before passing here.
#>

. "$PSScriptRoot\TextNormalization.ps1"

# ── PASS 1: STRICT PATTERNS (high precision) ──────────────────────────────────

$CASE_STRICT = @(
    # Modern court format: 123456-01-24
    '(?<case>\d{5,8}-\d{2}-\d{2})',
    # Canonical abbreviations (after normalization: תא, תפ, עא, עפ, שא, בגץ)
    '(?<case>(?:תא|תפ|עא|עפ|שא|בגץ|רמ)\s+\d{1,7}-\d{2,4})',
    '(?<case>(?:תא|תפ|עא|עפ|שא|בגץ|רמ)\s+\d{1,7}/\d{2,4})'
)

$ID_STRICT = '\b([0-9]{9})\b'   # 9 digits; validated by Luhn after match

$REPORT_STRICT = @(
    '(?:דוח|דו"ח|דו\.ח)\s+(?:מס[.\'"]?\s*|מספר\s+)(\d{4,10})',
    'report\s+(?:no\.?|number)\s*:?\s*(\d{4,10})'
)

$PROCEDURE_STRICT = @(
    'הליך\s+(?:מספר|מס[\'"]?)\s*:?\s*([\d\-/]{4,15})',
    'מספר\s+הליך\s*:?\s*([\d\-/]{4,15})'
)

# Names after strong role indicators (highest confidence)
$NAME_STRICT = @(
    '(?:התובע(?:ת)?|הנתבע(?:ת)?)\s*:\s*([^\n\r,;]{2,35})',
    '(?:לקוח|מרשי|מרשתי)\s*:\s*([^\n\r,;]{2,35})',
    '(?:שם\s+מלא)\s*:\s*([^\n\r,;]{2,25})'
)

# ── PASS 2: FUZZY PATTERNS (medium precision) ──────────────────────────────────

$CASE_FUZZY = @(
    # תיק מספר / תיק מס with various separators
    '(?<case>תיק\s+(?:מספר|מס[\'"]?|מ\')\s*:?\s*[\d\-/]{4,15})',
    # Bare court abbreviation with number (may have OCR noise around it)
    '(?<case>[תעשב][אפגץ]\s+\d{3,7})'
)

$NAME_FUZZY = @(
    # Name after "שם" (without colon — fuzzier)
    '(?:^|\n)שם[:\s]+([^\n\r,;]{2,30})',
    # English plaintiff/defendant
    '(?:plaintiff|defendant|client)\s*:\s*([a-zA-Zא-ת][a-zA-Zא-ת\s]{2,30})'
)

# ── PASS 3: HEURISTIC (context-based, lowest precision) ────────────────────────

# Look for "X נגד Y" → X is one party, Y the other
$VERSUS_PATTERN = '([^\n,;]{2,30})\s+נגד\s+([^\n,;]{2,30})'

# Court block: lines containing "בית משפט" often precede the case number
$COURT_BLOCK_PATTERN = 'בית\s+(?:המ)?שפט[^\n]{0,60}\n([^\n]{5,80})'

# ── CONTACT ROLES ─────────────────────────────────────────────────────────────

$CONTACT_ROLE_PATTERNS = @{
    'judge'              = '(?:כב[\'"]?\s+)?השופט(?:ת)?\s+([^\n\r,;]{2,30})'
    'lawyer-opposing'    = 'עו["\']?ד\s+([^\n\r,;]{2,30})(?=\s*ב"כ)'
    'police-officer'     = '(?:סמ"ר|שוטר|פקח|רב"ט|סרן|רס"מ|ניצב)\s+([^\n\r,;]{2,25})'
    'medical-expert'     = '(?:ד"ר|פרופ[\'"]?|מומחה)\s*:?\s*([^\n\r,;]{2,30})'
    'prosecutor'         = 'תובע\s+(?:פלילי|מדינה)\s*:?\s*([^\n\r,;]{2,30})'
}

# ── HEARING DETECTION ─────────────────────────────────────────────────────────

$HEARING_PATTERNS = @(
    '(?:דיון|ישיבה|שמיעה)\s+(?:מיום\s+|בתאריך\s+)?(\d{1,2}[./]\d{1,2}[./]\d{2,4})',
    'נקבע\s+לדיון\s+(?:ביום\s+)?([^\n]{5,40})',
    'hearing\s+(?:date\s+)?:?\s*(\d{1,2}[./]\d{1,2}[./]\d{2,4})'
)

# ── MAIN FUNCTION ─────────────────────────────────────────────────────────────

function Get-ParsedIdentifiers {
    <#
    .SYNOPSIS
        3-pass extraction with per-field confidence.
        Input text should already be normalized via Normalize-HebrewText.
    #>
    param([string]$Text)

    $result = [PSCustomObject]@{
        # Fields
        CaseNumber            = $null
        CaseType              = "unknown"
        ReportNumber          = $null
        ProcedureNumber       = $null
        ClientName            = $null
        ClientIDNumber        = $null
        DocumentDate          = $null
        Contacts              = @()
        HearingDates          = @()
        # Per-field confidence (0-100)
        CaseNumberConfidence  = 0
        IDConfidence          = 0
        ClientNameConfidence  = 0
        DocTypeConfidence     = 0   # set by DocumentClassifier
        # Overall weighted confidence
        OverallConfidence     = 0
    }

    if (-not $Text) { return $result }

    # Split into sections for layout-aware parsing
    $sections = Split-DocumentSections $Text

    # ── PASS 1: Strict patterns on the header first, then full text ────────────

    # Case number — header has priority
    $caseSource = $null
    foreach ($p in $CASE_STRICT) {
        if ($sections.Header -match $p) {
            $result.CaseNumber           = $Matches['case'].Trim() -replace '\s+',' '
            $result.CaseNumberConfidence = 90
            $caseSource = "header-strict"
            break
        }
    }
    if (-not $result.CaseNumber) {
        foreach ($p in $CASE_STRICT) {
            if ($Text -match $p) {
                $result.CaseNumber           = $Matches['case'].Trim() -replace '\s+',' '
                $result.CaseNumberConfidence = 75
                $caseSource = "body-strict"
                break
            }
        }
    }

    # ── PASS 2: Fuzzy if strict found nothing ─────────────────────────────────
    if (-not $result.CaseNumber) {
        foreach ($p in $CASE_FUZZY) {
            if ($Text -match $p) {
                $result.CaseNumber           = $Matches['case'].Trim() -replace '\s+',' '
                $result.CaseNumberConfidence = 50
                break
            }
        }
    }

    # ── PASS 3: Heuristic "נגד" pattern ─────────────────────────────────────
    $versusParties = $null
    if ($Text -match $VERSUS_PATTERN) {
        $versusParties = @{ Plaintiff = $Matches[1].Trim(); Defendant = $Matches[2].Trim() }
    }

    # Case type from case number prefix
    if ($result.CaseNumber) {
        switch -Regex ($result.CaseNumber) {
            'תפ|עפ|פלילי|criminal' { $result.CaseType = "criminal" }
            'עא|ערעור|appeal'      { $result.CaseType = "civil-appeal" }
            'עפ'                   { $result.CaseType = "criminal-appeal" }
            'בגץ'                  { $result.CaseType = "hcj" }
            default                { $result.CaseType = "civil" }
        }
    }

    # Report number
    foreach ($p in $REPORT_STRICT) {
        if ($Text -match $p) { $result.ReportNumber = $Matches[1]; break }
    }

    # Procedure number
    foreach ($p in $PROCEDURE_STRICT) {
        if ($Text -match $p) { $result.ProcedureNumber = $Matches[1]; break }
    }

    # Israeli ID — strict: 9-digit Luhn-valid
    $allIdMatches = [regex]::Matches($Text, $ID_STRICT)
    foreach ($m in $allIdMatches) {
        if (Test-LuhnID $m.Groups[1].Value) {
            $result.ClientIDNumber = $m.Groups[1].Value
            $result.IDConfidence   = 95   # Luhn validation makes this very reliable
            break
        }
    }

    # Client name — strict patterns first (colon present = higher confidence)
    foreach ($p in $NAME_STRICT) {
        if ($Text -match $p) {
            $name = $Matches[1].Trim() -replace '\s+',' '
            if (Test-ValidName $name) {
                $result.ClientName           = $name
                $result.ClientNameConfidence = 80
                break
            }
        }
    }
    # Fuzzy name patterns
    if (-not $result.ClientName) {
        foreach ($p in $NAME_FUZZY) {
            if ($Text -match $p) {
                $name = $Matches[1].Trim() -replace '\s+',' '
                if (Test-ValidName $name) {
                    $result.ClientName           = $name
                    $result.ClientNameConfidence = 50
                    break
                }
            }
        }
    }
    # Heuristic: take plaintiff from "נגד" pattern
    if (-not $result.ClientName -and $versusParties) {
        $name = $versusParties.Plaintiff
        if (Test-ValidName $name) {
            $result.ClientName           = $name
            $result.ClientNameConfidence = 35
        }
    }

    # Contacts (judges, opposing lawyers, etc.)
    $contacts = @()
    foreach ($role in $CONTACT_ROLE_PATTERNS.Keys) {
        $m = [regex]::Match($Text, $CONTACT_ROLE_PATTERNS[$role])
        if ($m.Success) {
            $name = $m.Groups[1].Value.Trim() -replace '\s+',' '
            if (Test-ValidName $name) {
                $contacts += [PSCustomObject]@{ Name=$name; PersonType=$role }
            }
        }
    }
    $result.Contacts = $contacts

    # Hearing dates
    $hearings = @()
    foreach ($p in $HEARING_PATTERNS) {
        $hMatches = [regex]::Matches($Text, $p)
        foreach ($hm in $hMatches) {
            $hearings += $hm.Groups[1].Value.Trim()
        }
    }
    $result.HearingDates = $hearings | Select-Object -Unique

    # Document date
    $result.DocumentDate = Get-DocumentDate $sections.Header
    if (-not $result.DocumentDate) {
        $result.DocumentDate = Get-DocumentDate $Text
    }

    # Overall weighted confidence
    $weights = @{
        CaseNumberConfidence = 0.35
        IDConfidence         = 0.30
        ClientNameConfidence = 0.25
        DocTypeConfidence    = 0.10
    }
    $overall = 0
    foreach ($kv in $weights.GetEnumerator()) {
        $overall += $result.$($kv.Key) * $kv.Value
    }
    $result.OverallConfidence = [int][Math]::Round($overall)

    return $result
}

# ── HELPERS ───────────────────────────────────────────────────────────────────

function Test-LuhnID {
    param([string]$id)
    if ($id.Length -ne 9) { return $false }
    $sum = 0
    for ($i = 0; $i -lt 9; $i++) {
        $d = [int]::Parse($id[$i].ToString())
        if ($i % 2 -eq 1) { $d *= 2; if ($d -gt 9) { $d -= 9 } }
        $sum += $d
    }
    return ($sum % 10 -eq 0)
}

function Test-ValidName {
    param([string]$name)
    if (-not $name -or $name.Length -lt 2 -or $name.Length -gt 40) { return $false }
    # Must contain Hebrew or Latin letters
    if ($name -notmatch '[א-תa-zA-Z]') { return $false }
    # Reject all-digits or all-symbols
    if ($name -match '^[\d\s\-_/\\\.,:;"]+$') { return $false }
    # Reject repeated characters (OCR garbage)
    if ($name -match '(.)\1{3,}') { return $false }
    # Reject obviously bad OCR strings
    if ($name -match '^[ְ-ׇ]+$') { return $false }
    return $true
}

function Get-DocumentDate {
    param([string]$Text)

    $gregorianPatterns = @(
        # ISO 8601
        '(?<y>\d{4})-(?<m>\d{2})-(?<d>\d{2})',
        # DD/MM/YYYY or DD.MM.YYYY
        '(?<d>\d{1,2})[./](?<m>\d{1,2})[./](?<y>\d{4})',
        # Hebrew written month name
        '(?<d>\d{1,2})\s+ב?(ינואר|פברואר|מרץ|אפריל|מאי|יוני|יולי|אוגוסט|ספטמבר|אוקטובר|נובמבר|דצמבר)\s+(?<y>\d{4})'
    )

    foreach ($p in $gregorianPatterns) {
        if ($Text -match $p) {
            $y = $Matches['y']; $m = $Matches['m']; $d = $Matches['d']
            $yi = [int]$y
            if ($yi -gt 1950 -and $yi -lt 2050) {
                return "$y-$($m.PadLeft(2,'0'))-$($d.PadLeft(2,'0'))"
            }
        }
    }
    return $null
}
