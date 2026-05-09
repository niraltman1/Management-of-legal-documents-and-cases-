#Requires -Version 5.1
<#
.SYNOPSIS
    STEP 10 — AI-powered document drafter.
    Generates a Hebrew legal document draft (Word/Markdown) using the Law-IL E2B model.
    Requires: Ollama + law-il-E2B model.

.PARAMETER CaseID         Case to draft a document for (required).
.PARAMETER DocumentType   Hebrew document type, e.g. "כתב תביעה", "בקשה לצו מניעה".
                          If omitted, suggests the next required document from DB.
.PARAMETER OutputFormat   "markdown" (default) or "docx" (requires Word/LibreOffice).
.PARAMETER OutputDir      Where to save the draft. Default: _Reports\Drafts\.
#>

param(
    [string]$DbPath        = "",
    [string]$RootPath      = "",
    [int]$CaseID           = 0,
    [string]$DocumentType  = "",
    [ValidateSet("markdown","docx")]
    [string]$OutputFormat  = "markdown",
    [string]$OutputDir     = ""
)

$ScriptDir = $PSScriptRoot
. "$ScriptDir\..\lib\Config.ps1"
. "$ScriptDir\..\lib\Database.ps1"
. "$ScriptDir\..\lib\LegalAI.ps1"

if ($DbPath)    { $script:DbPath    = $DbPath }
if ($RootPath)  { $script:RootPath  = $RootPath }

Import-Module PSSQLite -ErrorAction Stop
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

Write-Host ""
Write-Host "══════════════════════════════════════════" -ForegroundColor Cyan
Write-Host "  STEP 10 — מחולל מסמכים משפטיים (v3.0)" -ForegroundColor Cyan
Write-Host "══════════════════════════════════════════" -ForegroundColor Cyan
Write-Host ""

# Validate CaseID
if ($CaseID -le 0) {
    # Interactive: list cases
    $cases = Invoke-SqliteQuery -DataSource $script:DbPath `
        -Query "SELECT CaseID, CaseNumber, CaseName, CaseType FROM Cases WHERE Status='active' ORDER BY CaseNumber"
    if (-not $cases -or @($cases).Count -eq 0) {
        Write-Host "  אין תיקים פעילים." -ForegroundColor Yellow
        exit 1
    }
    Write-Host "  תיקים פעילים:" -ForegroundColor Cyan
    @($cases) | ForEach-Object { Write-Host "  [$($_.CaseID)] $($_.CaseNumber) — $($_.CaseName) ($($_.CaseType))" }
    Write-Host ""
    $input = Read-Host "  הזן CaseID"
    $CaseID = [int]$input
}

$caseRow = Invoke-SqliteQuery -DataSource $script:DbPath `
    -Query "SELECT ca.*, c.LastName, c.FirstName, c.IDNumber FROM Cases ca JOIN Clients c ON c.ClientID=ca.ClientID WHERE ca.CaseID=@cid" `
    -SqlParameters @{cid=$CaseID}

if (-not $caseRow) {
    Write-Host "  תיק $CaseID לא נמצא." -ForegroundColor Red
    exit 1
}

Write-Host "  תיק: $($caseRow.CaseNumber) — $($caseRow.LastName) $($caseRow.FirstName)" -ForegroundColor White

# Determine document type
if (-not $DocumentType) {
    # Suggest from DB (next pending procedural step)
    $step = Invoke-SqliteQuery -DataSource $script:DbPath -Query @"
SELECT StepName, ExpectedDate FROM Procedural_Steps
WHERE CaseID=@cid AND Status IN ('pending','missed') AND ActualDate IS NULL
ORDER BY ExpectedDate ASC LIMIT 1
"@ -SqlParameters @{cid=$CaseID}

    $options = @(
        "כתב תביעה", "כתב הגנה", "בקשה לצו מניעה",
        "בקשה לדחיית מועד", "תצהיר", "סיכומים", "ערעור", "חוות דעת"
    )

    if ($step) {
        Write-Host "  המסמך הבא לפי לוח הזמנים: $($step.StepName) (עד $($step.ExpectedDate))" -ForegroundColor Yellow
        $options = @($step.StepName) + $options
    }

    Write-Host "  סוגי מסמכים זמינים:" -ForegroundColor Cyan
    for ($i = 0; $i -lt $options.Count; $i++) {
        Write-Host "  [$i] $($options[$i])"
    }
    $sel = Read-Host "  בחר מספר (או הקלד סוג מסמך חופשי)"
    if ($sel -match '^\d+$' -and [int]$sel -lt $options.Count) {
        $DocumentType = $options[[int]$sel]
    } else {
        $DocumentType = $sel
    }
}

if (-not $DocumentType) {
    Write-Host "  לא נבחר סוג מסמך." -ForegroundColor Red
    exit 1
}

Write-Host "  מסמך: $DocumentType" -ForegroundColor White

# Check Ollama
if (-not (Test-OllamaAvailable)) {
    Write-Host "  ⚠ Ollama לא זמין — לא ניתן לייצר טיוטה AI." -ForegroundColor Red
    Write-Host "    הרץ: .\Scripts\Setup\02b-Install-Ollama.ps1" -ForegroundColor Yellow
    exit 1
}

# Gather opponent/counterparty info from case documents
$contacts = Invoke-SqliteQuery -DataSource $script:DbPath -Query @"
SELECT DISTINCT co.FullName, co.PersonType
FROM Contacts co
JOIN ContactCaseLinks ccl ON ccl.ContactID = co.ContactID
WHERE ccl.CaseID = @cid AND co.PersonType IN ('defendant','plaintiff','lawyer-opposing')
ORDER BY co.PersonType
"@ -SqlParameters @{cid=$CaseID}

$defendant = if ($contacts) {
    $d = @($contacts) | Where-Object { $_.PersonType -eq 'defendant' } | Select-Object -First 1
    if ($d) { $d.FullName } else { "הנתבע" }
} else { "הנתבע" }

# Get case facts from extracted texts
$factsRows = Invoke-SqliteQuery -DataSource $script:DbPath -Query @"
SELECT SUBSTR(fc.ExtractedText, 1, 600) AS Snippet, pi.DocumentType, f.OriginalName
FROM Files f
JOIN FileContent fc ON fc.FileID = f.FileID
LEFT JOIN ParsedIdentifiers pi ON pi.FileID = f.FileID
JOIN FileCaseLinks fcl ON fcl.FileID = f.FileID
WHERE fcl.CaseID = @cid AND fc.ExtractedText IS NOT NULL
ORDER BY f.DateModified ASC LIMIT 4
"@ -SqlParameters @{cid=$CaseID}

$factsText = if ($factsRows) {
    (@($factsRows) | ForEach-Object { "[$($_.OriginalName)]: $($_.Snippet)" }) -join "`n---`n"
} else {
    "פרטי תיק: $($caseRow.CaseNumber)"
}

# Build case data for draft
$caseData = @{
    CaseNumber  = $caseRow.CaseNumber
    ClientName  = "$($caseRow.LastName) $($caseRow.FirstName)"
    Defendant   = $defendant
    Court       = if ($caseRow.Court) { $caseRow.Court } else { "בית משפט שלום" }
    CaseType    = $caseRow.CaseType
    Facts       = $factsText
}

Write-Host ""
Write-Host "  מייצר טיוטה... (עשוי לקחת 30-60 שניות)" -ForegroundColor Cyan

$draft = Invoke-DocumentDraft -DocumentType $DocumentType -CaseData $caseData

# Save output
$draftsDir = if ($OutputDir) { $OutputDir } else { Join-Path $script:OutputPath "Drafts" }
if (-not (Test-Path $draftsDir)) { New-Item -ItemType Directory -Path $draftsDir -Force | Out-Null }

$stamp    = Get-Date -Format "yyyyMMdd_HHmmss"
$safeName = $DocumentType -replace '[\\/:*?"<>|]', '-'
$filename = "$($caseRow.CaseNumber)_${safeName}_$stamp"

if ($OutputFormat -eq "docx") {
    # Save as Markdown with .docx extension note (requires pandoc/Word on target machine)
    $mdPath = Join-Path $draftsDir "$filename.md"
    [System.IO.File]::WriteAllText($mdPath, $draft, [System.Text.Encoding]::UTF8)
    Write-Host ""
    Write-Host "  טיוטה נשמרה (Markdown): $mdPath" -ForegroundColor Green
    Write-Host "  להמרה ל-Word: pandoc `"$mdPath`" -o `"${filename}.docx`"" -ForegroundColor Gray
} else {
    $mdPath = Join-Path $draftsDir "$filename.md"
    [System.IO.File]::WriteAllText($mdPath, $draft, [System.Text.Encoding]::UTF8)
    Write-Host ""
    Write-Host "  ✓ טיוטה נשמרה: $mdPath" -ForegroundColor Green
}

