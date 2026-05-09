#Requires -Version 5.1
<#
.SYNOPSIS
    נקודת כניסה למשתמש — תפריט ראשי בעברית.
    הפעל בלחיצה כפולה או מ-PowerShell: .\START-HERE.ps1
    אין צורך בידע תכנותי.
#>

[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding = [System.Text.Encoding]::UTF8

$ScriptDir = $PSScriptRoot
. "$ScriptDir\lib\Config.ps1"
. "$ScriptDir\lib\LegalAI.ps1"

# Auto-download itextsharp.dll if missing
$_dll = Join-Path $ScriptDir "lib\deps\itextsharp.dll"
if (-not (Test-Path $_dll)) {
    Write-Host "  itextsharp.dll חסר — מוריד אוטומטית..." -ForegroundColor Yellow
    & "$ScriptDir\Setup\Download-Dependencies.ps1"
}

function Show-Menu {
    Clear-Host
    $aiStatus = if (Test-OllamaAvailable) { " [AI: ON]" } else { "" }
    Write-Host ""
    Write-Host "  ╔══════════════════════════════════════════════╗" -ForegroundColor Cyan
    Write-Host "  ║     מנהל קבצים משפטיים — תפריט ראשי         ║" -ForegroundColor Cyan
    Write-Host "  ╠══════════════════════════════════════════════╣" -ForegroundColor Cyan
    Write-Host "  ║  תיקיית שורש: $($script:RootPath.PadRight(30))║" -ForegroundColor Gray
    if ($aiStatus) {
        Write-Host "  ║  $('AI: law-il-E2B פעיל'.PadRight(44))║" -ForegroundColor Green
    }
    Write-Host "  ╚══════════════════════════════════════════════╝" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "  [1]  סרוק את כל הקבצים ובנה מסד נתונים" -ForegroundColor White
    Write-Host "       (בפעם הראשונה — לוקח זמן בהתאם לכמות הקבצים)" -ForegroundColor Gray
    Write-Host ""
    Write-Host "  [2]  הפק דוח HTML ופתח בדפדפן" -ForegroundColor White
    Write-Host "       (לאחר סריקה — מציג לקוחות, תיקים, הצעות לשמות)" -ForegroundColor Gray
    Write-Host ""
    Write-Host "  [3]  אשר שינויים מקובץ CSV ובצע העברה" -ForegroundColor White
    Write-Host "       (לאחר שסימנת APPROVED בקובץ ActionPlan)" -ForegroundColor Gray
    Write-Host ""
    Write-Host "  [4]  שחזר קובץ שהועבר" -ForegroundColor White
    Write-Host "       (בטל כל פעולה שבוצעה — אפשרי תמיד)" -ForegroundColor Gray
    Write-Host ""
    Write-Host "  [5]  סקור תיקיית הסגר (_Quarantine)" -ForegroundColor White
    Write-Host "       (הצג קבצים כפולים שהוסגרו — החלט מה לעשות איתם)" -ForegroundColor Gray
    Write-Host ""
    Write-Host "  [6]  בדוק ספריות נחיתה (_Inbox)" -ForegroundColor White
    Write-Host ""
    Write-Host "  [7]  הגדרות — שנה תיקיית שורש" -ForegroundColor White
    Write-Host ""
    if ($aiStatus) {
        Write-Host "  [8]  סריקה + ניתוח AI מלא (law-il-E2B)" -ForegroundColor Magenta
        Write-Host "       (זיהוי קבצים + מועדי הגשה + ניתוח סתירות)" -ForegroundColor DarkGray
        Write-Host ""
        Write-Host "  [9]  כלי עוזר AI לתיק ספציפי" -ForegroundColor Magenta
        Write-Host "       (הכן Brief לדיון / צור טיוטת מסמך / הצג ציר זמן)" -ForegroundColor DarkGray
    } else {
        Write-Host "  [8]  התקן בינה מלאכותית (Ollama + law-il-E2B)" -ForegroundColor DarkGray
        Write-Host "       (דרוש אינטרנט, ~3.4 GB — מאיץ זיהוי ומוסיף מועדי הגשה)" -ForegroundColor DarkGray
        Write-Host ""
        Write-Host "  [9]  כלי עוזר AI (דורש התקנת [8] תחילה)" -ForegroundColor DarkGray
    }
    Write-Host ""
    Write-Host "  [0]  יציאה" -ForegroundColor DarkGray
    Write-Host ""
}

function Confirm-Action {
    param([string]$Message)
    Write-Host "  $Message" -ForegroundColor Yellow
    $r = Read-Host "  האם להמשיך? (כן/לא)"
    return $r -match '^כ|^y|^Y'
}

$running = $true
while ($running) {
    Show-Menu
    $choice = Read-Host "  בחר אפשרות (0-9)"

    switch ($choice) {
        "1" {
            Write-Host ""
            Write-Host "  מתחיל סריקה מלאה..." -ForegroundColor Cyan
            Write-Host "  (ניתן להפסיק ב-Ctrl+C ולהמשיך מאוחר יותר — הסריקה ממשיכה מאיפה שנעצרה)" -ForegroundColor Gray
            Write-Host ""
            & "$ScriptDir\Run-All.ps1"
            Read-Host "  הקש Enter לחזרה לתפריט"
        }
        "2" {
            Write-Host ""
            Write-Host "  מפיק דוח HTML..." -ForegroundColor Cyan
            & "$ScriptDir\Pipeline\07-Generate-Report.ps1"
            Read-Host "  הקש Enter לחזרה לתפריט"
        }
        "3" {
            Write-Host ""
            $csvPath = Read-Host "  הזן נתיב לקובץ ActionPlan CSV"
            if (Test-Path $csvPath) {
                if (Confirm-Action "תועברנה רק קבצים עם UserAction=APPROVED. כל שאר הקבצים לא ייגעו.") {
                    & "$ScriptDir\Action\08-Apply-Approved.ps1" -CsvPath $csvPath
                }
            } else {
                Write-Host "  הקובץ לא נמצא: $csvPath" -ForegroundColor Red
            }
            Read-Host "  הקש Enter לחזרה לתפריט"
        }
        "4" {
            Write-Host ""
            Write-Host "  ── שחזור קבצים ──" -ForegroundColor Yellow
            Write-Host "  [A]  הצג רשימת פעולות שניתנות לשחזור"
            Write-Host "  [B]  שחזר קובץ ספציפי (לפי FileID)"
            Write-Host "  [C]  שחזר הכל מקובץ Manifest (גיבוי שלם)"
            $sub = Read-Host "  בחר"
            switch ($sub.ToUpper()) {
                "A" { & "$ScriptDir\Action\Restore-Quarantine.ps1" -ListOnly }
                "B" {
                    $fid = Read-Host "  הזן FileID"
                    & "$ScriptDir\Action\Restore-Quarantine.ps1" -FileID ([int]$fid)
                }
                "C" {
                    $mf = Read-Host "  הזן נתיב לקובץ Manifest JSON"
                    & "$ScriptDir\Action\Restore-Quarantine.ps1" -ManifestFile $mf
                }
            }
            Read-Host "  הקש Enter לחזרה לתפריט"
        }
        "5" {
            Write-Host ""
            Write-Host "  ── סקירת _Quarantine ──" -ForegroundColor Yellow
            Write-Host "  [A]  הצג תוכן (בלי שינויים)"
            Write-Host "  [B]  בחר קובץ לשחזור"
            Write-Host "  [C]  מחק קבצים ישנים (לאחר $($script:QuarantineDays) ימים)"
            $sub = Read-Host "  בחר"
            switch ($sub.ToUpper()) {
                "A" { & "$ScriptDir\Action\Review-Quarantine.ps1" -ListOnly }
                "B" { & "$ScriptDir\Action\Review-Quarantine.ps1" }
                "C" { & "$ScriptDir\Action\Review-Quarantine.ps1" -AutoPurge }
            }
            Read-Host "  הקש Enter לחזרה לתפריט"
        }
        "6" {
            Write-Host ""
            $inboxPath = Join-Path $script:RootPath "_Inbox"
            if (Test-Path $inboxPath) {
                $files = Get-ChildItem $inboxPath -Recurse -File
                Write-Host "  קבצים ב-_Inbox: $($files.Count)" -ForegroundColor Cyan
                $files | ForEach-Object { Write-Host "    $($_.FullName)" }
            } else {
                Write-Host "  תיקיית _Inbox לא נמצאה. הפעל תחילה את אפשרות [1]." -ForegroundColor Yellow
            }
            Read-Host "  הקש Enter לחזרה לתפריט"
        }
        "7" {
            Write-Host ""
            Write-Host "  תיקייה נוכחית: $($script:RootPath)" -ForegroundColor Gray
            $newPath = Read-Host "  הזן תיקיית שורש חדשה (Enter לביטול)"
            if ($newPath -and (Test-Path $newPath)) {
                # Update Config.ps1
                $configPath = "$ScriptDir\lib\Config.ps1"
                $content    = Get-Content $configPath -Encoding UTF8 -Raw
                $content    = $content -replace '\$RootPath\s*=\s*"[^"]*"', "`$RootPath = `"$newPath`""
                Set-Content -Path $configPath -Value $content -Encoding UTF8
                . "$ScriptDir\lib\Config.ps1"   # reload
                Write-Host "  תיקייה עודכנה: $newPath" -ForegroundColor Green
            } elseif ($newPath) {
                Write-Host "  התיקייה לא נמצאה: $newPath" -ForegroundColor Red
            }
            Read-Host "  הקש Enter לחזרה לתפריט"
        }
        "8" {
            Write-Host ""
            if (Test-OllamaAvailable) {
                Write-Host "  מריץ סריקה מלאה עם ניתוח AI..." -ForegroundColor Magenta
                Write-Host "  כולל: זיהוי מסמכים + חישוב מועדי הגשה + ניתוח סתירות" -ForegroundColor Gray
                Write-Host ""
                & "$ScriptDir\Run-All.ps1" -UseAI
            } else {
                Write-Host "  Ollama לא מותקן — מתחיל התקנה (~3.4 GB)..." -ForegroundColor Yellow
                & "$ScriptDir\Setup\02b-Install-Ollama.ps1"
            }
            Read-Host "  הקש Enter לחזרה לתפריט"
        }
        "9" {
            Write-Host ""
            if (-not (Test-OllamaAvailable)) {
                Write-Host "  ⚠ Ollama לא זמין. הרץ תחילה אפשרות [8] להתקנה." -ForegroundColor Yellow
                Read-Host "  הקש Enter לחזרה לתפריט"
            } else {
                Write-Host "  ── כלי עוזר AI ──" -ForegroundColor Magenta
                Write-Host "  [A]  הכן Brief לדיון (ניתוח סתירות + שאלות לחקירה נגדית)"
                Write-Host "  [B]  צור טיוטת מסמך משפטי (AI)"
                Write-Host "  [C]  הפק דוח HTML עם ציר זמן ו-Brief"
                $sub = Read-Host "  בחר"
                switch ($sub.ToUpper()) {
                    "A" {
                        Write-Host ""
                        $cidIn = Read-Host "  הזן CaseID (0 = כל התיקים הפעילים)"
                        $cidVal = [int]$cidIn
                        if ($cidVal -gt 0) {
                            & "$ScriptDir\Pipeline\09-Prepare-Brief.ps1" -DbPath $script:DbPath -CaseID $cidVal
                        } else {
                            & "$ScriptDir\Pipeline\09-Prepare-Brief.ps1" -DbPath $script:DbPath
                        }
                    }
                    "B" {
                        Write-Host ""
                        $cidIn2 = Read-Host "  הזן CaseID"
                        if ($cidIn2 -match '^\d+$') {
                            & "$ScriptDir\Pipeline\10-Generate-Document.ps1" -DbPath $script:DbPath -CaseID ([int]$cidIn2)
                        } else {
                            & "$ScriptDir\Pipeline\10-Generate-Document.ps1" -DbPath $script:DbPath
                        }
                    }
                    "C" {
                        Write-Host ""
                        Write-Host "  מפיק דוח HTML עם ציר זמן..." -ForegroundColor Cyan
                        & "$ScriptDir\Pipeline\07-Generate-Report.ps1"
                    }
                }
                Read-Host "  הקש Enter לחזרה לתפריט"
            }
        }
        "0"     { $running = $false }
        default { Write-Host "  בחירה לא תקינה." -ForegroundColor Red; Start-Sleep 1 }
    }
}

Write-Host ""
Write-Host "  להתראות!" -ForegroundColor Cyan
Write-Host ""
