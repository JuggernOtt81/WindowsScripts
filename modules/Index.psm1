# Index module: tracks which files have been copied

# Module-level state
$script:IndexPath = $null
$script:CopiedSourceKeys = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
$script:DestinationContentKeys = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)

function Get-MediaCopyIndexPath {
    param([Parameter(Mandatory=$true)][string]$DestinationRoot,
          [string]$FileName = '.mediacopy_index.csv')
    return (Join-Path -Path $DestinationRoot -ChildPath $FileName)
}

function Get-MediaCopyFileKey {
    param([Parameter(Mandatory=$true)][System.IO.FileInfo]$File)
    # Cheap fingerprint: Name + Length + LastWriteTimeUtc.Ticks
    return ("{0}|{1}|{2}" -f $File.Name.ToLowerInvariant(), $File.Length, $File.LastWriteTimeUtc.Ticks)
}

function Test-MediaCopyIndexIntegrity {
    <#
    .SYNOPSIS
        Validates the integrity of the index CSV file.
    
    .DESCRIPTION
        Checks if the index file can be parsed and contains valid data.
        Reports any corrupted or invalid entries.
    
    .PARAMETER IndexPath
        Path to the index CSV file.
    
    .RETURNS
        PSCustomObject with validation results.
    #>
    param([Parameter(Mandatory=$true)][string]$IndexPath)
    
    try {
        if (-not (Test-Path -LiteralPath $IndexPath)) {
            return [PSCustomObject]@{
                Valid = 0
                Invalid = 0
                IsHealthy = $true
                IsNew = $true
                Error = $null
            }
        }
        
        # Protect reads with the same mutex used by writers to avoid partial reads
        $entries = $null
        $readMutex = $null
        try {
            $readMutex = New-MediaCopyIndexMutex -Path $IndexPath
            if ($readMutex.WaitOne(5000)) {
                $entries = Import-Csv -LiteralPath $IndexPath -Encoding UTF8 -ErrorAction Stop
            } else {
                Write-MediaCopyLog "Timeout waiting for index read lock during integrity test; proceeding without lock" 'WARN'
                $entries = Import-Csv -LiteralPath $IndexPath -Encoding UTF8 -ErrorAction Stop
            }
        }
        finally {
            if ($readMutex) { try { $readMutex.ReleaseMutex() } catch { } $readMutex.Dispose() }
        }
        $valid = 0
        $invalid = 0
        
        foreach ($entry in $entries) {
            # Check required fields
            if ([string]::IsNullOrWhiteSpace($entry.SourceName) -or 
                [string]::IsNullOrWhiteSpace($entry.SourceLength) -or
                [string]::IsNullOrWhiteSpace($entry.SourceMTimeTicks)) {
                $invalid++
            } else {
                # Validate numeric fields
                $length = 0
                $ticks = 0
                if ([int64]::TryParse($entry.SourceLength, [ref]$length) -and 
                    [int64]::TryParse($entry.SourceMTimeTicks, [ref]$ticks)) {
                    $valid++
                } else {
                    $invalid++
                }
            }
        }
        
        return [PSCustomObject]@{
            Valid = $valid
            Invalid = $invalid
            IsHealthy = ($invalid -eq 0)
            IsNew = $false
            Error = $null
        }
    }
    catch {
        return [PSCustomObject]@{
            Valid = 0
            Invalid = -1
            IsHealthy = $false
            IsNew = $false
            Error = $_.Exception.Message
        }
    }
}

function New-MediaCopyIndexMutex {
    param([Parameter(Mandatory=$true)][string]$Path)
    $hashBytes = [System.Security.Cryptography.SHA256]::Create().ComputeHash(
        [System.Text.Encoding]::UTF8.GetBytes($Path.ToLowerInvariant())
    )
    $hashString = [System.BitConverter]::ToString($hashBytes).Replace('-', '').Substring(0, 32)
    return [System.Threading.Mutex]::new($false, "Global\MediaCopyIndex_$hashString")
}

