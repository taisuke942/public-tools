param(
    [string]$Root = "H:\VB6\Ukanri"
)

$ErrorActionPreference = "Stop"

if (-not (Test-Path -LiteralPath $Root)) {
    $Root = Split-Path -Parent $MyInvocation.MyCommand.Path
}

$timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
$OutDir = Join-Path $Root "_vb6_analysis_$timestamp"
New-Item -ItemType Directory -Force -Path $OutDir | Out-Null

$targetExts = @(".bas", ".mdb", ".exe", ".frm", ".cls", ".ctl", ".vbp")

function Write-Utf8BomLines($Path, $Lines) {
    $enc = New-Object System.Text.UTF8Encoding($true)
    [System.IO.File]::WriteAllLines($Path, $Lines, $enc)
}

function Safe-Tsv($Value) {
    if ($null -eq $Value) { return "" }
    $s = [string]$Value
    $s = $s -replace "`t", " "
    $s = $s -replace "`r", " "
    $s = $s -replace "`n", " "
    return $s
}

function To-TsvLine($Fields) {
    return (($Fields | ForEach-Object { Safe-Tsv $_ }) -join "`t")
}

function Get-RelPath($Base, $Path) {
    $baseFull = (Resolve-Path -LiteralPath $Base).Path.TrimEnd("\") + "\"
    $pathFull = (Resolve-Path -LiteralPath $Path).Path
    if ($pathFull.StartsWith($baseFull, [System.StringComparison]::OrdinalIgnoreCase)) {
        return $pathFull.Substring($baseFull.Length)
    }
    return $pathFull
}

function Get-TextLines($Path) {
    $bytes = [System.IO.File]::ReadAllBytes($Path)

    if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) {
        $enc = New-Object System.Text.UTF8Encoding($true)
    }
    elseif ($bytes.Length -ge 2 -and $bytes[0] -eq 0xFF -and $bytes[1] -eq 0xFE) {
        $enc = [System.Text.Encoding]::Unicode
    }
    elseif ($bytes.Length -ge 2 -and $bytes[0] -eq 0xFE -and $bytes[1] -eq 0xFF) {
        $enc = [System.Text.Encoding]::BigEndianUnicode
    }
    else {
        $enc = [System.Text.Encoding]::GetEncoding(932)
    }

    $text = $enc.GetString($bytes)
    if ($text.Length -gt 0 -and $text[0] -eq [char]0xFEFF) {
        $text = $text.Substring(1)
    }

    return $text -split "`r`n|`n|`r"
}

function Remove-VBComment($Line) {
    if ($null -eq $Line) { return "" }

    $trim = $Line.TrimStart()
    if ($trim -match "^(?i)Rem\b") {
        return ""
    }

    $inString = $false
    for ($i = 0; $i -lt $Line.Length; $i++) {
        $ch = $Line[$i]

        if ($ch -eq '"') {
            if ($inString -and $i + 1 -lt $Line.Length -and $Line[$i + 1] -eq '"') {
                $i++
            }
            else {
                $inString = -not $inString
            }
        }
        elseif ($ch -eq [char]39 -and -not $inString) {
            return $Line.Substring(0, $i)
        }
    }

    return $Line
}

function Split-VBList($Text) {
    $items = New-Object System.Collections.Generic.List[string]
    $sb = New-Object System.Text.StringBuilder
    $depth = 0
    $inString = $false

    for ($i = 0; $i -lt $Text.Length; $i++) {
        $ch = $Text[$i]

        if ($ch -eq '"') {
            [void]$sb.Append($ch)
            if ($inString -and $i + 1 -lt $Text.Length -and $Text[$i + 1] -eq '"') {
                $i++
                [void]$sb.Append($Text[$i])
            }
            else {
                $inString = -not $inString
            }
            continue
        }

        if (-not $inString) {
            if ($ch -eq "(") { $depth++ }
            elseif ($ch -eq ")" -and $depth -gt 0) { $depth-- }
            elseif ($ch -eq "," -and $depth -eq 0) {
                $items.Add($sb.ToString().Trim())
                [void]$sb.Clear()
                continue
            }
        }

        [void]$sb.Append($ch)
    }

    if ($sb.Length -gt 0) {
        $items.Add($sb.ToString().Trim())
    }

    return $items
}

