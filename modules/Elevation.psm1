function Test-MediaCopyElevation {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Invoke-MediaCopyElevationRestart {
    param(
            [Parameter(Mandatory=$true)][string]$ScriptPath,
        [string]$SourcePath,
        [string]$DestinationPath,
        [string]$LogPath,
        [string]$MapPath,
        [int]$Batch,
        [int]$Retries,
        [int]$Threads,
        [bool]$Continue
    )

    $hostPath = (Get-Process -Id $PID).Path
    if (-not $hostPath) {
        $hostPath = (Join-Path -Path $PSHOME -ChildPath 'pwsh.exe')
    }

    $argumentList = @(
        '-NoProfile',
        '-ExecutionPolicy', 'Bypass',
            '-File', '"' + $ScriptPath + '"',
        '-Source', "`"$SourcePath`"",
        '-Destination', "`"$DestinationPath`"",
        '-LogFile', "`"$LogPath`"",
        '-ExtensionMapPath', "`"$MapPath`"",
        '-BatchSize', $Batch,
        '-MaxRetries', $Retries,
        '-RobocopyThreads', $Threads
    )

    if ($Continue) {
        $argumentList += '-ContinueOnFailure'
    }

    $process = Start-Process -FilePath $hostPath -ArgumentList $argumentList -Verb RunAs -Wait -PassThru
    if ($null -ne $process) {
        exit $process.ExitCode
    }
    exit 1
}

Export-ModuleMember -Function Test-MediaCopyElevation,Invoke-MediaCopyElevationRestart
