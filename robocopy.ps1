# Robust media copy entry point with full WhatIf/Confirm support
[CmdletBinding(SupportsShouldProcess = $true)]
<#
.SYNOPSIS
    Robust media copy entry point with full WhatIf/Confirm support

.DESCRIPTION
    Copies media files from a source directory to a destination, organizing by extension/category, with logging and error handling.

.PARAMETER Source
    The source directory containing files to copy. Must exist and be a directory.

.PARAMETER Destination
    The destination directory for copied files. Will be created if it does not exist.

.PARAMETER LogFile
    Path to the log file for recording actions, warnings, and errors.

.PARAMETER ExtensionMapPath
    Path to the XML file mapping file extensions to categories. Defaults to 'extensions.xml' in the script directory.

.PARAMETER BatchSize
    Number of files to process in each batch copy operation. Default is 50.

.PARAMETER MaxRetries
    Maximum number of retry attempts for failed copy operations. Default is 3.

.PARAMETER RobocopyThreads
    Number of threads to use for robocopy operations. Default is 8.

.PARAMETER ContinueOnFailure
    If specified, the script will continue copying files even after errors occur.
#>
param(
    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$Source,

    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$Destination,

    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$LogFile,

    [ValidateNotNullOrEmpty()]
    [string]$ExtensionMapPath = (Join-Path -Path $PSScriptRoot -ChildPath 'extensions.xml'),

    [ValidateRange(1, 5000)]
    [int]$BatchSize = 50,

    [ValidateRange(1, 20)]
    [int]$MaxRetries = 3,

    [ValidateRange(1, 128)]
    [int]$RobocopyThreads = 8,

    [switch]$ContinueOnFailure
)


Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$PSDefaultParameterValues['*:Encoding'] = 'utf8'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

# Import refactored modules using dynamic path resolution
$modulePath = Join-Path -Path $PSScriptRoot -ChildPath 'modules'
Import-Module (Join-Path -Path $modulePath -ChildPath 'Logging.psm1') -Force
Import-Module (Join-Path -Path $modulePath -ChildPath 'Elevation.psm1') -Force
Import-Module (Join-Path -Path $modulePath -ChildPath 'ExtensionMap.psm1') -Force
Import-Module (Join-Path -Path $modulePath -ChildPath 'CopyOps.psm1') -Force
Import-Module (Join-Path -Path $modulePath -ChildPath 'Index.psm1') -Force
Import-Module (Join-Path -Path $modulePath -ChildPath 'Config.psm1') -Force
Import-Module (Join-Path -Path $modulePath -ChildPath 'Baseline.psm1') -Force

# Apply configuration defaults when parameters weren't explicitly provided
try { $config = Get-MediaCopyConfig } catch { $config = $null }
if ($null -ne $config) {
    if (-not $PSBoundParameters.ContainsKey('ExtensionMapPath')) { $ExtensionMapPath = $config.DefaultExtensionMap }
    if (-not $PSBoundParameters.ContainsKey('BatchSize'))       { $BatchSize       = $config.DefaultBatchSize }
    if (-not $PSBoundParameters.ContainsKey('MaxRetries'))      { $MaxRetries      = $config.DefaultMaxRetries }
    if (-not $PSBoundParameters.ContainsKey('RobocopyThreads')) { $RobocopyThreads = $config.DefaultRobocopyThreads }
}

# Register Event Log source early (with fallback)
Register-MediaCopyEventLogSource -ErrorAction SilentlyContinue

# Expose cmdlet context and shared state to helper functions
$script:Cmdlet = $PSCmdlet
$script:SourceRoot = $null
$script:DestinationRoot = $null
$script:LogFilePath = $null
$script:ExtensionMap = @{}
$script:ContinueOnFailure = $ContinueOnFailure.IsPresent
# Tracks every destination file path to avoid collisions when renaming
$script:DestNameTracker = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)

# Collect error records for end-of-run summary
$script:ErrorRecords = New-Object System.Collections.Generic.List[object]

# Mutex for concurrency protection
$script:Mutex = $null

# Performance counters
$script:Perf = [ordered]@{
    TotalMs = 0
    ScanMs = 0
    GroupMs = 0
    CopyMs = 0
    TotalFiles = 0
    ToCopy = 0
}

