#Requires -Version 5.1
<#
.SYNOPSIS
    Classifies documents by type and domain.
    Handles the Medical-Legal bridge (expert opinions vs. study materials).
    Strictly isolates: Legal-Case / Legal-Research / Medical / Teaching / Personal.
#>

# ── DOCUMENT TYPE KEYWORD RULES ───────────────────────────────────────────────
# Each rule: Keywords (any match scores points), required minimum score, result type
$DocTypeRules = @(
    [PSCustomObject]@{ Slug="KtavTvia";    He="כתב תביעה";    Score=0; Keywords=@("כתב תביעה","statement of claim","תביעה") }
    [PSCustomObject]@{ Slug="KtavHagana"; He="כתב הגנה";     Score=0; Keywords=@("כתב הגנה","statement of defense","הגנה") }
    [PSCustomObject]@{ Slug="Tatzir";     He="תצהיר";        Score=0; Keywords=@("תצהיר","affidavit","מצהיר") }
    [PSCustomObject]@{ Slug="Irur";       He="ערעור";        Score=0; Keywords=@("ערעור","appeal","בית המשפט העליון") }
    [PSCustomObject]@{ Slug="Bakasha";    He="בקשה";         Score=0; Keywords=@("בקשה","motion","application","מתבקש") }
    [PSCustomObject]@{ Slug="Tguva";      He="תגובה";        Score=0; Keywords=@("תגובה","response","reply") }
    [PSCustomObject]@{ Slug="Hahlata";    He="החלטה";        Score=0; Keywords=@("החלטה","court order","ruling","צו") }
    [PSCustomObject]@{ Slug="PsakDin";    He="פסק דין";      Score=0; Keywords=@("פסק דין","judgment","verdict","נפסק") }
    [PSCustomObject]@{ Slug="DochTnua";   He="דוח תנועה";    Score=0; Keywords=@("דוח תנועה","דו\"ח תנועה","traffic report","תעבורה","דוח קנס") }
    [PSCustomObject]@{ Slug="EdutEd";     He="עדות עד";      Score=0; Keywords=@("עדות","עד","witness statement","הצהרת עד") }
    [PSCustomObject]@{ Slug="HodaatNeasham"; He="הודעת נאשם"; Score=0; Keywords=@("הודעת נאשם","חשוד","נאשם","עצור") }
    [PSCustomObject]@{ Slug="HavatDaat";  He="חוות דעת";     Score=0; Keywords=@("חוות דעת","expert opinion","מומחה") }
    [PSCustomObject]@{ Slug="HavatDaatRefuit"; He="חוות דעת רפואית"; Score=0; Keywords=@("חוות דעת רפואית","מומחה רפואי","נכות","נזק גוף","אחוזי נכות") }
    [PSCustomObject]@{ Slug="TeuzdatZehut"; He="תעודת זהות";  Score=0; Keywords=@("תעודת זהות","ת.ז.","ת\"ז","identity card") }
    [PSCustomObject]@{ Slug="RishyonNehiga"; He="רישיון נהיגה"; Score=0; Keywords=@("רישיון נהיגה","driver","license","ת.ר.") }
    [PSCustomObject]@{ Slug="YipuiKoach"; He="ייפוי כוח";    Score=0; Keywords=@("ייפוי כוח","power of attorney","מייפה") }
    [PSCustomObject]@{ Slug="HeskemSchtat"; He="הסכם שכ\"ט"; Score=0; Keywords=@("הסכם שכר טרחה","שכ\"ט","שכר טרחה","retainer") }
    [PSCustomObject]@{ Slug="Heskem";     He="הסכם";         Score=0; Keywords=@("הסכם","חוזה","contract","agreement") }
    [PSCustomObject]@{ Slug="Cheshbonit"; He="חשבונית";      Score=0; Keywords=@("חשבונית","invoice","receipt","קבלה") }
)

