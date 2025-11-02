# Track Event Log writes to throttle excessive logging
$script:EventLogWriteCount = 0
$script:EventLogLastReset = Get-Date
$script:EventLogMaxPerMinute = 10
$script:EventLogSourceRegistered = $false
$script:LogFilePath = $null
$script:AuditFilePath = $null

function Register-MediaCopyEventLogSource {
    param([string]$SourceName = 'MediaCopyScript')
    
    if ($script:EventLogSourceRegistered) {
        return $true
    }
    
    try {
        # Check if source exists
        if ([System.Diagnostics.EventLog]::SourceExists($SourceName)) {
            $script:EventLogSourceRegistered = $true
            return $true
        }
        
        # Try to create the source (requires admin rights)
        try {
            [System.Diagnostics.EventLog]::CreateEventSource($SourceName, 'Application')
            $script:EventLogSourceRegistered = $true
            Write-Verbose "Successfully registered Event Log source: $SourceName"
            return $true
        }
        catch [System.Security.SecurityException] {
            Write-Warning "Cannot register Event Log source '$SourceName' - insufficient permissions. Event logging will be skipped."
            return $false
        }
        catch [System.InvalidOperationException] {
            # Source might exist but under different log
            Write-Warning "Event Log source '$SourceName' exists under a different log. Event logging will be skipped."
            return $false
        }
    }
    catch {
        Write-Warning "Failed to register Event Log source: $_. Event logging will be skipped."
        return $false
    }
}

function Write-MediaCopyEventLog {
    param(
        [string]$Message,
        [System.Diagnostics.EventLogEntryType]$EntryType,
        [int]$EventId
    )
    
    # Throttle Event Log writes to prevent flooding
    $now = Get-Date
    if (($now - $script:EventLogLastReset).TotalSeconds -ge 60) {
        $script:EventLogWriteCount = 0
        $script:EventLogLastReset = $now
    }
    
    if ($script:EventLogWriteCount -ge $script:EventLogMaxPerMinute) {
        return  # Skip writing to Event Log if threshold exceeded
    }
    
    if (-not $script:EventLogSourceRegistered) {
        if (-not (Register-MediaCopyEventLogSource)) {
            return  # Can't write to Event Log
        }
    }
    
    try {
        Write-EventLog -LogName 'Application' -Source 'MediaCopyScript' -EntryType $EntryType -EventId $EventId -Message $Message
        $script:EventLogWriteCount++
    }
    catch {
        # Silently fail - don't disrupt main operation
        Write-Verbose "Failed to write to Event Log: $_"
    }
}

function Initialize-MediaCopyLogRotation {
    <#
    .SYNOPSIS
        Rotates log file if it exceeds maximum size.
    
    .DESCRIPTION
        Checks the log file size and moves it to an archived file if it exceeds
        the specified maximum size. This prevents unlimited log growth.
    
    .PARAMETER LogPath
        Path to the log file to check and potentially rotate.
    
    .PARAMETER MaxSizeMB
        Maximum size in megabytes before rotation. Default is 10MB.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$LogPath,
        
        [ValidateRange(1, 100)]
        [int]$MaxSizeMB = 10
    )
    
    if (-not (Test-Path -LiteralPath $LogPath)) {
        return  # Nothing to rotate
    }
    
    try {
        $logInfo = Get-Item -LiteralPath $LogPath -ErrorAction Stop
        $maxBytes = $MaxSizeMB * 1MB
        
        if ($logInfo.Length -gt $maxBytes) {
            $archivePath = "$LogPath.$(Get-Date -Format 'yyyyMMdd-HHmmss').old"
            Move-Item -LiteralPath $LogPath -Destination $archivePath -Force -ErrorAction Stop
            Write-Verbose "Rotated log file to: $archivePath"
            
            # Create new empty log file
            New-Item -Path $LogPath -ItemType File -Force | Out-Null
        }
    }
    catch {
        Write-Warning "Failed to rotate log file: $_"
    }
}

function Set-MediaCopyLogPath {
    <#
    .SYNOPSIS
        Sets the module-level log file path and initializes rotation if needed.
    
    .PARAMETER Path
        Path to the log file.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )
    
    $script:LogFilePath = $Path
    
    # Perform log rotation check when setting the path
    Initialize-MediaCopyLogRotation -LogPath $Path -MaxSizeMB 10
}

function Get-MediaCopyLogPath {
    <#
    .SYNOPSIS
        Returns the current log file path used by the Logging module.
    #>
    [CmdletBinding()] param()
    return $script:LogFilePath
}

function Set-MediaCopyAuditPath {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Path)
    $script:AuditFilePath = $Path
}

function Write-MediaCopyAudit {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Event,
        [hashtable]$Data
    )
    try {
        if (-not $script:AuditFilePath) { return }
        $record = [ordered]@{
            ts    = (Get-Date).ToUniversalTime().ToString('o')
            event = $Event
            data  = $Data
        }
        $json = $record | ConvertTo-Json -Depth 5 -Compress
        Add-Content -LiteralPath $script:AuditFilePath -Value $json -Encoding UTF8
    } catch {
        Write-Verbose "Failed to write audit record: $_"
    }
}

function Write-MediaCopyLog {
    param(
        [Parameter(Mandatory = $true)][string]$Message,
        [ValidateSet('TRACE','DEBUG','INFO','WARN','ERROR')][string]$Level = 'INFO'
    )

    # Try to capture the caller context for better diagnostics
    $ctxText = $null
    try {
        $stack = Get-PSCallStack
        if ($stack -and $stack.Count -gt 1) {
            $caller = $stack[1]
            # $func assignment removed; use inline below if needed
            $line = $caller.ScriptLineNumber
            $ctxText = "[" + [System.IO.Path]::GetFileName($caller.ScriptName) + ":" + $line + " " + $func + "]"
        }
    } catch { }

    $timestamp = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
    $msgWithCtx = if ($ctxText) { "$ctxText $Message" } else { $Message }
    $entry = "[$timestamp] [$Level] $msgWithCtx"

    # Write to file log
    if ($script:LogFilePath -and (Test-Path -LiteralPath $script:LogFilePath)) {
        try {
            Add-Content -LiteralPath $script:LogFilePath -Value $entry -Encoding UTF8
        }
        catch {
            Write-Warning "Failed to write to log file: $_"
        }
    }

    # Write to console
    switch ($Level) {
        'TRACE' { Write-Debug $Message }
        'DEBUG' { Write-Verbose $Message }
        'ERROR' {
            Write-Error $Message
            # Write to Event Log for errors only
            Write-MediaCopyEventLog -Message $Message -EntryType Error -EventId 1001
        }
        'WARN'  { 
            Write-Warning $Message 
            # Optionally log warnings to Event Log (less critical)
            if ($script:EventLogWriteCount -lt ($script:EventLogMaxPerMinute / 2)) {
                Write-MediaCopyEventLog -Message $Message -EntryType Warning -EventId 1002
            }
        }
        default { 
            Write-Information -MessageData $Message -Tags 'MediaCopy' -InformationAction Continue 
        }
    }
}

Export-ModuleMember -Function Write-MediaCopyLog,Register-MediaCopyEventLogSource,Initialize-MediaCopyLogRotation,Set-MediaCopyLogPath,Get-MediaCopyLogPath,Set-MediaCopyAuditPath,Write-MediaCopyAudit
