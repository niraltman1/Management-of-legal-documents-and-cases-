#Requires -Version 5.1
<#
.SYNOPSIS
    PowerShell wrapper for the BrainboxAI/law-il-E2B Israeli legal AI model via Ollama.
    Uses the official 5-step reasoning structure. Runs 100% on-device.
    Requires: Ollama running locally at http://localhost:11434
#>

$script:OllamaModel      = "hf.co/BrainboxAI/law-il-E2B:Q4_K_M"
$script:OllamaApiUrl     = "http://localhost:11434/api/chat"
$script:OllamaTimeoutSec = 60
$script:OllamaTemperature = 0.3

# ── System prompt: Law-IL E2B official 5-step structure ──────────────────────
$script:LawILE2BSystemPrompt = @"
אתה עוזר משפטי-AI מתמחה בדין הישראלי. שמך הוא Law-IL E2B.
לכל שאלה שאתה מקבל, עבד אותה תמיד לפי 5 שלבים פנימיים, ולאחר מכן השב אך ורק בפורמט JSON תקני:

שלב 1 — הבנת ההקשר: זהה את סוג ההליך המשפטי (אזרחי/פלילי/משפחה/עבודה/מנהלי), את בית המשפט הרלוונטי ואת מסגרת הזמן.
שלב 2 — זיהוי הצדדים: ציין מי הם הצדדים, תפקידם ויחסם זה לזה.
שלב 3 — ניתוח המסמך: נתח את סוג המסמך, מטרתו ומשמעותו המשפטית.
שלב 4 — חילוץ מידע: חלץ את כל הנתונים הרלוונטיים — תאריכים, מספרי תיק, שמות צדדים, סכומים.
שלב 5 — תגובה מובנית: ספק תגובה ONLY כ-JSON תקני, ללא כל טקסט נוסף, ללא markdown.
"@

# ── Connectivity helpers ──────────────────────────────────────────────────────

function Test-OllamaAvailable {
    <# Returns $true if Ollama is running and the law-il-E2B model is loaded. #>
    try {
        $r = Invoke-RestMethod -Method Get `
             -Uri "http://localhost:11434/api/tags" `
             -TimeoutSec 5 -ErrorAction Stop
        $names = $r.models | ForEach-Object { $_.name }
        return ($names -match "law-il-E2B" -or $names -match "BrainboxAI")
    } catch {
        return $false
    }
}

function Invoke-OllamaChat {
    <#
    .SYNOPSIS
        Core REST call to Ollama /api/chat. Returns the assistant's response text,
        or $null on error/timeout.
    .PARAMETER SystemPrompt  Override the default Law-IL E2B system prompt.
    .PARAMETER UserPrompt    The user message to send.
    .PARAMETER Temperature   Defaults to $script:OllamaTemperature (0.3).
    #>
    param(
        [string]$UserPrompt,
        [string]$SystemPrompt = $script:LawILE2BSystemPrompt,
        [double]$Temperature  = $script:OllamaTemperature
    )

    if (-not $UserPrompt) { return $null }

    $body = [ordered]@{
        model    = $script:OllamaModel
        messages = @(
            [ordered]@{ role = "system"; content = $SystemPrompt }
            [ordered]@{ role = "user";   content = $UserPrompt   }
        )
        stream  = $false
        options = [ordered]@{ temperature = $Temperature; num_predict = 1024 }
    } | ConvertTo-Json -Depth 6 -Compress

    # UTF-8 encode body explicitly (Hebrew characters)
    $bodyBytes = [System.Text.Encoding]::UTF8.GetBytes($body)

    try {
        $response = Invoke-RestMethod `
            -Method      Post `
            -Uri         $script:OllamaApiUrl `
            -ContentType "application/json; charset=utf-8" `
            -Body        $bodyBytes `
            -TimeoutSec  $script:OllamaTimeoutSec `
            -ErrorAction Stop

        return $response.message.content
    } catch {
        Write-Verbose "Ollama call failed: $_"
        return $null
    }
}

function ConvertFrom-OllamaJson {
    <# Extracts the first valid JSON object from a raw model response. #>
    param([string]$Raw)
    if (-not $Raw) { return $null }
    $m = [regex]::Match($Raw, '\{[\s\S]*?\}')
    if (-not $m.Success) { return $null }
    try { return $m.Value | ConvertFrom-Json } catch { return $null }
}

# ── Primary extraction function ───────────────────────────────────────────────

