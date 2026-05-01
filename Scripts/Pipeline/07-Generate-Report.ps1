#Requires -Version 5.1
<#
.SYNOPSIS
    STEP 7 — Generates the self-contained HTML report.
    Tabs: Summary | Clients | Cases | Tasks | Action Plan | Duplicates | Unresolved | Search
    No external dependencies — all CSS/JS is inlined.
    Opens the report in the default browser when done.
#>

param(
    [string]$DbPath     = "",
    [string]$OutputPath = "",
    [switch]$NoOpen
)

. "$PSScriptRoot\..\lib\Config.ps1"
. "$PSScriptRoot\..\lib\Database.ps1"
if ($DbPath)     { $script:DbPath     = $DbPath }
if ($OutputPath) { $script:OutputPath = $OutputPath }

Import-Module PSSQLite -ErrorAction Stop
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

$stamp      = Get-Date -Format "yyyyMMdd_HHmmss"
$reportPath = Join-Path $script:OutputPath "Report_$stamp.html"
Write-Host "Generating HTML report..." -ForegroundColor Cyan

# ── Query data ─────────────────────────────────────────────────────────────────

$summary = Invoke-SqliteQuery -DataSource $script:DbPath -Query @"
SELECT
  COUNT(*) AS TotalFiles,
  SUM(SizeBytes) / 1048576.0 AS TotalMB,
  SUM(CASE WHEN ProcessingStatus='planned' THEN 1 ELSE 0 END) AS Planned,
  SUM(CASE WHEN Domain='Legal-Case' THEN 1 ELSE 0 END) AS LegalCase,
  SUM(CASE WHEN Domain='Legal-Research' THEN 1 ELSE 0 END) AS LegalResearch,
  SUM(CASE WHEN Domain='Medical' THEN 1 ELSE 0 END) AS Medical,
  SUM(CASE WHEN Domain='Teaching' THEN 1 ELSE 0 END) AS Teaching,
  SUM(CASE WHEN Domain='Personal' THEN 1 ELSE 0 END) AS Personal,
  SUM(CASE WHEN Domain='Unknown' THEN 1 ELSE 0 END) AS Unknown
FROM Files;
"@

$clients = Invoke-SqliteQuery -DataSource $script:DbPath -Query @"
SELECT c.ClientID, c.LastName, c.FirstName, c.IDNumber, c.FolderPath,
       COUNT(DISTINCT fcl.FileID) AS FileCount,
       COUNT(DISTINCT ca.CaseID) AS CaseCount
FROM Clients c
LEFT JOIN FileClientLinks fcl ON fcl.ClientID = c.ClientID
LEFT JOIN Cases ca ON ca.ClientID = c.ClientID
GROUP BY c.ClientID ORDER BY c.LastName;
"@

$cases = Invoke-SqliteQuery -DataSource $script:DbPath -Query @"
SELECT ca.CaseID, ca.CaseNumber, ca.CaseType, ca.Status, ca.FolderPath,
       ca.HasInvestigationMaterials,
       c.LastName, c.FirstName,
       COUNT(fcl.FileID) AS FileCount
FROM Cases ca
LEFT JOIN Clients c ON c.ClientID = ca.ClientID
LEFT JOIN FileCaseLinks fcl ON fcl.CaseID = ca.CaseID
GROUP BY ca.CaseID ORDER BY ca.CaseNumber;
"@

$plan = Invoke-SqliteQuery -DataSource $script:DbPath -Query @"
SELECT f.FileID, f.OriginalName, f.OriginalPath, f.Extension, f.SizeBytes,
       fp.SuggestedName, fp.SuggestedPath, fp.NamingReason, fp.UserAction,
       pi.CaseNumber, pi.ClientName, pi.DocumentType, pi.OverallConfidence,
       fc.OcrConfidence, fc.ExtractionMethod
FROM FilePlan fp
JOIN Files f ON f.FileID = fp.FileID
LEFT JOIN ParsedIdentifiers pi ON pi.FileID = fp.FileID
LEFT JOIN FileContent fc ON fc.FileID = fp.FileID
ORDER BY pi.OverallConfidence DESC, f.OriginalName;
"@