function Get-VBLogicalLines($RawLines) {
    $result = New-Object System.Collections.Generic.List[object]
    $buf = ""
    $startLine = 1

    for ($i = 0; $i -lt $RawLines.Count; $i++) {
        $lineNo = $i + 1
        $line = $RawLines[$i]
        $noComment = Remove-VBComment $line
        $trimEnd = $noComment.TrimEnd()

        if ($buf -eq "") {
            $startLine = $lineNo
        }

        if ($trimEnd -match "\s_$") {
            $part = $trimEnd -replace "\s_$", " "
            $buf += $part + " "
        }
        else {
            $buf += $line
            $result.Add([pscustomobject]@{
                LineNo = $startLine
                Text   = $buf
            })
            $buf = ""
        }
    }

    if ($buf -ne "") {
        $result.Add([pscustomobject]@{
            LineNo = $startLine
            Text   = $buf
        })
    }

    return $result
}

$ident = "[\p{L}_][\p{L}\p{N}_]*"

function Get-ArgNames($ArgsText) {
    $names = New-Object System.Collections.Generic.List[string]
    if ([string]::IsNullOrWhiteSpace($ArgsText)) {
        return $names
    }

    $inner = $ArgsText.Trim()
    if ($inner.StartsWith("(") -and $inner.EndsWith(")") -and $inner.Length -ge 2) {
        $inner = $inner.Substring(1, $inner.Length - 2)
    }

    foreach ($part in Split-VBList $inner) {
        $p = $part.Trim()
        if ($p -eq "") { continue }

        $p = $p -replace "(?i)\bOptional\b", ""
        $p = $p -replace "(?i)\bByVal\b", ""
        $p = $p -replace "(?i)\bByRef\b", ""
        $p = $p -replace "(?i)\bParamArray\b", ""
        $p = $p.Trim()

        if ($p -match "^\s*($script:ident)\b") {
            $names.Add($Matches[1])
        }
    }

    return $names
}

function Get-DeclNames($Text) {
    $names = New-Object System.Collections.Generic.List[string]

    foreach ($part in Split-VBList $Text) {
        $p = $part.Trim()
        $p = $p -replace "^(?i)WithEvents\s+", ""
        $p = $p.Trim()

        if ($p -match "^\s*($script:ident)\b") {
            $names.Add($Matches[1])
        }
    }

    return $names
}

function Count-SymbolUse($Text, $Name) {
    if ([string]::IsNullOrWhiteSpace($Name)) { return 0 }
    $escaped = [System.Text.RegularExpressions.Regex]::Escape($Name)
    $pattern = "(?i)(?<![\p{L}\p{N}_])$escaped(?![\p{L}\p{N}_])"
    return [System.Text.RegularExpressions.Regex]::Matches($Text, $pattern).Count
}

$files = Get-ChildItem -LiteralPath $Root -Recurse -File -ErrorAction SilentlyContinue |
    Where-Object { $targetExts -contains $_.Extension.ToLowerInvariant() } |
    Sort-Object FullName

$fileLines = New-Object System.Collections.Generic.List[string]
$fileLines.Add((To-TsvLine @("Extension","FileName","Folder","RelativePath","FullPath","SizeKB","LastWriteTime")))

foreach ($f in $files) {
    $fileLines.Add((To-TsvLine @(
        $f.Extension.TrimStart(".").ToLowerInvariant(),
        $f.Name,
        $f.DirectoryName,
        (Get-RelPath $Root $f.FullName),
        $f.FullName,
        [math]::Round($f.Length / 1KB, 2),
        $f.LastWriteTime.ToString("yyyy-MM-dd HH:mm:ss")
    )))
}

Write-Utf8BomLines (Join-Path $OutDir "01_files.tsv") $fileLines

$vbExts = @(".bas", ".frm", ".cls", ".ctl")
$vbFiles = $files | Where-Object { $vbExts -contains $_.Extension.ToLowerInvariant() }

$memberLines = New-Object System.Collections.Generic.List[string]
$usageLines = New-Object System.Collections.Generic.List[string]
$callLines = New-Object System.Collections.Generic.List[string]

$memberLines.Add((To-TsvLine @("FilePath","FileName","FileType","Kind","Scope","Name","Procedure","Arguments","LineNo","Declaration")))
$usageLines.Add((To-TsvLine @("FilePath","FileName","SymbolKind","SymbolName","DeclaredScope","DeclaredProcedure","UsedInProcedure","UseCount","IsArgument","DeclarationLine")))
$callLines.Add((To-TsvLine @("FilePath","FileName","Procedure","LineNo","CalledText","SourceLine")))

