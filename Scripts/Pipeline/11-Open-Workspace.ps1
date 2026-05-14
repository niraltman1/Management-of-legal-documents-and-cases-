#Requires -Version 5.1
<#
.SYNOPSIS
    STEP 11 — Legal-OS Knowledge Graph Workspace.
    Generates and opens a self-contained dark-mode workspace: SVG knowledge graph,
    glassmorphism side panel, procedural timeline dock, and case dashboard.
    Live data is injected from the SQLite database.

.PARAMETER DbPath     Path to the SQLite database.
.PARAMETER CaseID     Focus a specific case on startup (optional).
.PARAMETER NoOpen     Generate but do not open in the browser.
#>

param(
    [string]$DbPath  = "",
    [int]$CaseID     = 0,
    [switch]$NoOpen
)

$ScriptDir = $PSScriptRoot
. "$ScriptDir\..\lib\Config.ps1"
. "$ScriptDir\..\lib\Database.ps1"
if ($DbPath) { $script:DbPath = $DbPath }

Import-Module PSSQLite -ErrorAction Stop
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

Write-Host ""
Write-Host "══════════════════════════════════════════════" -ForegroundColor Cyan
Write-Host "  STEP 11 — Legal-OS Workspace (Knowledge Graph)" -ForegroundColor Cyan
Write-Host "══════════════════════════════════════════════" -ForegroundColor Cyan
Write-Host ""

# ── Query live data ──────────────────────────────────────────────────────────

