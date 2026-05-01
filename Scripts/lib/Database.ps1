#Requires -Version 5.1
<#
.SYNOPSIS
    SQLite database helpers. Requires PSSQLite module.
    Install once: Install-Module PSSQLite -Scope CurrentUser
#>

function Initialize-Database {
    param([string]$DbPath)

    $schema = @"
PRAGMA journal_mode=WAL;
PRAGMA foreign_keys=ON;

CREATE TABLE IF NOT EXISTS Files (
    FileID          INTEGER PRIMARY KEY AUTOINCREMENT,
    OriginalName    TEXT NOT NULL,
    OriginalPath    TEXT NOT NULL UNIQUE,
    CurrentPath     TEXT,
    Extension       TEXT,
    SizeBytes       INTEGER,
    DateModified    TEXT,
    DateCreated     TEXT,
    MD5Hash         TEXT,
    Domain          TEXT DEFAULT 'Unknown',
    ProcessingStatus TEXT DEFAULT 'pending',
    ScanDate        TEXT
);

CREATE TABLE IF NOT EXISTS FileContent (
    FileID            INTEGER PRIMARY KEY REFERENCES Files(FileID),
    ExtractedText     TEXT,
    ExtractionMethod  TEXT,
    OcrConfidence     INTEGER DEFAULT 0,
    DetectedLanguage  TEXT,
    WordCount         INTEGER DEFAULT 0
);

CREATE VIRTUAL TABLE IF NOT EXISTS FileContent_FTS USING fts5(
    FileID UNINDEXED,
    ExtractedText,
    content='FileContent',
    content_rowid='FileID',
    tokenize='unicode61'
);

CREATE TABLE IF NOT EXISTS ParsedIdentifiers (
    FileID                INTEGER PRIMARY KEY REFERENCES Files(FileID),
    ClientName            TEXT,
    ClientNameConfidence  INTEGER DEFAULT 0,
    ClientIDNumber        TEXT,
    IDConfidence          INTEGER DEFAULT 0,
    CaseNumber            TEXT,
    CaseNumberConfidence  INTEGER DEFAULT 0,
    CaseType              TEXT,
    ReportNumber          TEXT,
    ProcedureNumber       TEXT,
    DocumentDate          TEXT,
    DocumentType          TEXT,
    DocumentTypeSlug      TEXT,
    DocTypeConfidence     INTEGER DEFAULT 0,
    OverallConfidence     INTEGER DEFAULT 0
);

CREATE TABLE IF NOT EXISTS Contacts (
    ContactID         INTEGER PRIMARY KEY AUTOINCREMENT,
    FullName          TEXT NOT NULL,
    IDNumber          TEXT,
    PersonType        TEXT DEFAULT 'other',
    Organization      TEXT,
    PhoneNumber       TEXT,
    EmailAddress      TEXT,
    FirstSeenFileID   INTEGER REFERENCES Files(FileID),
    Notes             TEXT,
    UNIQUE(FullName, PersonType)
);

CREATE TABLE IF NOT EXISTS ContactCaseLinks (
    LinkID            INTEGER PRIMARY KEY AUTOINCREMENT,
    ContactID         INTEGER REFERENCES Contacts(ContactID),
    CaseID            INTEGER REFERENCES Cases(CaseID),
    RoleInCase        TEXT,
    FileID            INTEGER REFERENCES Files(FileID)
);

CREATE TABLE IF NOT EXISTS Clients (
    ClientID          INTEGER PRIMARY KEY AUTOINCREMENT,
    LastName          TEXT,
    FirstName         TEXT,
    IDNumber          TEXT UNIQUE,
    FolderPath        TEXT,
    IsActive          INTEGER DEFAULT 1,
    Notes             TEXT,
    CreatedDate       TEXT
);

CREATE TABLE IF NOT EXISTS Cases (
    CaseID            INTEGER PRIMARY KEY AUTOINCREMENT,
    ClientID          INTEGER REFERENCES Clients(ClientID),
    CaseNumber        TEXT,
    CaseName          TEXT,
    CaseType          TEXT DEFAULT 'civil',
    Court             TEXT,
    Status            TEXT DEFAULT 'active',
    OpenDate          TEXT,
    CloseDate         TEXT,
    FolderPath        TEXT,
    HasInvestigationMaterials INTEGER DEFAULT 0,
    UNIQUE(CaseNumber)
);

CREATE TABLE IF NOT EXISTS FileCaseLinks (
    LinkID            INTEGER PRIMARY KEY AUTOINCREMENT,
    FileID            INTEGER REFERENCES Files(FileID),
    CaseID            INTEGER REFERENCES Cases(CaseID),
    LinkSource        TEXT,
    DocumentRole      TEXT
);

CREATE TABLE IF NOT EXISTS LegalArguments (
    ArgumentID        INTEGER PRIMARY KEY AUTOINCREMENT,
    Title             TEXT,
    SourceFileID      INTEGER REFERENCES Files(FileID),
    CaseID            INTEGER REFERENCES Cases(CaseID),
    ArgumentText      TEXT,
    PrecedentCaseNumbers TEXT,
    Tags              TEXT,
    CreatedDate       TEXT
);

CREATE TABLE IF NOT EXISTS FilePlan (
    FileID            INTEGER PRIMARY KEY REFERENCES Files(FileID),
    SuggestedPath     TEXT,
    SuggestedName     TEXT,
    NamingReason      TEXT,
    UserAction        TEXT DEFAULT 'PENDING',
    ReviewedDate      TEXT
);

CREATE TABLE IF NOT EXISTS Duplicates (
    DupID             INTEGER PRIMARY KEY AUTOINCREMENT,
    GroupID           INTEGER,
    FileID            INTEGER REFERENCES Files(FileID),
    IsRecommendedKeep INTEGER DEFAULT 0,
    QuarantineTier    TEXT DEFAULT 'review',
    UserAction        TEXT DEFAULT 'REVIEW'
);

CREATE TABLE IF NOT EXISTS ActionLog (
    LogID             INTEGER PRIMARY KEY AUTOINCREMENT,
    FileID            INTEGER REFERENCES Files(FileID),
    ActionTime        TEXT,
    ActionType        TEXT,
    OldPath           TEXT,
    NewPath           TEXT,
    OldName           TEXT,
    NewName           TEXT
);

CREATE TABLE IF NOT EXISTS Hearings (
    HearingID         INTEGER PRIMARY KEY AUTOINCREMENT,
    CaseID            INTEGER REFERENCES Cases(CaseID),
    HearingDate       TEXT,
    Court             TEXT,
    Judge             TEXT,
    HearingType       TEXT,
    Notes             TEXT,
    SourceFileID      INTEGER REFERENCES Files(FileID)
);

CREATE TABLE IF NOT EXISTS DryRunSnapshot (
    SnapshotID        INTEGER PRIMARY KEY AUTOINCREMENT,
    RunStamp          TEXT,
    FileID            INTEGER REFERENCES Files(FileID),
    OriginalPath      TEXT,
    ProposedPath      TEXT,
    ProposedName      TEXT,
    ActionType        TEXT
);

CREATE INDEX IF NOT EXISTS idx_files_md5       ON Files(MD5Hash);
CREATE INDEX IF NOT EXISTS idx_files_status    ON Files(ProcessingStatus);
CREATE INDEX IF NOT EXISTS idx_files_domain    ON Files(Domain);
CREATE INDEX IF NOT EXISTS idx_cases_number    ON Cases(CaseNumber);
CREATE INDEX IF NOT EXISTS idx_contacts_type   ON Contacts(PersonType);
CREATE INDEX IF NOT EXISTS idx_parsed_case     ON ParsedIdentifiers(CaseNumber);
CREATE INDEX IF NOT EXISTS idx_parsed_id       ON ParsedIdentifiers(ClientIDNumber);
CREATE INDEX IF NOT EXISTS idx_hearings_case   ON Hearings(CaseID);
CREATE INDEX IF NOT EXISTS idx_hearings_date   ON Hearings(HearingDate);
"@

    Invoke-SqliteQuery -DataSource $DbPath -Query $schema
    Write-Host "  Database initialized: $DbPath" -ForegroundColor Green
}