$duplicates = Invoke-SqliteQuery -DataSource $script:DbPath -Query @"
SELECT d.GroupID, d.FileID, d.IsRecommendedKeep, d.QuarantineTier, d.UserAction,
       f.OriginalName, f.OriginalPath, f.SizeBytes, f.Domain
FROM Duplicates d
JOIN Files f ON f.FileID = d.FileID
ORDER BY d.GroupID, d.IsRecommendedKeep DESC;
"@

$unresolved = Invoke-SqliteQuery -DataSource $script:DbPath -Query @"
SELECT f.FileID, f.OriginalName, f.OriginalPath, f.Extension, f.SizeBytes,
       fc.OcrConfidence, fc.ExtractionMethod,
       SUBSTR(fc.ExtractedText, 1, 300) AS TextPreview
FROM Files f
JOIN FileContent fc ON fc.FileID = f.FileID
WHERE fc.OcrConfidence < 50 AND fc.ExtractedText IS NOT NULL AND fc.ExtractedText != ''
   OR fc.ExtractionMethod = 'none'
ORDER BY fc.OcrConfidence ASC;
"@

$tasks = Invoke-SqliteQuery -DataSource $script:DbPath -Query @"
SELECT t.TaskID, t.CaseID, t.ClientID, t.Title, t.Description, t.Category,
       t.IsChecked, t.DueDate, t.Priority, t.CreatedDate, t.CompletedDate,
       c.CaseNumber, cl.LastName || ' ' || cl.FirstName AS ClientName
FROM Tasks t
LEFT JOIN Cases c ON c.CaseID = t.CaseID
LEFT JOIN Clients cl ON cl.ClientID = COALESCE(t.ClientID, c.ClientID)
ORDER BY t.IsChecked ASC, t.Priority DESC, t.DueDate ASC;
"@

# ── Build HTML ─────────────────────────────────────────────────────────────────

$totalMB = [math]::Round($summary.TotalMB, 1)
$dupCount = ($duplicates | Select-Object -ExpandProperty GroupID -Unique).Count

# Convert data to JSON for embedded JavaScript
$clientsJson    = $clients    | ConvertTo-Json -Compress
$casesJson      = $cases      | ConvertTo-Json -Compress
$planJson       = $plan       | ConvertTo-Json -Compress
$duplicatesJson = $duplicates | ConvertTo-Json -Compress
$unresolvedJson = $unresolved | ConvertTo-Json -Compress
$tasksJson      = $tasks      | ConvertTo-Json -Compress
$taskCount      = if ($tasks) { @($tasks).Count } else { 0 }
$pendingTasks   = if ($tasks) { @($tasks | Where-Object { $_.IsChecked -eq 0 }).Count } else { 0 }

$domainData = @"
[$($summary.LegalCase),$($summary.LegalResearch),$($summary.Medical),$($summary.Teaching),$($summary.Personal),$($summary.Unknown)]
"@.Trim()

