# Legal File Organizer / מנהל קבצים משפטיים

An intelligent, Hebrew-first file organization system for Israeli lawyers.  
Scans every file on your PC, reads its content via OCR, extracts legal identifiers,  
renames files meaningfully, and organizes them into a structured folder taxonomy —  
all while building a searchable SQLite database ready for future cloud CRM integration.

---

## What It Does

| Step | What happens | Your files touched? |
|------|-------------|---------------------|
| Scan | Catalogs every file, computes MD5 hash | **No** |
| Extract | Reads text from PDFs, Word, images (OCR) | **No** |
| Parse | Finds ת.ז., case numbers, client names, document types | **No** |
| Build | Creates client/case records in database | **No** |
| Classify | Assigns domain + destination + new filename | **No** |
| Report | Generates HTML report you review in browser | **No** |
| **Apply** | **Moves/renames ONLY files you mark APPROVED** | **Yes — only what you approve** |

---

## Prerequisites (one-time setup)

### 1. PowerShell 5.1+
Already included in Windows 10/11.

### 2. PSSQLite (database module)
Open PowerShell and run:
```powershell
Install-Module PSSQLite -Scope CurrentUser
```

### 3. Tesseract OCR with Hebrew pack (for scanned documents and images)
```
choco install tesseract
```
Then download `heb.traineddata` and `eng.traineddata` from:  
`https://github.com/tesseract-ocr/tessdata`  
and place both files in:  
`C:\Program Files\Tesseract-OCR\tessdata\`

### 4. GhostScript (for converting scanned PDFs to images before OCR)
```
choco install ghostscript
```

### 5. iTextSharp (for extracting text from digital PDFs)
Download from NuGet (`iTextSharp` package), extract `itextsharp.dll`,  
and place it in: `Scripts\lib\deps\itextsharp.dll`

> **Note:** Steps 3–5 are only required for scanned documents and image files.  
> Word (DOCX), PowerPoint (PPTX), and text-based PDFs work without them.

---

## Quick Start

### Step 1 — Check prerequisites
```powershell
.\Scripts\Setup\00-Install-Prerequisites.ps1
```

### Step 2 — Set your root folder
Edit `Scripts\lib\Config.ps1` and change:
```powershell
$RootPath = "C:\MyFiles"   # ← change this to your actual folder
```

### Step 3 — Create the folder structure
```powershell
.\Scripts\Setup\01-CreateFolderStructure.ps1
```

### Step 4 — Run the full pipeline (or use the menu)
**Option A — Hebrew menu (recommended for non-technical users):**
```powershell
.\Scripts\START-HERE.ps1
```

**Option B — Full pipeline directly:**
```powershell
.\Scripts\Run-All.ps1
```

### Step 5 — Review the HTML report
The report opens automatically. Check:
- **לקוחות (Clients)** — all files per client
- **תיקים (Cases)** — all documents per case  
- **תוכנית פעולה (Action Plan)** — proposed renames and moves

### Step 6 — Approve and apply
Edit the `ActionPlan_*.csv` file: change `UserAction` from `PENDING` to `APPROVED`  
for each file you want renamed/moved. Then run:
```powershell
.\Scripts\Action\08-Apply-Approved.ps1 -CsvPath "path\to\ActionPlan_*.csv"
```

### Step 7 — Restore anything (if needed)
```powershell
# List all reversible actions
.\Scripts\Action\Restore-Quarantine.ps1 -ListOnly

# Restore a specific file
.\Scripts\Action\Restore-Quarantine.ps1 -FileID 42

