#Requires -Version 5.1
<#
.SYNOPSIS
    Builds a .docx file from plain Hebrew text using Open XML (ZIP structure).
    No external tools required — pure PowerShell + System.IO.Compression.
    Compatible with Microsoft Word 2010+ and LibreOffice.

.EXAMPLE
    New-DocxFile -Text $myDraft -OutputPath "C:\Reports\Drafts\brief.docx" -Title "כתב תביעה"
#>

Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem

function New-DocxFile {
    <#
    .SYNOPSIS
        Creates a .docx file from a plain-text string. Handles Hebrew RTL,
        paragraphs (split on newlines), bold headings (lines ending with ':'),
        and numbered paragraphs (lines starting with digits).
    .PARAMETER Text     Full document text (Hebrew/English mixed OK).
    .PARAMETER OutputPath  Destination .docx path.
    .PARAMETER Title    Document title (shown as first heading).
    .PARAMETER Author   Author name embedded in document metadata.
    #>
    param(
        [Parameter(Mandatory)][string]$Text,
        [Parameter(Mandatory)][string]$OutputPath,
        [string]$Title  = "",
        [string]$Author = "Legal-OS"
    )

    # ── Build XML parts ────────────────────────────────────────────────────────
    $docXml   = _Build-DocumentXml  -Text $Text -Title $Title
    $relXml   = _Build-RelationshipsXml
    $coreXml  = _Build-CorePropsXml -Title $Title -Author $Author
    $appXml   = _Build-AppPropsXml
    $contXml  = _Build-ContentTypesXml
    $wordRels = _Build-WordRelsXml

    # ── Write ZIP (.docx) ──────────────────────────────────────────────────────
    $tmpPath = [System.IO.Path]::GetTempFileName() + ".docx"
    try {
        $zip = [System.IO.Compression.ZipFile]::Open($tmpPath,
               [System.IO.Compression.ZipArchiveMode]::Create)

        _AddEntry $zip "[Content_Types].xml"               $contXml
        _AddEntry $zip "_rels/.rels"                       $relXml
        _AddEntry $zip "word/document.xml"                 $docXml
        _AddEntry $zip "word/_rels/document.xml.rels"      $wordRels
        _AddEntry $zip "docProps/core.xml"                 $coreXml
        _AddEntry $zip "docProps/app.xml"                  $appXml

        $zip.Dispose()

        # Move to final path
        $dir = Split-Path $OutputPath
        if ($dir -and -not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
        if (Test-Path $OutputPath) { Remove-Item $OutputPath -Force }
        Move-Item $tmpPath $OutputPath
        return $true
    } catch {
        if ($zip) { try { $zip.Dispose() } catch {} }
        if (Test-Path $tmpPath) { Remove-Item $tmpPath -Force -ErrorAction SilentlyContinue }
        Write-Warning "DocxBuilder: $_"
        return $false
    }
}

# ── Internal helpers ──────────────────────────────────────────────────────────

function _AddEntry {
    param($Zip, [string]$Name, [string]$Content)
    $entry  = $Zip.CreateEntry($Name)
    $stream = $entry.Open()
    $bytes  = [System.Text.Encoding]::UTF8.GetBytes($Content)
    $stream.Write($bytes, 0, $bytes.Length)
    $stream.Close()
}

function _XmlEsc {
    param([string]$s)
    return $s `
        -replace '&',  '&amp;' `
        -replace '<',  '&lt;'  `
        -replace '>',  '&gt;'  `
        -replace '"',  '&quot;'
}

function _Build-DocumentXml {
    param([string]$Text, [string]$Title)

    # Split on newlines; classify each line
    $lines = $Text -split "`r?`n"

    $bodyParts = [System.Text.StringBuilder]::new()

    # Title paragraph
    if ($Title) {
        $t = _XmlEsc $Title
        [void]$bodyParts.Append(@"
<w:p>
  <w:pPr><w:jc w:val="center"/><w:bidi/><w:pStyle w:val="Heading1"/></w:pPr>
  <w:r><w:rPr><w:b/><w:sz w:val="32"/><w:rtl/></w:rPr><w:t xml:space="preserve">$t</w:t></w:r>
</w:p>
"@)
    }

    foreach ($line in $lines) {
        $trimmed = $line.Trim()

        if ($trimmed -eq '') {
            # Empty line → spacing paragraph
            [void]$bodyParts.Append('<w:p><w:pPr><w:spacing w:after="0"/></w:pPr></w:p>')
            continue
        }

        $escaped = _XmlEsc $trimmed

        # Detect heading: line ends with ':' or is ALL-CAPS Hebrew/English header
        $isHeading = $trimmed.EndsWith(':') -or ($trimmed -cmatch '^[A-Zא-ת\s]{4,}$')
        # Detect numbered paragraph
        $isNumbered = $trimmed -match '^\d+[\.\)]\s'

        if ($isHeading) {
            [void]$bodyParts.Append(@"
<w:p>
  <w:pPr><w:bidi/><w:jc w:val="right"/><w:spacing w:before="120" w:after="60"/></w:pPr>
  <w:r><w:rPr><w:b/><w:rtl/></w:rPr><w:t xml:space="preserve">$escaped</w:t></w:r>
</w:p>
"@)
        } elseif ($isNumbered) {
            [void]$bodyParts.Append(@"
<w:p>
  <w:pPr><w:bidi/><w:jc w:val="right"/><w:ind w:right="360"/></w:pPr>
  <w:r><w:rPr><w:rtl/></w:rPr><w:t xml:space="preserve">$escaped</w:t></w:r>
</w:p>
"@)
        } else {
            [void]$bodyParts.Append(@"
<w:p>
  <w:pPr><w:bidi/><w:jc w:val="right"/><w:spacing w:after="100"/></w:pPr>
  <w:r><w:rPr><w:rtl/></w:rPr><w:t xml:space="preserve">$escaped</w:t></w:r>
</w:p>
"@)
        }
    }

    return @"
<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<w:document
  xmlns:wpc="http://schemas.microsoft.com/office/word/2010/wordprocessingCanvas"
  xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"
  xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">
<w:body>
<w:sectPr>
  <w:bidi/>
  <w:pgSz w:w="11906" w:h="16838"/>
  <w:pgMar w:top="1134" w:right="1134" w:bottom="1134" w:left="1134"/>
  <w:textDirection w:val="btLr"/>
</w:sectPr>
$($bodyParts.ToString())
</w:body>
</w:document>
"@
}

function _Build-RelationshipsXml {
    return @'
<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
  <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/>
  <Relationship Id="rId2" Type="http://schemas.openxmlformats.org/package/2006/relationships/metadata/core-properties" Target="docProps/core.xml"/>
  <Relationship Id="rId3" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/extended-properties" Target="docProps/app.xml"/>
</Relationships>
'@
}

function _Build-WordRelsXml {
    return @'
<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
</Relationships>
'@
}

function _Build-CorePropsXml {
    param([string]$Title, [string]$Author)
    $t = _XmlEsc $Title
    $a = _XmlEsc $Author
    $d = (Get-Date -Format "yyyy-MM-ddTHH:mm:ssZ")
    return @"
<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<cp:coreProperties xmlns:cp="http://schemas.openxmlformats.org/package/2006/metadata/core-properties"
  xmlns:dc="http://purl.org/dc/elements/1.1/"
  xmlns:dcterms="http://purl.org/dc/terms/"
  xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
  <dc:title>$t</dc:title>
  <dc:creator>$a</dc:creator>
  <dcterms:created xsi:type="dcterms:W3CDTF">$d</dcterms:created>
  <dcterms:modified xsi:type="dcterms:W3CDTF">$d</dcterms:modified>
</cp:coreProperties>
"@
}

function _Build-AppPropsXml {
    return @'
<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<Properties xmlns="http://schemas.openxmlformats.org/officeDocument/2006/extended-properties">
  <Application>Legal-OS v3.0</Application>
</Properties>
'@
}

function _Build-ContentTypesXml {
    return @'
<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
  <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>
  <Default Extension="xml"  ContentType="application/xml"/>
  <Override PartName="/word/document.xml"
    ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/>
  <Override PartName="/docProps/core.xml"
    ContentType="application/vnd.openxmlformats-package.core-properties+xml"/>
  <Override PartName="/docProps/app.xml"
    ContentType="application/vnd.openxmlformats-officedocument.extended-properties+xml"/>
</Types>
'@
}
