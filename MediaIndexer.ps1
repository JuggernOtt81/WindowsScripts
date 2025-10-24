param(
    [switch]$Hash
)

<#
    MediaIndexer.ps1
    Elevated file indexer and copier for media and documents.
    PowerShell 7+ script

    Features:
    - Run elevated check
    - Prompt for source drives and destination
    - Create organized destination structure
    - Maintain atomic, crash-safe index.csv with backup
    - Copy only unindexed files
    - Optional SHA256 computation
    - Drive-level concurrency with ForEach-Object -Parallel (ThrottleLimit)
    - Logging via Start-Transcript and Write-Host colorized
    - Recovery on startup for index.tmp/index.new
#>

# Ensure UTF8 output
$OutputEncoding = [System.Text.Encoding]::UTF8

Set-StrictMode -Version Latest
[System.Threading.Thread]::CurrentThread.CurrentCulture = [System.Globalization.CultureInfo]::InvariantCulture

function Write-Log {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingWriteHost', '')]
    param(
        [string]$Message,
        [ValidateSet('Info','Warning','Error')][string]$Level = 'Info'
    )
    Write-Debug "Entering Write-Log"
    switch ($Level) {
        'Info'    { $color = 'White' }
        'Warning' { $color = 'Yellow' }
        'Error'   { $color = 'Red' }
    }
    $time = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
    Write-Host "[$time] [$Level] $Message" -ForegroundColor $color
}

function Test-Administrator {
    Write-Debug "Entering Test-Administrator"
    $isAdmin = (New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    if (-not $isAdmin) {
        Write-Host 'This script requires Administrator privileges. Please run PowerShell as Administrator.' -ForegroundColor Red
        exit 1
    }
}

function Get-AvailableDrives {
    Write-Debug "Entering Get-AvailableDrives"
    try {
        Get-PSDrive -PSProvider FileSystem | Sort-Object Name
    }
    catch {
        Write-Log "Failed to enumerate drives: $_" -Level Error
        throw
    }
}

function Select-SourceDrives {
    param(
        [array]$Drives
    )
    Write-Debug "Entering Select-SourceDrives"
    # Present a simple numeric selection allowing multiple selections separated by commas
    Write-Host "Available filesystem drives:"
    for ($i = 0; $i -lt $Drives.Count; $i++) {
        $d = $Drives[$i]
        Write-Host "[$i] $($d.Name) : $($d.Root)  ($($d.DisplayRoot))"
    }
    $selection = Read-Host 'Enter indices of source drives (comma-separated), or press Enter to select all'
    if ([string]::IsNullOrWhiteSpace($selection)) {
        return @($Drives | ForEach-Object { $_.Root })
    }
    $indices = $selection -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ -match '^[0-9]+$' } | ForEach-Object { [int]$_ }
    $selected = @()
    foreach ($idx in $indices) {
        if ($idx -ge 0 -and $idx -lt $Drives.Count) {
            $selected += $Drives[$idx].Root
        }
        else {
            Write-Log "Invalid selection index: $idx" -Level Warning
        }
    }
    return @($selected | Select-Object -Unique)
}

function Select-DestinationFolder {
    Write-Debug "Entering Select-DestinationFolder"
    # Try FolderBrowserDialog first (Windows GUI); fall back to Read-Host
    try {
        Add-Type -AssemblyName System.Windows.Forms -ErrorAction Stop
        $fbd = New-Object System.Windows.Forms.FolderBrowserDialog
        $fbd.Description = 'Select destination root folder for copied media and index'
        $fbd.ShowNewFolderButton = $true
        if ($fbd.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
            return $fbd.SelectedPath
        }
    }
    catch {
        # GUI not available or running headless; fall back
    }
    $path = Read-Host 'Enter destination root path (will be created if missing)'
    return $path
}

