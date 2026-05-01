#Requires -Version 5.1
<#
.SYNOPSIS
    Extracts text from DOCX, PPTX, XLSX, PDF (text layer), EML, MSG.
    For scanned PDFs and images, falls back to OcrEngine.ps1.
#>

. "$PSScriptRoot\OcrEngine.ps1"

function Get-TextFromFile {
    param(
        [System.IO.FileInfo]$File,
        [string]$iTextSharpDll,
        [string]$TesseractExe,
        [string]$GsExe,
        [string]$OcrTempDir,
        [int]$MaxOcrPages = 10
    )

    $result = [PSCustomObject]@{
        Text       = ""
        Method     = "none"
        Confidence = 100
        Language   = "unknown"
        WordCount  = 0
    }

    $ext = $File.Extension.ToLower().TrimStart(".")

    try {
        switch ($ext) {
            { $_ -in "docx","odt" }  { $result = Extract-Docx  $File.FullName }
            { $_ -in "pptx" }        { $result = Extract-Pptx  $File.FullName }
            { $_ -in "xlsx","xls" }  { $result = Extract-Xlsx  $File.FullName }
            { $_ -in "txt","rtf","csv","md" } {
                $result.Text   = [System.IO.File]::ReadAllText($File.FullName, [System.Text.Encoding]::UTF8)
                $result.Method = "plain-text"
            }
            { $_ -eq "pdf" } {
                $result = Extract-Pdf $File.FullName $iTextSharpDll $TesseractExe $GsExe $OcrTempDir $MaxOcrPages
            }
            { $_ -in "jpg","jpeg","png","tiff","tif","bmp","gif" } {
                $ocr = Invoke-Ocr -ImagePath $File.FullName -TesseractExe $TesseractExe -OcrTempDir $OcrTempDir
                $result.Text       = $ocr.Text
                $result.Method     = "image-ocr"
                $result.Confidence = $ocr.Confidence
            }
            { $_ -eq "eml" } { $result = Extract-Eml $File.FullName }
            { $_ -eq "msg" } { $result = Extract-Msg $File.FullName }
            default { $result.Method = "none" }
        }
    } catch {
        $result.Method     = "error"
        $result.Text       = ""
        $result.Confidence = 0
    }

    # Post-process
    if ($result.Text) {
        $result.WordCount = ($result.Text -split '\s+' | Where-Object { $_ }).Count
        $result.Language  = Detect-Language $result.Text
    }

    return $result
}

function Extract-Docx {
    param([string]$FilePath)
    $r = [PSCustomObject]@{ Text=""; Method="docx-xml"; Confidence=100; Language=""; WordCount=0 }
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $zip = [System.IO.Compression.ZipFile]::OpenRead($FilePath)
    try {
        $entry = $zip.Entries | Where-Object { $_.FullName -eq "word/document.xml" }
        if ($entry) {
            $stream = $entry.Open()
            $reader = New-Object System.IO.StreamReader($stream, [System.Text.Encoding]::UTF8)
            $xml    = [xml]$reader.ReadToEnd()
            $reader.Dispose(); $stream.Dispose()
            $r.Text = ($xml.SelectNodes("//*[local-name()='t']") | ForEach-Object { $_.InnerText }) -join " "
        }
    } finally { $zip.Dispose() }
    return $r
}

function Extract-Pptx {
    param([string]$FilePath)
    $r = [PSCustomObject]@{ Text=""; Method="pptx-xml"; Confidence=100; Language=""; WordCount=0 }
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $zip = [System.IO.Compression.ZipFile]::OpenRead($FilePath)
    try {
        $slides = $zip.Entries | Where-Object { $_.FullName -like "ppt/slides/slide*.xml" }
        $texts  = foreach ($slide in $slides) {
            $stream = $slide.Open()
            $reader = New-Object System.IO.StreamReader($stream, [System.Text.Encoding]::UTF8)
            $xml    = [xml]$reader.ReadToEnd()
            $reader.Dispose(); $stream.Dispose()
            ($xml.SelectNodes("//*[local-name()='t']") | ForEach-Object { $_.InnerText }) -join " "
        }
        $r.Text = $texts -join "`n"
    } finally { $zip.Dispose() }
    return $r
}