# Set the destination tracker in the module scope so collision detection works
Set-MediaCopyDestTracker -Tracker $script:DestNameTracker

function Get-MediaCopyLock {
    <#
    .SYNOPSIS
        Acquires a global mutex lock to prevent concurrent execution.
    
    .DESCRIPTION
        Creates a named mutex based on the destination root path hash to ensure
        only one instance can process a given destination at a time.
    
    .PARAMETER DestinationRoot
        The destination path to lock.
    
    .RETURNS
        Mutex object that must be disposed when done.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)]
        [string]$DestinationRoot
    )
    
    # Create a stable mutex name from destination path
    $hashBytes = [System.Security.Cryptography.SHA256]::Create().ComputeHash(
        [System.Text.Encoding]::UTF8.GetBytes($DestinationRoot.ToLowerInvariant())
    )
    $hashString = [System.BitConverter]::ToString($hashBytes).Replace('-', '').Substring(0, 32)
    $mutexName = "Global\MediaCopy_$hashString"
    
    try {
        $mutex = [System.Threading.Mutex]::new($false, $mutexName)
        
        # Try to acquire lock (0 ms timeout = immediate return)
        if (-not $mutex.WaitOne(0)) {
            $mutex.Dispose()
            throw "Another instance of MediaCopy is already processing destination: $DestinationRoot`nOnly one instance can run per destination at a time."
        }
        
        Write-MediaCopyLog "Acquired exclusive lock for destination: $DestinationRoot" 'INFO'
        return $mutex
    }
    catch [System.Threading.AbandonedMutexException] {
        # Previous instance crashed without releasing - we can take over
        Write-MediaCopyLog "Recovered abandoned lock from crashed instance" 'WARN'
        return $mutex
    }
    catch {
        throw "Failed to acquire lock for destination: $_"
    }
}

function Remove-MediaCopyLock {
    <#
    .SYNOPSIS
        Releases the mutex lock.
    
    .DESCRIPTION
        Safely releases and disposes the mutex lock.
    
    .PARAMETER Mutex
        The mutex object to release.
    #>
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [Parameter(Mandatory=$false)]
        [System.Threading.Mutex]$Mutex
    )
    
    if ($null -ne $Mutex) {
        if ($PSCmdlet.ShouldProcess("MediaCopy Mutex Lock", "Release exclusive lock")) {
            try {
                $Mutex.ReleaseMutex()
                $Mutex.Dispose()
                Write-MediaCopyLog "Released exclusive lock" 'INFO'
            }
            catch {
                Write-MediaCopyLog "Warning: Could not release lock: $_" 'WARN'
            }
        }
    }
}

function Enable-MediaCopyLongPathSupport {
    <#
    .SYNOPSIS
        Safely enables Windows long path support if needed and possible.
    
    .DESCRIPTION
        Checks if long path support is already enabled. If not, and if running as admin,
        offers to enable it via ShouldProcess. Respects WhatIf and does not force changes.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param()
    
    # Check if running as admin
    if (-not (Test-MediaCopyElevation)) {
        Write-MediaCopyLog "Long path support requires administrator privileges. Some files with paths >260 characters may fail." 'WARN'
        return $false
    }
    
    # Check if already enabled
    try {
        $currentValue = Get-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\FileSystem' -Name 'LongPathsEnabled' -ErrorAction SilentlyContinue
        if ($currentValue.LongPathsEnabled -eq 1) {
            Write-MediaCopyLog "Long path support is already enabled" 'INFO'
            return $true
        }
    }
    catch {
        Write-MediaCopyLog "Could not check long path support status: $_" 'WARN'
        return $false
    }
    
    # Request permission to enable
    if ($script:Cmdlet.ShouldProcess('Registry: HKLM:\SYSTEM\CurrentControlSet\Control\FileSystem\LongPathsEnabled', 'Enable long path support (>260 characters)')) {
        try {
            Set-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\FileSystem' -Name 'LongPathsEnabled' -Value 1 -ErrorAction Stop
            Write-MediaCopyLog "Successfully enabled long path support (registry change will take effect after reboot)" 'INFO'
            return $true
        }
        catch [System.Security.SecurityException] {
            Write-MediaCopyLog "Access denied: Cannot enable long path support. Run as Administrator or enable manually." 'ERROR'
            return $false
        }
        catch [System.UnauthorizedAccessException] {
            Write-MediaCopyLog "Unauthorized: Cannot modify registry. This may be restricted by Group Policy." 'ERROR'
            return $false
        }
        catch {
            Write-MediaCopyLog "Failed to enable long path support: $_" 'ERROR'
            return $false
        }
    }
    else {
        Write-MediaCopyLog "Long path support not enabled (user declined or WhatIf mode)" 'INFO'
        return $false
    }
}

