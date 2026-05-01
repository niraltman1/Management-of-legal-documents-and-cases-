# Folder Structure / מבנה תיקיות

## Root: `C:\MyFiles\` (configured in `Scripts\lib\Config.ps1`)

```
C:\MyFiles\
│
├── Legal\
│   ├── Clients\
│   │   └── [שם-משפחה_שם-פרטי_מסתז]\         e.g. כהן_יוסף_123456782\
│   │       ├── Personal\
│   │       │   ├── ID-Documents\               תעודת זהות, דרכון, רישיון נהיגה
│   │       │   ├── Agreements\                 הסכם שכ"ט, ייפוי כוח
│   │       │   └── Correspondence\             מכתבים כלליים ללקוח
│   │       └── Cases\
│   │           └── [מספר-הליך_שם-תיק]\         e.g. תא-2024-042_כהן-נגד-לוי\
│   │               ├── Pleadings\              כתב תביעה, כתב הגנה, ערעור, תצהיר
│   │               ├── Motions\                בקשות, תגובות, החלטות, צווים
│   │               ├── Evidence\               תמונות, דוחות, מסמכים ראייתיים
│   │               ├── Correspondence\         מכתבים הקשורים לתיק
│   │               ├── Verdicts\               פסק דין, פסקי ביניים
│   │               ├── Administrative\         חשבוניות, פנקסי שכ"ט
│   │               └── [CRIMINAL ONLY]
│   │                   └── חומר-חקירה\
│   │                       ├── עדויות\         עדי תביעה, גרסאות עדים
│   │                       ├── מסמכי-משטרה\    דוחות חקירה, הודעות נאשם
│   │                       └── ראיות-פיזיות\   תמונות זירה, חוות דעת
│   │
│   ├── Legal-Research\
│   │   ├── Case-Law\
│   │   │   ├── Supreme-Court\                  בית משפט עליון
│   │   │   ├── District-Courts\                בתי משפט מחוזיים
│   │   │   └── Magistrate-Courts\              בתי משפט שלום
│   │   ├── Legislation\                        חוקים, תקנות, צווים
│   │   └── Commentary\                         מאמרים, ספרות משפטית
│   │
│   ├── Court-Filings\                          מסמכים שהוגשו טרם שויכו לתיק
│   ├── Contracts\                              חוזים כלליים
│   ├── Templates\                              נוסחאות, טפסים ריקים
│   └── Administrative\                         לשכת עו"ד, ביטוחים מקצועיים
│
├── Medical\
│   ├── Courses\
│   │   └── [Year]\[Subject]\
│   │       ├── Lectures\
│   │       ├── Lab\
│   │       ├── Study-Guides\
│   │       └── Exams\
│   ├── Research\
│   │   ├── Published-Papers\
│   │   └── Own-Research\
│   │       ├── Data\
│   │       └── Drafts\
│   └── Clinical-Materials\
│
├── Teaching\
│   ├── Car-Accident-Investigation\
│   │   ├── Lectures\
│   │   │   ├── Slides\
│   │   │   └── Handouts\
│   │   ├── Case-Studies\
│   │   ├── Exams\
│   │   │   ├── Question-Banks\
│   │   │   └── Graded\
│   │   └── Resources\
│   │       ├── Legislation\
│   │       ├── Technical-Standards\
│   │       └── Photos\
│   ├── Security-Officer-Training\
│   │   ├── Lectures\
│   │   │   ├── Slides\
│   │   │   └── Handouts\
│   │   ├── Regulatory\
│   │   └── Exams\
│   │       ├── Question-Banks\
│   │       └── Graded\
│   └── Other-Courses\
│       └── [CourseName]\
│           ├── Lectures\
│           ├── Exercises\
│           └── Exams\
│
├── Personal\
│   ├── Finance\
│   │   ├── Tax-Returns\
│   │   ├── Bank-Statements\
│   │   └── Insurance\
│   ├── Property\
│   ├── Family-Documents\
│   └── Health-Records\
│
├── _Quarantine\                                כפולים אפשריים — נשמרים 30 יום
│   └── [YYYY-MM-DD]\
│
└── _Inbox\
    ├── To-Review\                              ביטחון נמוך — דורש בדיקה ידנית
    └── Compressed\                             קבצי ZIP/RAR — פתח ידנית
```

## Naming Convention / מוסכמת שמות

### Legal files:
```
[שם-משפחה]_[מספר-הליך]_[תאריך]_[סוג-מסמך].[ext]
```
Example: `כהן_תא-2024-042_2024-03-15_כתב-תביעה.pdf`

### Medical files:
```
[מקצוע]_[נושא-הרצאה]_[תאריך].[ext]
```
Example: `אנטומיה_הרצאה5_מבנה-השריר_2024-02-15.pptx`

### Teaching files:
```
הוראה_[קורס]_[נושא]_[תאריך].[ext]
```
Example: `הוראה_תאונות-דרכים_הרצאה3_2024-01.pptx`

### Research verdicts (not your cases):
```
פסק-דין-מחקר_[ערכאה]_[תאריך].[ext]
```
Example: `פסק-דין-מחקר_עליון_2022-09-10.pdf`
