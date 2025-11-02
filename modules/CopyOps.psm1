# Module-level variable to track destination file names
$script:DestNameTracker = $null

function Set-MediaCopyDestTracker {
    param([Parameter(Mandatory = $true)]$Tracker)
    $script:DestNameTracker = $Tracker
}

function Get-MediaCopyHashSuffix {
    param([Parameter(Mandatory = $true)][System.IO.FileInfo]$File)
    
    try {
        # Use fast hash of file path + size + last write time for uniqueness
        $hashInput = "$($File.FullName.ToLowerInvariant())|$($File.Length)|$($File.LastWriteTimeUtc.Ticks)"
        $hash = [System.Security.Cryptography.SHA256]::Create().ComputeHash([System.Text.Encoding]::UTF8.GetBytes($hashInput))
        $hashString = [System.BitConverter]::ToString($hash).Replace('-', '').Substring(0, 8)
        return "_$hashString"
    }
    catch {
        # Fallback to timestamp-based suffix
        return "_$(Get-Date -Format 'yyyyMMddHHmmss')"
    }
}

function Resolve-MediaCopyTargetName {
    param(
        [string]$DestDir,
        [System.IO.FileInfo]$File
    )
    
    $baseName = $File.BaseName
    $extension = $File.Extension
    $targetPath = Join-Path -Path $DestDir -ChildPath $File.Name
    
    # Check if target already exists or is tracked
    if (-not $script:DestNameTracker.Contains($targetPath) -and -not (Test-Path -LiteralPath $targetPath)) {
        $script:DestNameTracker.Add($targetPath) | Out-Null
        return $File.Name
    }
    
    # File exists or name collision - add hash suffix
    $attempt = 0
    do {
        $hashSuffix = Get-MediaCopyHashSuffix -File $File
        if ($attempt -gt 0) {
            $hashSuffix += "_$attempt"
        }
        $newName = "$baseName$hashSuffix$extension"
        $targetPath = Join-Path -Path $DestDir -ChildPath $newName
        $attempt++
    } while (($script:DestNameTracker.Contains($targetPath) -or (Test-Path -LiteralPath $targetPath)) -and $attempt -lt 1000)
    
    if ($attempt -ge 1000) {
        throw "Could not resolve unique name for file: $($File.Name)"
    }
    
    $script:DestNameTracker.Add($targetPath) | Out-Null
    return $newName
}