# Full rollback to pre-run state (using saved manifest)
.\Scripts\Action\Restore-Quarantine.ps1 -ManifestFile "_Reports\Manifest_20240501_143022.json"
```

---

## Folder Structure Created

```
C:\MyFiles\
├── Legal\
│   ├── Clients\[שם-משפחה_שם-פרטי_ת.ז.]\
│   │   ├── Personal\{ID-Documents, Agreements, Correspondence}
│   │   └── Cases\[מספר-תיק]\
│   │       ├── Pleadings\, Motions\, Evidence\, Correspondence\, Verdicts\, Administrative\
│   │       └── חומר-חקירה\ (criminal cases only)
│   │           ├── עדויות\, מסמכי-משטרה\, ראיות-פיזיות\
│   ├── Legal-Research\{Case-Law, Legislation, Commentary}
│   ├── Contracts\, Templates\, Administrative\
├── Medical\{Courses, Research, Clinical-Materials}
├── Teaching\{Car-Accident-Investigation, Security-Officer-Training, Other-Courses}
├── Personal\{Finance, Property, Family-Documents, Health-Records}
├── _Quarantine\  ← probable duplicates, kept 30 days
└── _Inbox\       ← landing zone for new files
```

---

## File Naming Convention

**Legal files:**
```
[שם-משפחה]_[מספר-הליך]_[YYYY-MM-DD]_[סוג-מסמך].[ext]
```
Examples:
- `scan0042.jpg` → `כהן_תא-2024-042_2024-03-15_דוח-תנועה.jpg`
- `document (3).docx` → `מזרחי_תא-2023-017_2023-06-01_כתב-תביעה.docx`

**Medical files:**
```
[מקצוע]_[נושא]_[YYYY-MM-DD].[ext]
```
Example: `lecture5.pptx` → `אנטומיה_מבנה-השריר_2024-02-15.pptx`

**Research verdicts** (not your cases — for reference only):
```
פסק-דין-מחקר_[בית-משפט]_[YYYY-MM-DD].[ext]
```

---

## Duplicate Detection

Duplicates are detected by **file content** (MD5 hash), **not by filename**.  
Two files with similar names but different content are **never** flagged as duplicates.

| Tier | What happens |
|------|-------------|
| Auto | File in junk location (Desktop, Downloads) + identical copy in organized folder → moved to `_Quarantine\[date]\` automatically |
| Review | Both copies in organized folders → shown in report, you decide |
| Never touched | Files containing a ת.ז. number, single copies, low OCR confidence |

---

## Database / CRM

The SQLite database at `_Reports\LegalOrganizer.db` is designed for future cloud integration:

| Table | Purpose |
|-------|---------|
| `Files` | Every file cataloged |
| `FileContent` | Full extracted text (Hebrew UTF-8) |
| `FileContent_FTS` | Full-text search index (FTS5) |
| `ParsedIdentifiers` | ת.ז., case numbers, dates, per-field confidence |
| `Clients` | Client master records |
| `Cases` | Case records, linked to clients |
| `Hearings` | Court hearing dates, linked to cases |
| `LegalArguments` | Legal arguments for future knowledge base |
| `ActionLog` | Every rename/move — permanent, used for restore |

**Full-text search** (run directly in any SQLite browser tool):
```sql
SELECT f.OriginalName, snippet(FileContent_FTS,1,'>>','<<','...',20)
FROM FileContent_FTS
JOIN Files f ON f.FileID = FileContent_FTS.FileID
WHERE FileContent_FTS MATCH 'כהן פסק דין';
```

---

## Safety Guarantees

1. **Scripts 02–07 never touch your files** — read-only pipeline
2. **Script 08 only moves files you explicitly mark APPROVED**
3. **Every action logged** in `ActionLog` table — always reversible
4. **No file is ever deleted** — duplicates go to `_Quarantine`, not trash
5. **Files containing ת.ז. numbers** are never auto-quarantined
6. **Domains never mix** — medical files never get classified as legal, and vice versa

---

## Troubleshooting

| Problem | Solution |
|---------|---------|
| Hebrew text garbled in CSV | Open in Excel with UTF-8 encoding, or use Notepad++ |
| OCR confidence very low | Scan quality too poor — move file to `_Inbox\To-Review` manually |
| Script won't run | Run: `Set-ExecutionPolicy RemoteSigned -Scope CurrentUser` |
| PSSQLite not found | Run: `Install-Module PSSQLite -Scope CurrentUser` |
| Tesseract not found | Check path in `Config.ps1` → `$TesseractExe` |

---

## File Count Reference

```
Scripts\
├── lib\          → 7 library modules
├── Setup\        → 2 scripts
├── Pipeline\     → 6 pipeline scripts
├── Action\       → 2 action scripts
├── Run-All.ps1
└── START-HERE.ps1 (Hebrew menu — start here)
```