$MedicalStudyKeywords   = @("הרצאה","שיעור","תרגיל","סילבוס","lecture","syllabus","course","quiz","seminar","מבחן ב","בחינה ב","פרופ['''`]","faculty","university","אוניברסיטה","סמסטר")
$MedicalExpertKeywords  = @("חוות דעת","מומחה רפואי","נכות","נזק גוף","אחוזי נכות","medical opinion","disability","injury")
$TeachingKeywords       = @("תאונת דרכים","תאונה","car accident","reconstruction","accident scene","קב\"ט","אבטחה","security officer","שמירה","מאבטח","סיור")
$LegalResearchKeywords  = @("פסיקה","הלכה","precedent","supreme court","בית המשפט העליון","שיקולים","doctrine","case law")

# ── PUBLIC FUNCTIONS ──────────────────────────────────────────────────────────

function Get-DocumentClassification {
    param(
        [string]$Text,
        [string]$FilePath,
        [PSCustomObject]$ParsedIds,   # from IdentifierParser
        [string]$RootPath
    )

    $result = [PSCustomObject]@{
        Domain           = "Unknown"
        DocumentType     = "מסמך לא מזוהה"
        DocumentTypeSlug = "Unknown"
        SubFolder        = "_Inbox\To-Review"
        IsMedicalLegal   = $false
        IsResearchVerdict= $false
        CaseType         = $ParsedIds.CaseType
        ConfidenceBonus  = 0
    }

    if (-not $Text) { return $result }

    $lowerText = $Text.ToLower()

    # ── STEP 1: Check if already in a known domain folder ─────────────────────
    $relPath = ""
    if ($FilePath -and $RootPath) {
        $relPath = $FilePath.Replace($RootPath,"").ToLower()
    }

    # ── STEP 2: Detect document type ──────────────────────────────────────────
    $bestType  = $null
    $bestScore = 0
    foreach ($rule in $DocTypeRules) {
        $score = 0
        foreach ($kw in $rule.Keywords) {
            if ($lowerText -match [regex]::Escape($kw.ToLower())) { $score++ }
        }
        if ($score -gt $bestScore) { $bestScore = $score; $bestType = $rule }
    }

    if ($bestType -and $bestScore -gt 0) {
        $result.DocumentType     = $bestType.He
        $result.DocumentTypeSlug = $bestType.Slug
        $result.ConfidenceBonus  = [Math]::Min($bestScore * 10, 30)
    }

    # ── STEP 3: Domain classification ─────────────────────────────────────────

    # Medical-Legal bridge: medical expert opinion used as legal evidence
    $hasMedicalExpert = ($MedicalExpertKeywords | Where-Object { $lowerText -match [regex]::Escape($_.ToLower()) }).Count -gt 0
    $hasMedicalStudy  = ($MedicalStudyKeywords  | Where-Object { $lowerText -match [regex]::Escape($_.ToLower()) }).Count -gt 0
    $hasLegalCase     = [bool]$ParsedIds.CaseNumber

    if ($hasMedicalExpert -and $hasLegalCase) {
        $result.Domain       = "Legal-Case"
        $result.IsMedicalLegal = $true
        $result.DocumentType   = "חוות דעת רפואית"
        $result.DocumentTypeSlug = "HavatDaatRefuit"
        $result.SubFolder    = "Evidence"
    } elseif ($hasMedicalExpert -and $hasMedicalStudy) {
        # Ambiguous — route to review
        $result.Domain    = "Unknown"
        $result.SubFolder = "_Inbox\To-Review"
    } elseif ($hasMedicalStudy -and -not $hasLegalCase) {
        $result.Domain    = "Medical"
        $result.SubFolder = Resolve-MedicalSubfolder $Text
    }

    # Teaching detection (overrides medical if teaching keywords dominate)
    $teachingScore = ($TeachingKeywords | Where-Object { $lowerText -match [regex]::Escape($_.ToLower()) }).Count
    if ($teachingScore -ge 2 -and $result.Domain -eq "Unknown") {
        $result.Domain    = "Teaching"
        $result.SubFolder = Resolve-TeachingSubfolder $Text
    }

    # Legal case
    if ($result.Domain -eq "Unknown" -and $hasLegalCase) {
        $result.Domain = "Legal-Case"
    }

    # Research verdict: פסק דין but no matching case in the DB (caller checks DB separately)
    if ($result.DocumentTypeSlug -eq "PsakDin" -and -not $hasLegalCase) {
        $result.Domain           = "Legal-Research"
        $result.IsResearchVerdict= $true
        $result.SubFolder        = Resolve-ResearchSubfolder $Text
    }

    # Legal research articles / legislation
    $researchScore = ($LegalResearchKeywords | Where-Object { $lowerText -match [regex]::Escape($_.ToLower()) }).Count
    if ($researchScore -ge 2 -and $result.Domain -eq "Unknown") {
        $result.Domain    = "Legal-Research"
        $result.SubFolder = "Legal-Research\Commentary"
    }

    # Personal documents (ID cards, licenses, fee agreements, invoices)
    if ($result.Domain -eq "Unknown") {
        if ($result.DocumentTypeSlug -in @("TeuzdatZehut","RishyonNehiga","YipuiKoach","HeskemSchtat","Cheshbonit")) {
            $result.Domain    = "Legal-Case"
            $result.SubFolder = "Personal"
        }
    }

    return $result
}

