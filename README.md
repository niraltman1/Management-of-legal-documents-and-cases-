# Legal-OS v3.0 — Visual Legal Operating System

> **Hebrew-first, AI-powered legal knowledge platform for Israeli lawyers.**
> Scans your PC, OCRs every document, builds a graph of laws → cases → decisions → evidence, and reasons across them with an explainable 5-step AI engine — all on-device, no data leaves your machine.

---

## What it does

Legal-OS is three things in one:

| Layer | What it does |
|---|---|
| **File organiser** | Scans Windows PC, OCRs PDFs/images, extracts ת.ז./case numbers, rebuilds the filesystem into `Legal\Clients\[name_id]\Cases\[number]\{Pleadings,Motions,Evidence,…}` |
| **Knowledge graph** | Every entity (law, section, decision, case, judge, client, evidence, task) becomes a node with typed, confidence-scored edges |
| **Reasoning engine** | On-device Graph-RAG AI (Law-IL E2B via Ollama) — 5-step reasoning: *Context → Classification → Authorities → Conflict/Risk → Practical Conclusion* |

---

## Quick start

```powershell
# 1. Install dependencies
.\Scripts\Setup\01-Install-Dependencies.ps1

# 2. (Optional) Install Ollama + Law-IL E2B for AI features
.\Scripts\Setup\02b-Install-Ollama.ps1

# 3. Interactive menu — choose what to run
.\Scripts\START-HERE.ps1

# 4. Or run the full pipeline at once
.\Scripts\Run-All.ps1 -RootPath "C:\MyFiles" -UseAI
```

---

## Pipeline — step by step

| Script | What it does |
|---|---|
| `02-Scan-Files.ps1` | Walks the directory tree; records every file in SQLite |
| `03-Extract-Content.ps1` | Extracts text — native PDF parser → OCR fallback (Tesseract/Windows OCR) |
| `04-Parse-Identifiers.ps1` | Detects ת.ז., case numbers (`תא-`, `בג"ץ`, `ת"פ`…), document types |
| `04b-AI-Enrich.ps1` | Law-IL E2B enrichment — classifies documents not caught by regex |
| `05-Build-Clients-Cases.ps1` | Groups files → clients → cases; infers court type |
| `06-Classify-And-Plan.ps1` | Builds `FilePlan` table — SuggestedName, SuggestedPath for each file |
| `07-Generate-Report.ps1` | **Self-contained HTML report** — tabs: Summary, Clients, Cases, ⏱ Timeline, ⚖ Brief, Tasks, Action Plan, Duplicates, Search. Mark procedural steps as done directly from the browser |
| `08-Apply-Approved.ps1` | Physically moves/renames files that you APPROVED in the report |
| **`09-Prepare-Brief.ps1`** | **v3.0** — AI procedural analysis: calculates deadlines per 20 Israeli rules, detects contradictions across documents, generates cross-examination questions |
| **`10-Generate-Document.ps1`** | **v3.0** — AI document drafter: suggests the next required document, generates Hebrew draft, exports to `.docx` (native Open XML, no pandoc) or `.md` |
| **`11-Open-Workspace.ps1`** | **v3.0** — Opens the dark-mode knowledge graph workspace with live DB data: SVG graph canvas, 5-step reasoning side panel, procedural timeline dock, case dashboard |

---

## AI features (v3.0)