function Test-MediaCopyPathValid {
    <#
    .SYNOPSIS
        Validates that a path is safe and properly formatted.
    
    .DESCRIPTION
        Performs comprehensive validation including:
        - Null/empty check
        - Invalid characters
        - Reserved names (CON, PRN, etc.)
        - Path length limits
        - UNC path format
        - Network connectivity (for UNC paths)
        - Path traversal protection
    
    .PARAMETER Path
        Path to validate.
    
    .PARAMETER MustExist
        If specified, path must exist.
    
    .PARAMETER BasePath
        If specified, path must be under this base path (prevents traversal).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)]
        [AllowEmptyString()]
        [string]$Path,
        
        [switch]$MustExist,
        
        [string]$BasePath
    )
    
    # Check for null/empty
    if ([string]::IsNullOrWhiteSpace($Path)) {
        throw "Path cannot be empty"
    }
    
    $Path = $Path.Trim()
    
    # Check for invalid characters
    $invalidChars = [System.IO.Path]::GetInvalidPathChars()
    foreach ($char in $invalidChars) {
        if ($Path.Contains($char)) {
            throw "Path contains invalid character: '$char' in path: $Path"
        }
    }
    
    # Check for reserved names in path components
    $reservedNames = @('CON', 'PRN', 'AUX', 'NUL', 'COM1', 'COM2', 'COM3', 'COM4', 
                       'COM5', 'COM6', 'COM7', 'COM8', 'COM9', 'LPT1', 'LPT2', 
                       'LPT3', 'LPT4', 'LPT5', 'LPT6', 'LPT7', 'LPT8', 'LPT9')
    
    $pathParts = $Path.Split([System.IO.Path]::DirectorySeparatorChar, [System.IO.Path]::AltDirectorySeparatorChar)
    foreach ($part in $pathParts) {
        if ([string]::IsNullOrWhiteSpace($part)) { continue }
        
        $baseName = [System.IO.Path]::GetFileNameWithoutExtension($part).ToUpperInvariant()
        if ($reservedNames -contains $baseName) {
            throw "Path contains reserved Windows name: $part"
        }
    }
    
    # Check path length
    $maxLength = 260  # Default Windows MAX_PATH
    try {
        $longPathEnabled = Get-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\FileSystem' -Name 'LongPathsEnabled' -ErrorAction SilentlyContinue
        if ($longPathEnabled.LongPathsEnabled -eq 1) {
            $maxLength = 32767  # Unicode max path
        }
    }
    catch {
        # Silently continue if unable to check long path support
        Write-Verbose "Unable to check long path support: $_"
    }
    
    if ($Path.Length -gt $maxLength) {
        throw "Path exceeds maximum length of $maxLength characters: $($Path.Length) chars"
    }
    
    # Validate UNC path format
    if ($Path.StartsWith('\\')) {
        $uncPattern = '^\\\\[^\\]+\\[^\\]+'
        if ($Path -notmatch $uncPattern) {
            throw "Invalid UNC path format: $Path (expected \\server\share)"
        }
        
        # Test network connectivity
        $server = ($Path -replace '^\\\\([^\\]+)\\.*', '$1')
        Write-Verbose "Testing connectivity to UNC server: $server"
        
        if (-not (Test-Connection -ComputerName $server -Count 1 -Quiet -ErrorAction SilentlyContinue)) {
            throw "Cannot reach server: $server (network unavailable or server down)"
        }
    }
    
    # Path traversal protection
    if ($BasePath) {
        try {
            $resolvedPath = [System.IO.Path]::GetFullPath($Path)
            $resolvedBase = [System.IO.Path]::GetFullPath($BasePath)
            
            if (-not $resolvedPath.StartsWith($resolvedBase, [StringComparison]::OrdinalIgnoreCase)) {
                throw "Path '$Path' is outside the allowed base directory '$BasePath' (potential path traversal)"
            }
        }
        catch {
            throw "Path validation failed: $_"
        }
    }
    
    # Check existence if required
    if ($MustExist -and -not (Test-Path -LiteralPath $Path)) {
        throw "Path does not exist: $Path"
    }
    
    return $true
}