function Invoke-MediaCopyBatchCopy {
    param(
        [string]$SourceDir,
        [string]$DestDir,
        [string[]]$FileNames,
        [string]$Extension,
        [int]$Retries,
        [bool]$Continue,
        [int]$Threads
    )
    
    if ($FileNames.Count -eq 0) { return }
    
    try {
        # Build robocopy arguments
        $robocopyArgs = @(
            $SourceDir
            $DestDir
        )
        
        # Add file names (file names only, no paths)
        $robocopyArgs += $FileNames
        
        # Add robocopy options (no delete/mirror flags used)
        $options = @(
            "/NFL"  # No file list
            "/NDL"  # No directory list
            "/NJH"  # No job header
            "/NJS"  # No job summary
            "/R:$Retries"
            "/W:1"  # Wait 1 second between retries
            "/MT:$Threads"
            "/XO"   # Skip older files if they exist
        )

        # Append robocopy logs to the main log file if available via Logging module
        try {
            if (Get-Command -Name Get-MediaCopyLogPath -ErrorAction SilentlyContinue) {
                $logPath = Get-MediaCopyLogPath
                if ($logPath -and $logPath.Trim()) { $options += "/LOG+:$logPath" }
            }
        } catch { }

        $robocopyArgs += $options

        # Validate inputs before executing
        if ([string]::IsNullOrWhiteSpace($SourceDir) -or -not (Test-Path -LiteralPath $SourceDir)) {
            throw "Invalid source directory for batch copy: '$SourceDir'"
        }
        if ([string]::IsNullOrWhiteSpace($DestDir)) {
            throw "Invalid destination directory for batch copy: '$DestDir'"
        }

        # Log a concise preview for diagnostics
        $previewFiles = ($FileNames | Select-Object -First 3) -join ', '
        Write-MediaCopyLog "Robocopy args preview: '$SourceDir' '$DestDir' [$previewFiles]" 'INFO'

        # Resolve robocopy path and execute with reliable quoting
        $robocopyExe = (Get-Command robocopy.exe -ErrorAction SilentlyContinue).Source
        if (-not $robocopyExe) { $robocopyExe = "robocopy.exe" }

        & $robocopyExe @robocopyArgs
        $exitCode = $LASTEXITCODE
        
        # Robocopy exit codes: 0-7 are success, 8+ are errors
        # Provide detailed, actionable descriptions for diagnostics
        function Get-RobocopyExitDescription([int]$code) {
            switch ($code) {
                0 { 'No files copied. Source and destination are already in sync.' }
                1 { 'All files copied successfully.' }
                2 { 'Extra files or directories detected. No files copied.' }
                3 { 'Files copied successfully and extra files detected.' }
                4 { 'Some mismatched files or directories detected.' }
                5 { 'Files copied successfully and mismatches detected.' }
                6 { 'Mismatches and extra files detected (some files may be out of sync).' }
                7 { 'Files copied, mismatches detected, and extra files present.' }
                8 { 'Some files or directories could not be copied (e.g., in use or permission denied).' }
                16 { 'Serious error: robocopy did not execute properly.' }
                default { "Unknown robocopy exit code: $code" }
            }
        }

        switch ($exitCode) {
            0 { Write-MediaCopyLog ("Robocopy: {0}" -f (Get-RobocopyExitDescription 0)) 'INFO' }
            1 { Write-MediaCopyLog ("Robocopy: {0} ({1} files)" -f (Get-RobocopyExitDescription 1), $FileNames.Count) 'INFO' }
            2 { Write-MediaCopyLog ("Robocopy: {0}" -f (Get-RobocopyExitDescription 2)) 'INFO' }
            3 { Write-MediaCopyLog ("Robocopy: {0}" -f (Get-RobocopyExitDescription 3)) 'INFO' }
            4 { Write-MediaCopyLog ("Robocopy: {0}" -f (Get-RobocopyExitDescription 4)) 'WARN' }
            5 { Write-MediaCopyLog ("Robocopy: {0}" -f (Get-RobocopyExitDescription 5)) 'WARN' }
            6 { Write-MediaCopyLog ("Robocopy: {0}" -f (Get-RobocopyExitDescription 6)) 'WARN' }
            7 { Write-MediaCopyLog ("Robocopy: {0}" -f (Get-RobocopyExitDescription 7)) 'WARN' }
            8 {
                $errorMsg = "Robocopy: $(Get-RobocopyExitDescription 8) for extension '$Extension' (exit code: 8)"
                Write-MediaCopyLog $errorMsg 'WARN'
                if (-not $Continue) { throw $errorMsg }
            }
            16 {
                $errorMsg = "Robocopy: $(Get-RobocopyExitDescription 16) for extension '$Extension' (exit code: 16)"
                Write-MediaCopyLog $errorMsg 'ERROR'
                if (-not $Continue) { throw $errorMsg }
            }
            default {
                $errorMsg = "Robocopy failed with exit code $exitCode for extension '$Extension'"
                Write-MediaCopyLog $errorMsg 'ERROR'
                if (-not $Continue) { throw $errorMsg }
            }
        }
        
        # Append to index for successfully copied files
        if ($exitCode -lt 8) {
            foreach ($name in $FileNames) {
                $destPath = Join-Path -Path $DestDir -ChildPath $name
                $srcPath = Join-Path -Path $SourceDir -ChildPath $name
                if (Test-Path -LiteralPath $destPath) {
                    try {
                        $srcInfo = [System.IO.FileInfo]::new($srcPath)
                        Add-MediaCopyIndexEntry -SourceFile $srcInfo -DestFullPath $destPath
                    } catch {}
                }
            }
        }
    }
    catch {
        Write-MediaCopyLog "Batch copy failed: $_" 'ERROR'
        if (-not $Continue) { throw }
    }
}

