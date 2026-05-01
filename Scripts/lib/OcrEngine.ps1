#Requires -Version 5.1
<#
.SYNOPSIS
    Tesseract OCR wrapper with dual-language mode, auto-rotation,
    grayscale pre-processing, and post-OCR correction.
    Dual-pass: runs Hebrew-only first, then Hebrew+English; merges best segments.
#>

. "$PSScriptRoot\TextNormalization.ps1"

function Invoke-Ocr {
    <#
    .SYNOPSIS
        OCR a single image file. Returns text + average confidence.
        Uses dual-pass (heb → heb+eng) and applies OCR correction dictionary.
    #>
    param(
        [string]$ImagePath,
        [string]$TesseractExe,
        [string]$OcrTempDir,
        [switch]$SkipDualPass   # set for speed when caller knows language
    )

    $result = [PSCustomObject]@{
        Text       = ""
        Confidence = 0
        Method     = "image-ocr"
        Error      = $null
    }

    if (-not (Test-Path $TesseractExe)) {
        $result.Error = "Tesseract not found: $TesseractExe"
        return $result
    }
    if (-not (Test-Path $ImagePath)) {
        $result.Error = "Image not found: $ImagePath"
        return $result
    }

    try {
        $base         = [System.IO.Path]::GetFileNameWithoutExtension($ImagePath)
        $processedImg = Join-Path $OcrTempDir "$base`_proc.png"

        # ── Pre-process: grayscale + 300 DPI ──────────────────────────────────
        Add-Type -AssemblyName System.Drawing
        $src = [System.Drawing.Bitmap]::FromFile($ImagePath)
        $src.SetResolution(300, 300)
        $gray = New-Object System.Drawing.Bitmap($src.Width, $src.Height)
        $gray.SetResolution(300, 300)
        $g   = [System.Drawing.Graphics]::FromImage($gray)
        # Luminance-based grayscale matrix
        $cm  = [System.Drawing.Imaging.ColorMatrix]::new(@(
            [float[]]@(0.299f, 0.299f, 0.299f, 0f, 0f),
            [float[]]@(0.587f, 0.587f, 0.587f, 0f, 0f),
            [float[]]@(0.114f, 0.114f, 0.114f, 0f, 0f),
            [float[]]@(0f,     0f,     0f,     1f, 0f),
            [float[]]@(0f,     0f,     0f,     0f, 1f)
        ))
        $ia  = New-Object System.Drawing.Imaging.ImageAttributes
        $ia.SetColorMatrix($cm)
        $rect = [System.Drawing.Rectangle]::new(0, 0, $src.Width, $src.Height)
        $g.DrawImage($src, $rect, 0, 0, $src.Width, $src.Height,
            [System.Drawing.GraphicsUnit]::Pixel, $ia)
        $gray.Save($processedImg, [System.Drawing.Imaging.ImageFormat]::Png)
        $g.Dispose(); $gray.Dispose(); $src.Dispose()

        # ── Auto-rotation via OSD ──────────────────────────────────────────────
        $osdBase = Join-Path $OcrTempDir "$base`_osd"
        & $TesseractExe $processedImg $osdBase --psm 0 -l osd 2>$null
        $osdTxt  = if (Test-Path "$osdBase.txt") {
            Get-Content "$osdBase.txt" -Encoding UTF8 -Raw
        } else { "" }
        Remove-Item "$osdBase.txt" -ErrorAction SilentlyContinue

        $rotAngle = 0
        if ($osdTxt -match "Rotate:\s*(\d+)") { $rotAngle = [int]$Matches[1] }

        if ($rotAngle -in @(90, 180, 270)) {
            $rotBmp = [System.Drawing.Bitmap]::FromFile($processedImg)
            switch ($rotAngle) {
                90  { $rotBmp.RotateFlip([System.Drawing.RotateFlipType]::Rotate90FlipNone) }
                180 { $rotBmp.RotateFlip([System.Drawing.RotateFlipType]::Rotate180FlipNone) }
                270 { $rotBmp.RotateFlip([System.Drawing.RotateFlipType]::Rotate270FlipNone) }
            }
            $rotBmp.Save($processedImg, [System.Drawing.Imaging.ImageFormat]::Png)
            $rotBmp.Dispose()
        }

        # ── Pass 1: Hebrew only ────────────────────────────────────────────────
        $pass1 = Invoke-TesseractPass -Image $processedImg -Lang "heb" `
                    -TesseractExe $TesseractExe -TempDir $OcrTempDir -Suffix "p1"

        if ($SkipDualPass -or $pass1.Confidence -ge 80) {
            # High confidence on Hebrew alone — no need for second pass
            $result.Text       = $pass1.Text
            $result.Confidence = $pass1.Confidence
        } else {
            # ── Pass 2: Hebrew + English ───────────────────────────────────────
            $pass2 = Invoke-TesseractPass -Image $processedImg -Lang "heb+eng" `
                        -TesseractExe $TesseractExe -TempDir $OcrTempDir -Suffix "p2"

            # Merge: use whichever pass produced higher confidence per-word
            $merged = Merge-OcrPasses $pass1 $pass2
            $result.Text       = $merged.Text
            $result.Confidence = $merged.Confidence
        }

        # Apply OCR correction dictionary, then normalize
        $result.Text = Invoke-OcrCorrection $result.Text
        $result.Text = Normalize-HebrewText $result.Text

    } catch {
        $result.Error      = $_.Exception.Message
        $result.Confidence = 0
    } finally {
        Remove-Item $processedImg -ErrorAction SilentlyContinue
    }

    return $result
}

