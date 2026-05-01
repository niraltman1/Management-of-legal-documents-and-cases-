#Requires -Version 5.1
<#
.SYNOPSIS
    Central configuration for the Legal File Organizer.
    Edit $RootPath below before running any script.
#>

# ── USER SETTINGS ─────────────────────────────────────────────────────────────

# Root folder on your PC where all organized files will live
$RootPath = "C:\MyFiles"

# Where Tesseract is installed (default Chocolatey path)
$TesseractExe = "C:\Program Files\Tesseract-OCR\tesseract.exe"

# Where GhostScript is installed
$GsExe = "C:\Program Files\gs\gs10.03.1\bin\gswin64c.exe"

# Minimum OCR confidence to auto-classify (0-100). Below this → _Inbox\To-Review
$OcrConfidenceThreshold = 50

# Days to keep files in _Quarantine before prompting for permanent decision
$QuarantineDays = 30

# ── SYSTEM SETTINGS (do not change) ───────────────────────────────────────────

$ScriptRoot    = $PSScriptRoot
$RepoRoot      = Split-Path (Split-Path $ScriptRoot -Parent) -Parent
$OutputPath    = Join-Path $RootPath "_Reports"
$DbPath        = Join-Path $OutputPath "LegalOrganizer.db"
$QuarantinePath= Join-Path $RootPath "_Quarantine"
$InboxPath     = Join-Path $RootPath "_Inbox"
$RunStamp      = Get-Date -Format "yyyyMMdd_HHmmss"
$iTextSharpDll = Join-Path $ScriptRoot "deps\itextsharp.dll"
$OcrTempDir    = Join-Path $env:TEMP "LegalOCR_Temp"

# Force UTF-8 throughout so Hebrew filenames survive CSV/HTML round-trips
[Console]::OutputEncoding        = [System.Text.Encoding]::UTF8
$OutputEncoding                  = [System.Text.Encoding]::UTF8
$PSDefaultParameterValues['*:Encoding'] = 'UTF8'

# Ensure output folder exists
if (-not (Test-Path $OutputPath)) { New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null }
if (-not (Test-Path $OcrTempDir)) { New-Item -ItemType Directory -Path $OcrTempDir  -Force | Out-Null }

# ── FOLDER TAXONOMY ────────────────────────────────────────────────────────────
# Used by 01-CreateFolderStructure.ps1 and DocumentClassifier.ps1

$FolderTree = @(
    "Legal\Clients"
    "Legal\Legal-Research\Case-Law\Supreme-Court"
    "Legal\Legal-Research\Case-Law\District-Courts"
    "Legal\Legal-Research\Case-Law\Magistrate-Courts"
    "Legal\Legal-Research\Legislation"
    "Legal\Legal-Research\Commentary"
    "Legal\Court-Filings"
    "Legal\Contracts"
    "Legal\Templates"
    "Legal\Administrative"
    "Medical\Courses"
    "Medical\Research\Published-Papers"
    "Medical\Research\Own-Research\Data"
    "Medical\Research\Own-Research\Drafts"
    "Medical\Clinical-Materials"
    "Teaching\Car-Accident-Investigation\Lectures\Slides"
    "Teaching\Car-Accident-Investigation\Lectures\Handouts"
    "Teaching\Car-Accident-Investigation\Case-Studies"
    "Teaching\Car-Accident-Investigation\Exams\Question-Banks"
    "Teaching\Car-Accident-Investigation\Exams\Graded"
    "Teaching\Car-Accident-Investigation\Resources\Legislation"
    "Teaching\Car-Accident-Investigation\Resources\Technical-Standards"
    "Teaching\Car-Accident-Investigation\Resources\Photos"
    "Teaching\Security-Officer-Training\Lectures\Slides"
    "Teaching\Security-Officer-Training\Lectures\Handouts"
    "Teaching\Security-Officer-Training\Regulatory"
    "Teaching\Security-Officer-Training\Exams\Question-Banks"
    "Teaching\Security-Officer-Training\Exams\Graded"
    "Teaching\Other-Courses"
    "Personal\Finance\Tax-Returns"
    "Personal\Finance\Bank-Statements"
    "Personal\Finance\Insurance"
    "Personal\Property"
    "Personal\Family-Documents"
    "Personal\Health-Records"
    "_Inbox\To-Review"
    "_Inbox\Compressed"
    "_Quarantine"
)

# Client case subfolders (created dynamically per case)
$CaseFolders = @("Pleadings","Motions","Evidence","Correspondence","Verdicts","Administrative")
$CriminalExtraFolders = @("חומר-חקירה\עדויות","חומר-חקירה\מסמכי-משטרה","חומר-חקירה\ראיות-פיזיות")

# ── MEDICAL SUBJECTS ──────────────────────────────────────────────────────────
$MedicalSubjects = @(
    "אנטומיה","פיזיולוגיה","ביוכימיה","פתולוגיה","פרמקולוגיה",
    "מיקרוביולוגיה","נוירולוגיה","כירורגיה","רדיולוגיה","אורתופדיה",
    "רפואת-ילדים","גינקולוגיה","פסיכיאטריה","רפואה-פנימית","אתיקה-רפואית",
    "anatomy","physiology","biochemistry","pathology","pharmacology",
    "microbiology","neurology","surgery","radiology","pediatrics",
    "psychiatry","internal medicine","medical ethics"
)