$html = @"
<!DOCTYPE html>
<html lang="he" dir="rtl">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>דוח ארגון קבצים — $stamp</title>
<style>
*{box-sizing:border-box;margin:0;padding:0}
body{font-family:'Segoe UI',Arial,sans-serif;background:#f4f6f9;color:#222;direction:rtl}
header{background:#1a3a5c;color:#fff;padding:16px 24px}
header h1{font-size:1.4rem}
header p{font-size:.85rem;opacity:.8;margin-top:4px}
nav{background:#fff;border-bottom:2px solid #1a3a5c;display:flex;gap:0;overflow-x:auto}
nav button{padding:12px 20px;border:none;background:none;cursor:pointer;font-size:.9rem;
  border-bottom:3px solid transparent;white-space:nowrap}
nav button.active{border-bottom-color:#1a3a5c;font-weight:bold;color:#1a3a5c}
nav button:hover{background:#f0f4f8}
.tab{display:none;padding:20px;max-width:1400px;margin:0 auto}
.tab.active{display:block}
.cards{display:grid;grid-template-columns:repeat(auto-fit,minmax(180px,1fr));gap:16px;margin-bottom:24px}
.card{background:#fff;border-radius:8px;padding:20px;box-shadow:0 1px 4px rgba(0,0,0,.1);text-align:center}
.card .num{font-size:2rem;font-weight:bold;color:#1a3a5c}
.card .lbl{font-size:.8rem;color:#666;margin-top:4px}
table{width:100%;border-collapse:collapse;background:#fff;border-radius:8px;
  overflow:hidden;box-shadow:0 1px 4px rgba(0,0,0,.1);font-size:.85rem}
th{background:#1a3a5c;color:#fff;padding:10px 12px;text-align:right}
td{padding:9px 12px;border-bottom:1px solid #eee}
tr:hover td{background:#f8fafc}
.badge{display:inline-block;padding:2px 8px;border-radius:12px;font-size:.75rem;font-weight:bold}
.badge-high{background:#d4edda;color:#155724}
.badge-med{background:#fff3cd;color:#856404}
.badge-low{background:#f8d7da;color:#721c24}
.badge-pending{background:#cce5ff;color:#004085}
.badge-approved{background:#d4edda;color:#155724}
.badge-rejected{background:#f8d7da;color:#721c24}
.badge-review{background:#fff3cd;color:#856404}
.client-card{background:#fff;border-radius:8px;padding:16px;box-shadow:0 1px 4px rgba(0,0,0,.1);
  margin-bottom:12px;border-right:4px solid #1a3a5c}
.dup-group{background:#fff;border-radius:8px;padding:16px;
  box-shadow:0 1px 4px rgba(0,0,0,.1);margin-bottom:12px;border-right:4px solid #e67e22}
.dup-keep{background:#f0fff4;border-right:3px solid #27ae60;padding:8px;border-radius:4px;margin:4px 0}
.dup-copy{background:#fffbf0;padding:8px;border-radius:4px;margin:4px 0}
.warn-banner{background:#fff3cd;border:1px solid #ffc107;border-radius:6px;padding:12px;
  margin-bottom:16px;color:#856404}
input[type=text]{padding:7px 12px;border:1px solid #ccc;border-radius:4px;
  width:100%;margin-bottom:12px;font-size:.9rem}
.path{font-family:monospace;font-size:.78rem;color:#555;word-break:break-all}
canvas{max-width:400px;margin:0 auto;display:block}
.task-list{background:#fff;border-radius:8px;padding:16px;box-shadow:0 1px 4px rgba(0,0,0,.1);margin-bottom:16px}
.task-list h3{font-size:.95rem;color:#1a3a5c;margin-bottom:10px;border-bottom:1px solid #eee;padding-bottom:6px}
.task-item{display:flex;align-items:flex-start;gap:10px;padding:6px 0;border-bottom:1px solid #f5f5f5}
.task-item:last-child{border-bottom:none}
.task-item input[type=checkbox]{width:16px;height:16px;cursor:pointer;flex-shrink:0;margin-top:2px;accent-color:#1a3a5c}
.task-item .task-title{flex:1;font-size:.88rem}
.task-item .task-title.done{text-decoration:line-through;color:#aaa}
.task-meta{font-size:.75rem;color:#888;margin-top:2px}
.task-due{font-size:.75rem}
.task-due.overdue{color:#c0392b;font-weight:bold}
.task-due.soon{color:#e67e22}
.task-due.ok{color:#27ae60}
.pri-high::before{content:'⚑ ';color:#c0392b}
.pri-low::before{content:'↓ ';color:#888}
.task-progress{background:#eee;border-radius:4px;height:6px;margin-bottom:12px}
.task-progress-bar{background:#1a3a5c;border-radius:4px;height:6px;transition:width .3s}
.task-filter-row{display:flex;gap:8px;margin-bottom:12px;flex-wrap:wrap}
.task-filter-row button{padding:5px 12px;border:1px solid #ccc;border-radius:16px;
  background:#fff;cursor:pointer;font-size:.8rem}
.task-filter-row button.active{background:#1a3a5c;color:#fff;border-color:#1a3a5c}
</style>
</head>
<body>
<header>
  <h1>דוח ארגון קבצים משפטיים</h1>
  <p>הופק: $((Get-Date).ToString('dd/MM/yyyy HH:mm')) | קבצים: $($summary.TotalFiles) | גודל: $totalMB MB</p>
</header>

<nav>
  <button class="active" onclick="show('summary')">סיכום</button>
  <button onclick="show('clients')">לקוחות ($($clients.Count))</button>
  <button onclick="show('cases')">תיקים ($($cases.Count))</button>
  <button onclick="show('tasks')">משימות ($pendingTasks פתוחות)</button>
  <button onclick="show('plan')">תוכנית פעולה ($($plan.Count))</button>
  <button onclick="show('dups')">כפולים ($dupCount קבוצות)</button>
  <button onclick="show('unresolved')">לא פוענח ($($unresolved.Count))</button>
  <button onclick="show('search')">חיפוש חופשי</button>
</nav>

<!-- SUMMARY TAB -->
<div id="tab-summary" class="tab active">
  <div class="cards">
    <div class="card"><div class="num">$($summary.TotalFiles)</div><div class="lbl">סה"כ קבצים</div></div>
    <div class="card"><div class="num">$totalMB</div><div class="lbl">MB גודל כולל</div></div>
    <div class="card"><div class="num">$dupCount</div><div class="lbl">קבוצות כפולים</div></div>
    <div class="card"><div class="num">$($unresolved.Count)</div><div class="lbl">לא פוענח</div></div>
    <div class="card"><div class="num">$($summary.Planned)</div><div class="lbl">מוכן להעברה</div></div>
  </div>
  <canvas id="domainChart" width="400" height="300"></canvas>
</div>

<!-- CLIENTS TAB -->
<div id="tab-clients" class="tab">
  <input type="text" id="clientSearch" onkeyup="filterClients()" placeholder="חפש לקוח...">
  <div id="clientList"></div>
</div>

<!-- CASES TAB -->
<div id="tab-cases" class="tab">
  <input type="text" id="caseSearch" onkeyup="filterTable('casesTable',this.value)" placeholder="חפש תיק...">
  <table id="casesTable">
    <thead><tr><th>מספר תיק</th><th>לקוח</th><th>סוג</th><th>סטטוס</th><th>קבצים</th><th>חומר חקירה</th></tr></thead>
    <tbody id="casesTbody"></tbody>
  </table>
</div>

<!-- TASKS TAB -->
<div id="tab-tasks" class="tab">
  <div class="task-filter-row">
    <button class="active" onclick="filterTasks('all',this)">הכל</button>
    <button onclick="filterTasks('pending',this)">פתוחות בלבד</button>
    <button onclick="filterTasks('done',this)">הושלמו</button>
    <button onclick="filterTasks('high',this)">עדיפות גבוהה</button>
    <button onclick="filterTasks('overdue',this)">באיחור</button>
  </div>
  <input type="text" id="taskSearch" onkeyup="renderTasks()" placeholder="חפש משימה, תיק, לקוח...">
  <div id="tasksList"></div>
</div>

<!-- ACTION PLAN TAB -->
<div id="tab-plan" class="tab">
  <div class="warn-banner">⚠ סקור כל שורה לפני אישור. שנה את עמודת UserAction ל-APPROVED עבור קבצים שאתה מאשר להעברה. <strong>שום דבר לא יזוז עד שתריץ את 08-Apply-Approved.ps1</strong></div>
  <input type="text" id="planSearch" onkeyup="filterTable('planTable',this.value)" placeholder="חפש...">
  <table id="planTable">
    <thead><tr><th>שם נוכחי</th><th>שם מוצע</th><th>תיקייה מוצעת</th><th>לקוח / תיק</th><th>סוג מסמך</th><th>ביטחון</th><th>פעולה</th></tr></thead>
    <tbody id="planTbody"></tbody>
  </table>
</div>

<!-- DUPLICATES TAB -->
<div id="tab-dups" class="tab">
  <div class="warn-banner">⚠ זיהוי כפולים מבוסס על תוכן זהה (MD5) בלבד. קבצים עם שמות דומים אך תוכן שונה <strong>לא</strong> יופיעו כאן. ודא ידנית לפני כל מחיקה.</div>
  <div id="dupsList"></div>
</div>

<!-- UNRESOLVED TAB -->
<div id="tab-unresolved" class="tab">
  <p style="margin-bottom:12px;color:#856404">קבצים אלו הועברו ל-_Inbox\To-Review כי איכות ה-OCR נמוכה מדי לסיווג אמין.</p>
  <table>
    <thead><tr><th>שם קובץ</th><th>שיטת חילוץ</th><th>ביטחון OCR</th><th>תצוגה מקדימה</th></tr></thead>
    <tbody id="unresTbody"></tbody>
  </table>
</div>

<!-- SEARCH TAB -->
<div id="tab-search" class="tab">
  <p style="margin-bottom:12px">חיפוש בתוכן כל הקבצים שנסרקו (FTS). לתוצאות מדויקות יותר, הפעל את הסקריפט עם שאילתת SQL ישירות על הבסיס נתונים.</p>
  <input type="text" id="searchBox" onkeyup="filterTable('searchTable',this.value)" placeholder='חפש ביטוי, שם לקוח, מספר תיק...'>
  <table id="searchTable">
    <thead><tr><th>שם קובץ</th><th>נתיב</th><th>תצוגה מקדימה</th></tr></thead>
    <tbody id="searchTbody"></tbody>
  </table>
</div>

<script>
const clients    = $clientsJson;
const cases      = $casesJson;
const plan       = $planJson;
const dups       = $duplicatesJson;
const unresolved = $unresolvedJson;
const tasksData  = $tasksJson;

function show(tab){
  document.querySelectorAll('.tab').forEach(t=>t.classList.remove('active'));
  document.querySelectorAll('nav button').forEach(b=>b.classList.remove('active'));
  document.getElementById('tab-'+tab).classList.add('active');
  event.target.classList.add('active');
}

function confBadge(c){
  if(c>=75) return '<span class="badge badge-high">'+c+'%</span>';
  if(c>=50) return '<span class="badge badge-med">'+c+'%</span>';
  return '<span class="badge badge-low">'+c+'%</span>';
}
function actionBadge(a){
  const cls={PENDING:'badge-pending',APPROVED:'badge-approved',REJECTED:'badge-rejected',REVIEW:'badge-review'};
  return '<span class="badge '+(cls[a]||'badge-pending')+'">'+a+'</span>';
}
function fmt(bytes){return bytes?(bytes/1048576).toFixed(1)+' MB':'—'}
function esc(s){return s?(s+'').replace(/&/g,'&amp;').replace(/</g,'&lt;').replace(/>/g,'&gt;'):''}

// Build client cards
function renderClients(arr){
  const el=document.getElementById('clientList');
  el.innerHTML=arr.map(c=>`
    <div class="client-card">
      <strong>${esc(c.LastName)} ${esc(c.FirstName)}</strong>
      ${c.IDNumber?'<span style="color:#888;font-size:.8rem"> ת.ז. '+esc(c.IDNumber)+'</span>':''}
      <br><span style="font-size:.8rem;color:#555">${c.CaseCount} תיק(ים) | ${c.FileCount} קבצים</span>
      <br><span class="path">${esc(c.FolderPath)}</span>
    </div>`).join('');
}
renderClients(Array.isArray(clients)?clients:[clients].filter(Boolean));

function filterClients(){
  const q=document.getElementById('clientSearch').value.toLowerCase();
  const arr=(Array.isArray(clients)?clients:[clients]).filter(c=>
    (c.LastName+' '+c.FirstName+' '+c.IDNumber+' '+c.CaseCount).toLowerCase().includes(q));
  renderClients(arr);
}

// Build cases table
const casesTb=document.getElementById('casesTbody');
const casesArr=Array.isArray(cases)?cases:[cases].filter(Boolean);
casesTb.innerHTML=casesArr.map(c=>`<tr>
  <td><strong>${esc(c.CaseNumber)}</strong></td>
  <td>${esc(c.LastName)} ${esc(c.FirstName)}</td>
  <td>${esc(c.CaseType)}</td>
  <td>${esc(c.Status)}</td>
  <td>${c.FileCount}</td>
  <td>${c.HasInvestigationMaterials?'<span class="badge badge-low">כן — חומר חקירה</span>':'—'}</td>
</tr>`).join('');

// Build plan table
const planTb=document.getElementById('planTbody');
const planArr=Array.isArray(plan)?plan:[plan].filter(Boolean);
planTb.innerHTML=planArr.map(p=>`<tr>
  <td class="path">${esc(p.OriginalName)}</td>
  <td><strong>${esc(p.SuggestedName)}</strong></td>
  <td class="path">${esc(p.SuggestedPath)}</td>
  <td>${esc(p.ClientName||'')} ${esc(p.CaseNumber||'')}</td>
  <td>${esc(p.DocumentType||'—')}</td>
  <td>${confBadge(p.OverallConfidence||0)}</td>
  <td>${actionBadge(p.UserAction)}</td>
</tr>`).join('');

// Build duplicates
const dupGroups={};
(Array.isArray(dups)?dups:[dups].filter(Boolean)).forEach(d=>{
  if(!dupGroups[d.GroupID]) dupGroups[d.GroupID]=[];
  dupGroups[d.GroupID].push(d);
});
document.getElementById('dupsList').innerHTML=Object.entries(dupGroups).map(([gid,files])=>`
  <div class="dup-group">
    <strong>קבוצה #${gid}</strong> — ${files.length} עותקים —
    גודל: ${fmt(files[0].SizeBytes)}
    <br><em style="font-size:.78rem;color:#777">שכפול: ${files[0].QuarantineTier==='auto'?'בטוח להסגר אוטומטי':'נדרש סקירה'}</em>
    ${files.map(f=>`
      <div class="${f.IsRecommendedKeep?'dup-keep':'dup-copy'}">
        ${f.IsRecommendedKeep?'★ שמור: ':'העתק: '}
        <span class="path">${esc(f.OriginalPath)}</span>
        ${actionBadge(f.UserAction)}
      </div>`).join('')}
  </div>`).join('');

// Build unresolved table
document.getElementById('unresTbody').innerHTML=
  (Array.isArray(unresolved)?unresolved:[unresolved].filter(Boolean)).map(u=>`<tr>
    <td>${esc(u.OriginalName)}</td>
    <td>${esc(u.ExtractionMethod)}</td>
    <td>${confBadge(u.OcrConfidence||0)}</td>
    <td><small>${esc(u.TextPreview||'אין טקסט')}</small></td>
  </tr>`).join('');

// Full-text search (client-side filter on all plan items for now)
const searchTb=document.getElementById('searchTbody');
searchTb.innerHTML=planArr.map(p=>`<tr>
  <td>${esc(p.OriginalName)}</td>
  <td class="path">${esc(p.OriginalPath)}</td>
  <td><small>${esc((p.NamingReason||'').substring(0,120))}</small></td>
</tr>`).join('');

function filterTable(tableId, q){
  q=q.toLowerCase();
  document.querySelectorAll('#'+tableId+' tbody tr').forEach(r=>{
    r.style.display=r.textContent.toLowerCase().includes(q)?'':'none';
  });
}

// ── Tasks ─────────────────────────────────────────────────────────────────────
const tasksArr = Array.isArray(tasksData) ? tasksData : (tasksData ? [tasksData] : []);
let taskFilter = 'all';
const today = new Date().toISOString().slice(0,10);

function dueCls(due){
  if(!due) return '';
  if(due < today) return 'overdue';
  const d = new Date(due), t = new Date(today);
  return (d - t) <= 7*86400000 ? 'soon' : 'ok';
}

function filterTasks(f, btn){
  taskFilter = f;
  document.querySelectorAll('.task-filter-row button').forEach(b=>b.classList.remove('active'));
  btn.classList.add('active');
  renderTasks();
}

function renderTasks(){
  const q = (document.getElementById('taskSearch').value||'').toLowerCase();
  let arr = tasksArr.filter(t=>{
    const text = [t.Title, t.Description, t.CaseNumber, t.ClientName, t.Category].join(' ').toLowerCase();
    if(q && !text.includes(q)) return false;
    if(taskFilter==='pending' && t.IsChecked) return false;
    if(taskFilter==='done'    && !t.IsChecked) return false;
    if(taskFilter==='high'    && t.Priority!=='high') return false;
    if(taskFilter==='overdue' && (!t.DueDate || t.DueDate >= today)) return false;
    return true;
  });

  // Group by CaseNumber (or ClientName if no case)
  const groups = {};
  arr.forEach(t=>{
    const key = t.CaseNumber || (t.ClientName ? 'לקוח: '+t.ClientName : 'ללא שיוך');
    if(!groups[key]) groups[key] = [];
    groups[key].push(t);
  });

  const el = document.getElementById('tasksList');
  if(!arr.length){ el.innerHTML='<p style="color:#888;padding:20px">אין משימות מתאימות לפילטר שנבחר.</p>'; return; }

  el.innerHTML = Object.entries(groups).map(([grpName, items])=>{
    const total = items.length;
    const done  = items.filter(i=>i.IsChecked).length;
    const pct   = total ? Math.round(done/total*100) : 0;
    const rows  = items.map(t=>{
      const dCls = dueCls(t.DueDate);
      const priCls = t.Priority==='high'?'pri-high':t.Priority==='low'?'pri-low':'';
      const dueLabel = t.DueDate ? `<span class="task-due ${dCls}">${dCls==='overdue'?'⚠ באיחור — ':dCls==='soon'?'⏰ בקרוב — ':'עד '}${t.DueDate}</span>` : '';
      const catLabel = t.Category && t.Category!=='general' ? `<span style="color:#555"> [${esc(t.Category)}]</span>` : '';
      return `<div class="task-item" data-id="${t.TaskID}">
        <input type="checkbox" ${t.IsChecked?'checked':''} onchange="toggleTask(${t.TaskID},this)">
        <div style="flex:1">
          <div class="task-title ${t.IsChecked?'done':''} ${priCls}">${esc(t.Title)}</div>
          <div class="task-meta">${dueLabel}${catLabel}${t.Description?'<br><small>'+esc(t.Description.substring(0,100))+'</small>':''}</div>
        </div>
      </div>`;
    }).join('');

    return `<div class="task-list">
      <h3>${esc(grpName)} <span style="font-weight:normal;font-size:.8rem;color:#888">${done}/${total} הושלמו</span></h3>
      <div class="task-progress"><div class="task-progress-bar" style="width:${pct}%"></div></div>
      ${rows}
    </div>`;
  }).join('');
}
renderTasks();

function toggleTask(id, cb){
  // Visual update only — actual DB update requires running Set-TaskChecked via PowerShell
  const item = cb.closest('.task-item');
  item.querySelector('.task-title').classList.toggle('done', cb.checked);
  // Re-render to update progress bar
  const caseKey = item.closest('.task-list').querySelector('h3').textContent;
  const t = tasksArr.find(x=>x.TaskID===id);
  if(t) t.IsChecked = cb.checked ? 1 : 0;
  renderTasks();
}

// ── Domain pie chart (Chart.js via CDN) ──────────────────────────────────────
const script=document.createElement('script');
script.src='https://cdn.jsdelivr.net/npm/chart.js@4.4.0/dist/chart.umd.min.js';
script.onload=()=>{
  new Chart(document.getElementById('domainChart'),{
    type:'doughnut',
    data:{
      labels:['תיקים משפטיים','מחקר משפטי','רפואה','הוראה','אישי','לא מסווג'],
      datasets:[{data:$domainData,
        backgroundColor:['#1a3a5c','#2980b9','#27ae60','#e67e22','#8e44ad','#95a5a6']}]
    },
    options:{plugins:{legend:{position:'bottom'}}}
  });
};
document.head.appendChild(script);
</script>
</body>
</html>
"@

[System.IO.File]::WriteAllText($reportPath, $html, [System.Text.Encoding]::UTF8)
Write-Host "Report saved: $reportPath" -ForegroundColor Green

if (-not $NoOpen) {
    Invoke-Item $reportPath
}
