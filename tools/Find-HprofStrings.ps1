param(
    [Parameter(Mandatory = $true)]
    [string] $Path,

    [string[]] $Patterns = @("nitrite", "Nitrite", "org.dizitart", "org/dizitart", "MVStore", ".mv.db", ".db", "filePath"),

    [int] $MinLength = 6,

    [int] $MaxResultsPerPattern = 80
)

$ErrorActionPreference = "Stop"

function Test-Match {
    param(
        [string] $Text,
        [string[]] $Patterns
    )

    foreach ($pattern in $Patterns) {
        if ($Text.IndexOf($pattern, [StringComparison]::OrdinalIgnoreCase) -ge 0) {
            return $pattern
        }
    }

    return $null
}

function Add-Candidate {
    param(
        [string] $Text,
        [string] $EncodingName,
        [hashtable] $Seen,
        [hashtable] $Counts,
        [string[]] $Patterns,
        [int] $MaxResultsPerPattern
    )

    if ($Text.Length -lt $MinLength) {
        return
    }

    $match = Test-Match -Text $Text -Patterns $Patterns
    if ($null -eq $match) {
        return
    }

    if (-not $Counts.ContainsKey($match)) {
        $Counts[$match] = 0
    }

    if ($Counts[$match] -ge $MaxResultsPerPattern) {
        return
    }

    $key = "$EncodingName`t$Text"
    if ($Seen.ContainsKey($key)) {
        return
    }

    $Seen[$key] = $true
    $Counts[$match]++
    [pscustomobject]@{
        Pattern = $match
        Encoding = $EncodingName
        Text = $Text
    }
}

function Scan-Ascii {
    param(
        [byte[]] $Bytes,
        [int] $Length,
        [hashtable] $Seen,
        [hashtable] $Counts
    )

    $builder = [System.Text.StringBuilder]::new()
    for ($i = 0; $i -lt $Length; $i++) {
        $b = $Bytes[$i]
        if ($b -ge 32 -and $b -le 126) {
            [void] $builder.Append([char] $b)
        } else {
            if ($builder.Length -ge $MinLength) {
                Add-Candidate -Text $builder.ToString() -EncodingName "ascii" -Seen $Seen -Counts $Counts -Patterns $Patterns -MaxResultsPerPattern $MaxResultsPerPattern
            }
            [void] $builder.Clear()
        }
    }

    if ($builder.Length -ge $MinLength) {
        Add-Candidate -Text $builder.ToString() -EncodingName "ascii" -Seen $Seen -Counts $Counts -Patterns $Patterns -MaxResultsPerPattern $MaxResultsPerPattern
    }
}

function Scan-Utf16Le {
    param(
        [byte[]] $Bytes,
        [int] $Length,
        [hashtable] $Seen,
        [hashtable] $Counts
    )

    $builder = [System.Text.StringBuilder]::new()
    for ($i = 0; $i + 1 -lt $Length; $i += 2) {
        $lo = $Bytes[$i]
        $hi = $Bytes[$i + 1]
        if ($hi -eq 0 -and $lo -ge 32 -and $lo -le 126) {
            [void] $builder.Append([char] $lo)
        } else {
            if ($builder.Length -ge $MinLength) {
                Add-Candidate -Text $builder.ToString() -EncodingName "utf16le" -Seen $Seen -Counts $Counts -Patterns $Patterns -MaxResultsPerPattern $MaxResultsPerPattern
            }
            [void] $builder.Clear()
        }
    }

    if ($builder.Length -ge $MinLength) {
        Add-Candidate -Text $builder.ToString() -EncodingName "utf16le" -Seen $Seen -Counts $Counts -Patterns $Patterns -MaxResultsPerPattern $MaxResultsPerPattern
    }
}

$resolved = Resolve-Path -LiteralPath $Path
$bufferSize = 16MB
$overlap = 4096
$buffer = New-Object byte[] ($bufferSize + $overlap)
$seen = @{}
$counts = @{}

$stream = [System.IO.File]::Open($resolved.Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
try {
    $carryLength = 0
    while ($true) {
        $read = $stream.Read($buffer, $carryLength, $bufferSize)
        if ($read -le 0) {
            break
        }

        $length = $carryLength + $read
        Scan-Ascii -Bytes $buffer -Length $length -Seen $seen -Counts $counts
        Scan-Utf16Le -Bytes $buffer -Length $length -Seen $seen -Counts $counts

        $carryLength = [Math]::Min($overlap, $length)
        [Array]::Copy($buffer, $length - $carryLength, $buffer, 0, $carryLength)
    }
} finally {
    $stream.Dispose()
}
