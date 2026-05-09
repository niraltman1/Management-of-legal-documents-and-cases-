#Requires -Version 5.1
<#
.SYNOPSIS
    v3.0 — Procedural Engine: calculates legal deadlines, builds case brief,
    identifies contradictions, and suggests the next required document.
    Requires: Ollama + law-il-E2B model (via LegalAI.ps1).
              PSSQLite module.
#>

# Dot-source dependencies (caller is responsible for loading Config.ps1 first)
$_libDir = Join-Path $PSScriptRoot "..\lib"
. "$_libDir\LegalAI.ps1"
. "$_libDir\Database.ps1"

Import-Module PSSQLite -ErrorAction Stop

# ── Public API ────────────────────────────────────────────────────────────────

function Invoke-ProceduralAnalysis {
    <#
    .SYNOPSIS
        Full procedural analysis for a single case:
        1. Classify procedure type (AI)
        2. Calculate deadlines from Rules_Engine
        3. Save Procedural_Steps to DB
        4. Generate CaseBrief items (contradictions + questions)
    .OUTPUTS
        Hashtable with: ProcedureType, DeadlinesCreated, BriefItemsCreated
    #>
    param(
        [string]$DbPath,
        [int]$CaseID,
        [switch]$Force   # re-run even if steps already exist
    )

    if (-not (Test-OllamaAvailable)) {
        Write-Warning "  Ollama לא זמין — דלג על ניתוח פרוצדורלי לתיק $CaseID"
        return $null
    }

    # Skip if already processed (unless -Force)
    if (-not $Force) {
        $existing = Invoke-SqliteQuery -DataSource $DbPath `
            -Query "SELECT COUNT(*) AS N FROM Procedural_Steps WHERE CaseID=@cid AND AIGenerated=1" `
            -SqlParameters @{cid=$CaseID}
        if ($existing.N -gt 0) {
            Write-Verbose "  תיק $CaseID כבר עובד — דלג."
            return $null
        }
    }

    # Get case info + all extracted text for this case
    $caseRow = Invoke-SqliteQuery -DataSource $DbPath `
        -Query "SELECT * FROM Cases WHERE CaseID=@cid" `
        -SqlParameters @{cid=$CaseID}
    if (-not $caseRow) { return $null }

    $texts = Invoke-SqliteQuery -DataSource $DbPath -Query @"
SELECT fc.ExtractedText, f.OriginalName, pi.DocumentType, pi.DocumentDate, f.FileID
FROM Files f
JOIN FileContent fc ON fc.FileID = f.FileID
LEFT JOIN ParsedIdentifiers pi ON pi.FileID = f.FileID
JOIN FileCaseLinks fcl ON fcl.FileID = f.FileID
WHERE fcl.CaseID = @cid AND fc.ExtractedText IS NOT NULL AND length(fc.ExtractedText) > 50
ORDER BY f.DateModified ASC;
"@ -SqlParameters @{cid=$CaseID}

    if (-not $texts -or @($texts).Count -eq 0) {
        Write-Warning "  אין טקסט זמין לתיק $CaseID"
        return $null
    }

    Write-Host "  ניתוח פרוצדורלי לתיק $($caseRow.CaseNumber) ($(@($texts).Count) מסמכים)..." -ForegroundColor Cyan

    # Step 1: Classify procedure type using the first substantive document
    $firstText  = @($texts)[0].ExtractedText
    $procResult = Invoke-ProceduralClassify -Text $firstText

    $procedureType = if ($procResult -and $procResult.ProcedureType -ne "unknown") {
        $procResult.ProcedureType
    } else {
        # Fallback: infer from CaseType stored in Cases table
        switch ($caseRow.CaseType) {
            "criminal" { "criminal" }
            "family"   { "family" }
            "labor"    { "labor" }
            default    { "civil-standard" }
        }
    }

    $triggerEvent = if ($procResult -and $procResult.TriggerEvent) { $procResult.TriggerEvent } else { "complaint-filed" }
    $triggerDate  = if ($procResult -and $procResult.TriggerDate -match '^\d{4}-\d{2}-\d{2}$') {
        $procResult.TriggerDate
    } else {
        # Try DocumentDate from first text
        $firstDoc = @($texts)[0]
        if ($firstDoc.DocumentDate -match '^\d{4}-\d{2}-\d{2}$') { $firstDoc.DocumentDate }
        else { (Get-Date).ToString('yyyy-MM-dd') }
    }

    Write-Host "    סוג הליך: $procedureType | אירוע פתיחה: $triggerEvent | תאריך: $triggerDate" -ForegroundColor Gray

    # Step 2: Calculate deadlines
    $stepsCreated = Save-ProceduralSteps -DbPath $DbPath `
        -CaseID $CaseID -ProcedureType $procedureType `
        -TriggerEvent $triggerEvent -TriggerDate $triggerDate

    # Step 3: Generate case brief items
    $briefCreated = Generate-CaseBrief -DbPath $DbPath -CaseID $CaseID -Texts $texts

    return @{
        ProcedureType    = $procedureType
        TriggerEvent     = $triggerEvent
        TriggerDate      = $triggerDate
        DeadlinesCreated = $stepsCreated
        BriefItemsCreated = $briefCreated
    }
}

