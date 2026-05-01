#Requires -Version 5.1
<#
.SYNOPSIS
    Hebrew text normalization and OCR error correction.
    Must be called on raw text BEFORE any regex parsing.
    Handles: diacritics removal, quote normalization, court abbreviation variants,
    whitespace collapse, and common Tesseract OCR confusion pairs for Hebrew.
#>

# ── OCR CORRECTION DICTIONARY ─────────────────────────────────────────────────
# Maps common Tesseract misreads of Hebrew characters to correct forms.
# Keys are regex patterns; values are replacement strings.
$script:OcrCorrections = [ordered]@{
    # Court abbreviation misreads (highest priority)
    '(?<!\p{L})חא(?=\s|\d)'       = 'תא'    # ת misread as ח before number
    '(?<!\p{L})מא(?=\s|\d)'       = 'תא'    # ת misread as מ
    '(?<!\p{L})חפ(?=\s|\d)'       = 'תפ'    # criminal court
    '(?<!\p{L})חג["״]ץ'           = 'בגץ'   # HCJ

    # Common Hebrew letter confusions (final vs. medial forms)
    '(?<=\s)ן(?=\s|$)'            = 'נ'     # ן where נ expected mid-word context
    '(?<=\s)ם(?=\s|$)'            = 'מ'
    '(?<=\s)ך(?=\s|$)'            = 'כ'
    '(?<=\s)ף(?=\s|$)'            = 'פ'
    '(?<=\s)ץ(?=\s|$)'            = 'צ'

    # Very common name/word OCR errors
    'כחן'                          = 'כהן'   # ה misread as ח
    'לוי\b'                        = 'לוי'   # already correct, skip
    'ישרסל'                        = 'ישראל'
    'מישסד'                        = 'מיסד'

    # Digit/letter confusion
    '(?<=\d)S(?=\d)'               = '5'     # S misread as 5
    '(?<=\d)O(?=\d)'               = '0'     # O misread as 0
    '(?<=\d)l(?=\d)'               = '1'     # l misread as 1
    '(?<=\d)I(?=\d)'               = '1'     # I misread as 1

    # Punctuation normalization
    '״|״|''|`{2}'                  = '"'     # normalize geresh/gershayim
    '״'                        = '"'     # Hebrew gershayim → double quote
    '׳'                        = "'"     # Hebrew geresh → single quote
}

# ── PUBLIC FUNCTIONS ───────────────────────────────────────────────────────────

function Normalize-HebrewText {
    <#
    .SYNOPSIS
        Full normalization pipeline: diacritics → quotes → abbreviations →
        whitespace → case numbers. Returns cleaned text ready for parsing.
    #>
    param([string]$Text)

    if (-not $Text) { return "" }

    # 1. Remove Hebrew diacritics (ניקוד) U+05B0–U+05C7
    $t = [regex]::Replace($Text, '[ְ-ׇ]', '')

    # 2. Normalize quotation marks
    $t = $t -replace '[״׳״]', '"'
    $t = $t -replace '[“”„]', '"'
    $t = $t -replace "[‘’‚]", "'"

    # 3. Normalize court number abbreviations to canonical form
    #    ת.א. / ת"א / ת׳א → תא   (and similarly for all court types)
    $t = $t -replace 'ת["\'׳\.]?\s*א\.?', 'תא '
    $t = $t -replace 'ת["\'׳\.]?\s*פ\.?', 'תפ '
    $t = $t -replace 'ע["\'׳\.]?\s*א\.?', 'עא '
    $t = $t -replace 'ע["\'׳\.]?\s*פ\.?', 'עפ '
    $t = $t -replace 'ש["\'׳\.]?\s*א\.?', 'שא '
    $t = $t -replace 'בג["\'׳\.]?\s*ץ\.?', 'בגץ '
    $t = $t -replace 'ר["\'׳\.]?\s*מ\.?', 'רמ '    # Magistrate appeal

    # 4. Normalize slash/dash separators in case numbers (123456/24 → 123456-24)
    $t = [regex]::Replace($t, '(\d{4,8})\s*/\s*(\d{2,4})', '$1-$2')

    # 5. Collapse whitespace (but preserve newlines as paragraph breaks)
    $t = [regex]::Replace($t, '[ \t]{2,}', ' ')
    $t = [regex]::Replace($t, '(\r?\n){3,}', "`n`n")

    # 6. Strip zero-width characters
    $t = [regex]::Replace($t, '[​-‏‪-‮﻿]', '')

    return $t.Trim()
}

function Invoke-OcrCorrection {
    <#
    .SYNOPSIS
        Applies the OCR correction dictionary to text returned by Tesseract.
        Call this AFTER OCR, BEFORE Normalize-HebrewText.
    #>
    param([string]$Text)

    if (-not $Text) { return "" }

    foreach ($kv in $script:OcrCorrections.GetEnumerator()) {
        try {
            $Text = [regex]::Replace($Text, $kv.Key, $kv.Value)
        } catch {
            # Skip malformed patterns silently
        }
    }
    return $Text
}

function Get-TextHeader {
    <#
    .SYNOPSIS
        Returns the top 25% of document text (where court/case info typically appears).
        Used for layout-aware parsing — parse header first for high-confidence identifiers.
    #>
    param([string]$Text, [float]$Fraction = 0.25)

    if (-not $Text) { return "" }
    $lines      = $Text -split "`n"
    $cutoff     = [Math]::Max(1, [int]($lines.Count * $Fraction))
    return ($lines | Select-Object -First $cutoff) -join "`n"
}

function Split-DocumentSections {
    <#
    .SYNOPSIS
        Splits document text into: Header, Body, Footer.
        Header = top 20%, Footer = bottom 10%, Body = remainder.
        Used by DocumentClassifier for section-based classification.
    #>
    param([string]$Text)

    $lines  = $Text -split "`n"
    $total  = $lines.Count
    $hEnd   = [Math]::Max(1, [int]($total * 0.20))
    $fStart = [Math]::Max($hEnd + 1, [int]($total * 0.90))

    return [PSCustomObject]@{
        Header = ($lines[0..($hEnd-1)]) -join "`n"
        Body   = ($lines[$hEnd..($fStart-1)]) -join "`n"
        Footer = ($lines[$fStart..($total-1)]) -join "`n"
        Full   = $Text
    }
}
