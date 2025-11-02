# Performance baseline tracker for MediaCopy operations
# Records run metrics to detect regressions and establish baselines

$script:BaselineCSV = $null

function Set-MediaCopyBaselinePath {
    [CmdletBinding()]
    param([Parameter(Mandatory=$true)][string]$Path)
    $script:BaselineCSV = $Path
}

function Write-MediaCopyBaseline {
    <#
    .SYNOPSIS
        Appends a performance baseline entry to the CSV file.
    
    .PARAMETER Metrics
        Hashtable of performance metrics to record.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)][hashtable]$Metrics
    )
    
    if (-not $script:BaselineCSV) { return }
    
    try {
        $record = [PSCustomObject]@{
            Timestamp = (Get-Date).ToUniversalTime().ToString('o')
            TotalFiles = $Metrics.TotalFiles
            ToCopy = $Metrics.ToCopy
            TotalMs = $Metrics.TotalMs
            ScanMs = $Metrics.ScanMs
            GroupMs = $Metrics.GroupMs
            CopyMs = $Metrics.CopyMs
            FilesPerSecond = if ($Metrics.TotalMs -gt 0) { [math]::Round($Metrics.ToCopy / ($Metrics.TotalMs / 1000.0), 2) } else { 0 }
        }
        
        # Create file with headers if it doesn't exist
        if (-not (Test-Path -LiteralPath $script:BaselineCSV)) {
            $record | Export-Csv -LiteralPath $script:BaselineCSV -NoTypeInformation -Encoding UTF8
        } else {
            $record | Export-Csv -LiteralPath $script:BaselineCSV -Append -NoTypeInformation -Encoding UTF8
        }
    }
    catch {
        Write-Verbose "Failed to write baseline record: $_"
    }
}

function Get-MediaCopyBaselineStats {
    <#
    .SYNOPSIS
        Reads and summarizes baseline data (mean, min, max, stddev).
    #>
    [CmdletBinding()]
    param()
    
    if (-not $script:BaselineCSV -or -not (Test-Path -LiteralPath $script:BaselineCSV)) {
        return $null
    }
    
    try {
        $data = Import-Csv -LiteralPath $script:BaselineCSV -Encoding UTF8
        
        if ($data.Count -eq 0) { return $null }
        
        $totalMsList = $data | ForEach-Object { [double]$_.TotalMs }
        $copyMsList = $data | ForEach-Object { [double]$_.CopyMs }
        $fpsList = $data | ForEach-Object { [double]$_.FilesPerSecond }
        
        function Get-Stats($values) {
            $mean = ($values | Measure-Object -Average).Average
            $min = ($values | Measure-Object -Minimum).Minimum
            $max = ($values | Measure-Object -Maximum).Maximum
            $stddev = if ($values.Count -gt 1) {
                $variance = ($values | ForEach-Object { [math]::Pow($_ - $mean, 2) } | Measure-Object -Average).Average
                [math]::Sqrt($variance)
            } else { 0 }
            return @{ Mean=$mean; Min=$min; Max=$max; StdDev=$stddev }
        }
        
        return [PSCustomObject]@{
            Count = $data.Count
            TotalMs = Get-Stats $totalMsList
            CopyMs = Get-Stats $copyMsList
            FilesPerSecond = Get-Stats $fpsList
        }
    }
    catch {
        Write-Verbose "Failed to read baseline stats: $_"
        return $null
    }
}

Export-ModuleMember -Function Set-MediaCopyBaselinePath,Write-MediaCopyBaseline,Get-MediaCopyBaselineStats