function Initialize-MediaCopyIndex {
    param(
        [Parameter(Mandatory=$true)][string]$DestinationRoot,
        [string]$IndexFileName = '.mediacopy_index.csv'
    )

    $script:IndexPath = Get-MediaCopyIndexPath -DestinationRoot $DestinationRoot -FileName $IndexFileName

    # Ensure destination directory exists
    if (-not (Test-Path -LiteralPath $DestinationRoot)) {
        New-Item -Path $DestinationRoot -ItemType Directory -Force | Out-Null
    }

    # Check index integrity before loading
    $integrity = Test-MediaCopyIndexIntegrity -IndexPath $script:IndexPath
    
    if (-not $integrity.IsHealthy -and -not $integrity.IsNew) {
        if ($integrity.Error) {
            Write-MediaCopyLog "Index file is corrupted: $($integrity.Error). Creating backup and starting fresh." 'WARN'
        } else {
            Write-MediaCopyLog "Index has $($integrity.Invalid) invalid entries out of $($integrity.Valid + $integrity.Invalid). Creating backup." 'WARN'
        }
        
        # Backup corrupted index
        if (Test-Path -LiteralPath $script:IndexPath) {
            $backupPath = "$script:IndexPath.corrupt.$(Get-Date -Format 'yyyyMMddHHmmss').bak"
            Copy-Item -LiteralPath $script:IndexPath -Destination $backupPath -ErrorAction SilentlyContinue
            Write-MediaCopyLog "Corrupted index backed up to: $backupPath" 'INFO'
        }
    }

    # Create new index file if it doesn't exist or is corrupted
    if (-not (Test-Path -LiteralPath $script:IndexPath) -or -not $integrity.IsHealthy) {
        $header = [PSCustomObject]@{
            Timestamp = ''
            SourceFullPath = ''
            SourceName = ''
            SourceLength = ''
            SourceMTimeTicks = ''
            DestFullPath = ''
        }
        $header | Export-Csv -LiteralPath $script:IndexPath -NoTypeInformation -Encoding UTF8
    }

    $loaded = 0
    try {
        # Use Import-Csv for proper CSV parsing with quote handling
        $entries = $null
        $readMutex = $null
        try {
            $readMutex = New-MediaCopyIndexMutex -Path $script:IndexPath
            if ($readMutex.WaitOne(5000)) {
                $entries = Import-Csv -LiteralPath $script:IndexPath -Encoding UTF8 -ErrorAction Stop
            } else {
                Write-MediaCopyLog "Timeout waiting for index read lock; proceeding without lock" 'WARN'
                $entries = Import-Csv -LiteralPath $script:IndexPath -Encoding UTF8 -ErrorAction Stop
            }
        }
        finally {
            if ($readMutex) { try { $readMutex.ReleaseMutex() } catch { } $readMutex.Dispose() }
        }
        
        foreach ($entry in $entries) {
            # Skip empty or header-only rows
            if ([string]::IsNullOrWhiteSpace($entry.SourceName)) { 
                continue 
            }
            
            # Validate numeric fields before using them
            $length = 0
            $ticks = 0
            if (-not [int64]::TryParse($entry.SourceLength, [ref]$length)) {
                Write-Verbose "Skipping entry with invalid length: $($entry.SourceName)"
                continue
            }
            if (-not [int64]::TryParse($entry.SourceMTimeTicks, [ref]$ticks)) {
                Write-Verbose "Skipping entry with invalid timestamp: $($entry.SourceName)"
                continue
            }
            
            $name = [System.IO.Path]::GetFileName($entry.SourceName)
            $key = ("{0}|{1}|{2}" -f $name.ToLowerInvariant(), $length, $ticks)
            
            [void]$script:CopiedSourceKeys.Add($key)
            $loaded++
        }
    }
    catch {
        Write-MediaCopyLog "Warning: Could not load existing index entries: $_" 'WARN'
    }

    # Scan destination to capture existing content keys not yet indexed
    $addedFromDest = 0
    try {
        if (Test-Path -LiteralPath $DestinationRoot) {
            $destFiles = Get-ChildItem -LiteralPath $DestinationRoot -File -Recurse -ErrorAction SilentlyContinue
            
            foreach ($file in $destFiles) {
                $key = Get-MediaCopyFileKey -File $file
                
                if (-not $script:DestinationContentKeys.Contains($key)) {
                    [void]$script:DestinationContentKeys.Add($key)
                }
                
                # If not present in copied keys, append a dest-only entry
                if (-not $script:CopiedSourceKeys.Contains($key)) {
                    $entry = [PSCustomObject]@{
                        Timestamp = (Get-Date).ToUniversalTime().ToString('o')
                        SourceFullPath = ''
                        SourceName = $file.Name
                        SourceLength = $file.Length
                        SourceMTimeTicks = $file.LastWriteTimeUtc.Ticks
                        DestFullPath = $file.FullName
                    }
                    
                    try {
                        $entry | Export-Csv -LiteralPath $script:IndexPath -Append -NoTypeInformation -Encoding UTF8
                        [void]$script:CopiedSourceKeys.Add($key)
                        $addedFromDest++
                    }
                    catch {
                        Write-Verbose "Could not add destination file to index: $($file.Name)"
                    }
                }
            }
        }
    }
    catch {
        Write-MediaCopyLog "Warning: Could not scan destination for existing files: $_" 'WARN'
    }

    [PSCustomObject]@{
        IndexPath = $script:IndexPath
        LoadedFromIndex = $loaded
        AddedFromDestinationScan = $addedFromDest
        CopiedKeyCount = $script:CopiedSourceKeys.Count
        DestinationKeyCount = $script:DestinationContentKeys.Count
        IntegrityStatus = $integrity.IsHealthy
    }
}