# Mark step as having a draft in Procedural_Steps
$stepToUpdate = Invoke-SqliteQuery -DataSource $script:DbPath -Query @"
SELECT StepID FROM Procedural_Steps
WHERE CaseID=@cid AND StepName LIKE @doc AND ActualDate IS NULL
LIMIT 1
"@ -SqlParameters @{cid=$CaseID; doc="%$DocumentType%"}

if ($stepToUpdate) {
    Invoke-SqliteQuery -DataSource $script:DbPath `
        -Query "UPDATE Procedural_Steps SET Notes=@note WHERE StepID=@sid" `
        -SqlParameters @{note="טיוטה נוצרה: $mdPath"; sid=$stepToUpdate.StepID}
}

# Also log in Case_Brief as suggested document
Upsert-CaseBrief -DbPath $script:DbPath -Row @{
    CaseID              = $CaseID
    FileID              = $null
    BriefType           = "next-document"
    ContradictionFound  = $null
    RecommendedQuestion = $null
    SuggestedDocument   = "טיוטה נוצרה: $DocumentType → $mdPath"
    LegalBasis          = $null
    ConfidenceScore     = 80
    AIGenerated         = 1
}

Write-Host ""
Write-Host "  הצג טיוטה: notepad `"$mdPath`"" -ForegroundColor Cyan
Write-Host ""

# Show first 20 lines as preview
Write-Host "  ── תצוגה מקדימה ──" -ForegroundColor Yellow
$lines = $draft -split "`n" | Select-Object -First 20
$lines | ForEach-Object { Write-Host "  $_" }
if ($draft -split "`n" | Measure-Object | Select-Object -ExpandProperty Count | ForEach-Object { $_ -gt 20 }) {
    Write-Host "  ... (המסמך המלא נמצא בקובץ)" -ForegroundColor Gray
}
Write-Host ""