function Invoke-TesseractPass {
    param(
        [string]$Image,
        [string]$Lang,
        [string]$TesseractExe,
        [string]$TempDir,
        [string]$Suffix
    )
    $base    = [System.IO.Path]::GetFileNameWithoutExtension($Image)
    $outBase = Join-Path $TempDir "$base`_$Suffix"

    & $TesseractExe $Image $outBase -l $Lang --oem 1 --psm 3 tsv 2>$null

    $tsvPath = "$outBase.tsv"
    $text    = ""; $conf = 0

    if (Test-Path $tsvPath) {
        $rows  = Import-Csv -Path $tsvPath -Delimiter "`t" -Encoding UTF8
        $words = $rows | Where-Object { $_.conf -ne "-1" -and $_.text -match '\S' }
        if ($words) {
            $text      = ($words | ForEach-Object { $_.text }) -join " "
            $confVals  = $words | ForEach-Object { [int]$_.conf } | Where-Object { $_ -ge 0 }
            $conf      = if ($confVals) {
                [int](($confVals | Measure-Object -Average).Average)
            } else { 0 }
        }
        Remove-Item $tsvPath -ErrorAction SilentlyContinue
    }

    return [PSCustomObject]@{ Text = $text; Confidence = $conf }
}

function Merge-OcrPasses {
    <#
    .SYNOPSIS
        Simple merge: if pass2 confidence is meaningfully higher, use pass2 text;
        otherwise use pass1. A word-level merge would need alignment — this is
        a pragmatic document-level approach that works well for mixed he/en docs.
    #>
    param($Pass1, $Pass2)

    if ($Pass2.Confidence -gt ($Pass1.Confidence + 5)) {
        return $Pass2
    }
    # Blend: insert English words from pass2 that are absent in pass1
    $p1Words = $Pass1.Text -split '\s+'
    $p2Words = $Pass2.Text -split '\s+'
    $enOnly  = $p2Words | Where-Object { $_ -match '^[a-zA-Z]{2,}$' -and $_ -notin $p1Words }
    $merged  = ($Pass1.Text, ($enOnly -join " ")) -join " "
    $avgConf = [int](($Pass1.Confidence + $Pass2.Confidence) / 2)
    return [PSCustomObject]@{ Text = $merged.Trim(); Confidence = $avgConf }
}

function ConvertPdfPageToImage {
    <#
    .SYNOPSIS
        Renders one page of a PDF to a PNG image using GhostScript.
    #>
    param(
        [string]$PdfPath,
        [int]$PageNumber = 1,
        [string]$GsExe,
        [string]$OcrTempDir
    )
    $outPath = Join-Path $OcrTempDir "page_$([System.IO.Path]::GetFileNameWithoutExtension($PdfPath))_$PageNumber.png"
    $gsArgs  = @(
        "-dNOPAUSE", "-dBATCH", "-dSAFER",
        "-sDEVICE=pnggray",
        "-r300",
        "-dFirstPage=$PageNumber", "-dLastPage=$PageNumber",
        "-sOutputFile=$outPath",
        $PdfPath
    )
    & $GsExe @gsArgs 2>$null
    return $outPath
}

function Get-PdfPageCount {
    param([string]$PdfPath, [string]$GsExe)
    $out = & $GsExe -dNOPAUSE -dBATCH -dSAFER -sDEVICE=nullpage $PdfPath 2>&1
    if ($out -match 'Processing pages \d+ through (\d+)') { return [int]$Matches[1] }
    return 1
}