function Confirm-MediaCopyInput {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [string]$SourcePath,
        [string]$DestinationPath,
        [string]$LogPath,
        [string]$MapPath
    )
    
    # Validate all input paths for security
    Write-Verbose "Validating source path: $SourcePath"
    Test-MediaCopyPathValid -Path $SourcePath -MustExist
    
    Write-Verbose "Validating destination path: $DestinationPath"
    Test-MediaCopyPathValid -Path $DestinationPath
    
    Write-Verbose "Validating log path: $LogPath"
    Test-MediaCopyPathValid -Path $LogPath
    
    Write-Verbose "Validating extension map path: $MapPath"
    Test-MediaCopyPathValid -Path $MapPath -MustExist
    
    # Convert to absolute paths and handle UNC/relative paths
    $script:SourceRoot = if ([System.IO.Path]::IsPathRooted($SourcePath)) {
        $SourcePath
    } else {
        Join-Path (Get-Location).Path $SourcePath | Resolve-Path | Select-Object -ExpandProperty Path
    }
    
    $script:DestinationRoot = if ([System.IO.Path]::IsPathRooted($DestinationPath)) {
        $DestinationPath
    } else {
        Join-Path (Get-Location).Path $DestinationPath
    }
    
    # Validate source exists and is a directory
    if (-not (Test-Path -LiteralPath $script:SourceRoot -PathType Container)) {
        throw "Source path does not exist or is not a directory: $script:SourceRoot"
    }
    
    # Create destination if it doesn't exist
    if (-not (Test-Path -LiteralPath $script:DestinationRoot)) {
        if ($script:Cmdlet.ShouldProcess($script:DestinationRoot, "Create destination directory")) {
            New-Item -Path $script:DestinationRoot -ItemType Directory -Force | Out-Null
            Write-MediaCopyLog "Created destination directory: $script:DestinationRoot" 'INFO'
        }
    }

    # Quick ACL/permission check: attempt to create and remove a temp file
    try {
        $tmpProbe = Join-Path $script:DestinationRoot (".mediacopy_probe_" + [guid]::NewGuid().ToString() + ".tmp")
        if ($script:Cmdlet.ShouldProcess($tmpProbe, 'Permission probe: create temporary file')) {
            New-Item -Path $tmpProbe -ItemType File -Force | Out-Null
            Remove-Item -LiteralPath $tmpProbe -Force -ErrorAction Stop
            Write-MediaCopyLog 'Destination write permission OK' 'DEBUG'
        }
    } catch {
        Write-MediaCopyLog "Destination permission check failed: $_" 'WARN'
        if (-not $script:ContinueOnFailure) { throw }
    }
    
    # Setup log file path (create directory if needed)
    $script:LogFilePath = if ([System.IO.Path]::IsPathRooted($LogPath)) {
        $LogPath
    } else {
        Join-Path (Get-Location).Path $LogPath
    }
    
    $logDir = Split-Path -Parent $script:LogFilePath
    if ($logDir -and -not (Test-Path -LiteralPath $logDir)) {
        New-Item -Path $logDir -ItemType Directory -Force | Out-Null
    }
    
    # Initialize log file
    if ($script:Cmdlet.ShouldProcess($script:LogFilePath, "Initialize log file")) {
        if (-not (Test-Path -LiteralPath $script:LogFilePath)) {
            New-Item -Path $script:LogFilePath -ItemType File -Force | Out-Null
        }
        $timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
        Add-Content -LiteralPath $script:LogFilePath -Value "`n========== Media Copy Session Started: $timestamp ==========" -Encoding UTF8
    }

    # Share the log file path with modules and initialize rotation
    Set-MediaCopyLogPath -Path $script:LogFilePath
    # Initialize audit trail in the same folder
    try {
        $auditPath = Join-Path (Split-Path -Parent $script:LogFilePath) 'audit.log'
        if (-not (Test-Path -LiteralPath $auditPath)) { New-Item -Path $auditPath -ItemType File -Force | Out-Null }
        Set-MediaCopyAuditPath -Path $auditPath
    } catch { }
    # Initialize baseline tracking
    try {
        $baselinePath = Join-Path (Split-Path -Parent $script:LogFilePath) 'baseline.csv'
        Set-MediaCopyBaselinePath -Path $baselinePath
    } catch { }
    
    # Validate and load extension map
    if (-not (Test-Path -LiteralPath $MapPath)) {
        throw "Extension map file not found: $MapPath"
    }
    
    $script:ExtensionMap = Import-MediaCopyExtensionMap -MapPath $MapPath
    
    # Set the extension map in the module scope so Get-MediaCopyCategory can access it
    Set-MediaCopyExtensionMap -Map $script:ExtensionMap
    
    Write-MediaCopyLog "Loaded $($script:ExtensionMap.Count) extension mappings from $MapPath" 'INFO'
    
    # Validate robocopy is available
    $robocopyPath = Get-Command robocopy.exe -ErrorAction SilentlyContinue
    if (-not $robocopyPath) {
        throw "robocopy.exe not found. This script requires robocopy to be available in PATH."
    }
    Write-MediaCopyLog "Found robocopy at: $($robocopyPath.Source)" 'INFO'
}