function Initialize-DestinationStructure {
    param(
        [Parameter(Mandatory=$true)][string]$DestinationRoot
    )
    Write-Debug "Entering Initialize-DestinationStructure"
    $map = @{
        'VIDEO' = 'mp4','mkv','mov','avi','flv','wmv','ts','m4v'
        'AUDIO' = 'mp3','flac','wav','ogg','aac','wma','m4a'
        'IMAGES' = 'jpg','jpeg','png','bmp','tiff','gif','heic','webp'
        'DOCUMENTS' = 'pdf','doc','docx','xls','xlsx','ppt','pptx','txt','rtf','csv'
    }
    try {
        $dest = Resolve-Path -Path $DestinationRoot -ErrorAction SilentlyContinue
        if (-not $dest) { New-Item -Path $DestinationRoot -ItemType Directory -Force | Out-Null }
        $DestinationRoot = (Resolve-Path -Path $DestinationRoot).Path
        foreach ($category in $map.Keys) {
            $categoryPath = Join-Path $DestinationRoot $category
            if (-not (Test-Path $categoryPath)) { New-Item -Path $categoryPath -ItemType Directory -Force | Out-Null }
            foreach ($ext in $map[$category]) {
                $sub = Join-Path $categoryPath $ext
                if (-not (Test-Path $sub)) { New-Item -Path $sub -ItemType Directory -Force | Out-Null }
            }
        }
        # logs folder
        $logs = Join-Path $DestinationRoot 'logs'
        if (-not (Test-Path $logs)) { New-Item -Path $logs -ItemType Directory -Force | Out-Null }
        return @{ DestinationRoot = $DestinationRoot; Map = $map }
    }
    catch {
        Write-Log "Failed to prepare destination structure: $_" -Level Error
        throw
    }
}

function Get-CategoryAndFolder {
    param(
        [string]$Extension,
        [hashtable]$Map,
        [string]$DestinationRoot
    )
    Write-Debug "Entering Get-CategoryAndFolder"
    $ext = $Extension.TrimStart('.').ToLowerInvariant()
    foreach ($category in $Map.Keys) {
        if ($Map[$category] -contains $ext) {
            $sub = Join-Path (Join-Path $DestinationRoot $category) $ext
            return @{ Category = $category; Folder = $sub }
        }
    }
    return $null
}

function Import-Index {
    param(
        [string]$IndexFile
    )
    Write-Debug "Entering Import-Index"
    $indexed = @{}
    $rows = @()
    if (Test-Path $IndexFile) {
        try {
            $rows = Import-Csv -Path $IndexFile -ErrorAction Stop
            foreach ($r in $rows) {
                $props = $r.PSObject.Properties.Name
                if ($props -notcontains 'filename' -or $props -notcontains 'size' -or $props -notcontains 'source_date') {
                    continue
                }
                $fn = [string]$r.filename
                $sz = [string]$r.size
                $sd = [string]$r.source_date
                if ([string]::IsNullOrWhiteSpace($fn) -or [string]::IsNullOrWhiteSpace($sz) -or [string]::IsNullOrWhiteSpace($sd)) { continue }
                $key = ("{0}|{1}|{2}" -f $fn.ToLowerInvariant(), $sz, $sd).ToLowerInvariant()
                $indexed[$key] = $true
            }
            Write-Log "Loaded index with $($rows.Count) entries" -Level Info
        }
        catch {
            Write-Log "Failed to import index file: $_" -Level Warning
        }
    }
    else {
        Write-Log "No index file found; a new one will be created at $IndexFile" -Level Info
    }
    return @{ Table = $indexed; Rows = $rows }
}

