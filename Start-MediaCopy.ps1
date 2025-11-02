<#
.SYNOPSIS
    Interactive launcher for Media Copy Script

.DESCRIPTION
    Prompts the user for source, destination, and optional settings, then calls robocopy.ps1.
    Designed to be launched from Start-MediaCopy.bat or directly.
#>
[CmdletBinding()]
param(
    [string]$Source,
    [string]$Destination,
    [string]$LogFile,
    [string]$ExtensionMapPath,
    [int]$BatchSize,
    [int]$MaxRetries,
    [int]$RobocopyThreads,
    [switch]$ContinueOnFailure,
    [switch]$WhatIf,
    [switch]$UseDefaults
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Write-Host "`n=== Media Copy Interactive Launcher ===" -ForegroundColor Cyan
Write-Host "PowerShell Version: $($PSVersionTable.PSVersion)" -ForegroundColor Gray
Write-Host "Script Path: $PSCommandPath" -ForegroundColor Gray
Write-Host ""

function Read-NonEmpty([string]$prompt, [string]$default=$null) {
    while ($true) {
        $val = Read-Host -Prompt ($default ? "$prompt [$default]" : $prompt)
        if ([string]::IsNullOrWhiteSpace($val)) {
            if ($default) { return $default }
        } else { return $val }
    }
}

# Setup defaults
$scriptDir = Split-Path -Parent $PSCommandPath
Write-Host "Script Directory: $scriptDir" -ForegroundColor Gray
$defaultSource = 'D:\'
$defaultDestination = 'G:\'
$defaultLogFile = Join-Path $scriptDir 'logs\mediacopy.log'
$defaultMap = Join-Path $scriptDir 'extensions.xml'
$defaultBatch = 10
$defaultRetries = 2
$defaultThreads = 6
$defaultContinue = $false

# Initialize $cont early to avoid uninitialized variable issues
$cont = $defaultContinue
$skipPrompts = $false

# Log received parameters
Write-Host "Received Parameters:" -ForegroundColor Gray
Write-Host "  Source: $(if ($Source) { $Source } else { '(not set)' })" -ForegroundColor Gray
Write-Host "  Destination: $(if ($Destination) { $Destination } else { '(not set)' })" -ForegroundColor Gray
Write-Host "  UseDefaults: $UseDefaults" -ForegroundColor Gray
Write-Host ""

# Ask if user wants to use defaults
if (-not $UseDefaults -and -not $PSBoundParameters.ContainsKey('Source')) {
    Write-Host "Default settings available:" -ForegroundColor Yellow
    Write-Host "  Source      : $defaultSource"
    Write-Host "  Destination : $defaultDestination"
    Write-Host "  LogFile     : $defaultLogFile"
    Write-Host "  Batch       : $defaultBatch  Retries: $defaultRetries  Threads: $defaultThreads"
    Write-Host "  Continue    : $defaultContinue  WhatIf: False"
    Write-Host ""
    
    $defaultsChoice = Read-NonEmpty 'Use these defaults? (Y/n)' 'Y'
    if ($defaultsChoice -match '^(y|yes|)$') {
        $Source = $defaultSource
        $Destination = $defaultDestination
        $LogFile = $defaultLogFile
        $ExtensionMapPath = $defaultMap
        $BatchSize = $defaultBatch
        $MaxRetries = $defaultRetries
        $RobocopyThreads = $defaultThreads
        $cont = $defaultContinue  # Boolean, not switch
        
        Write-Host "`n" -NoNewline
        $proceed = Read-Host -Prompt "Using defaults. Proceed? (Y/n)"
        if (-not $proceed) { $proceed = 'Y' }  # Treat empty as Y
        if ($proceed -notmatch '^(y|yes)$') {
            Write-Host "Cancelled." -ForegroundColor Yellow
            exit 0
        }
        
        # Skip to execution
        $skipPrompts = $true
    } else {
        $skipPrompts = $false
    }
} else {
    $skipPrompts = $false
}

# Prompt for values if not using defaults
if (-not $skipPrompts) {
    if (-not $Source) { $Source = Read-NonEmpty 'Enter source directory' $defaultSource }
    if (-not $Destination) { $Destination = Read-NonEmpty 'Enter destination directory' $defaultDestination }
    
    # Handle log file - accept directory or file path
    if (-not $LogFile) {
        $logInput = Read-NonEmpty 'Enter log file path (file or directory)' $defaultLogFile
        # Check if it's a directory or file path
        if ($logInput -notmatch '\.(log|txt)$' -and -not $logInput.Contains('\')) {
            # Looks like just a filename, prepend logs directory
            $LogFile = Join-Path (Join-Path $scriptDir 'logs') $logInput
        } elseif (Test-Path -Path $logInput -PathType Container -ErrorAction SilentlyContinue) {
            # It's a directory, add default filename
            $LogFile = Join-Path $logInput 'mediacopy.log'
        } elseif ($logInput -match '\\$') {
            # Ends with backslash, treat as directory
            $LogFile = Join-Path $logInput 'mediacopy.log'
        } else {
            # Treat as full file path
            $LogFile = $logInput
        }
    }
    
    if (-not $ExtensionMapPath) { $ExtensionMapPath = Read-NonEmpty 'Extension map path' $defaultMap }
    
    if ($BatchSize -eq 0) {
        $BatchSize = [int](Read-NonEmpty 'Batch size' $defaultBatch.ToString())
    }
    if ($MaxRetries -eq 0) {
        $MaxRetries = [int](Read-NonEmpty 'Max retries' $defaultRetries.ToString())
    }
    if ($RobocopyThreads -eq 0) {
        $RobocopyThreads = [int](Read-NonEmpty 'Robocopy threads (/MT)' $defaultThreads.ToString())
    }
    
    # Handle continue on failure
    if ($PSBoundParameters.ContainsKey('ContinueOnFailure')) {
        $cont = $ContinueOnFailure.IsPresent
    } else {
        $yn = Read-NonEmpty 'Continue on failure? (y/N)' 'N'
        $cont = $yn -match '^(y|yes)$'
    }
} else {
    # When using defaults, $cont is already set to $defaultContinue (boolean)
    # No action needed here
}

# Display final summary
Write-Host ''
Write-Host 'Summary:' -ForegroundColor Yellow
Write-Host "  Source      : $Source"
Write-Host "  Destination : $Destination"
Write-Host "  LogFile     : $LogFile"
Write-Host "  Map         : $ExtensionMapPath"
Write-Host "  Batch       : $BatchSize  Retries: $MaxRetries  Threads: $RobocopyThreads"
$whatIfStatus = if ($WhatIf) { $WhatIf.IsPresent } else { $false }
Write-Host "  Continue    : $cont  WhatIf: $whatIfStatus"

if (-not $skipPrompts) {
    $confirm = Read-NonEmpty 'Proceed? (Y/n)' 'Y'
    if ($confirm -notmatch '^(y|yes|)$') {
        Write-Host 'Cancelled.' -ForegroundColor Yellow
        exit 0
    }
}

# Ensure log directory exists
$logDir = Split-Path -Parent $LogFile
if ($logDir -and -not (Test-Path -Path $logDir)) {
    Write-Host "Creating log directory: $logDir" -ForegroundColor Cyan
    New-Item -Path $logDir -ItemType Directory -Force | Out-Null
}

# Build argument list for robocopy.ps1

$entry = Join-Path $scriptDir 'robocopy.ps1'
$argsList = @{
    Source = $Source
    Destination = $Destination
    LogFile = $LogFile
    ExtensionMapPath = $ExtensionMapPath
    BatchSize = $BatchSize
    MaxRetries = $MaxRetries
    RobocopyThreads = $RobocopyThreads
}
if ($cont) {
    Write-Host "Adding -ContinueOnFailure switch" -ForegroundColor Gray
    $argsList["ContinueOnFailure"] = $true
}
if ($WhatIf -and $WhatIf.IsPresent) {
    Write-Host "Adding -WhatIf switch" -ForegroundColor Gray
    $argsList["WhatIf"] = $true
}

Write-Host "`nLaunching robocopy.ps1..." -ForegroundColor Cyan
Write-Host "Target script: $entry" -ForegroundColor Gray
Write-Host "Script exists: $(Test-Path $entry)" -ForegroundColor Gray

Write-Host "Debug - Args count: $($argsList.Keys.Count)" -ForegroundColor Gray
Write-Host "Arguments being passed:" -ForegroundColor Gray
foreach ($key in $argsList.Keys) {
    Write-Host "  $key = '$($argsList[$key])'" -ForegroundColor Gray
}
Write-Host ""

Write-Host "Invoking robocopy.ps1 with splatted arguments..." -ForegroundColor Cyan
try {
    & $entry @argsList
    $exitCode = $LASTEXITCODE
    Write-Host "robocopy.ps1 completed with exit code: $exitCode" -ForegroundColor $(if ($exitCode -eq 0) { 'Green' } else { 'Yellow' })
    exit $exitCode
} catch {
    Write-Host "ERROR: Failed to execute robocopy.ps1" -ForegroundColor Red
    Write-Host "Exception: $($_.Exception.Message)" -ForegroundColor Red
    Write-Host "Stack trace: $($_.ScriptStackTrace)" -ForegroundColor Red
    exit 1
}
