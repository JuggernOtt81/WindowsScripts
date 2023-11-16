# Define source and destination paths
$sourcePath = "<source path>"
$destinationPath = "<destination path>"

# Define log directory and format the log file name with date and time
# log directory should be a directory that is on the machine that is recieving the files
$logDirectory = "<log directory>"
$logFileName = "RobocopyLog-{0:yyyyMMdd-HHmm}" -f (Get-Date)

# Combine log directory and file name
$logFilePath = [System.IO.Path]::Combine($logDirectory, $logFileName)

# Create log directory if not exist
if (-not (Test-Path $logDirectory)) {
    New-Item -ItemType Directory -Path $logDirectory | Out-Null
}

# Run robocopy command without /PURGE
$robocopyOptions = "/E /COPY:DAT /DCOPY:T /XO /FFT /LOG+:`"$logFilePath.txt`" /NP"
Start-Process "robocopy" -ArgumentList "`"$sourcePath`" `"$destinationPath`" * $robocopyOptions" -Wait

# Create a shortcut to the log file in the specified directory with the same filename structure
# shortcut directory should be a directory that is on the machine that is running the script
$shortcutDirectory = "<shortcut directory>"
$counter = 1

# Check if the log file already exists and increment the counter accordingly
while (Test-Path (Join-Path -Path $shortcutDirectory -ChildPath "RobocopyLog-$logFileName-$counter.lnk")) {
    $counter++
}

# Create the log file shortcut
$shortcutFilePath = Join-Path -Path $shortcutDirectory -ChildPath "RobocopyLog-$logFileName-$counter.lnk"
$shell = New-Object -ComObject WScript.Shell
$shortcut = $shell.CreateShortcut($shortcutFilePath)
$shortcut.TargetPath = "$logFilePath.txt"
$shortcut.Save()