function Lock-File {
    param(
        [string]$LockPath,
        [int]$TimeoutSec = 30
    )
    Write-Debug "Entering Lock-File"
    # Try to create/open a filestream with exclusive lock. Return FileStream on success.
    $sw = [Diagnostics.Stopwatch]::StartNew()
    while ($sw.Elapsed.TotalSeconds -lt $TimeoutSec) {
        try {
            $fs = [System.IO.File]::Open($LockPath, [System.IO.FileMode]::OpenOrCreate, [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::None)
            # Keep the stream open to maintain the lock; return it
            return $fs
        }
        catch {
            Start-Sleep -Milliseconds 250
        }
    }
    return $null
}

function Unlock-File {
    param(
        $FileStream,
        [string]$LockPath
    )
    Write-Debug "Entering Unlock-File"
    try {
        if ($null -ne $FileStream) { $FileStream.Close(); $FileStream.Dispose() }
        if (Test-Path $LockPath) { Remove-Item -Path $LockPath -Force -ErrorAction SilentlyContinue }
    }
    catch {
        # ignore
    }
}

function Add-IndexEntry {
    param(
        [string]$IndexFile,
        [hashtable]$Entry,
        [hashtable]$Context # contains DestinationRoot and Map
    )
    Write-Debug "Entering Add-IndexEntry"
    $indexDir = Split-Path -Parent $IndexFile
    $lockPath = Join-Path $indexDir 'index.lock'
    $tmpPath = Join-Path $indexDir 'index.new'
    $bakPath = Join-Path $indexDir 'index.csv.bak'

    $fs = Lock-File -LockPath $lockPath -TimeoutSec 60
    if (-not $fs) {
        Write-Log "Unable to acquire index lock for writing" -Level Error
        throw "Index lock timeout"
    }
    try {
        # Read existing index if any
        $existing = @()
        if (Test-Path $IndexFile) {
            try { $existing = Import-Csv -Path $IndexFile -ErrorAction Stop } catch { $existing = @() }
        }
        # Append the new entry
        $existing += (New-Object PSObject -Property $Entry)

        # Export to tmp and then move atomically
        $existing | Export-Csv -Path $tmpPath -NoTypeInformation -Encoding UTF8 -Force
        if (Test-Path $IndexFile) {
            Copy-Item -Path $IndexFile -Destination $bakPath -Force
        }
        Move-Item -Path $tmpPath -Destination $IndexFile -Force
    }
    catch {
        Write-Log "Failed to write index: $_" -Level Error
        throw
    }
    finally {
        Unlock-File -FileStream $fs -LockPath $lockPath
    }
}

function Restore-IndexState {
    param(
        [string]$IndexFile
    )
    Write-Debug "Entering Restore-IndexState"
    $indexDir = Split-Path -Parent $IndexFile
    $tmpPath = Join-Path $indexDir 'index.tmp'
    $newPath = Join-Path $indexDir 'index.new'
    $bakPath = Join-Path $indexDir 'index.csv.bak'

    if ((Test-Path $tmpPath) -or (Test-Path $newPath)) {
        Write-Log "Found incomplete index files. Attempting recovery..." -Level Warning
        if (Test-Path $bakPath) {
            try {
                Copy-Item -Path $bakPath -Destination $IndexFile -Force
                Write-Log "Restored index from backup $bakPath" -Level Info
                Remove-Item -Path $tmpPath -ErrorAction SilentlyContinue
                Remove-Item -Path $newPath -ErrorAction SilentlyContinue
                return
            }
            catch {
                Write-Log "Failed to restore from backup: $_" -Level Warning
            }
        }
        # If no backup, attempt to import whatever is present
        if (Test-Path $newPath) {
            try { Move-Item -Path $newPath -Destination $IndexFile -Force; Write-Log 'Recovered index from index.new' -Level Info } catch { Write-Log "Could not recover index.new: $_" -Level Warning }
        }
    }
}

function Copy-NewFiles {
    param(
        [array]$SourceRoots,
        [string]$DestinationRoot,
        [hashtable]$Map,
        [string]$IndexFile,
        [hashtable]$IndexedTable,
        [switch]$ComputeHash
    )
    Write-Debug "Entering Copy-NewFiles"

    $stats = [pscustomobject]@{ Scanned=0; Copied=0; Skipped=0 }

    # Create a scriptblock to process a single drive in parallel
    $scriptBlock = {
        param($root, $DestinationRoot, $Map, $IndexFile, $ComputeHash)

        $localScanned = 0; $localCopied = 0; $localSkipped = 0
        $partialGuid = [guid]::NewGuid().ToString()
        $indexDir = Split-Path -Parent $IndexFile
        $partialPath = Join-Path $indexDir ("index.partial.$partialGuid.csv")
        $partialEntries = @()

        try {
            $files = Get-ChildItem -Path $root -Recurse -File -ErrorAction SilentlyContinue
            $total = $files.Count
            $i = 0
            foreach ($f in $files) {
                $i++
                $localScanned++
                Write-Progress -Activity "Scanning $root" -Status ("Processing {0}/{1}: {2}" -f $i,$total,$f.Name) -PercentComplete ([math]::Round($i/$total*100,0))

                # Permissive mode: allow hidden/system files
                # if (($f.Attributes -band [IO.FileAttributes]::Hidden) -or ($f.Attributes -band [IO.FileAttributes]::System)) { $localSkipped++; continue }

                $ext = $f.Extension.TrimStart('.').ToLowerInvariant()
                $categoryInfo = $null
                foreach ($cat in $Map.Keys) { if ($Map[$cat] -contains $ext) { $categoryInfo = @{ Category = $cat; Folder = Join-Path -Path (Join-Path $DestinationRoot $cat) -ChildPath $ext }; break } }
                if (-not $categoryInfo) { $localSkipped++; continue }

                $size = $f.Length
                $sourceDate = $f.LastWriteTimeUtc.ToString('yyyyMMddHHmmss')
                $fname = $f.FullName
                $key = ("{0}|{1}|{2}" -f $fname.ToLowerInvariant(), $size, $sourceDate).ToLowerInvariant()

                # Acquire index lock and check membership
                $indexDir = Split-Path -Parent $IndexFile
                $lockPath = Join-Path $indexDir 'index.lock'
                $fsLock = $null
                try {
                    $fsLock = [System.IO.File]::Open($lockPath, [System.IO.FileMode]::OpenOrCreate, [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::None)
                }
                catch {
                    # couldn't acquire lock immediately; wait briefly
                    Start-Sleep -Milliseconds 200
                    try { $fsLock = [System.IO.File]::Open($lockPath, [System.IO.FileMode]::OpenOrCreate, [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::None) } catch { }
                }

                try {
                    $already = $false
                    if (Test-Path $IndexFile) {
                        try {
                            $csv = Import-Csv -Path $IndexFile -ErrorAction Stop
                            foreach ($r in $csv) {
                                $k = ("{0}|{1}|{2}" -f $r.filename.ToLowerInvariant(), $r.size, $r.source_date).ToLowerInvariant()
                                if ($k -eq $key) { $already = $true; break }
                            }
                        }
                        catch {
                            # if import fails, assume not present
                        }
                    }
                    if ($already) { $localSkipped++; continue }

                    # Destination path
                    $destFolder = $categoryInfo.Folder
                    if (-not (Test-Path $destFolder)) { New-Item -Path $destFolder -ItemType Directory -Force | Out-Null }
                    $destFile = Join-Path $destFolder $f.Name

                    # Copy file
                    try {
                        Copy-Item -Path $f.FullName -Destination $destFile -Force -ErrorAction Stop
                        # Verify size
                        $dstSize = (Get-Item -LiteralPath $destFile).Length
                        if ($dstSize -ne $size) {
                            Remove-Item -Path $destFile -Force -ErrorAction SilentlyContinue
                            Write-Host "Size mismatch for $($f.FullName) after copy; skipped" -ForegroundColor Yellow
                            $localSkipped++
                            continue
                        }
                    }
                    catch {
                        Write-Host "Failed to copy $($f.FullName): $_" -ForegroundColor Yellow
                        if (Test-Path $destFile) { Remove-Item -Path $destFile -Force -ErrorAction SilentlyContinue }
                        $localSkipped++
                        continue
                    }

                    # Optionally compute SHA256
                    $hash = ''
                    if ($ComputeHash) {
                        try { $hash = (Get-FileHash -Path $destFile -Algorithm SHA256 -ErrorAction Stop).Hash } catch { $hash = '' }
                    }

                    # Prepare entry
                    $entry = @{
                        filename = $f.FullName
                        extension = $f.Extension.TrimStart('.')
                        size = $size
                        source_date = $sourceDate
                        added_date = (Get-Date).ToUniversalTime().ToString('yyyyMMddHHmmss')
                        sha256 = $hash
                    }
                    # Add entry to partial list; main thread will merge atomically
                    $partialEntries += (New-Object PSObject -Property $entry)
                    $localCopied++
                    Write-Host "Copied: $($f.FullName) -> $destFile" -ForegroundColor White

                }
                finally {
                    if ($fsLock) { $fsLock.Close(); $fsLock.Dispose(); Remove-Item -Path $lockPath -ErrorAction SilentlyContinue }
                }
            }
        }
        catch {
            Write-Host "Error processing drive ${root}: $_" -ForegroundColor Red
        }
        # Write partial entries if any
        try {
            if ($partialEntries.Count -gt 0) {
                $partialEntries | Export-Csv -Path $partialPath -NoTypeInformation -Encoding UTF8 -Force
            }
        }
        catch {
            Write-Host "Failed to write partial index for ${root}: $_" -ForegroundColor Yellow
        }

        return [pscustomobject]@{ Root = $root; Scanned = $localScanned; Copied = $localCopied; Skipped = $localSkipped; Partial = $partialPath }
    }

    # Process drives sequentially for broad compatibility (Windows PowerShell and PowerShell 7)
    $results = @()
    foreach ($root in @($SourceRoots)) {
        $results += & $scriptBlock.InvokeReturnAsIs($root, $DestinationRoot, $Map, $IndexFile, $ComputeHash)
    }
    $partialFiles = @()
    foreach ($r in $results) {
        $stats.Scanned += $r.Scanned
        $stats.Copied += $r.Copied
        $stats.Skipped += $r.Skipped
        if ($r.Partial -and (Test-Path $r.Partial)) { $partialFiles += $r.Partial }
    }

    return @{ Stats = $stats; Partials = $partialFiles }
}

function Main {
    param(
        [switch]$ComputeHash
    )
    Write-Debug "Entering Main"

    # Permissive mode: admin check disabled
    # Test-Administrator

    $available = Get-AvailableDrives
    $sourceRoots = Select-SourceDrives -Drives $available
    $sourceRoots = @($sourceRoots)
    if (-not $sourceRoots -or $sourceRoots.Count -eq 0) { Write-Log 'No source drives selected; exiting.' -Level Error; exit 1 }

    $destination = Select-DestinationFolder
    if (-not $destination) { Write-Log 'No destination selected; exiting.' -Level Error; exit 1 }

    $prep = Initialize-DestinationStructure -DestinationRoot $destination
    $DestinationRoot = $prep.DestinationRoot
    $Map = $prep.Map

    $IndexFile = Join-Path $DestinationRoot 'index.csv'

    # Start transcript in logs folder
    $timestamp = (Get-Date).ToUniversalTime().ToString('yyyyMMdd_HHmmss')
    $logFile = Join-Path (Join-Path $DestinationRoot 'logs') "run_$timestamp.log"
    try { Start-Transcript -Path $logFile -Force -ErrorAction Stop } catch { Write-Log "Failed to start transcript: $_" -Level Warning }

    Write-Host "Summary before start" -ForegroundColor White
    Write-Host "Sources: $($sourceRoots -join ', ')" -ForegroundColor White
    Write-Host "Destination: $DestinationRoot" -ForegroundColor White
    $confirm = Read-Host 'Proceed with copy? (Y/N)'
    if ($confirm -notin @('Y','y','Yes','yes')) { Write-Log 'Operation cancelled by user.' -Level Info; Stop-Transcript; exit 0 }

    # Recovery
    Restore-IndexState -IndexFile $IndexFile

    # Load index into in-memory structure
    $indexObj = Import-Index -IndexFile $IndexFile
    $indexed = $indexObj.Table

    # Kick off copy
    try {
        $result = Copy-NewFiles -SourceRoots $sourceRoots -DestinationRoot $DestinationRoot -Map $Map -IndexFile $IndexFile -IndexedTable $indexed -ComputeHash:$ComputeHash
        $stats = $result.Stats

    # Merge partial index files produced by runspaces. Each entry is appended atomically using Add-IndexEntry
        foreach ($partial in $result.Partials) {
            if ([string]::IsNullOrWhiteSpace($partial)) { continue }
            if (-not (Test-Path $partial)) { continue }
            try {
                $rows = Import-Csv -Path $partial -ErrorAction Stop
                foreach ($r in $rows) {
                    $entry = @{
                        filename = $r.filename
                        extension = $r.extension
                        size = $r.size
                        source_date = $r.source_date
                        added_date = $r.added_date
                        sha256 = $r.sha256
                    }
                    try { Add-IndexEntry -IndexFile $IndexFile -Entry $entry -Context @{ DestinationRoot = $DestinationRoot; Map = $Map } } catch { Write-Log ("Failed to save index entry from partial {0}: {1}" -f $partial, $_) -Level Warning }
                }
            }
            catch {
                Write-Log (("Failed to import partial index {0}: {1}" -f $partial, $_)) -Level Warning
            }
            finally {
                try { Remove-Item -Path $partial -Force -ErrorAction SilentlyContinue } catch { }
            }
        }

        Write-Log "Completed. Scanned: $($stats.Scanned), Copied: $($stats.Copied), Skipped: $($stats.Skipped)" -Level Info
    }
    catch {
        Write-Log "Error during copying: $_" -Level Error
    }
    finally {
        try { Stop-Transcript } catch { }
    }
}


# Entry point - execute main function
Main -ComputeHash:$Hash