function Calculate-Deadlines {
    <#
    .SYNOPSIS
        Given a trigger date and procedure type, returns an array of deadline objects
        by querying Rules_Engine. Does NOT write to DB.
    #>
    param(
        [string]$DbPath,
        [string]$ProcedureType,
        [string]$TriggerDate
    )

    $rules = Invoke-SqliteQuery -DataSource $DbPath `
        -Query "SELECT * FROM Rules_Engine WHERE ProcedureType=@pt ORDER BY DaysFromTrigger ASC" `
        -SqlParameters @{pt=$ProcedureType}

    if (-not $rules) { return @() }

    $anchor = try { [datetime]::ParseExact($TriggerDate, 'yyyy-MM-dd', $null) } catch { Get-Date }

    return @($rules) | ForEach-Object {
        $expected = $anchor.AddDays([int]($_.DaysFromTrigger))
        [PSCustomObject]@{
            RuleID         = $_.RuleID
            StepName       = $_.StepName
            StepNameHeb    = $_.StepNameHeb
            DaysFromTrigger = $_.DaysFromTrigger
            ExpectedDate   = $expected.ToString('yyyy-MM-dd')
            LegalBasis     = $_.LegalBasis
            TriggerEvent   = $_.TriggerEvent
            IsRequired     = $_.IsRequired
        }
    }
}