function Extract-Xlsx {
    param([string]$FilePath)
    $r = [PSCustomObject]@{ Text=""; Method="xlsx-xml"; Confidence=100; Language=""; WordCount=0 }
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $zip = [System.IO.Compression.ZipFile]::OpenRead($FilePath)
    try {
        $ssEntry = $zip.Entries | Where-Object { $_.FullName -eq "xl/sharedStrings.xml" }
        if ($ssEntry) {
            $stream = $ssEntry.Open()
            $reader = New-Object System.IO.StreamReader($stream, [System.Text.Encoding]::UTF8)
            $xml    = [xml]$reader.ReadToEnd()
            $reader.Dispose(); $stream.Dispose()
            $r.Text = ($xml.SelectNodes("//*[local-name()='t']") | ForEach-Object { $_.InnerText }) -join " "
        }
    } finally { $zip.Dispose() }
    return $r
}

function Extract-Pdf {
    param([string]$FilePath, [string]$DllPath, [string]$TesseractExe,
          [string]$GsExe, [string]$OcrTempDir, [int]$MaxPages)

    $r = [PSCustomObject]@{ Text=""; Method="pdf-text"; Confidence=100; Language=""; WordCount=0 }

    # Try text layer first (iTextSharp)
    if (Test-Path $DllPath) {
        try {
            Add-Type -Path $DllPath
            $reader = New-Object iTextSharp.text.pdf.PdfReader($FilePath)
            $sb     = New-Object System.Text.StringBuilder
            $pages  = [Math]::Min($reader.NumberOfPages, $MaxPages)
            for ($i = 1; $i -le $pages; $i++) {
                $strategy = New-Object iTextSharp.text.pdf.parser.LocationTextExtractionStrategy
                $text     = [iTextSharp.text.pdf.parser.PdfTextExtractor]::GetTextFromPage($reader, $i, $strategy)
                [void]$sb.AppendLine($text)
            }
            $reader.Close()
            $r.Text = $sb.ToString().Trim()
        } catch { $r.Text = "" }
    }

    # If very little text extracted → scanned PDF, use OCR
    if ($r.Text.Length -lt 50 -and (Test-Path $GsExe) -and (Test-Path $TesseractExe)) {
        $r.Method = "pdf-ocr"
        $allText  = @()
        $confVals = @()
        for ($page = 1; $page -le $MaxPages; $page++) {
            $imgPath = ConvertPdfPageToImage -PdfPath $FilePath -PageNumber $page -GsExe $GsExe -OcrTempDir $OcrTempDir
            if (-not (Test-Path $imgPath)) { break }
            $ocr = Invoke-Ocr -ImagePath $imgPath -TesseractExe $TesseractExe -OcrTempDir $OcrTempDir
            Remove-Item $imgPath -ErrorAction SilentlyContinue
            if ($ocr.Text) { $allText += $ocr.Text; $confVals += $ocr.Confidence }
        }
        $r.Text       = $allText -join "`n"
        $r.Confidence = if ($confVals) { [int](($confVals | Measure-Object -Average).Average) } else { 0 }
    }

    return $r
}

function Extract-Eml {
    param([string]$FilePath)
    $r = [PSCustomObject]@{ Text=""; Method="eml"; Confidence=100; Language=""; WordCount=0 }
    $raw   = [System.IO.File]::ReadAllText($FilePath, [System.Text.Encoding]::UTF8)
    $lines = $raw -split "`r?`n"
    $subject = ($lines | Where-Object { $_ -match "^Subject:" } | Select-Object -First 1) -replace "^Subject:\s*",""
    $body    = ($raw -split "`r?`n`r?`n",2)[1]
    $r.Text  = "$subject`n$body"
    return $r
}

function Extract-Msg {
    param([string]$FilePath)
    $r = [PSCustomObject]@{ Text=""; Method="msg"; Confidence=100; Language=""; WordCount=0 }
    try {
        $outlook = New-Object -ComObject Outlook.Application -ErrorAction Stop
        $ns      = $outlook.GetNamespace("MAPI")
        $mail    = $ns.OpenSharedItem($FilePath)
        $r.Text  = "$($mail.Subject)`n$($mail.SenderName)`n$($mail.Body)"
        $mail.Close(0)
    } catch {
        # Fallback: raw string scan for readable text
        $bytes = [System.IO.File]::ReadAllBytes($FilePath)
        $raw   = [System.Text.Encoding]::Unicode.GetString($bytes)
        $r.Text = ($raw -replace '[^ -~֐-׿‏‎]+', ' ').Trim()
        $r.Method = "msg-raw"
    }
    return $r
}

function Detect-Language {
    param([string]$Text)
    if (-not $Text) { return "unknown" }
    $heChars = ($Text -replace '[^֐-׿]','').Length
    $enChars = ($Text -replace '[^a-zA-Z]','').Length
    if ($heChars -gt $enChars * 2) { return "he" }
    if ($enChars -gt $heChars * 2) { return "en" }
    return "mixed"
}