function Upsert-File {
    param([string]$DbPath, [hashtable]$Row)
    $q = @"
INSERT INTO Files (OriginalName,OriginalPath,CurrentPath,Extension,SizeBytes,
                   DateModified,DateCreated,MD5Hash,ProcessingStatus,ScanDate)
VALUES (@OriginalName,@OriginalPath,@OriginalPath,@Extension,@SizeBytes,
        @DateModified,@DateCreated,@MD5Hash,'pending',@ScanDate)
ON CONFLICT(OriginalPath) DO UPDATE SET
    SizeBytes=excluded.SizeBytes,
    DateModified=excluded.DateModified,
    MD5Hash=excluded.MD5Hash,
    ScanDate=excluded.ScanDate;
"@
    Invoke-SqliteQuery -DataSource $DbPath -Query $q -SqlParameters $Row
}

function Set-FileContent {
    param([string]$DbPath, [hashtable]$Row)
    $q = @"
INSERT INTO FileContent (FileID,ExtractedText,ExtractionMethod,OcrConfidence,DetectedLanguage,WordCount)
VALUES (@FileID,@ExtractedText,@ExtractionMethod,@OcrConfidence,@DetectedLanguage,@WordCount)
ON CONFLICT(FileID) DO UPDATE SET
    ExtractedText=excluded.ExtractedText,
    ExtractionMethod=excluded.ExtractionMethod,
    OcrConfidence=excluded.OcrConfidence,
    DetectedLanguage=excluded.DetectedLanguage,
    WordCount=excluded.WordCount;
"@
    Invoke-SqliteQuery -DataSource $DbPath -Query $q -SqlParameters $Row

    # Keep FTS index in sync
    $ftsq = @"
INSERT INTO FileContent_FTS(rowid, FileID, ExtractedText)
VALUES (@FileID, @FileID, @ExtractedText)
ON CONFLICT(rowid) DO UPDATE SET ExtractedText=excluded.ExtractedText;
"@
    Invoke-SqliteQuery -DataSource $DbPath -Query $ftsq -SqlParameters @{
        FileID = $Row.FileID; ExtractedText = $Row.ExtractedText
    }
}