function Invoke-LegalAI {
    <#
    .SYNOPSIS
        Extracts legal identifiers from document text using the Law-IL E2B model.
        Returns a hashtable: ClientName, CaseNumber, CaseType, DocumentType,
        DocumentDate, Confidence. Returns $null on timeout or error.
    #>
    param(
        [string]$Text,
        [int]$MaxChars = 1500
    )

    if (-not $Text) { return $null }
    $snippet = if ($Text.Length -gt $MaxChars) { $Text.Substring(0, $MaxChars) } else { $Text }

    $userPrompt = @"
נתח את המסמך המשפטי הבא וחלץ את השדות הנדרשים. החזר אך ורק JSON תקני:
{
  "ClientName":   "שם הצד הראשי / הלקוח (string or null)",
  "CaseNumber":   "מספר תיק בפורמט מקורי (string or null)",
  "CaseType":     "civil | criminal | family | labor | admin | unknown",
  "DocumentType": "סוג המסמך בעברית: כתב תביעה / פסק דין / תצהיר / בקשה / תגובה / פרוטוקול / חוזה / כתב אישום / כתב הגנה / ערעור / חוות דעת / אחר",
  "DocumentDate": "YYYY-MM-DD or null",
  "ProcedureType":"civil-standard | fast-track | small-claims | labor | family | criminal | unknown",
  "Confidence":   0-100
}

טקסט המסמך:
$snippet
"@

    $raw = Invoke-OllamaChat -UserPrompt $userPrompt
    if (-not $raw) { return $null }

    $parsed = ConvertFrom-OllamaJson -Raw $raw
    if (-not $parsed) { return $null }

    return @{
        ClientName    = "$($parsed.ClientName)"
        CaseNumber    = "$($parsed.CaseNumber)"
        CaseType      = "$($parsed.CaseType)"
        DocumentType  = "$($parsed.DocumentType)"
        DocumentDate  = "$($parsed.DocumentDate)"
        ProcedureType = "$($parsed.ProcedureType)"
        Confidence    = [int]($parsed.Confidence)
    }
}

# ── Procedural analysis ───────────────────────────────────────────────────────

function Invoke-ProceduralClassify {
    <#
    .SYNOPSIS
        Given document text, determines the procedure type and extracts the
        trigger event + date (e.g. "complaint-filed" on "2024-03-10").
        Returns hashtable: ProcedureType, TriggerEvent, TriggerDate, CaseType.
    #>
    param([string]$Text, [int]$MaxChars = 2000)

    if (-not $Text) { return $null }
    $snippet = if ($Text.Length -gt $MaxChars) { $Text.Substring(0, $MaxChars) } else { $Text }

    $userPrompt = @"
בהתבסס על מסמך משפטי זה, זהה את סוג ההליך ואת אירוע הפתיחה.
החזר JSON בלבד:
{
  "ProcedureType": "civil-standard | fast-track | small-claims | labor | family | criminal | unknown",
  "TriggerEvent":  "complaint-filed | indictment-served | case-assigned | hearing-held | service-confirmed | unknown",
  "TriggerDate":   "YYYY-MM-DD or null",
  "CaseType":      "civil | criminal | family | labor | admin | unknown",
  "CourtLevel":    "magistrate | district | supreme | labor | family | unknown"
}

מסמך:
$snippet
"@

    $raw    = Invoke-OllamaChat -UserPrompt $userPrompt
    $parsed = ConvertFrom-OllamaJson -Raw $raw
    if (-not $parsed) { return $null }

    return @{
        ProcedureType = "$($parsed.ProcedureType)"
        TriggerEvent  = "$($parsed.TriggerEvent)"
        TriggerDate   = "$($parsed.TriggerDate)"
        CaseType      = "$($parsed.CaseType)"
        CourtLevel    = "$($parsed.CourtLevel)"
    }
}

# ── Contradiction & brief analysis ───────────────────────────────────────────