function New-MediaCopyDirectoryIfNotExist {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param([string]$Path)
    
    if (-not (Test-Path -LiteralPath $Path)) {
        if ($script:Cmdlet.ShouldProcess($Path, "Create category directory")) {
            try {
                New-Item -Path $Path -ItemType Directory -Force | Out-Null
                Write-MediaCopyLog "Created directory: $Path" 'INFO'
            }
            catch {
                Write-MediaCopyLog "Failed to create directory: $Path - $_" 'ERROR'
                throw
            }
        }
    }
}

function Invoke-MediaCopyProcessing {
    param(
        [string]$SourceRoot,
        [int]$Batch,
        [int]$Retries,
        [bool]$Continue,
        [int]$Threads
    )
    
    Write-MediaCopyLog "Scanning source directory for files..." 'INFO'
    $swTotal = [System.Diagnostics.Stopwatch]::StartNew()
    $swScan = [System.Diagnostics.Stopwatch]::StartNew()
    
    # Initialize index and load existing entries; also scan destination for existing files not yet indexed
    $indexStats = Initialize-MediaCopyIndex -DestinationRoot $script:DestinationRoot
    Write-MediaCopyLog "Index initialized: Path=$($indexStats.IndexPath); Loaded=$($indexStats.LoadedFromIndex); AddedFromDest=$($indexStats.AddedFromDestinationScan)" 'INFO'

    # Get all files from source (recursive)
    $allFiles = Get-ChildItem -LiteralPath $SourceRoot -File -Recurse -ErrorAction SilentlyContinue
    $totalFiles = $allFiles.Count
    $script:Perf.TotalFiles = $totalFiles
    
    if ($totalFiles -eq 0) {
        Write-MediaCopyLog "No files found in source directory." 'WARN'
        return
    }
    
    Write-MediaCopyLog "Found $totalFiles files in source." 'INFO'

    # Filter out files already present per index/destination scan
    $allFiles = $allFiles | Where-Object { Test-MediaCopyShouldCopy -File $_ }
    $totalToCopy = $allFiles.Count
    Write-MediaCopyLog "After index filtering: $totalToCopy files to copy." 'INFO'
    $script:Perf.ToCopy = $totalToCopy
    $swScan.Stop(); $script:Perf.ScanMs = $swScan.ElapsedMilliseconds
    
    # Group files by extension
    $swGroup = [System.Diagnostics.Stopwatch]::StartNew()
    $fileGroups = $allFiles | Group-Object -Property Extension | ForEach-Object {
        $ext = $_.Name.TrimStart('.')
        if ([string]::IsNullOrWhiteSpace($ext)) { $ext = 'no_extension' }
        
        $category = Get-MediaCopyCategory -Extension $ext
        $sanitizedCategory = Get-MediaCopySanitizedName -Value $category
        $destDir = Join-Path -Path $script:DestinationRoot -ChildPath $sanitizedCategory
        
        [PSCustomObject]@{
            Extension = $ext
            Category = $category
            DestinationDir = $destDir
            Files = $_.Group
            Count = $_.Count
        }
    }
    
    Write-MediaCopyLog "Files grouped into $($fileGroups.Count) categories." 'INFO'
    $swGroup.Stop(); $script:Perf.GroupMs = $swGroup.ElapsedMilliseconds
    if ($WhatIfPreference) {
        Write-MediaCopyLog "WhatIf summary: Would process $totalToCopy files across $($fileGroups.Count) categories." 'INFO'
    }
    
    # Process each group
    $swCopy = [System.Diagnostics.Stopwatch]::StartNew()
    $processedCount = 0
    $errorCount = 0
    $skippedCount = 0
    
    # Decide whether to process in parallel based on config (default is 1 = sequential)
    try { $parallelism = (Get-MediaCopyConfig).DefaultCategoryParallelism } catch { $parallelism = 1 }
    if ($parallelism -lt 1) { $parallelism = 1 }
    
    if ($parallelism -gt 1 -and $fileGroups.Count -gt 1) {
        Write-MediaCopyLog "Processing $($fileGroups.Count) categories in parallel (throttle=$parallelism)" 'INFO'
        
        # Use ForEach-Object -Parallel (PowerShell 7+) with explicit module imports per runspace
        $fileGroups | ForEach-Object -ThrottleLimit $parallelism -Parallel {
            $group = $_
            $retries = $using:Retries
            $continue = $using:Continue
            $threads = $using:Threads
            $batch = $using:Batch
            $modulePath = $using:modulePath
            
            # Import modules in parallel runspace
            Import-Module (Join-Path -Path $modulePath -ChildPath 'Logging.psm1') -Force -ErrorAction SilentlyContinue
            Import-Module (Join-Path -Path $modulePath -ChildPath 'CopyOps.psm1') -Force -ErrorAction SilentlyContinue
            Import-Module (Join-Path -Path $modulePath -ChildPath 'Index.psm1') -Force -ErrorAction SilentlyContinue
            Import-Module (Join-Path -Path $modulePath -ChildPath 'ExtensionMap.psm1') -Force -ErrorAction SilentlyContinue
            
            try {
                Write-MediaCopyLog "Processing category '$($group.Category)' ($($group.Count) files)..." 'INFO'
                Invoke-MediaCopyFlushGroup -Group $group -Retries $retries -Continue $continue -Threads $threads -Batch $batch
                Write-MediaCopyLog "Category complete: '$($group.Category)' ($($group.Count) files)." 'INFO'
            }
            catch {
                Write-MediaCopyLog "Failed to process group '$($group.Category)': $_" 'ERROR'
                if (-not $continue) { throw }
            }
        }
        
        # Aggregate counts after parallel execution
        foreach ($group in $fileGroups) {
            $processedCount += $group.Count
        }
    }
    else {
        # Sequential processing (original path)
        foreach ($group in $fileGroups) {
            Write-MediaCopyLog "Processing category '$($group.Category)' ($($group.Count) files)..." 'INFO'
            
            # Ensure destination directory exists
            New-MediaCopyDirectoryIfNotExist -Path $group.DestinationDir
            
            try {
                Invoke-MediaCopyFlushGroup -Group $group -Retries $Retries -Continue $Continue -Threads $Threads -Batch $Batch
                $processedCount += $group.Count
                Write-MediaCopyLog "Category complete: '$($group.Category)' ($($group.Count) files)." 'INFO'
            }
            catch {
                $errorCount += $group.Count
                Write-MediaCopyLog "Failed to process group '$($group.Category)': $_" 'ERROR'
                # Capture error details for summary
                $script:ErrorRecords.Add([PSCustomObject]@{
                    Category      = $group.Category
                    Extension     = $group.Extension
                    Destination   = $group.DestinationDir
                    FileCount     = $group.Count
                    Error         = $_.Exception.Message
                }) | Out-Null
                if (-not $Continue) {
                    throw
                }
            }

            # Progress indicator (console) and log to file
            $percentComplete = if ($totalFiles -gt 0) { [math]::Round(($processedCount / $totalFiles) * 100, 2) } else { 100 }
            Write-Progress -Activity "Copying Files" -Status "Processed $processedCount of $totalFiles files ($percentComplete%)" -PercentComplete $percentComplete
            Write-MediaCopyLog "Progress: $processedCount/$totalFiles files ($percentComplete%) processed; Errors so far: $errorCount" 'INFO'
        }
    }
    
    Write-Progress -Activity "Copying Files" -Completed
    $swCopy.Stop(); $script:Perf.CopyMs = $swCopy.ElapsedMilliseconds

    # Error summary (if any)
    if ($script:ErrorRecords.Count -gt 0) {
        Write-MediaCopyLog "Error summary: $($script:ErrorRecords.Count) group-level errors encountered." 'ERROR'
        # Group similar errors by message for concise summary
        $byMessage = $script:ErrorRecords | Group-Object -Property Error | Sort-Object -Property Count -Descending
        $top = $byMessage | Select-Object -First 10
        foreach ($g in $top) {
            Write-MediaCopyLog (" - Error '" + $g.Name + "' occurred in " + $g.Count + " groups") 'ERROR'
        }
    }

    $swTotal.Stop(); $script:Perf.TotalMs = $swTotal.ElapsedMilliseconds
    Write-MediaCopyLog "Processing complete. Processed: $processedCount, Errors: $errorCount, Skipped: $skippedCount" 'INFO'
    Write-MediaCopyLog ("Performance: total={0}ms, scan={1}ms, group={2}ms, copy={3}ms" -f $script:Perf.TotalMs,$script:Perf.ScanMs,$script:Perf.GroupMs,$script:Perf.CopyMs) 'DEBUG'
    
    # Write baseline entry
    try {
        Write-MediaCopyBaseline -Metrics $script:Perf
        $baselineStats = Get-MediaCopyBaselineStats
        if ($baselineStats) {
            Write-MediaCopyLog ("Baseline stats (n={0}): avg={1}ms, min={2}ms, max={3}ms, stddev={4}ms" -f $baselineStats.Count, [math]::Round($baselineStats.TotalMs.Mean,0), $baselineStats.TotalMs.Min, $baselineStats.TotalMs.Max, [math]::Round($baselineStats.TotalMs.StdDev,0)) 'DEBUG'
        }
    } catch { }
}