function Get-FileID {
    param([string]$DbPath, [string]$FilePath)
    $r = Invoke-SqliteQuery -DataSource $DbPath `
        -Query "SELECT FileID FROM Files WHERE OriginalPath=@p" `
        -SqlParameters @{p=$FilePath}
    return $r.FileID
}

function Set-ProcessingStatus {
    param([string]$DbPath, [int]$FileID, [string]$Status)
    Invoke-SqliteQuery -DataSource $DbPath `
        -Query "UPDATE Files SET ProcessingStatus=@s WHERE FileID=@id" `
        -SqlParameters @{s=$Status; id=$FileID}
}

function Upsert-ParsedIdentifiers {
    param([string]$DbPath, [hashtable]$Row)
    $q = @"
INSERT INTO ParsedIdentifiers (
    FileID, ClientName, ClientNameConfidence, ClientIDNumber, IDConfidence,
    CaseNumber, CaseNumberConfidence, CaseType, ReportNumber, ProcedureNumber,
    DocumentDate, DocumentType, DocumentTypeSlug, DocTypeConfidence, OverallConfidence)
VALUES (
    @FileID, @ClientName, @ClientNameConfidence, @ClientIDNumber, @IDConfidence,
    @CaseNumber, @CaseNumberConfidence, @CaseType, @ReportNumber, @ProcedureNumber,
    @DocumentDate, @DocumentType, @DocumentTypeSlug, @DocTypeConfidence, @OverallConfidence)
ON CONFLICT(FileID) DO UPDATE SET
    ClientName=excluded.ClientName, ClientNameConfidence=excluded.ClientNameConfidence,
    ClientIDNumber=excluded.ClientIDNumber, IDConfidence=excluded.IDConfidence,
    CaseNumber=excluded.CaseNumber, CaseNumberConfidence=excluded.CaseNumberConfidence,
    CaseType=excluded.CaseType, ReportNumber=excluded.ReportNumber,
    ProcedureNumber=excluded.ProcedureNumber, DocumentDate=excluded.DocumentDate,
    DocumentType=excluded.DocumentType, DocumentTypeSlug=excluded.DocumentTypeSlug,
    DocTypeConfidence=excluded.DocTypeConfidence, OverallConfidence=excluded.OverallConfidence;
"@
    Invoke-SqliteQuery -DataSource $DbPath -Query $q -SqlParameters $Row
}

function Upsert-Hearing {
    param([string]$DbPath, [hashtable]$Row)
    $q = @"
INSERT INTO Hearings (CaseID, HearingDate, Court, Judge, HearingType, Notes, SourceFileID)
VALUES (@CaseID, @HearingDate, @Court, @Judge, @HearingType, @Notes, @SourceFileID);
"@
    Invoke-SqliteQuery -DataSource $DbPath -Query $q -SqlParameters $Row
}

function Get-DuplicateGroups {
    param([string]$DbPath)
    $q = @"
SELECT MD5Hash, COUNT(*) AS Cnt, GROUP_CONCAT(FileID) AS FileIDs
FROM Files
WHERE MD5Hash IS NOT NULL AND MD5Hash NOT LIKE 'ERROR%'
GROUP BY MD5Hash HAVING COUNT(*) > 1;
"@
    return Invoke-SqliteQuery -DataSource $DbPath -Query $q
}

function Search-FullText {
    param([string]$DbPath, [string]$Query)
    $q = @"
SELECT f.FileID, f.OriginalName, f.CurrentPath,
       snippet(FileContent_FTS,1,'>>','<<','...',20) AS Snippet
FROM FileContent_FTS fts
JOIN Files f ON f.FileID = fts.FileID
WHERE fts.ExtractedText MATCH @q
ORDER BY rank;
"@
    return Invoke-SqliteQuery -DataSource $DbPath -Query $q -SqlParameters @{q=$Query}
}