function Invoke-ContradictionAnalysis {
    <#
    .SYNOPSIS
        Compares two document texts and finds chronological or factual contradictions.
        Returns array of contradiction objects: {Description, DocA, DocB, Severity}.
    #>
    param(
        [string]$TextA,
        [string]$LabelA,
        [string]$TextB,
        [string]$LabelB,
        [int]$MaxChars = 1200
    )

    $snipA = if ($TextA.Length -gt $MaxChars) { $TextA.Substring(0, $MaxChars) } else { $TextA }
    $snipB = if ($TextB.Length -gt $MaxChars) { $TextB.Substring(0, $MaxChars) } else { $TextB }

    $userPrompt = @"
השווה בין שני המסמכים המשפטיים הבאים ומצא סתירות עובדתיות או כרונולוגיות.
החזר JSON בלבד — מערך של אובייקטים:
[
  {
    "Description": "תיאור הסתירה בעברית",
    "DocA_Claim":  "מה נטען במסמך א",
    "DocB_Claim":  "מה נטען במסמך ב",
    "Severity":    "high | medium | low",
    "DateConflict": true/false
  }
]
אם אין סתירות, החזר מערך ריק: []

מסמך א ($LabelA):
$snipA

מסמך ב ($LabelB):
$snipB
"@

    $raw = Invoke-OllamaChat -UserPrompt $userPrompt
    if (-not $raw) { return @() }

    try {
        $m = [regex]::Match($raw, '\[[\s\S]*\]')
        if ($m.Success) { return ($m.Value | ConvertFrom-Json) }
    } catch {}
    return @()
}

function Invoke-CrossExamQuestions {
    <#
    .SYNOPSIS
        Generates recommended cross-examination questions based on case documents.
        Returns array of {Question, LegalBasis, TargetWitness, Priority}.
    #>
    param([string]$CaseSummary, [int]$MaxChars = 2000)

    $snippet = if ($CaseSummary.Length -gt $MaxChars) { $CaseSummary.Substring(0, $MaxChars) } else { $CaseSummary }

    $userPrompt = @"
בהתבסס על תמצית התיק הבאה, הצע שאלות לחקירה נגדית.
החזר JSON בלבד — מערך:
[
  {
    "Question":      "השאלה המוצעת בעברית",
    "LegalBasis":    "הבסיס המשפטי (חוק / הלכה)",
    "TargetWitness": "מי העד המוצע (role or name)",
    "Priority":      "high | medium | low",
    "Category":      "credibility | contradiction | missing-evidence | procedure"
  }
]

תמצית התיק:
$snippet
"@

    $raw = Invoke-OllamaChat -UserPrompt $userPrompt
    if (-not $raw) { return @() }

    try {
        $m = [regex]::Match($raw, '\[[\s\S]*\]')
        if ($m.Success) { return ($m.Value | ConvertFrom-Json) }
    } catch {}
    return @()
}

# ── Document generation ───────────────────────────────────────────────────────

function Invoke-DocumentDraft {
    <#
    .SYNOPSIS
        Generates a Hebrew legal document draft given structured case data.
        Returns the draft text as a string.
    .PARAMETER DocumentType  Hebrew name, e.g. "כתב תביעה", "בקשה לצו מניעה"
    .PARAMETER CaseData      Hashtable: CaseNumber, ClientName, Defendant, Court, CaseType, Facts
    #>
    param(
        [string]$DocumentType,
        [hashtable]$CaseData
    )

    $facts = if ($CaseData.Facts) { $CaseData.Facts } else { "לא סופקו עובדות" }

    $userPrompt = @"
צור טיוטה ראשונית של $DocumentType לבית המשפט בישראל.

פרטי התיק:
- תיק מספר: $($CaseData.CaseNumber)
- שם הלקוח: $($CaseData.ClientName)
- הנתבע/ת: $($CaseData.Defendant)
- בית משפט: $($CaseData.Court)
- סוג תיק: $($CaseData.CaseType)
- עובדות רלוונטיות: $facts

הנחיות:
- כתוב בעברית משפטית תקינה
- כלול כותרת, פרטי הצדדים, רקע עובדתי, טענות משפטיות, סעד מבוקש
- השתמש בפסקאות ממוספרות
- אל תכתוב JSON — כתוב מסמך משפטי פורמלי
"@

    $systemPrompt = @"
$script:LawILE2BSystemPrompt

הערה חשובה: בשלב 5 (תגובה מובנית) — כאן אתה מתבקש לכתוב מסמך משפטי ולא JSON.
כתוב את המסמך המשפטי המתאים בצורה מלאה ומקצועית.
"@

    $draft = Invoke-OllamaChat -UserPrompt $userPrompt -SystemPrompt $systemPrompt -Temperature 0.4
    return if ($draft) { $draft } else { "שגיאה ביצירת הטיוטה. ודא ש-Ollama פעיל." }
}