function Test-MediaCopyShouldCopy {
    param([Parameter(Mandatory=$true)][System.IO.FileInfo]$File)
    $key = Get-MediaCopyFileKey -File $File
    return -not ($script:CopiedSourceKeys.Contains($key) -or $script:DestinationContentKeys.Contains($key))
}

function Add-MediaCopyIndexEntry {
    <#
    .SYNOPSIS
        Adds an entry to the index with mutex-based file locking.
    
    .DESCRIPTION
        Appends a copy operation record to the CSV index file using a mutex
        to prevent corruption from concurrent writes.
    
    .PARAMETER SourceFile
        The source file information object.
    
    .PARAMETER DestFullPath
        The full path to the destination file.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)][System.IO.FileInfo]$SourceFile,
        [Parameter(Mandatory=$true)][string]$DestFullPath
    )
    if (-not $script:IndexPath) { return }

    function Sanitize-ForCsvInjection {
        param([string]$value)
        if ($value -and $value -match '^[=\+\-@]') {
            return "'" + $value
        }
        return $value
    }

    $entry = [PSCustomObject]@{
        Timestamp        = (Get-Date).ToUniversalTime().ToString('o')  # ISO 8601 format
        SourceFullPath   = (Sanitize-ForCsvInjection $SourceFile.FullName)
        SourceName       = (Sanitize-ForCsvInjection $SourceFile.Name)
        SourceLength     = $SourceFile.Length
        SourceMTimeTicks = $SourceFile.LastWriteTimeUtc.Ticks
        DestFullPath     = (Sanitize-ForCsvInjection $DestFullPath)
    }
    
    # Use mutex for thread-safe CSV append operations
    $mutex = $null
    
    try {
    $mutex = New-MediaCopyIndexMutex -Path $script:IndexPath
        
        # Wait up to 5 seconds for the mutex
        if ($mutex.WaitOne(5000)) {
            try {
                # Use Export-Csv with proper quote escaping
                $entry | Export-Csv -LiteralPath $script:IndexPath -Append -NoTypeInformation -Encoding UTF8

                $key = Get-MediaCopyFileKey -File $SourceFile
                [void]$script:CopiedSourceKeys.Add($key)
            }
            finally {
                try { $mutex.ReleaseMutex() } catch { }
            }
        }
        else {
            Write-MediaCopyLog "Warning: Timeout waiting for index lock. Entry not written: $($SourceFile.Name)" 'WARN'
        }
    }
    catch [System.Threading.AbandonedMutexException] {
        # Previous process crashed - we recovered the mutex, try again
        Write-MediaCopyLog "Warning: Recovered abandoned index mutex. Writing entry: $($SourceFile.Name)" 'WARN'
        try {
            $entry | Export-Csv -LiteralPath $script:IndexPath -Append -NoTypeInformation -Encoding UTF8
            $key = Get-MediaCopyFileKey -File $SourceFile
            [void]$script:CopiedSourceKeys.Add($key)
        }
        catch {
            Write-MediaCopyLog "Warning: Could not write index entry for $($SourceFile.Name): $_" 'WARN'
        }
        finally {
            if ($null -ne $mutex) {
                try { $mutex.ReleaseMutex() } catch { }
            }
        }
    }
    catch {
        Write-MediaCopyLog "Warning: Could not write index entry for $($SourceFile.Name): $_" 'WARN'
    }
    finally {
        if ($null -ne $mutex) {
            $mutex.Dispose()
        }
    }
}

Export-ModuleMember -Function Get-MediaCopyIndexPath,Get-MediaCopyFileKey,Test-MediaCopyIndexIntegrity,Initialize-MediaCopyIndex,Test-MediaCopyShouldCopy,Add-MediaCopyIndexEntry
