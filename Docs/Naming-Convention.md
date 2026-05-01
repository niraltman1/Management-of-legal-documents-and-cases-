# File Naming Convention / מוסכמת שמות קבצים

## Legal Files

**Format:** `[שם-משפחה]_[מספר-הליך]_[תאריך]_[סוג-מסמך].[ext]`

| Field | How it is determined |
|-------|----------------------|
| שם-משפחה | Client last name extracted from document text |
| מספר-הליך | Case/procedure number (e.g. `תא-2024-042`) from text |
| תאריך | Date found inside document; fallback to file DateModified |
| סוג-מסמך | Document type classified from content keywords |

**Examples:**

| Original | Renamed |
|----------|---------|
| `scan0042.jpg` | `כהן_תא-2024-042_2024-03-15_דוח-תנועה.jpg` |
| `IMG_20231114.pdf` | `לוי_87654321_2023-11-14_רישיון-נהיגה.pdf` |
| `document (3).docx` | `מזרחי_תא-2023-017_2023-06-01_כתב-תביעה.docx` |
| `verdict_final2.pdf` *(research)* | `פסק-דין-מחקר_עליון_2022-09-10.pdf` |
| `witness_statement.pdf` | `כהן_תפ-2023-005_2023-08-20_עדות-עד.pdf` |

**Fallback** (when no client/case found):
`[סוג-מסמך]_[4-char-hash]_[DateModified].[ext]`
e.g. `מסמך-לא-זוהה_a3f9_2024-01-15.pdf`

---

## Medical Files

**Format:** `[מקצוע]_[נושא-הרצאה]_[תאריך].[ext]`

The subject and lecture title are extracted from the file's content (headings, title slide, first lines).

**Examples:**

| Original | Renamed |
|----------|---------|
| `lecture5.pptx` | `אנטומיה_הרצאה5_מבנה-השריר_2024-02-15.pptx` |
| `scan_notes.pdf` | `פיזיולוגיה_מערכת-הלב_2024-03-10.pdf` |
| `IMG_20240110.jpg` | `פרמקולוגיה_מינוני-תרופות_2024-01-10.jpg` |

---

## Teaching Files

**Format:** `הוראה_[קורס]_[נושא]_[תאריך].[ext]`

**Examples:**

| Original | Renamed |
|----------|---------|
| `lecture5.pptx` | `הוראה_תאונות-דרכים_הרצאה5_שחזור_2024-01.pptx` |
| `security_exam.docx` | `הוראה_קב"ט_מבחן3_2023-11.docx` |

---

## Rules

1. No spaces — use hyphens within a field, underscores between fields
2. Date format is always `YYYY-MM-DD` (or `YYYY-MM` if only month known)
3. Hebrew characters are preserved — filenames are UTF-8
4. Extension is always lowercase
5. Maximum filename length: 200 characters
6. No special characters: `/ \ : * ? " < > |`