try {
    if (-not (Test-MediaCopyElevation)) {
        Invoke-MediaCopyElevationRestart -ScriptPath $PSCommandPath -SourcePath $Source -DestinationPath $Destination -LogPath $LogFile -MapPath $ExtensionMapPath -Batch $BatchSize -Retries $MaxRetries -Threads $RobocopyThreads -Continue $script:ContinueOnFailure
    }

    # Attempt to enable long path support if needed (with user consent)
    Enable-MediaCopyLongPathSupport

    Confirm-MediaCopyInput -SourcePath $Source -DestinationPath $Destination -LogPath $LogFile -MapPath $ExtensionMapPath
    
    # Acquire exclusive lock for this destination
    $script:Mutex = Get-MediaCopyLock -DestinationRoot $script:DestinationRoot
    
    Write-MediaCopyLog "Starting copy from '$script:SourceRoot' to '$script:DestinationRoot'." 'INFO'
    Write-MediaCopyAudit -Event 'copy_start' -Data @{ source = $script:SourceRoot; destination = $script:DestinationRoot; batch = $BatchSize; retries = $MaxRetries; threads = $RobocopyThreads; continue = $script:ContinueOnFailure }

    Invoke-MediaCopyProcessing -SourceRoot $script:SourceRoot -Batch $BatchSize -Retries $MaxRetries -Continue $script:ContinueOnFailure -Threads $RobocopyThreads

    Write-MediaCopyLog 'Copy completed successfully.' 'INFO'
    Write-MediaCopyAudit -Event 'copy_complete' -Data @{ total = $script:Perf.TotalFiles; toCopy = $script:Perf.ToCopy; perf = $script:Perf }
}
catch {
    Write-MediaCopyLog "Script failed: $_" 'ERROR'
    throw
}
finally {
    # Always release the mutex lock
    Remove-MediaCopyLock -Mutex $script:Mutex
}