function Copy-MediaCopyManualFile {
    param(
        [System.IO.FileInfo]$SourceFile,
        [string]$DestDir,
        [string]$TargetName,
        [int]$Retries,
        [bool]$Continue
    )
    
    $destPath = Join-Path -Path $DestDir -ChildPath $TargetName
    $attempt = 0
    $lastError = $null
    
    while ($attempt -lt $Retries) {
        try {
            # Perform the copy; Copy-Item will honor WhatIf/Confirm preferences set by the caller
            Copy-Item -LiteralPath $SourceFile.FullName -Destination $destPath -Force -ErrorAction Stop
            Write-MediaCopyLog "Copied: $($SourceFile.Name) -> $TargetName" 'INFO'
            # Update index
            Add-MediaCopyIndexEntry -SourceFile $SourceFile -DestFullPath $destPath
            return $true
        }
        catch {
            $attempt++
            $lastError = $_
            
            # Check if error is permanent (permissions, disk full, etc.)
            if ($_.Exception.Message -match 'Access.*denied|Unauthorized|disk.*full|insufficient') {
                Write-MediaCopyLog "Permanent error copying $($SourceFile.Name): $_" 'ERROR'
                if (-not $Continue) { throw }
                return $false
            }
            
            if ($attempt -lt $Retries) {
                Write-MediaCopyLog "Retry $attempt of $Retries for $($SourceFile.Name): $_" 'WARN'
                Start-Sleep -Seconds 1
            }
        }
    }
    
    Write-MediaCopyLog "Failed to copy $($SourceFile.Name) after $Retries attempts: $lastError" 'ERROR'
    if (-not $Continue) { throw $lastError }
    return $false
}

function Invoke-MediaCopyFlushGroup {
    param(
        [pscustomobject]$Group,
        [int]$Retries,
        [bool]$Continue,
        [int]$Threads,
        [int]$Batch
    )
    
    $files = $Group.Files
    $destDir = $Group.DestinationDir
    
    if ($files.Count -eq 0) { return }
    
    # Ensure destination directory exists for both robocopy and manual copy paths (covers parallel paths too)
    if (-not (Test-Path -LiteralPath $destDir)) {
        try {
            New-Item -Path $destDir -ItemType Directory -Force | Out-Null
            Write-MediaCopyLog "Created directory: $destDir" 'INFO'
        } catch {
            Write-MediaCopyLog "Failed to create directory: $destDir - $_" 'ERROR'
            if (-not $Continue) { throw }
        }
    }
    
    # For small batches or files that need renaming, copy individually
    # For large batches of same-named files, use robocopy
    
    $filesNeedingRename = @()
    $filesForBatch = @()
    
    foreach ($file in $files) {
        $targetName = Resolve-MediaCopyTargetName -DestDir $destDir -File $file

        # Robocopy treats tokens beginning with '-' or '/' as switches; handle such names via manual copy
        $looksLikeSwitch = $file.Name.StartsWith('-') -or $file.Name.StartsWith('/')
        if ($looksLikeSwitch) {
            $filesNeedingRename += @{
                Source     = $file
                TargetName = $file.Name
            }
            continue
        }

        if ($targetName -ne $file.Name) {
            # File needs rename - copy manually
            $filesNeedingRename += @{
                Source     = $file
                TargetName = $targetName
            }
        }
        else {
            # File can be batch copied
            $filesForBatch += $file
        }
    }
    
    # Batch copy files that don't need renaming
    if ($filesForBatch.Count -gt 0) {
        # Group by parent directory for efficient robocopy
        $bySourceDir = $filesForBatch | Group-Object -Property { $_.DirectoryName }
        
        foreach ($dirGroup in $bySourceDir) {
            $sourceDir = $dirGroup.Name
            $fileNamesAll = $dirGroup.Group | ForEach-Object { $_.Name }

            # Split into batches based on requested Batch size (default honored upstream)
            $batchSize = if ($Batch -gt 0) { $Batch } else { 50 }
            for ($i = 0; $i -lt $fileNamesAll.Count; $i += $batchSize) {
                $chunk = $fileNamesAll[$i..([math]::Min($i + $batchSize - 1, $fileNamesAll.Count - 1))]
                Invoke-MediaCopyBatchCopy -SourceDir $sourceDir -DestDir $destDir -FileNames $chunk -Extension $Group.Extension -Retries $Retries -Continue $Continue -Threads $Threads
            }
        }
    }
    
    # Manually copy files that need renaming
    foreach ($item in $filesNeedingRename) {
        Copy-MediaCopyManualFile -SourceFile $item.Source -DestDir $destDir -TargetName $item.TargetName -Retries $Retries -Continue $Continue
    }
}

Export-ModuleMember -Function Set-MediaCopyDestTracker,Set-MediaCopyLogPath,Get-MediaCopyHashSuffix,Resolve-MediaCopyTargetName,Invoke-MediaCopyBatchCopy,Copy-MediaCopyManualFile,Invoke-MediaCopyFlushGroup
