#Requires -Version 5.1
<#
.SYNOPSIS
    Downloads and installs Ollama for Windows, then pulls the BrainboxAI/law-il-E2B model.
    Run ONCE before using the AI enrichment feature.
    Requires internet access (~3.5 GB download for the model).
    Does NOT require Administrator rights.
#>

[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$ErrorActionPreference = "Continue"

Write-Host ""
Write-Host "================================================" -ForegroundColor Cyan
Write-Host "  Legal AI Setup — Ollama + law-il-E2B" -ForegroundColor Cyan
Write-Host "================================================" -ForegroundColor Cyan
Write-Host ""

$model = "hf.co/BrainboxAI/law-il-E2B:Q4_K_M"

# ── 1. Check if Ollama already installed ──────────────────────────────────────
$ollamaExe = Get-Command ollama -ErrorAction SilentlyContinue
if ($ollamaExe) {
    Write-Host "[1/3] Ollama כבר מותקן: $($ollamaExe.Source)" -ForegroundColor Green
} else {
    Write-Host "[1/3] מוריד Ollama לWindows..." -ForegroundColor Cyan

    $setupPath = Join-Path $env:TEMP "OllamaSetup.exe"
    try {
        $wc = New-Object System.Net.WebClient
        $wc.DownloadFile("https://ollama.com/download/OllamaSetup.exe", $setupPath)
        Write-Host "  הורד ($([math]::Round((Get-Item $setupPath).Length/1MB,1)) MB)" -ForegroundColor Gray

        Write-Host "  מתקין בשקט (ייתכן שיקח דקה)..." -ForegroundColor Yellow
        $proc = Start-Process -FilePath $setupPath -ArgumentList "/silent" -Wait -PassThru
        Remove-Item $setupPath -Force -ErrorAction SilentlyContinue

        if ($proc.ExitCode -ne 0) {
            Write-Host "  אזהרה: קוד יציאה $($proc.ExitCode) — בדוק ידנית." -ForegroundColor Yellow
        } else {
            Write-Host "  Ollama הותקן בהצלחה." -ForegroundColor Green
        }

        # Refresh PATH
        $env:PATH = [System.Environment]::GetEnvironmentVariable("PATH", "Machine") + ";" +
                    [System.Environment]::GetEnvironmentVariable("PATH", "User")
    } catch {
        Write-Host "  שגיאה בהתקנה: $_" -ForegroundColor Red
        Write-Host "  הורד ידנית מ: https://ollama.com/download" -ForegroundColor Yellow
        exit 1
    }
}

# ── 2. Start Ollama service if needed ─────────────────────────────────────────
Write-Host ""
Write-Host "[2/3] בודק שירות Ollama..." -ForegroundColor Cyan
$ollamaProc = Get-Process ollama -ErrorAction SilentlyContinue
if (-not $ollamaProc) {
    Write-Host "  מפעיל שירות Ollama ברקע..." -ForegroundColor Yellow
    Start-Process ollama -ArgumentList "serve" -WindowStyle Hidden
    Start-Sleep 3
}
Write-Host "  שירות פעיל." -ForegroundColor Green

# ── 3. Pull the model ─────────────────────────────────────────────────────────
Write-Host ""
Write-Host "[3/3] מוריד מודל law-il-E2B (~3.4 GB)..." -ForegroundColor Cyan
Write-Host "  זה עלול לקחת מספר דקות בהתאם למהירות האינטרנט." -ForegroundColor Gray
Write-Host ""

$existing = & ollama list 2>&1
if ($existing -match "law-il-E2B") {
    Write-Host "  המודל כבר קיים — אין צורך בהורדה." -ForegroundColor Green
} else {
    & ollama pull $model
    if ($LASTEXITCODE -ne 0) {
        Write-Host ""
        Write-Host "  שגיאה בהורדת המודל (קוד $LASTEXITCODE)." -ForegroundColor Red
        Write-Host "  נסה ידנית: ollama pull $model" -ForegroundColor Yellow
        exit 1
    }
    Write-Host ""
    Write-Host "  המודל הורד בהצלחה." -ForegroundColor Green
}

# ── Summary ───────────────────────────────────────────────────────────────────
Write-Host ""
Write-Host "================================================" -ForegroundColor Green
Write-Host "  הכל מוכן! כדי להשתמש ב-AI:" -ForegroundColor Green
Write-Host ""
Write-Host "  .\Scripts\Run-All.ps1 -UseAI" -ForegroundColor White
Write-Host "  או בחר אפשרות [8] מתפריט START-HERE" -ForegroundColor White
Write-Host "================================================" -ForegroundColor Green
Write-Host ""