All AI runs **locally** via [Ollama](https://ollama.ai/) + the `BrainboxAI/law-il-E2B` model. No internet connection required after setup. Attorney-client privilege preserved.

### 5-step reasoning engine

Every AI assertion follows an explainable chain:

1. **Context** — entity type and source documents
2. **Legal classification** — document type, court, procedure type
3. **Authorities** — statutes and precedents cited or applicable
4. **Conflict / risk** — contradictions with other documents or precedents
5. **Practical conclusion** — actionable recommendation

### Procedural deadline engine

20 Israeli procedural rules seeded automatically:

- Civil standard (תקנות סדר הדין האזרחי)
- Fast-track (סדר דין מקוצר)
- Small claims (תביעות קטנות)
- Labor court (בית דין לעבודה)
- Family court (בית משפט לענייני משפחה)
- Criminal (סדר הדין הפלילי)

The engine calculates `ExpectedDate` for every required step from the trigger event (complaint filed, first hearing, etc.), flags missed deadlines in red, and surfaces them in both the HTML report Timeline tab and the workspace timeline dock.

### Contradiction analysis

`09-Prepare-Brief.ps1` compares document pairs within each case, identifies factual/legal contradictions, and stores them in the `Case_Brief` table. Results appear in the ⚖ Brief tab of the HTML report and the AI view of the workspace.

### Document drafter

`10-Generate-Document.ps1` suggests the next document required by the procedural calendar, then generates a full Hebrew draft using the Law-IL E2B model. Output: `.docx` (native Word XML, opens directly in Microsoft Word or LibreOffice) or `.md`.

---

## Knowledge graph workspace (Step 11)

`11-Open-Workspace.ps1` generates a self-contained dark-mode HTML workspace and opens it in your default browser. Features:

- **SVG graph canvas** — nodes for each active case + law/procedure/AI-insight entities, typed edges
- **Glassmorphism side panel** — click any node to inspect: entity summary, 5-step reasoning, related contradictions/AI insights, action buttons
- **Procedural timeline dock** — compact timeline strip at the bottom showing upcoming and overdue deadlines
- **Case dashboard** — KPI tiles (active cases, open deadlines, AI insights, files indexed), cases table, AI insights feed
- **Command palette** — Ctrl+K to search cases and entities instantly

No internet connection or build step required — everything is inline HTML/JS.

---

## Database schema

SQLite database at `_Reports\legal_os.db` (default). Core tables:

| Table | Purpose |
|---|---|
| `Files` | Every file scanned — path, size, domain, OCR confidence |
| `FileContent` | Extracted text, OCR method, FTS5 full-text search |
| `ParsedIdentifiers` | ת.ז., case numbers, document types extracted per file |
| `Clients` | Deduplicated client records with ת.ז. |
| `Cases` | Case records linked to clients — number, type, status, court |
| `Tasks` | Deadlines and to-do items per case |
| `FilePlan` | Rename/move plan — SuggestedName, SuggestedPath, UserAction |
| `Duplicates` | Duplicate groups by MD5 hash + quarantine tier |
| `Rules_Engine` | 20 Israeli procedural rules — trigger, days, legal basis |
| `Procedural_Steps` | Calculated deadline per case per rule — Expected/ActualDate, Status |
| `Case_Brief` | AI output — contradictions, cross-exam questions, next-document suggestions |

---

## Setup requirements

| Requirement | Notes |
|---|---|
| PowerShell 5.1+ | Built-in on Windows 10/11 |
| PSSQLite module | Installed automatically by `01-Install-Dependencies.ps1` |
| Tesseract OCR (optional) | For scanned PDFs/images — installer in `Scripts\Setup\` |
| Ollama (optional) | Required for Steps 4b, 9, 10, and the AI graph workspace |
| Law-IL E2B model | `ollama pull BrainboxAI/law-il-E2B:Q4_K_M` — ~1.4 GB |

The pipeline runs without Ollama — AI steps are skipped gracefully with a clear warning.

---

## Output structure

```
_Reports\
  legal_os.db             ← SQLite database (all structured data)
  Report_YYYYMMDD.html    ← HTML report (self-contained, open in any browser)
  Workspace_YYYYMMDD.html ← Knowledge graph workspace
  Drafts\
    תא-2024-042_כתב-תביעה_20240522.docx   ← AI-generated document drafts
```

---

## Configuration

Edit `Scripts\lib\Config.ps1` to change defaults:

```powershell
$script:DbPath     = "$RootPath\_Reports\legal_os.db"
$script:OutputPath = "$RootPath\_Reports"
$script:OllamaUrl  = "http://localhost:11434"   # Ollama REST endpoint
```

---

## Supported Israeli legal identifiers

| Pattern | Example |
|---|---|
| ת.ז. (ID number) | `123456782` |
| Civil — Magistrate | `תא-2024-042` |
| Criminal | `ת"פ-2023-005` |
| Supreme Court | `בג"ץ 6821/93` |
| Civil Appeal | `ע"א 5678/22` |
| Labor | `עב-2024-001` |
| Family | `תמש-2024-010` |
| Administrative | `עת"מ-2023-088` |

---

## Architecture

```
START-HERE.ps1 / Run-All.ps1
    │
    ├── 02 Scan Files
    ├── 03 Extract Content (PDF native → OCR)
    ├── 04 Parse Identifiers (regex + AI)
    ├── 05 Build Clients/Cases
    ├── 06 Classify & Plan
    ├── 07 Generate HTML Report  ← Mark-as-Done HTTP listener (port 8765)
    ├── 08 Apply Approved (move/rename files)
    ├── 09 Prepare Brief  ← AI: deadlines + contradictions + cross-exam
    ├── 10 Generate Document  ← AI draft → .docx / .md
    └── 11 Open Workspace  ← Dark-mode knowledge graph UI
```

---

## Hebrew / RTL notes

- All text storage and display is UTF-8.
- The HTML report and workspace are `dir="rtl"` by default.
- Hebrew fonts: Heebo (sans) + David Libre (serif, for formal legal documents).
- The AI model is trained on Israeli legal Hebrew and uses formal register throughout.
- Document drafts use formal Israeli legal style: `כבוד בית המשפט`, `לבית המשפט הנכבד`.

---

## Contributing / extending

- **Add procedural rules**: Insert rows into `Rules_Engine` — `ProcedureType`, `StepName`, `DaysFromTrigger`, `TriggerEvent`, `LegalBasis`.
- **Add document types**: Extend the regex patterns in `Scripts\lib\IdentifierParser.ps1`.
- **Extend the graph**: Add more node types in `11-Open-Workspace.ps1` `NODE_COLORS` map.
- **Custom AI prompts**: Edit `$script:LawILE2BSystemPrompt` in `Scripts\lib\LegalAI.ps1`.

---

## License

MIT — see `LICENSE` file. Legal-OS is a tool, not legal advice.