function Resolve-MedicalSubfolder {
    param([string]$Text)
    $t = $Text.ToLower()
    $subjects = @{
        "אנטומיה|anatomy"           = "Courses\Anatomy"
        "פיזיולוגיה|physiology"     = "Courses\Physiology"
        "ביוכימיה|biochemistry"     = "Courses\Biochemistry"
        "פתולוגיה|pathology"        = "Courses\Pathology"
        "פרמקולוגיה|pharmacology"   = "Courses\Pharmacology"
        "מיקרוביולוגיה|microbiology"= "Courses\Microbiology"
        "נוירולוגיה|neurology"      = "Courses\Neurology"
        "כירורגיה|surgery"          = "Courses\Surgery"
        "רדיולוגיה|radiology"       = "Courses\Radiology"
        "פסיכיאטריה|psychiatry"     = "Courses\Psychiatry"
        "רפואה פנימית|internal medicine" = "Courses\Internal-Medicine"
        "אתיקה רפואית|medical ethics"    = "Courses\Medical-Ethics"
        "רפואת ילדים|pediatrics"    = "Courses\Pediatrics"
    }
    foreach ($kv in $subjects.GetEnumerator()) {
        if ($t -match $kv.Key) { return "Medical\$($kv.Value)" }
    }
    return "Medical\Courses"
}

function Resolve-TeachingSubfolder {
    param([string]$Text)
    $t = $Text.ToLower()
    if ($t -match "תאונ|accident|תנועה|traffic") {
        if ($t -match "הרצאה|lecture|slides|ppt") { return "Teaching\Car-Accident-Investigation\Lectures\Slides" }
        if ($t -match "מבחן|exam|test")            { return "Teaching\Car-Accident-Investigation\Exams\Question-Banks" }
        return "Teaching\Car-Accident-Investigation\Case-Studies"
    }
    if ($t -match "אבטח|security|קב.ט|שמירה|guard") {
        if ($t -match "הרצאה|lecture")  { return "Teaching\Security-Officer-Training\Lectures\Slides" }
        if ($t -match "מבחן|exam")      { return "Teaching\Security-Officer-Training\Exams\Question-Banks" }
        return "Teaching\Security-Officer-Training"
    }
    return "Teaching\Other-Courses"
}

function Resolve-ResearchSubfolder {
    param([string]$Text)
    $t = $Text.ToLower()
    if ($t -match "עליון|supreme") { return "Legal\Legal-Research\Case-Law\Supreme-Court" }
    if ($t -match "מחוזי|district") { return "Legal\Legal-Research\Case-Law\District-Courts" }
    if ($t -match "שלום|magistrate|שלום") { return "Legal\Legal-Research\Case-Law\Magistrate-Courts" }
    return "Legal\Legal-Research\Case-Law"
}