function Save-ProceduralSteps {
    <#
    .SYNOPSIS
        Calculates and writes Procedural_Steps records for a case.
        Returns count of steps created.
    #>
    param(
        [string]$DbPath,
        [int]$CaseID,
        [string]$ProcedureType,
        [string]$TriggerEvent,
        [string]$TriggerDate
    )

    $deadlines = Calculate-Deadlines -DbPath $DbPath `
        -ProcedureType $ProcedureType -TriggerDate $TriggerDate

    if (-not $deadlines -or @($deadlines).Count -eq 0) { return 0 }

    $count = 0
    foreach ($d in $deadlines) {
        $today = (Get-Date).ToString('yyyy-MM-dd')
        $status = if ($d.ExpectedDate -lt $today) { "missed" } else { "pending" }

        Upsert-ProceduralStep -DbPath $DbPath -Row @{
            CaseID       = $CaseID
            FileID       = $null
            RuleID       = $d.RuleID
            StepName     = $d.StepNameHeb
            TriggerEvent = $TriggerEvent
            TriggerDate  = $TriggerDate
            ExpectedDate = $d.ExpectedDate
            ActualDate   = $null
            Status       = $status
            Notes        = $d.LegalBasis
            AIGenerated  = 1
        }
        $count++
    }

    Write-Host "    נוצרו $count שלבים פרוצדורליים" -ForegroundColor Gray
    return $count
}

function Generate-CaseBrief {
    <#
    .SYNOPSIS
        Runs contradiction analysis across all case documents and generates
        recommended cross-examination questions. Writes to Case_Brief table.
        Returns count of brief items created.
    #>
    param(
        [string]$DbPath,
        [int]$CaseID,
        [object[]]$Texts   # rows from FileContent query
    )

    if (-not $Texts -or @($Texts).Count -eq 0) { return 0 }

    $count = 0
    $textsArr = @($Texts)

    # Contradiction analysis: compare consecutive document pairs
    for ($i = 0; $i -lt ($textsArr.Count - 1); $i++) {
        $a = $textsArr[$i]
        $b = $textsArr[$i + 1]

        $contradictions = Invoke-ContradictionAnalysis `
            -TextA $a.ExtractedText -LabelA ($a.OriginalName) `
            -TextB $b.ExtractedText -LabelB ($b.OriginalName)

        foreach ($c in $contradictions) {
            $desc = "$($c.Description) [מסמך א: $($c.DocA_Claim) | מסמך ב: $($c.DocB_Claim)]"
            Upsert-CaseBrief -DbPath $DbPath -Row @{
                CaseID              = $CaseID
                FileID              = $a.FileID
                BriefType           = "contradiction"
                ContradictionFound  = $desc
                RecommendedQuestion = $null
                SuggestedDocument   = $null
                LegalBasis          = $null
                ConfidenceScore     = switch ($c.Severity) { "high" { 85 } "medium" { 60 } default { 40 } }
                AIGenerated         = 1
            }
            $count++
        }
    }

    # Build case summary for cross-examination questions
    $summary = ($textsArr | Select-Object -First 3 | ForEach-Object {
        "$($_.OriginalName): $($_.ExtractedText.Substring(0, [Math]::Min(400, $_.ExtractedText.Length)))"
    }) -join "`n`n"

    $questions = Invoke-CrossExamQuestions -CaseSummary $summary
    foreach ($q in $questions) {
        Upsert-CaseBrief -DbPath $DbPath -Row @{
            CaseID              = $CaseID
            FileID              = $textsArr[0].FileID
            BriefType           = "question"
            ContradictionFound  = $null
            RecommendedQuestion = "$($q.Question) [$($q.Category)]"
            SuggestedDocument   = $null
            LegalBasis          = "$($q.LegalBasis)"
            ConfidenceScore     = switch ($q.Priority) { "high" { 85 } "medium" { 60 } default { 40 } }
            AIGenerated         = 1
        }
        $count++
    }

    # Add next-document suggestion
    $nextDoc = Suggest-NextDocument -DbPath $DbPath -CaseID $CaseID
    if ($nextDoc) {
        Upsert-CaseBrief -DbPath $DbPath -Row @{
            CaseID              = $CaseID
            FileID              = $textsArr[0].FileID
            BriefType           = "next-document"
            ContradictionFound  = $null
            RecommendedQuestion = $null
            SuggestedDocument   = $nextDoc
            LegalBasis          = $null
            ConfidenceScore     = 70
            AIGenerated         = 1
        }
        $count++
    }

    Write-Host "    נוצרו $count פריטי brief (סתירות + שאלות + מסמך הבא)" -ForegroundColor Gray
    return $count
}

function Suggest-NextDocument {
    <#
    .SYNOPSIS
        Looks at existing Procedural_Steps and filed documents to suggest
        the next required document. Returns a string (document name in Hebrew).
    #>
    param(
        [string]$DbPath,
        [int]$CaseID
    )

    # Find oldest pending overdue step that has no filed document
    $step = Invoke-SqliteQuery -DataSource $DbPath -Query @"
SELECT ps.StepName, ps.ExpectedDate, ps.Status
FROM Procedural_Steps ps
WHERE ps.CaseID = @cid AND ps.Status IN ('pending','missed')
  AND ps.ActualDate IS NULL
ORDER BY ps.ExpectedDate ASC
LIMIT 1;
"@ -SqlParameters @{cid=$CaseID}

    if ($step) {
        $urgency = if ($step.Status -eq 'missed') { "⚠ באיחור — " } else { "" }
        return "$urgency$($step.StepName) (מועד: $($step.ExpectedDate))"
    }

    return $null
}

# ── Batch runner ──────────────────────────────────────────────────────────────

function Invoke-AllCasesProceduralAnalysis {
    <#
    .SYNOPSIS
        Runs procedural analysis for all active cases in the database.
        Uses background jobs for parallelism.
    #>
    param(
        [string]$DbPath,
        [switch]$Force,
        [int]$MaxParallel = 3
    )

    $cases = Invoke-SqliteQuery -DataSource $DbPath `
        -Query "SELECT CaseID, CaseNumber, CaseType FROM Cases WHERE Status='active' ORDER BY CaseID"

    if (-not $cases -or @($cases).Count -eq 0) {
        Write-Host "  אין תיקים פעילים לעיבוד." -ForegroundColor Yellow
        return
    }

    $casesArr = @($cases)
    Write-Host "  מעבד $($casesArr.Count) תיקים פעילים..." -ForegroundColor Cyan

    $total = 0; $deadlines = 0; $briefs = 0
    foreach ($c in $casesArr) {
        Write-Host "  [$($c.CaseNumber)]" -NoNewline
        $result = Invoke-ProceduralAnalysis -DbPath $DbPath -CaseID $c.CaseID -Force:$Force
        if ($result) {
            $deadlines += $result.DeadlinesCreated
            $briefs    += $result.BriefItemsCreated
            $total++
            Write-Host " → $($result.DeadlinesCreated) מועדים, $($result.BriefItemsCreated) brief" -ForegroundColor Green
        } else {
            Write-Host " — דולג" -ForegroundColor Gray
        }
    }

    Write-Host ""
    Write-Host "  סיכום: $total תיקים עובדו | $deadlines מועדי הגשה | $briefs פריטי brief" -ForegroundColor Green
}