$casesRaw = @()
try {
    $casesRaw = @(Invoke-SqliteQuery -DataSource $script:DbPath -Query @"
SELECT ca.CaseID, ca.CaseNumber, ca.CaseName, ca.CaseType, ca.Status,
       ca.HasInvestigationMaterials,
       c.LastName || ' ' || c.FirstName AS ClientName,
       COUNT(fcl.FileID) AS FileCount
FROM Cases ca
LEFT JOIN Clients c ON c.ClientID = ca.ClientID
LEFT JOIN FileCaseLinks fcl ON fcl.CaseID = ca.CaseID
WHERE ca.Status = 'active'
GROUP BY ca.CaseID ORDER BY ca.CaseNumber LIMIT 20;
"@)
} catch { <# empty DB #> }

$tasksRaw = @()
try {
    $tasksRaw = @(Invoke-SqliteQuery -DataSource $script:DbPath -Query @"
SELECT t.TaskID, t.Title, t.DueDate, t.Priority, t.IsChecked, t.Category,
       ca.CaseNumber, c.LastName || ' ' || c.FirstName AS ClientName
FROM Tasks t
LEFT JOIN Cases ca ON ca.CaseID = t.CaseID
LEFT JOIN Clients c ON c.ClientID = COALESCE(t.ClientID, ca.ClientID)
WHERE t.IsChecked = 0
ORDER BY t.Priority DESC, t.DueDate ASC LIMIT 30;
"@)
} catch { <# empty #> }

$stepsRaw = @()
try {
    Update-DatabaseSchema-v3 -DbPath $script:DbPath
    $stepsRaw = @(Invoke-SqliteQuery -DataSource $script:DbPath -Query @"
SELECT ps.StepID, ps.StepName, ps.ExpectedDate, ps.ActualDate, ps.Status,
       ps.Notes, ca.CaseNumber, ca.CaseType,
       c.LastName || ' ' || c.FirstName AS ClientName
FROM Procedural_Steps ps
JOIN Cases ca ON ca.CaseID = ps.CaseID
LEFT JOIN Clients c ON c.ClientID = ca.ClientID
WHERE ps.ExpectedDate IS NOT NULL
ORDER BY ps.ExpectedDate ASC LIMIT 60;
"@)
} catch { <# v3 not yet seeded #> }

$briefRaw = @()
try {
    $briefRaw = @(Invoke-SqliteQuery -DataSource $script:DbPath -Query @"
SELECT cb.BriefType, cb.ContradictionFound, cb.RecommendedQuestion,
       cb.SuggestedDocument, cb.LegalBasis, cb.ConfidenceScore,
       ca.CaseNumber, c.LastName || ' ' || c.FirstName AS ClientName
FROM Case_Brief cb
JOIN Cases ca ON ca.CaseID = cb.CaseID
LEFT JOIN Clients c ON c.ClientID = ca.ClientID
ORDER BY cb.ConfidenceScore DESC LIMIT 20;
"@)
} catch { <# not seeded yet #> }

$summaryRaw = $null
try {
    $summaryRaw = Invoke-SqliteQuery -DataSource $script:DbPath -Query @"
SELECT COUNT(*) AS TotalFiles,
       SUM(CASE WHEN ProcessingStatus='planned' THEN 1 ELSE 0 END) AS Planned,
       COUNT(DISTINCT ca.CaseID) AS ActiveCases,
       SUM(CASE WHEN ps.Status='missed' THEN 1 ELSE 0 END) AS OverdueDL
FROM Files f
LEFT JOIN Cases ca ON ca.Status='active'
LEFT JOIN Procedural_Steps ps ON ps.Status='missed'
LIMIT 1;
"@
} catch { <# ignore #> }

# Serialise to JSON
$casesJson  = if ($casesRaw)  { $casesRaw  | ConvertTo-Json -Compress -Depth 4 } else { "[]" }
$tasksJson  = if ($tasksRaw)  { $tasksRaw  | ConvertTo-Json -Compress -Depth 4 } else { "[]" }
$stepsJson  = if ($stepsRaw)  { $stepsRaw  | ConvertTo-Json -Compress -Depth 4 } else { "[]" }
$briefJson  = if ($briefRaw)  { $briefRaw  | ConvertTo-Json -Compress -Depth 4 } else { "[]" }

$totalFiles   = if ($summaryRaw) { $summaryRaw.TotalFiles }   else { 0 }
$activeCases  = if ($casesRaw)   { @($casesRaw).Count }       else { 0 }
$overdueCount = if ($stepsRaw)   { @($stepsRaw | Where-Object { $_.Status -eq 'missed' }).Count } else { 0 }
$aiInsights   = if ($briefRaw)   { @($briefRaw).Count }        else { 0 }

$focusCaseNumber = ""
if ($CaseID -gt 0 -and $casesRaw) {
    $fc = @($casesRaw) | Where-Object { $_.CaseID -eq $CaseID } | Select-Object -First 1
    if ($fc) { $focusCaseNumber = $fc.CaseNumber }
}

$stamp       = Get-Date -Format "yyyyMMdd_HHmmss"
$workspacePath = Join-Path $script:OutputPath "Workspace_$stamp.html"
if (-not (Test-Path $script:OutputPath)) { New-Item -ItemType Directory -Path $script:OutputPath -Force | Out-Null }

# ── Generate HTML ─────────────────────────────────────────────────────────────

$workspaceHtml = @"
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8"/>
<meta name="viewport" content="width=device-width,initial-scale=1"/>
<title>Legal-OS Workspace</title>
<style>
/* ── Design tokens ─────────────────────────────────────────────────────── */
:root{
  --bg-abyss:#050a18;--bg-base:#0a1124;--bg-surface:#111a33;
  --bg-surface-2:#18233f;--bg-surface-3:#1f2c4d;
  --bg-glass:rgba(17,26,51,0.55);--bg-glass-strong:rgba(10,17,36,0.82);
  --fg-1:#f4f7ff;--fg-2:#c9d3eb;--fg-3:#8a99bd;--fg-4:#5a6789;
  --fg-inverse:#0a1124;
  --stroke-1:rgba(255,255,255,0.06);--stroke-2:rgba(255,255,255,0.12);
  --stroke-3:rgba(255,255,255,0.22);--stroke-cyan:rgba(94,234,232,0.45);
  --brand-cyan:#5eeae8;--brand-cyan-2:#38bdf8;--brand-cyan-deep:#0891b2;
  --brand-steel:#cbd5e1;--brand-navy:#0a1124;
  --node-law:#5eeae8;--node-section:#7dd3fc;--node-decision:#4ade80;
  --node-case:#fb923c;--node-judge:#6b7280;--node-lawyer:#3b82f6;
  --node-expert:#a78bfa;--node-concept:#2dd4bf;--node-procedure:#ca8a04;
  --node-document:#e2e8f0;--node-client:#f9a8d4;--node-evidence:#b91c1c;
  --node-article:#86efac;--node-institution:#60a5fa;--node-task:#fdba74;
  --node-ai:#c084fc;--node-academic:#f0c674;
  --edge-cites:#5eeae8;--edge-contradicts:#f87171;--edge-supports:#4ade80;
  --edge-derived:#a78bfa;--edge-procedural:#fbbf24;--edge-ai:#c084fc;
  --edge-default:rgba(202,213,225,0.35);
  --ok:#34d399;--ok-bg:rgba(52,211,153,0.12);
  --warn:#fbbf24;--warn-bg:rgba(251,191,36,0.12);
  --risk:#f87171;--risk-bg:rgba(248,113,113,0.12);
  --info:#5eeae8;--info-bg:rgba(94,234,232,0.12);
  --font-display:"Cormorant Garamond","David Libre","Times New Roman",serif;
  --font-sans:"Inter","Heebo",-apple-system,"Segoe UI",system-ui,sans-serif;
  --font-heb:"David Libre","David","Frank Ruehl CLM","Times New Roman",serif;
  --font-mono:"JetBrains Mono","SF Mono","Menlo","Consolas",monospace;
  --shadow-2:0 4px 14px rgba(0,0,0,0.45);
  --shadow-3:0 10px 32px rgba(0,0,0,0.55),0 2px 4px rgba(0,0,0,0.4);
  --glow-cyan:0 0 0 1px rgba(94,234,232,0.35),0 0 24px rgba(94,234,232,0.25);
  --glow-risk:0 0 0 1px rgba(248,113,113,0.45),0 0 24px rgba(248,113,113,0.25);
  --ease-out:cubic-bezier(0.16,1,0.3,1);
  --t-quick:160ms;--t-base:240ms;
}

/* ── Reset + base ──────────────────────────────────────────────────────── */
*{box-sizing:border-box;margin:0;padding:0}
html,body{height:100%;width:100%;overflow:hidden}
body{font-family:var(--font-sans);background:var(--bg-base);color:var(--fg-1);
  font-size:14px;line-height:1.5;-webkit-font-smoothing:antialiased}
button{font-family:inherit;cursor:pointer}
button:focus-visible{outline:2px solid var(--brand-cyan);outline-offset:2px}
::-webkit-scrollbar{width:6px;height:6px}
::-webkit-scrollbar-track{background:transparent}
::-webkit-scrollbar-thumb{background:var(--bg-surface-3);border-radius:3px}
::-webkit-scrollbar-thumb:hover{background:var(--stroke-3)}

/* ── Layout shell ──────────────────────────────────────────────────────── */
#app{display:flex;height:100vh;width:100vw;overflow:hidden}
#left-rail{width:72px;flex-shrink:0;background:var(--bg-surface);
  border-right:1px solid var(--stroke-1);display:flex;flex-direction:column;
  padding:14px 0;gap:0;z-index:10}
#main{flex:1;display:flex;flex-direction:column;min-width:0;overflow:hidden}
#top-bar{height:56px;flex-shrink:0;background:var(--bg-surface);
  border-bottom:1px solid var(--stroke-1);display:flex;align-items:center;
  gap:12px;padding:0 18px;z-index:9}
#content-area{flex:1;display:flex;overflow:hidden;position:relative}
#timeline-dock{height:96px;flex-shrink:0;border-top:1px solid var(--stroke-1);
  background:var(--bg-surface);padding:10px 18px 14px 18px;
  display:flex;flex-direction:column;gap:6px}

/* ── Left rail nav ─────────────────────────────────────────────────────── */
.rail-logo{width:44px;height:44px;margin:0 auto 14px;border-radius:10px;
  background:linear-gradient(135deg,#1a3a5c,#0891b2);display:flex;
  align-items:center;justify-content:center;font-size:18px;font-weight:700;
  color:var(--brand-cyan);letter-spacing:-.02em;
  box-shadow:0 0 0 1px rgba(94,234,232,0.25),0 0 14px rgba(94,234,232,0.15)}
.rail-search-btn{width:44px;height:44px;margin:0 auto 8px;
  background:var(--bg-surface-2);border:1px solid var(--stroke-2);
  border-radius:10px;color:var(--fg-3);display:flex;align-items:center;
  justify-content:center;transition:all var(--t-quick) var(--ease-out)}
.rail-search-btn:hover{background:var(--bg-surface-3);color:var(--brand-cyan);
  border-color:rgba(94,234,232,0.3)}
.rail-nav{display:flex;flex-direction:column;gap:4px;padding:8px 10px}
.rail-item{padding:9px 0;background:transparent;border:1px solid transparent;
  border-radius:8px;color:var(--fg-3);display:flex;flex-direction:column;
  align-items:center;gap:4px;font-size:9px;letter-spacing:.07em;
  text-transform:uppercase;font-weight:600;width:100%;
  transition:all var(--t-quick) var(--ease-out)}
.rail-item:hover{background:rgba(94,234,232,0.05);color:var(--fg-2)}
.rail-item.active{background:rgba(94,234,232,0.1);
  border-color:rgba(94,234,232,0.3);color:var(--brand-cyan)}
.rail-spacer{flex:1}
.rail-avatar{width:36px;height:36px;margin:0 auto;border-radius:999px;
  background:linear-gradient(135deg,var(--node-lawyer),var(--brand-cyan-deep));
  display:flex;align-items:center;justify-content:center;
  color:#fff;font-size:11px;font-weight:600;
  box-shadow:0 0 0 1px rgba(255,255,255,0.1)}

/* ── Top bar ───────────────────────────────────────────────────────────── */
.topbar-breadcrumb{display:flex;align-items:center;gap:8px;flex:1;min-width:0}
.topbar-logo-text{font-family:var(--font-display);font-size:18px;font-weight:500;
  color:var(--fg-1);letter-spacing:-.015em;white-space:nowrap}
.topbar-sep{color:var(--fg-4);font-size:13px}
.topbar-case-chip{background:var(--bg-surface-2);border:1px solid var(--stroke-2);
  border-radius:6px;padding:3px 10px;font-family:var(--font-mono);font-size:11px;
  color:var(--brand-cyan);white-space:nowrap;overflow:hidden;text-overflow:ellipsis;max-width:240px}
.topbar-right{display:flex;align-items:center;gap:8px}
.topbar-btn{background:transparent;border:1px solid var(--stroke-2);
  border-radius:8px;color:var(--fg-3);padding:6px 12px;font-size:12px;
  display:flex;align-items:center;gap:6px;
  transition:all var(--t-quick) var(--ease-out)}
.topbar-btn:hover{background:var(--bg-surface-2);color:var(--fg-1);
  border-color:var(--stroke-3)}
.topbar-kbd{font-family:var(--font-mono);font-size:10px;
  background:var(--bg-surface-3);border:1px solid var(--stroke-2);
  padding:1px 5px;border-radius:3px;color:var(--fg-4)}

/* ── Graph canvas ──────────────────────────────────────────────────────── */
#graph-canvas{flex:1;position:relative;overflow:hidden;background:var(--bg-base)}
#graph-svg{width:100%;height:100%}
.circuit-overlay{position:absolute;inset:0;pointer-events:none;opacity:0.04;
  background-image:url("data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' width='80' height='80'%3E%3Crect width='80' height='80' fill='none'/%3E%3Cpath d='M10 40h20M50 40h20M40 10v20M40 50v20' stroke='%235eeae8' stroke-width='1' fill='none'/%3E%3Ccircle cx='40' cy='40' r='3' fill='%235eeae8'/%3E%3Ccircle cx='10' cy='40' r='2' fill='%235eeae8'/%3E%3Ccircle cx='70' cy='40' r='2' fill='%235eeae8'/%3E%3Ccircle cx='40' cy='10' r='2' fill='%235eeae8'/%3E%3Ccircle cx='40' cy='70' r='2' fill='%235eeae8'/%3E%3C/svg%3E")}
.node-label{font-family:var(--font-mono);font-size:10px;fill:var(--fg-2);
  pointer-events:none;text-anchor:middle}
.node-label-heb{font-family:var(--font-heb);font-size:10px;fill:var(--fg-2);
  pointer-events:none;text-anchor:middle}
.edge-line{stroke-width:1.5;fill:none;opacity:0.6}
.graph-node{cursor:pointer;transition:all 120ms}
.graph-node:hover circle,.graph-node:hover rect{filter:brightness(1.25)}
.empty-graph{display:flex;flex-direction:column;align-items:center;
  justify-content:center;gap:10px;height:100%;color:var(--fg-3);font-size:14px}

/* ── Side panel ────────────────────────────────────────────────────────── */
#side-panel{width:400px;flex-shrink:0;border-left:1px solid var(--stroke-2);
  background:var(--bg-glass-strong);
  -webkit-backdrop-filter:blur(24px) saturate(140%);
  backdrop-filter:blur(24px) saturate(140%);
  display:flex;flex-direction:column;overflow:hidden;
  transition:width var(--t-base) var(--ease-out)}
#side-panel.hidden{width:0;border:0}
.sp-head{padding:16px 18px 14px;border-bottom:1px solid var(--stroke-1)}
.sp-eyebrow{font-size:10px;letter-spacing:.14em;text-transform:uppercase;
  font-weight:600;color:var(--fg-3)}
.sp-title{font-size:17px;font-weight:600;color:var(--fg-1);
  font-family:var(--font-heb),var(--font-sans);line-height:1.3;
  margin:4px 0 8px}
.sp-ident{font-family:var(--font-mono);font-size:11px;color:var(--brand-cyan);
  background:rgba(94,234,232,0.08);border:1px solid rgba(94,234,232,0.15);
  padding:2px 8px;border-radius:4px;display:inline-block}
.sp-body{flex:1;overflow-y:auto;padding:14px 18px 24px}
.sp-section{margin-bottom:18px}
.sp-summary{font-size:13px;color:var(--fg-2);line-height:1.55}
.sp-chip-row{display:flex;gap:6px;flex-wrap:wrap;margin-top:8px}
.chip{display:inline-flex;align-items:center;padding:2px 8px;border-radius:5px;
  font-size:11px;font-weight:500;background:var(--bg-surface-2);
  border:1px solid var(--stroke-2);color:var(--fg-2)}
.chip.high{background:rgba(74,222,128,0.12);border-color:rgba(74,222,128,0.3);color:#4ade80}
.chip.med{background:rgba(251,191,36,0.12);border-color:rgba(251,191,36,0.3);color:#fbbf24}
.chip.low{background:rgba(248,113,113,0.12);border-color:rgba(248,113,113,0.3);color:#f87171}
.chip.ai{background:rgba(192,132,252,0.12);border-color:rgba(192,132,252,0.3);color:#c084fc}
.reasoning-box{background:var(--bg-surface);border:1px solid var(--stroke-2);
  border-radius:10px;padding:10px 12px}
.r-step{display:grid;grid-template-columns:26px 1fr;gap:10px;
  padding:7px 0;border-bottom:1px solid var(--stroke-1)}
.r-step:last-child{border-bottom:0}
.r-dot{width:22px;height:22px;border-radius:999px;font-size:11px;
  font-weight:600;font-family:var(--font-mono);display:flex;
  align-items:center;justify-content:center}
.r-dot.done{background:rgba(94,234,232,0.15);border:1px solid rgba(94,234,232,0.4);
  color:var(--brand-cyan)}
.r-dot.current{background:var(--brand-cyan);border:1px solid var(--brand-cyan);
  color:var(--fg-inverse);box-shadow:0 0 0 4px rgba(94,234,232,0.18)}
.r-dot.pending{background:var(--bg-surface-3);border:1px solid var(--stroke-2);
  color:var(--fg-3)}
.r-label{font-size:10px;letter-spacing:.12em;text-transform:uppercase;
  font-weight:600;color:var(--fg-3);margin-bottom:2px}
.r-text{font-size:12px;color:var(--fg-1);line-height:1.4;
  font-family:var(--font-heb),var(--font-sans)}
.r-text.pending{color:var(--fg-3)}
.related-item{padding:8px 10px;border:1px solid var(--stroke-2);border-radius:7px;
  display:flex;align-items:center;gap:8px;margin-bottom:5px;
  background:var(--bg-surface)}
.related-item.risk{background:rgba(248,113,113,0.06);
  border-color:rgba(248,113,113,0.25)}
.sp-actions{display:flex;gap:8px;flex-wrap:wrap}
.sp-btn{padding:6px 12px;border-radius:7px;font-size:12px;font-weight:500;
  display:flex;align-items:center;gap:6px;
  transition:all var(--t-quick) var(--ease-out)}
.sp-btn.primary{background:var(--brand-cyan);border:none;color:var(--fg-inverse)}
.sp-btn.primary:hover{background:var(--brand-cyan-2)}
.sp-btn.secondary{background:transparent;border:1px solid var(--stroke-3);color:var(--fg-2)}
.sp-btn.secondary:hover{background:var(--bg-surface-2);color:var(--fg-1)}
.sp-btn.ghost{background:transparent;border:1px solid transparent;color:var(--fg-3)}
.sp-btn.ghost:hover{background:var(--bg-surface);color:var(--fg-2)}
.sp-close{background:transparent;border:0;color:var(--fg-3);padding:4px;
  cursor:pointer;border-radius:5px}
.sp-close:hover{color:var(--fg-1);background:var(--bg-surface-2)}

/* ── Timeline dock ─────────────────────────────────────────────────────── */
.tl-header{display:flex;align-items:center;justify-content:space-between}
.tl-legend{display:flex;gap:14px;font-size:10px;color:var(--fg-3)}
.tl-dot{width:8px;height:8px;border-radius:999px;display:inline-block;margin-right:4px}
.tl-axis{position:relative;flex:1;margin-top:4px}
.tl-line{position:absolute;top:50%;left:0;right:0;height:1px;
  background:var(--stroke-2)}
.tl-events{position:relative;display:flex;justify-content:space-between;
  align-items:center;height:48px}
.tl-event{display:flex;flex-direction:column;align-items:center;gap:3px;flex:1}
.tl-event-date{font-size:9px;color:var(--fg-3);font-family:var(--font-mono)}
.tl-event-dot{width:11px;height:11px;border-radius:999px;
  border:2px solid var(--bg-surface)}
.tl-event-label{font-size:9px;color:var(--fg-2);text-align:center;
  max-width:80px;line-height:1.1}
.tl-event-label.danger{color:var(--risk);font-weight:600}
.tl-event-label.upcoming{color:var(--brand-cyan);font-weight:600}
.tl-today{position:absolute;top:0;bottom:0;width:1px;
  background:var(--brand-cyan);opacity:0.5;
  box-shadow:0 0 8px var(--brand-cyan)}

/* ── Command palette ───────────────────────────────────────────────────── */
#palette-overlay{position:fixed;inset:0;z-index:100;
  background:rgba(5,10,24,0.65);
  -webkit-backdrop-filter:blur(4px);backdrop-filter:blur(4px);
  display:flex;align-items:flex-start;justify-content:center;
  padding-top:12vh;display:none}
#palette-overlay.open{display:flex}
#palette-box{width:580px;max-width:90%;
  background:var(--bg-glass-strong);
  -webkit-backdrop-filter:blur(24px) saturate(140%);
  backdrop-filter:blur(24px) saturate(140%);
  border:1px solid var(--stroke-2);border-radius:14px;overflow:hidden;
  box-shadow:0 30px 80px rgba(0,0,0,0.6),0 0 0 1px rgba(94,234,232,0.06) inset}
#palette-input-row{display:flex;align-items:center;gap:12px;
  padding:14px 16px;border-bottom:1px solid var(--stroke-1)}
#palette-input{flex:1;background:transparent;border:0;outline:0;
  color:var(--fg-1);font-size:15px;font-family:var(--font-sans)}
#palette-input::placeholder{color:var(--fg-4)}
#palette-results{max-height:360px;overflow-y:auto;padding:6px 0}
.palette-section-label{padding:8px 16px 4px;font-size:9px;letter-spacing:.14em;
  text-transform:uppercase;color:var(--fg-4);font-weight:600}
.palette-item{padding:9px 16px;display:flex;align-items:center;gap:10px;
  cursor:pointer;transition:background 80ms;border-left:2px solid transparent}
.palette-item:hover,.palette-item.focused{background:rgba(94,234,232,0.06);
  border-left-color:var(--brand-cyan)}
.palette-item-dot{width:8px;height:8px;border-radius:999px;flex-shrink:0}
.palette-item-id{font-family:var(--font-mono);font-size:11px;color:var(--brand-cyan);
  background:rgba(94,234,232,0.08);border:1px solid rgba(94,234,232,0.15);
  padding:1px 6px;border-radius:3px;white-space:nowrap}
.palette-item-label{flex:1;font-size:13px;color:var(--fg-1);
  font-family:var(--font-heb),var(--font-sans)}
.palette-item-type{font-size:9px;letter-spacing:.1em;text-transform:uppercase;
  color:var(--fg-4);font-weight:600}
#palette-footer{padding:9px 16px;border-top:1px solid var(--stroke-1);
  display:flex;gap:14px;font-size:10px;color:var(--fg-3)}
#palette-footer .key{font-family:var(--font-mono)}

/* ── Dashboard ─────────────────────────────────────────────────────────── */
#dashboard{flex:1;overflow:auto;background:var(--bg-base);padding:24px 32px;display:none}
#dashboard.active{display:block}
.dash-title{font-family:var(--font-display);font-size:34px;font-weight:500;
  letter-spacing:-.02em;color:var(--fg-1)}
.dash-subtitle{color:var(--fg-3);font-size:13px;margin-top:4px;margin-bottom:22px}
.kpi-grid{display:grid;grid-template-columns:repeat(4,1fr);gap:14px;margin-bottom:24px}
.kpi-card{padding:14px 16px;background:var(--bg-surface);
  border:1px solid var(--stroke-2);border-radius:12px;position:relative;overflow:hidden}
.kpi-accent{position:absolute;top:0;left:0;right:0;height:2px;opacity:0.7}
.kpi-label{font-size:10px;letter-spacing:.12em;text-transform:uppercase;
  font-weight:600;color:var(--fg-3);margin-bottom:8px}
.kpi-value{font-family:var(--font-display);font-size:30px;font-weight:500;
  color:var(--fg-1);line-height:1;margin-bottom:4px}
.kpi-delta{font-size:11px}
.dash-grid{display:grid;grid-template-columns:1.6fr 1fr;gap:18px}
.dash-panel{background:var(--bg-surface);border:1px solid var(--stroke-2);border-radius:12px;overflow:hidden}
.dash-panel-head{padding:13px 16px;border-bottom:1px solid var(--stroke-1);
  display:flex;align-items:center;justify-content:space-between}
.dash-table{width:100%;border-collapse:collapse;font-size:12px}
.dash-table th{text-align:left;padding:8px 14px;color:var(--fg-3);
  font-size:10px;text-transform:uppercase;letter-spacing:.1em;font-weight:600}
.dash-table td{padding:10px 14px;border-top:1px solid var(--stroke-1);color:var(--fg-2)}
.dash-table td:first-child{font-family:var(--font-mono);font-size:11px;color:var(--brand-cyan)}
.dash-table tr:hover td{background:var(--bg-surface-2)}
.insight-item{padding:10px 0;border-bottom:1px solid var(--stroke-1);
  display:flex;align-items:flex-start;gap:10px}
.insight-item:last-child{border-bottom:0}
.insight-text{flex:1;font-size:12px;color:var(--fg-1);line-height:1.4;
  font-family:var(--font-heb),var(--font-sans)}
.insight-time{font-size:10px;color:var(--fg-4);flex-shrink:0}

/* ── View stubs ─────────────────────────────────────────────────────────── */
.view-stub{flex:1;display:flex;align-items:center;justify-content:center;
  flex-direction:column;gap:8px;color:var(--fg-3);display:none}
.view-stub.active{display:flex}
.view-stub-title{font-family:var(--font-display);font-size:30px;color:var(--fg-2)}

/* ── Misc ───────────────────────────────────────────────────────────────── */
.eyebrow{font-size:10px;letter-spacing:.14em;text-transform:uppercase;
  font-weight:600;color:var(--fg-3)}
.overdue-banner{background:rgba(248,113,113,0.1);border:1px solid rgba(248,113,113,0.3);
  border-radius:6px;padding:8px 12px;color:var(--risk);font-size:12px;
  font-weight:600;margin-bottom:10px}
</style>
</head>
<body>
<div id="app">

  <!-- LEFT RAIL -->
  <aside id="left-rail">
    <div class="rail-logo">LO</div>
    <button class="rail-search-btn" onclick="openPalette()" title="Command palette (Ctrl+K)">
      <svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round">
        <circle cx="11" cy="11" r="8"/><path d="m21 21-4.35-4.35"/>
      </svg>
    </button>
    <nav class="rail-nav">
      <button class="rail-item active" onclick="setView('graph',this)" id="rail-graph">
        <svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round"><circle cx="18" cy="5" r="3"/><circle cx="6" cy="12" r="3"/><circle cx="18" cy="19" r="3"/><path d="m8.59 13.51 6.83 3.98M15.41 6.51l-6.82 3.98"/></svg>
        <span>Graph</span>
      </button>
      <button class="rail-item" onclick="setView('dash',this)" id="rail-dash">
        <svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round"><rect width="7" height="9" x="3" y="3" rx="1"/><rect width="7" height="5" x="14" y="3" rx="1"/><rect width="7" height="9" x="14" y="12" rx="1"/><rect width="7" height="5" x="3" y="16" rx="1"/></svg>
        <span>Dashboard</span>
      </button>
      <button class="rail-item" onclick="setView('time',this)" id="rail-time">
        <svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round"><circle cx="12" cy="12" r="10"/><polyline points="12 6 12 12 16 14"/></svg>
        <span>Timeline</span>
      </button>
      <button class="rail-item" onclick="setView('files',this)" id="rail-files">
        <svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round"><path d="M22 19a2 2 0 0 1-2 2H4a2 2 0 0 1-2-2V5a2 2 0 0 1 2-2h5l2 3h9a2 2 0 0 1 2 2z"/></svg>
        <span>Files</span>
      </button>
      <button class="rail-item" onclick="setView('auth',this)" id="rail-auth">
        <svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round"><path d="M12 22s8-4 8-10V5l-8-3-8 3v7c0 6 8 10 8 10z"/></svg>
        <span>Authorities</span>
      </button>
      <button class="rail-item" onclick="setView('ai',this)" id="rail-ai">
        <svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round"><path d="M12 2a4 4 0 0 1 4 4 4 4 0 0 1-4 4 4 4 0 0 1-4-4 4 4 0 0 1 4-4m0 10c4.42 0 8 1.79 8 4v2H4v-2c0-2.21 3.58-4 8-4z"/></svg>
        <span>AI</span>
      </button>
    </nav>
    <div class="rail-spacer"></div>
    <div class="rail-avatar">נר</div>
  </aside>

  <!-- MAIN AREA -->
  <div id="main">
    <!-- TOP BAR -->
    <header id="top-bar">
      <div class="topbar-breadcrumb">
        <span class="topbar-logo-text">Legal<span style="color:var(--brand-cyan)">OS</span></span>
        <span class="topbar-sep">/</span>
        <span id="topbar-case-label" class="topbar-case-chip">$focusCaseNumber</span>
      </div>
      <div class="topbar-right">
        <button class="topbar-btn" onclick="openPalette()">
          <svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round"><circle cx="11" cy="11" r="8"/><path d="m21 21-4.35-4.35"/></svg>
          Search
          <span class="topbar-kbd">Ctrl K</span>
        </button>
        <button class="topbar-btn" onclick="window.location.reload()">
          <svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round"><path d="M3 12a9 9 0 1 0 9-9 9.75 9.75 0 0 0-6.74 2.74L3 8"/><path d="M3 3v5h5"/></svg>
          Refresh
        </button>
      </div>
    </header>

    <!-- CONTENT AREA -->
    <div id="content-area">
      <!-- GRAPH VIEW -->
      <div id="graph-canvas">
        <div class="circuit-overlay"></div>
        <svg id="graph-svg"></svg>
      </div>

      <!-- SIDE PANEL -->
      <aside id="side-panel" class="hidden">
        <div class="sp-head">
          <div style="display:flex;align-items:center;justify-content:space-between;margin-bottom:10px">
            <div id="sp-eyebrow" class="sp-eyebrow"></div>
            <button class="sp-close" onclick="closeSidePanel()">
              <svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round"><path d="M18 6 6 18M6 6l12 12"/></svg>
            </button>
          </div>
          <div id="sp-title" class="sp-title"></div>
          <div style="display:flex;gap:6px;flex-wrap:wrap">
            <span id="sp-ident" class="sp-ident"></span>
          </div>
        </div>
        <div class="sp-body">
          <div class="sp-section">
            <div class="eyebrow" style="margin-bottom:6px">Entity summary</div>
            <div id="sp-summary" class="sp-summary"></div>
            <div id="sp-chips" class="sp-chip-row"></div>
          </div>
          <div class="sp-section">
            <div style="display:flex;align-items:center;justify-content:space-between;margin-bottom:8px">
              <div class="eyebrow">5-step reasoning</div>
            </div>
            <div class="reasoning-box" id="sp-reasoning"></div>
          </div>
          <div id="sp-related-section" class="sp-section" style="display:none">
            <div class="eyebrow" style="margin-bottom:8px">Related</div>
            <div id="sp-related"></div>
          </div>
          <div class="eyebrow" style="margin-bottom:8px">Suggested actions</div>
          <div class="sp-actions">
            <button class="sp-btn primary">
              <svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round"><path d="M12 3c.132 0 .263 0 .393 0a7.5 7.5 0 0 0 7.92 12.446A9 9 0 1 1 12 2.992z"/></svg>
              Generate memo
            </button>
            <button class="sp-btn secondary">
              <svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round"><circle cx="18" cy="5" r="3"/><circle cx="6" cy="12" r="3"/><circle cx="18" cy="19" r="3"/><path d="m8.59 13.51 6.83 3.98M15.41 6.51l-6.82 3.98"/></svg>
              Expand graph
            </button>
            <button class="sp-btn ghost">
              <svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round"><path d="M2 3h6a4 4 0 0 1 4 4v14a3 3 0 0 0-3-3H2z"/><path d="M22 3h-6a4 4 0 0 0-4 4v14a3 3 0 0 1 3-3h7z"/></svg>
              Open file
            </button>
          </div>
        </div>
      </aside>

      <!-- DASHBOARD VIEW -->
      <div id="dashboard">
        <div class="dash-title">Workspace</div>
        <div class="dash-subtitle" id="dash-subtitle"></div>
        <div class="kpi-grid" id="kpi-grid"></div>
        <div class="dash-grid">
          <div class="dash-panel">
            <div class="dash-panel-head">
              <div class="eyebrow">Active cases</div>
            </div>
            <table class="dash-table">
              <thead><tr><th>Case</th><th>Client</th><th>Type</th><th>Files</th><th>Risk</th></tr></thead>
              <tbody id="cases-tbody"></tbody>
            </table>
          </div>
          <div class="dash-panel" style="padding:14px 16px">
            <div class="eyebrow" style="margin-bottom:14px">AI Insights</div>
            <div id="insights-list"></div>
          </div>
        </div>
      </div>

      <!-- TIMELINE VIEW (stub — timeline dock shows procedural timeline) -->
      <div class="view-stub" id="view-time">
        <div class="view-stub-title">ציר זמן</div>
        <div style="font-size:13px">Procedural timeline displayed in the dock below.</div>
      </div>

      <!-- OTHER VIEW STUBS -->
      <div class="view-stub" id="view-files">
        <div class="view-stub-title">Files</div>
        <div style="font-size:13px">Open the HTML report for full file explorer.</div>
      </div>
      <div class="view-stub" id="view-auth">
        <div class="view-stub-title">Authorities</div>
        <div style="font-size:13px">Law &amp; precedent browser — coming soon.</div>
      </div>
      <div class="view-stub" id="view-ai">
        <div class="view-stub-title">AI Insights</div>
        <div id="view-ai-content" style="max-width:560px;width:100%"></div>
      </div>
    </div>

    <!-- TIMELINE DOCK -->
    <div id="timeline-dock">
      <div class="tl-header">
        <div class="eyebrow">Procedural timeline</div>
        <div class="tl-legend">
          <span><span class="tl-dot" style="background:var(--node-task)"></span>Deadlines</span>
          <span><span class="tl-dot" style="background:var(--node-decision)"></span>Hearings</span>
          <span><span class="tl-dot" style="background:var(--risk)"></span>Overdue</span>
        </div>
      </div>
      <div class="tl-axis">
        <div class="tl-line"></div>
        <div class="tl-events" id="tl-events"></div>
        <div class="tl-today" id="tl-today"></div>
      </div>
    </div>
  </div><!-- /#main -->
</div><!-- /#app -->

<!-- COMMAND PALETTE -->
<div id="palette-overlay" onclick="closePalette()">
  <div id="palette-box" onclick="event.stopPropagation()">
    <div id="palette-input-row">
      <svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="var(--fg-3)" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round"><circle cx="11" cy="11" r="8"/><path d="m21 21-4.35-4.35"/></svg>
      <input id="palette-input" placeholder="Search cases, clients, laws — or ask AI…" oninput="filterPalette(this.value)">
      <span style="font-family:var(--font-mono);font-size:10px;background:var(--bg-surface-3);
        border:1px solid var(--stroke-2);padding:2px 6px;border-radius:3px;color:var(--fg-4)">esc</span>
    </div>
    <div id="palette-results"></div>
    <div id="palette-footer">
      <span><span class="key">↑↓</span> navigate</span>
      <span><span class="key">↵</span> open in graph</span>
      <span><span class="key">Ctrl K</span> toggle</span>
    </div>
  </div>
</div>

<script>
// ── Data injected by PowerShell ─────────────────────────────────────────
const DB_CASES   = $casesJson;
const DB_TASKS   = $tasksJson;
const DB_STEPS   = $stepsJson;
const DB_BRIEF   = $briefJson;
const STATS = {
  totalFiles: $totalFiles,
  activeCases: $activeCases,
  overdueCount: $overdueCount,
  aiInsights: $aiInsights
};
const FOCUS_CASE = "$focusCaseNumber";

// ── Node type → color mapping ─────────────────────────────────────────
const NODE_COLORS = {
  Case: 'var(--node-case)', Law: 'var(--node-law)',
  Decision: 'var(--node-decision)', Section: 'var(--node-section)',
  Client: 'var(--node-client)', Evidence: 'var(--node-evidence)',
  Judge: 'var(--node-judge)', Lawyer: 'var(--node-lawyer)',
  Expert: 'var(--node-expert)', Concept: 'var(--node-concept)',
  Document: 'var(--node-document)', Task: 'var(--node-task)',
  AI: 'var(--node-ai)', Institution: 'var(--node-institution)',
  Procedure: 'var(--node-procedure)',
};

// ── View state ────────────────────────────────────────────────────────
let currentView = 'graph';
let selectedNode = null;

function setView(view, btn) {
  currentView = view;
  // Rail buttons
  document.querySelectorAll('.rail-item').forEach(b => b.classList.remove('active'));
  if (btn) btn.classList.add('active');
  else {
    const rb = document.getElementById('rail-'+view);
    if (rb) rb.classList.add('active');
  }
  // Canvas / dashboard / stubs
  document.getElementById('graph-canvas').style.display = view === 'graph' ? 'block' : 'none';
  document.getElementById('dashboard').classList.toggle('active', view === 'dash');
  ['time','files','auth','ai'].forEach(v => {
    const el = document.getElementById('view-'+v);
    if (el) el.classList.toggle('active', view === v);
  });
  // Timeline dock shows only on graph + time
  document.getElementById('timeline-dock').style.display =
    (view === 'graph' || view === 'time') ? 'flex' : 'none';
  // Keep side panel on graph only
  if (view !== 'graph') closeSidePanel();
}

// ── Graph canvas ──────────────────────────────────────────────────────
function buildGraph() {
  const svg = document.getElementById('graph-svg');
  const W = svg.clientWidth || 900, H = svg.clientHeight || 500;

  // Build nodes from live DB_CASES + some static knowledge nodes
  const nodes = [];
  const edges = [];

  // Cases as nodes
  DB_CASES.slice(0, 8).forEach((c, i) => {
    const angle = (i / Math.max(DB_CASES.length, 1)) * 2 * Math.PI;
    const r = Math.min(W, H) * 0.28;
    nodes.push({
      id: 'case-' + c.CaseID,
      type: 'Case',
      label: c.CaseNumber,
      sublabel: (c.ClientName || '').slice(0, 14),
      cx: W/2 + r * Math.cos(angle),
      cy: H/2 + r * Math.sin(angle),
      color: NODE_COLORS.Case,
      data: c
    });
  });

  // Center: a client node or law node
  nodes.push({
    id: 'center',
    type: 'Law',
    label: 'פקודת הנזיקין',
    sublabel: 'Primary statute',
    cx: W/2, cy: H/2,
    color: NODE_COLORS.Law,
    data: {}
  });

  // AI insights node
  if (STATS.aiInsights > 0) {
    nodes.push({
      id: 'ai-hub',
      type: 'AI',
      label: 'AI Insights',
      sublabel: STATS.aiInsights + ' items',
      cx: W * 0.82, cy: H * 0.25,
      color: NODE_COLORS.AI,
      data: {}
    });
  }

  // A procedural step node
  if (DB_STEPS.length > 0) {
    const s = DB_STEPS[0];
    nodes.push({
      id: 'proc-0',
      type: 'Procedure',
      label: (s.StepName || '').slice(0, 14),
      sublabel: s.ExpectedDate || '',
      cx: W * 0.18, cy: H * 0.25,
      color: s.Status === 'missed' ? 'var(--risk)' : NODE_COLORS.Procedure,
      data: s
    });
  }

  // Edges: every case → center law
  nodes.filter(n => n.type === 'Case').forEach(n => {
    edges.push({ from: n.id, to: 'center', type: 'cites' });
  });
  if (nodes.find(n => n.id === 'ai-hub')) {
    nodes.filter(n => n.type === 'Case').slice(0, 2).forEach(n => {
      edges.push({ from: 'ai-hub', to: n.id, type: 'ai' });
    });
  }
  if (nodes.find(n => n.id === 'proc-0')) {
    const first = nodes.find(n => n.type === 'Case');
    if (first) edges.push({ from: 'proc-0', to: first.id, type: 'procedural' });
  }

  const edgeColors = {
    cites: 'var(--edge-cites)', contradicts: 'var(--edge-contradicts)',
    supports: 'var(--edge-supports)', ai: 'var(--edge-ai)',
    procedural: 'var(--edge-procedural)', default: 'var(--edge-default)'
  };
  const edgeDash = { ai: '4 3', default: '' };

  let svgHtml = '';

  // defs: glow filter
  svgHtml += '<defs><filter id="glow"><feGaussianBlur stdDeviation="3" result="coloredBlur"/><feMerge><feMergeNode in="coloredBlur"/><feMergeNode in="SourceGraphic"/></feMerge></filter></defs>';

  // Edges
  edges.forEach(e => {
    const fromN = nodes.find(n => n.id === e.from);
    const toN   = nodes.find(n => n.id === e.to);
    if (!fromN || !toN) return;
    const color = edgeColors[e.type] || edgeColors.default;
    const dash  = edgeDash[e.type] || '';
    svgHtml += `<line x1="${fromN.cx}" y1="${fromN.cy}" x2="${toN.cx}" y2="${toN.cy}"
      class="edge-line" stroke="${color}" ${dash ? 'stroke-dasharray="'+dash+'"' : ''}/>`;
  });

  // Nodes
  nodes.forEach(n => {
    const isCenter = n.id === 'center';
    const r = isCenter ? 28 : 20;
    svgHtml += `<g class="graph-node" onclick="selectNode('${n.id}')" data-nid="${n.id}">
      <circle cx="${n.cx}" cy="${n.cy}" r="${r}"
        fill="${n.color}" fill-opacity="0.18"
        stroke="${n.color}" stroke-width="${isCenter ? 2 : 1.5}"
        ${isCenter ? 'filter="url(#glow)"' : ''}/>
      <text class="${n.sublabel && /[֐-׿]/.test(n.label) ? 'node-label-heb' : 'node-label'}"
        x="${n.cx}" y="${n.cy + 3.5}" fill="${n.color}" font-size="${isCenter ? 11 : 9}"
        >${esc(n.label)}</text>
      ${n.sublabel ? `<text class="node-label" x="${n.cx}" y="${n.cy + r + 12}" fill="var(--fg-3)" font-size="9">${esc(n.sublabel)}</text>` : ''}
    </g>`;
  });

  if (nodes.length === 0) {
    svgHtml += `<text x="${W/2}" y="${H/2}" text-anchor="middle" fill="var(--fg-3)" font-size="14" font-family="Inter,sans-serif">No nodes — run Step 9 (09-Prepare-Brief.ps1) to populate the graph.</text>`;
  }

  svg.innerHTML = svgHtml;

  // Store for selectNode lookup
  window._graphNodes = nodes;

  // Auto-select first case if focus case is set
  if (FOCUS_CASE) {
    const fn = nodes.find(n => n.data && n.data.CaseNumber === FOCUS_CASE);
    if (fn) setTimeout(() => selectNode(fn.id), 300);
  }
}

window._graphNodes = [];

function selectNode(nid) {
  const n = window._graphNodes.find(x => x.id === nid);
  if (!n) return;
  selectedNode = nid;

  // Highlight
  document.querySelectorAll('.graph-node circle').forEach(c => {
    c.style.strokeWidth = '';
    c.style.filter = '';
  });
  const el = document.querySelector('[data-nid="'+nid+'"] circle');
  if (el) { el.style.strokeWidth = '2.5'; el.style.filter = 'url(#glow)'; }

  openSidePanel(n);
}

function openSidePanel(node) {
  const panel = document.getElementById('side-panel');
  panel.classList.remove('hidden');
  document.getElementById('sp-eyebrow').textContent = node.type.toUpperCase();
  document.getElementById('sp-eyebrow').style.color = node.color;
  document.getElementById('sp-title').textContent = node.label + (node.sublabel ? ' — ' + node.sublabel : '');
  document.getElementById('sp-ident').textContent = node.data.CaseNumber || node.data.StepName || node.id;

  const summary = node.type === 'Case'
    ? 'Active case — ' + (node.data.FileCount || 0) + ' files indexed. ' + (node.data.CaseType || '')
    : node.type === 'AI'
    ? STATS.aiInsights + ' AI insights generated from cross-document analysis.'
    : node.type === 'Procedure'
    ? 'Procedural step: ' + (node.data.StepName || '') + '. Expected: ' + (node.data.ExpectedDate || '—') + '. Status: ' + (node.data.Status || 'pending')
    : 'Knowledge graph entity. Click related nodes to traverse.';

  document.getElementById('sp-summary').textContent = summary;

  // Chips
  const chips = [];
  if (node.data.CaseType) chips.push(['type', node.data.CaseType]);
  if (node.data.Status)   chips.push(['status', node.data.Status]);
  if (node.data.ExpectedDate) chips.push(['due', node.data.ExpectedDate]);
  document.getElementById('sp-chips').innerHTML = chips.map(([k,v]) =>
    `<span class="chip"><span style="color:var(--fg-4)">${k}</span>&nbsp;${esc(v)}</span>`
  ).join('');

  // 5-step reasoning
  const steps = [
    { label: 'Context',             done: true,    text: 'Entity identified and indexed from local files.' },
    { label: 'Classification',      done: true,    text: node.type + ' — ' + (node.data.CaseType || node.label) },
    { label: 'Authorities',         done: node.type==='Case', text: node.type==='Case' ? 'Cross-referenced with procedural rules engine.' : 'Pending — run 09-Prepare-Brief.ps1.' },
    { label: 'Conflict / risk',     current: true, text: STATS.overdueCount > 0 ? STATS.overdueCount + ' overdue deadline(s) detected.' : 'No conflicts detected.' },
    { label: 'Practical conclusion',pending: true,  text: 'Pending your review.' },
  ];
  document.getElementById('sp-reasoning').innerHTML = steps.map((s, i) => {
    const cls = s.done ? 'done' : s.current ? 'current' : 'pending';
    return `<div class="r-step">
      <div class="r-dot ${cls}">${i+1}</div>
      <div>
        <div class="r-label">${s.label}</div>
        <div class="r-text ${s.pending ? 'pending' : ''}">${esc(s.text)}</div>
      </div>
    </div>`;
  }).join('');

  // Related
  const briefItems = DB_BRIEF.filter(b => !node.data.CaseNumber || b.CaseNumber === node.data.CaseNumber).slice(0, 3);
  if (briefItems.length > 0) {
    document.getElementById('sp-related-section').style.display = 'block';
    document.getElementById('sp-related').innerHTML = briefItems.map(b => {
      const isRisk = b.BriefType === 'contradiction';
      return `<div class="related-item ${isRisk ? 'risk' : ''}">
        <span class="eyebrow" style="color:${isRisk ? 'var(--risk)' : 'var(--fg-3)'}">${esc(b.BriefType)}</span>
        <div style="flex:1;font-size:12px;color:var(--fg-1);font-family:var(--font-heb),var(--font-sans)">
          ${esc((b.ContradictionFound || b.SuggestedDocument || b.RecommendedQuestion || '').slice(0,70))}
        </div>
      </div>`;
    }).join('');
  } else {
    document.getElementById('sp-related-section').style.display = 'none';
  }
}

function closeSidePanel() {
  document.getElementById('side-panel').classList.add('hidden');
  selectedNode = null;
  document.querySelectorAll('.graph-node circle').forEach(c => {
    c.style.strokeWidth = '';
    c.style.filter = '';
  });
}

// ── Timeline dock ─────────────────────────────────────────────────────
function buildTimelineDock() {
  const container = document.getElementById('tl-events');
  const todayMarker = document.getElementById('tl-today');
  const steps = DB_STEPS.length > 0 ? DB_STEPS : [];

  if (steps.length === 0) {
    container.innerHTML = '<div style="flex:1;display:flex;align-items:center;justify-content:center;color:var(--fg-4);font-size:11px">No procedural steps — run 09-Prepare-Brief.ps1</div>';
    return;
  }

  // Take up to 8 events spread across the dock
  const sorted = steps.slice().sort((a,b) => (a.ExpectedDate||'').localeCompare(b.ExpectedDate||'')).slice(0, 8);
  const first = new Date(sorted[0].ExpectedDate);
  const last  = new Date(sorted[sorted.length-1].ExpectedDate);
  const range = Math.max(1, last - first);
  const today = new Date();

  // Position "today" marker as a percentage
  const todayPct = Math.max(0, Math.min(100, (today - first) / range * 100));
  todayMarker.style.left = todayPct + '%';

  container.innerHTML = sorted.map(s => {
    const d   = new Date(s.ExpectedDate);
    const pct = Math.max(0, Math.min(100, (d - first) / range * 100));
    const missed   = s.Status === 'missed';
    const upcoming = !missed && (d - today) >= 0 && (d - today) <= 14*86400000;
    const color = missed ? 'var(--risk)' : upcoming ? 'var(--node-task)' : 'var(--node-decision)';
    const glow  = missed
      ? '0 0 0 1px var(--risk),0 0 10px rgba(248,113,113,0.5)'
      : upcoming
      ? '0 0 0 1px var(--brand-cyan),0 0 10px rgba(94,234,232,0.4)'
      : 'none';
    const shortDate = (s.ExpectedDate || '').slice(5); // MM-DD
    const labelCls  = missed ? 'danger' : upcoming ? 'upcoming' : '';
    return `<div class="tl-event" title="${esc(s.StepName)} — ${esc(s.CaseNumber)}&#10;Expected: ${esc(s.ExpectedDate)}&#10;Status: ${esc(s.Status)}">
      <div class="tl-event-date">${shortDate}</div>
      <div class="tl-event-dot" style="background:${color};box-shadow:${glow}"></div>
      <div class="tl-event-label ${labelCls}">${esc((s.StepName||'').slice(0,12))}</div>
    </div>`;
  }).join('');
}

// ── Dashboard ─────────────────────────────────────────────────────────
function buildDashboard() {
  // Subtitle
  const today = new Date().toLocaleDateString('en-GB',{weekday:'long',day:'numeric',month:'long',year:'numeric'});
  document.getElementById('dash-subtitle').textContent =
    STATS.activeCases + ' active cases · ' + STATS.overdueCount + ' overdue deadline(s) · ' + STATS.totalFiles + ' files indexed.';

  // KPI tiles
  const kpis = [
    { label:'Active cases',   value: STATS.activeCases,  delta: DB_CASES.length + ' loaded', color:'var(--ok)' },
    { label:'Open deadlines', value: DB_TASKS.length,    delta: STATS.overdueCount + ' overdue', color: STATS.overdueCount > 0 ? 'var(--risk)' : 'var(--ok)' },
    { label:'AI insights',    value: STATS.aiInsights,   delta: 'from brief analysis', color:'var(--node-ai)' },
    { label:'Files indexed',  value: STATS.totalFiles,   delta: 'OCR complete', color:'var(--brand-cyan)' },
  ];
  document.getElementById('kpi-grid').innerHTML = kpis.map(k => `
    <div class="kpi-card">
      <div class="kpi-accent" style="background:${k.color}"></div>
      <div class="kpi-label">${k.label}</div>
      <div class="kpi-value">${k.value}</div>
      <div class="kpi-delta" style="color:${k.color}">${k.delta}</div>
    </div>`).join('');

  // Cases table
  const casesArr = Array.isArray(DB_CASES) ? DB_CASES : [];
  document.getElementById('cases-tbody').innerHTML = casesArr.map(c => {
    const riskCls = c.HasInvestigationMaterials ? 'low' : 'high';
    return `<tr>
      <td>${esc(c.CaseNumber)}</td>
      <td style="color:var(--fg-1);font-family:var(--font-heb),var(--font-sans)">${esc(c.ClientName||'')}</td>
      <td>${esc(c.CaseType||'')}</td>
      <td>${c.FileCount||0}</td>
      <td><span class="chip ${riskCls}">${c.HasInvestigationMaterials ? 'investigation' : 'civil'}</span></td>
    </tr>`;
  }).join('');

  // AI insights feed from DB_BRIEF
  const briefArr = Array.isArray(DB_BRIEF) ? DB_BRIEF : [];
  if (briefArr.length > 0) {
    document.getElementById('insights-list').innerHTML = briefArr.slice(0,5).map(b => {
      const kindCls = b.BriefType === 'contradiction' ? 'low' : b.BriefType === 'question' ? 'med' : 'ai';
      const text = b.ContradictionFound || b.RecommendedQuestion || b.SuggestedDocument || b.BriefType;
      const conf = b.ConfidenceScore ? (b.ConfidenceScore + '% conf') : '';
      return `<div class="insight-item">
        <span class="chip ${kindCls}" style="flex-shrink:0">${esc(b.BriefType)}</span>
        <div class="insight-text">${esc((text||'').slice(0,80))}</div>
        <span class="insight-time">${esc(conf)}</span>
      </div>`;
    }).join('');
  } else {
    document.getElementById('insights-list').innerHTML =
      '<div style="color:var(--fg-4);font-size:12px;padding:10px 0">Run 09-Prepare-Brief.ps1 to generate AI insights.</div>';
  }
}

// ── AI view ───────────────────────────────────────────────────────────
function buildAIView() {
  const container = document.getElementById('view-ai-content');
  if (!DB_BRIEF || DB_BRIEF.length === 0) {
    container.innerHTML = '<div style="color:var(--fg-4);font-size:13px">No AI insights yet. Run Step 9.</div>';
    return;
  }
  container.innerHTML = '<div class="eyebrow" style="margin-bottom:12px">AI Insights from brief analysis</div>' +
    DB_BRIEF.map(b => {
      const cls = b.BriefType === 'contradiction' ? 'low' : b.BriefType === 'question' ? 'med' : 'ai';
      const text = b.ContradictionFound || b.RecommendedQuestion || b.SuggestedDocument || '';
      return `<div style="background:var(--bg-surface-2);border:1px solid var(--stroke-2);border-radius:9px;padding:12px 14px;margin-bottom:8px">
        <div style="display:flex;gap:8px;align-items:center;margin-bottom:6px">
          <span class="chip ${cls}">${esc(b.BriefType)}</span>
          <span class="eyebrow">${esc(b.CaseNumber||'')}</span>
          ${b.ConfidenceScore ? '<span style="font-family:var(--font-mono);font-size:10px;color:var(--fg-4)">conf '+b.ConfidenceScore+'%</span>' : ''}
        </div>
        <div style="font-size:12.5px;color:var(--fg-1);line-height:1.45;font-family:var(--font-heb),var(--font-sans)">${esc(text)}</div>
        ${b.LegalBasis ? '<div style="font-size:11px;color:var(--fg-3);margin-top:5px">⚖ '+esc(b.LegalBasis)+'</div>' : ''}
      </div>`;
    }).join('');
}

// ── Command palette ───────────────────────────────────────────────────
const PALETTE_ITEMS = [
  ...DB_CASES.map(c => ({
    type:'Case', id: c.CaseNumber, label: c.ClientName || c.CaseName || '',
    color: NODE_COLORS.Case, nid: 'case-'+c.CaseID
  })),
  ...(DB_STEPS.length > 0 ? [{ type:'Procedure', id:'Procedural Steps', label: DB_STEPS.length + ' steps loaded', color: NODE_COLORS.Procedure, nid: null }] : []),
  { type:'Law', id:'פקודת הנזיקין', label:'Tort Ordinance', color: NODE_COLORS.Law, nid:'center' },
];

function openPalette() {
  document.getElementById('palette-overlay').classList.add('open');
  document.getElementById('palette-input').value = '';
  filterPalette('');
  setTimeout(() => document.getElementById('palette-input').focus(), 30);
}
function closePalette() {
  document.getElementById('palette-overlay').classList.remove('open');
}

function filterPalette(q) {
  const filtered = q ? PALETTE_ITEMS.filter(it =>
    (it.id+it.label).toLowerCase().includes(q.toLowerCase())
  ) : PALETTE_ITEMS;

  const aiActions = [
    { label: 'Find contradictions in active cases' },
    { label: 'Show overdue deadlines' },
    { label: 'List AI insights' },
  ];

  document.getElementById('palette-results').innerHTML =
    '<div class="palette-section-label">Entities</div>' +
    filtered.map((it, i) => `
      <div class="palette-item ${i===0&&!q?'focused':''}" onclick="pickPaletteItem(${JSON.stringify(it).replace(/"/g,'&quot;')})">
        <span class="palette-item-dot" style="background:${it.color}"></span>
        <span class="palette-item-id">${esc(it.id)}</span>
        <span class="palette-item-label">${esc(it.label)}</span>
        <span class="palette-item-type">${it.type}</span>
      </div>`).join('') +
    '<div class="palette-section-label">AI actions</div>' +
    aiActions.map(a => `
      <div class="palette-item" onclick="closePalette()">
        <span style="color:var(--node-ai)">
          <svg width="13" height="13" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round"><path d="M12 3c.132 0 .263 0 .393 0a7.5 7.5 0 0 0 7.92 12.446A9 9 0 1 1 12 2.992z"/></svg>
        </span>
        <span class="palette-item-label">${esc(a.label)}</span>
        <span class="chip ai">AI</span>
      </div>`).join('');
}

function pickPaletteItem(item) {
  closePalette();
  if (item.nid) {
    setView('graph', document.getElementById('rail-graph'));
    setTimeout(() => selectNode(item.nid), 100);
  }
}

// ── Utilities ─────────────────────────────────────────────────────────
function esc(s) {
  if (!s) return '';
  return String(s).replace(/&/g,'&amp;').replace(/</g,'&lt;').replace(/>/g,'&gt;').replace(/"/g,'&quot;');
}

// ── Keyboard shortcuts ────────────────────────────────────────────────
document.addEventListener('keydown', e => {
  if ((e.ctrlKey || e.metaKey) && e.key.toLowerCase() === 'k') {
    e.preventDefault();
    document.getElementById('palette-overlay').classList.contains('open') ? closePalette() : openPalette();
  }
  if (e.key === 'Escape') {
    closePalette();
    closeSidePanel();
  }
});

// ── Init ──────────────────────────────────────────────────────────────
buildGraph();
buildTimelineDock();
buildDashboard();
buildAIView();

// Resize SVG on window resize
window.addEventListener('resize', () => {
  if (currentView === 'graph') buildGraph();
});
</script>
</body>
</html>
"@

[System.IO.File]::WriteAllText($workspacePath, $workspaceHtml, [System.Text.Encoding]::UTF8)

Write-Host "  ✓ Workspace saved: $workspacePath" -ForegroundColor Green
Write-Host "  Cases loaded: $activeCases | Procedural steps: $($stepsRaw.Count) | AI insights: $aiInsights" -ForegroundColor Cyan

if ($overdueCount -gt 0) {
    Write-Host "  ⚠ $overdueCount overdue deadline(s) detected." -ForegroundColor Red
}

if (-not $NoOpen) {
    Invoke-Item $workspacePath
}