foreach ($f in $vbFiles) {
    try {
        $raw = Get-TextLines $f.FullName
        $logicalLines = Get-VBLogicalLines $raw
    }
    catch {
        continue
    }

    $procedures = New-Object System.Collections.Generic.List[object]
    $symbols = New-Object System.Collections.Generic.List[object]
    $current = $null

    foreach ($ll in $logicalLines) {
        $clean = (Remove-VBComment $ll.Text).Trim()
        if ($clean -eq "") { continue }

        if ($null -ne $current -and $clean -match "^(?i)End\s+(Sub|Function|Property)\b") {
            $current.EndLine = $ll.LineNo
            $current = $null
            continue
        }

        $procPattern = "(?i)^\s*(?:(Public|Private|Friend|Static)\s+)?(Sub|Function)\s+($ident)\s*(\([^\)]*\))?"
        $propPattern = "(?i)^\s*(?:(Public|Private|Friend|Static)\s+)?Property\s+(Get|Let|Set)\s+($ident)\s*(\([^\)]*\))?"
        $declarePattern = "(?i)^\s*(?:(Public|Private)\s+)?Declare\s+(Sub|Function)\s+($ident)\b"

        if ($clean -match $declarePattern) {
            $scope = $Matches[1]
            if ($scope -eq "") { $scope = "(default)" }
            $kind = "Declare " + $Matches[2]
            $name = $Matches[3]

            $memberLines.Add((To-TsvLine @(
                $f.FullName, $f.Name, $f.Extension.TrimStart("."),
                $kind, $scope, $name, "(Module)", "", $ll.LineNo, $clean
            )))
            continue
        }

        if ($clean -match $procPattern) {
            $scope = $Matches[1]
            if ($scope -eq "") { $scope = "(default)" }
            $kind = $Matches[2]
            $name = $Matches[3]
            $argsText = $Matches[4]
            $procName = "$kind $name"

            $current = [pscustomobject]@{
                Name      = $name
                ProcName  = $procName
                Kind      = $kind
                Scope     = $scope
                StartLine = $ll.LineNo
                EndLine   = ""
                BodyLines = New-Object System.Collections.Generic.List[string]
                BodyNos   = New-Object System.Collections.Generic.List[int]
            }
            $procedures.Add($current)

            $memberLines.Add((To-TsvLine @(
                $f.FullName, $f.Name, $f.Extension.TrimStart("."),
                $kind, $scope, $name, $procName, $argsText, $ll.LineNo, $clean
            )))

            foreach ($argName in Get-ArgNames $argsText) {
                $symbols.Add([pscustomobject]@{
                    Kind      = "Argument"
                    Name      = $argName
                    Scope     = "Procedure"
                    Procedure = $procName
                    LineNo    = $ll.LineNo
                    Decl      = $clean
                })

                $memberLines.Add((To-TsvLine @(
                    $f.FullName, $f.Name, $f.Extension.TrimStart("."),
                    "Argument", "Procedure", $argName, $procName, "", $ll.LineNo, $clean
                )))
            }

            continue
        }

        if ($clean -match $propPattern) {
            $scope = $Matches[1]
            if ($scope -eq "") { $scope = "(default)" }
            $kind = "Property " + $Matches[2]
            $name = $Matches[3]
            $argsText = $Matches[4]
            $procName = "$kind $name"

            $current = [pscustomobject]@{
                Name      = $name
                ProcName  = $procName
                Kind      = $kind
                Scope     = $scope
                StartLine = $ll.LineNo
                EndLine   = ""
                BodyLines = New-Object System.Collections.Generic.List[string]
                BodyNos   = New-Object System.Collections.Generic.List[int]
            }
            $procedures.Add($current)

            $memberLines.Add((To-TsvLine @(
                $f.FullName, $f.Name, $f.Extension.TrimStart("."),
                $kind, $scope, $name, $procName, $argsText, $ll.LineNo, $clean
            )))

            foreach ($argName in Get-ArgNames $argsText) {
                $symbols.Add([pscustomobject]@{
                    Kind      = "Argument"
                    Name      = $argName
                    Scope     = "Procedure"
                    Procedure = $procName
                    LineNo    = $ll.LineNo
                    Decl      = $clean
                })

                $memberLines.Add((To-TsvLine @(
                    $f.FullName, $f.Name, $f.Extension.TrimStart("."),
                    "Argument", "Procedure", $argName, $procName, "", $ll.LineNo, $clean
                )))
            }

            continue
        }

        if ($null -ne $current) {
            $current.BodyLines.Add($clean)
            $current.BodyNos.Add($ll.LineNo)

            if ($clean -match "(?i)\bCall\s+($ident(?:\.$ident)*)\b") {
                $callLines.Add((To-TsvLine @(
                    $f.FullName, $f.Name, $current.ProcName, $ll.LineNo, $Matches[1], $clean
                )))
            }
        }

        $constPattern = "(?i)^\s*(?:(Public|Private|Global|Friend|Static)\s+)?Const\s+(.+)$"
        $varPattern = "(?i)^\s*(Public|Private|Global|Dim|Static)\s+(?!Sub\b|Function\b|Property\b|Type\b|Enum\b|Declare\b|Const\b)(.+)$"

        if ($clean -match $constPattern) {
            $scope = $Matches[1]
            if ($scope -eq "") { $scope = "(default)" }
            $context = "(Module)"
            if ($null -ne $current) { $context = $current.ProcName; $scope = "Procedure" }

            foreach ($nm in Get-DeclNames $Matches[2]) {
                $symbols.Add([pscustomobject]@{
                    Kind      = "Const"
                    Name      = $nm
                    Scope     = $scope
                    Procedure = $context
                    LineNo    = $ll.LineNo
                    Decl      = $clean
                })

                $memberLines.Add((To-TsvLine @(
                    $f.FullName, $f.Name, $f.Extension.TrimStart("."),
                    "Const", $scope, $nm, $context, "", $ll.LineNo, $clean
                )))
            }

            continue
        }

        if ($clean -match $varPattern) {
            $declScope = $Matches[1]
            $context = "(Module)"
            if ($null -ne $current) { $context = $current.ProcName; $declScope = "Procedure" }

            foreach ($nm in Get-DeclNames $Matches[2]) {
                $symbols.Add([pscustomobject]@{
                    Kind      = "Variable"
                    Name      = $nm
                    Scope     = $declScope
                    Procedure = $context
                    LineNo    = $ll.LineNo
                    Decl      = $clean
                })

                $memberLines.Add((To-TsvLine @(
                    $f.FullName, $f.Name, $f.Extension.TrimStart("."),
                    "Variable", $declScope, $nm, $context, "", $ll.LineNo, $clean
                )))
            }

            continue
        }
    }

    foreach ($sym in $symbols) {
        $targetProcedures = @()

        if ($sym.Scope -eq "Procedure") {
            $targetProcedures = $procedures | Where-Object { $_.ProcName -eq $sym.Procedure }
        }
        else {
            $targetProcedures = $procedures
        }

        foreach ($p in $targetProcedures) {
            $body = ($p.BodyLines -join "`n")
            $cnt = Count-SymbolUse $body $sym.Name

            if ($cnt -gt 0 -or $sym.Kind -eq "Argument") {
                $usageLines.Add((To-TsvLine @(
                    $f.FullName,
                    $f.Name,
                    $sym.Kind,
                    $sym.Name,
                    $sym.Scope,
                    $sym.Procedure,
                    $p.ProcName,
                    $cnt,
                    ($sym.Kind -eq "Argument"),
                    $sym.LineNo
                )))
            }
        }
    }
}

Write-Utf8BomLines (Join-Path $OutDir "02_vb6_members.tsv") $memberLines
Write-Utf8BomLines (Join-Path $OutDir "03_vb6_symbol_usage.tsv") $usageLines
Write-Utf8BomLines (Join-Path $OutDir "04_vb6_call_lines.tsv") $callLines

$readme = @()
$readme += "Root: $Root"
$readme += "Output: $OutDir"
$readme += ""
$readme += "01_files.tsv: file list for bas, mdb, exe, frm, cls, ctl, vbp"
$readme += "02_vb6_members.tsv: procedures, functions, properties, constants, variables, arguments"
$readme += "03_vb6_symbol_usage.tsv: where variables/constants/arguments are used"
$readme += "04_vb6_call_lines.tsv: explicit Call statements"
$readme += ""
$readme += "Note: This is static text analysis. It is useful for study and investigation, but it is not a full VB6 compiler."
Write-Utf8BomLines (Join-Path $OutDir "README.txt") $readme

Write-Host ""
Write-Host "Done."
Write-Host "Output folder:"
Write-Host $OutDir