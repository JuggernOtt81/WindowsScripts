# Define source and destination directories
$sourceDirectory = "C:\Users\<user>\<path 1>"
$destinationRoot = "C:\Users\<user>\<path 2>"

# Define file categories and extensions
$categories = @{
    "SourceCode" = @{
        "SourceCodeAndConfig" = @(".aidl", ".class", ".cshtml", ".csproj", ".cs", ".js", ".mjs", ".py", ".ps1xml", ".psd1", ".psm1", ".xaml", ".gitconfig", ".eslintrc", ".editorconfig", ".eslintignore", ".prettierrc")
        "WebFiles" = @(".html", ".css", ".js", ".scss", ".sass", ".vue", ".jsx", ".cssmap", ".php", ".asp", ".xhtml", ".yaml", ".yml", ".twig", ".handlebars")
    }
    "BinaryFiles" = @{
        "CompiledFiles" = @(".bin", ".dex", ".dylib", ".o", ".so", ".wasm", ".a", ".lib", ".obj", ".pdb", ".jar", ".apk", ".dll")
        "ExecutableFiles" = @(".exe", ".apk", ".msi", ".bat", ".cmd", ".appx", ".ps1", ".jar", ".app", ".run", ".cgi", ".pl", ".sh")
    }
    "BackupAndArchiveFiles" = @{
        "Archives" = @(".backup", ".cab", ".tar", ".zip", ".pak", ".7z", ".rar", ".gz", ".xz", ".bz2", ".tgz", ".tar.gz")
        "TemporaryFiles" = @(".tmp", ".swp", ".bak", ".part", ".crdownload", ".lock", ".temp", ".session", ".swp")
    }
    "PackageAndDeploymentFiles" = @(".appinstaller", ".appxmanifest", ".appxrecipe", ".deploy", ".msix", ".pkg", ".msi", ".dmg", ".rpm", ".deb")
    "MultimediaFiles" = @{
        "Audio" = @(".mp3", ".wav", ".aac", ".flac", ".ogg", ".wma", ".3gp", ".m4a", ".opus", ".aiff", ".amr", ".ra", ".mid")
        "Images" = @(".jpg", ".jpeg", ".png", ".gif", ".bmp", ".tiff", ".ico", ".webp", ".raw", ".jpe", ".jfif", ".heic", ".xcf", ".svg", ".ai", ".psd", ".eps")
        "Video" = @(".3gp", ".mp4", ".avi", ".mkv", ".mov", ".wmv", ".webm", ".m4v", ".ts", ".flv", ".mpeg", ".mpg", ".swf", ".vob", ".ogv")
    }
    "DocumentFiles" = @(".docx", ".xlsx", ".pptx", ".ppt", ".pages", ".txt", ".rtf", ".xml", ".json", ".gdoc", ".gform", ".gsheet", ".gsite", ".pdf", ".odt", ".ods", ".odp", ".csv", ".md", ".tex", ".latex")
    "SystemAndConfigurationFiles" = @(".cfg", ".conf", ".properties", ".system", ".plist", ".env", ".lock", ".metadata", ".manifest", ".schema", ".ruleset", ".security", ".sys", ".ini", ".inf", ".iso")
    "DataFiles" = @(".csv", ".json", ".xml", ".sqlite", ".sqlite3", ".data", ".bin", ".proto", ".mdb", ".dat", ".log", ".mdf", ".ndjson", ".parquet", ".h5", ".avro")
    "FontFiles" = @(".ttf", ".otf", ".woff", ".woff2", ".eot", ".fon", ".fnt", ".ttc", ".otc")
    "VirtualMachineContainerFiles" = @(".qcow2", ".img", ".vmdk", ".vhd", ".vdi", ".raw")
    "SecurityFiles" = @(".pem", ".pfx", ".p12", ".key", ".crt", ".cer", ".p7s", ".asc", ".csr", ".jks", ".der", ".p8", ".pkcs12", ".pkcs7", ".crt", ".cert")
    "Miscellaneous" = @(".pdb", ".gitattributes", ".gitignore", ".gitkeep", ".searchconnector-ms", ".nuget", ".wslconfig", ".xsd", ".yml", ".yaml", ".nupkg", ".bundle", ".plugin", ".hpi", ".jar", ".xpi")
    "CADFiles" = @(".dwg", ".dxf", ".iges", ".stl", ".step", ".fbx", ".obj", ".3ds", ".blend", ".dae", ".x_t")
    "PresentationFiles" = @(".pptx", ".key", ".odp", ".revealjs", ".prezi")
    "SpreadsheetFiles" = @(".csv", ".xls", ".xlsx", ".ods", ".tsv", ".xlsm")
    "LogFiles" = @(".log", ".out", ".trace", ".dmp", ".stackdump", ".pid", ".core")
    "CloudAndServerConfig" = @(".json", ".yaml", ".yml", ".conf", ".ini", ".cfg", ".env", ".tf", ".tfvars", ".cloudformation", ".docker-compose")
    "FrontendFrameworks" = @(".vue", ".jsx", ".tsx", ".html", ".scss", ".less", ".styl")
    "ContainerImages" = @(".tar", ".img", ".iso", ".qcow2", ".vmdk")
    "GISFiles" = @(".shp", ".shx", ".dbf", ".gdb", ".kml", ".kmz", ".geojson", ".gpx", ".tif")
    "ScientificFiles" = @(".hdf5", ".fits", ".cif", ".mat", ".xls", ".xlsx", ".tsv")
    "GraphicDesignFiles" = @(".ai", ".psd", ".eps", ".svg", ".pdf", ".tiff", ".dxf", ".cdr")
    "3DModels" = @(".obj", ".fbx", ".stl", ".blend", ".dae", ".3ds", ".max", ".x3d", ".c4d", ".lwo")
    "VirtualizationFiles" = @(".vdi", ".vmdk", ".vhd", ".vhdx", ".vbox", ".iso")
    "GameDevelopmentFiles" = @(".unity", ".uasset", ".pak", ".gltf", ".obj", ".fbx", ".sln")
    "BackupFiles" = @(".bak", ".dmp", ".dfr", ".vhdx", ".hbk", ".iso")
    "ConfigManagementFiles" = @(".json", ".yml", ".rb", ".pp", ".pl", ".hcl", ".ini")
    "DiskPartitionFiles" = @(".vhd", ".vhdx", ".gpt", ".mbr", ".iso")
}

# Function to create directories for each category and subcategory
function Create-CategoryDirs {
    param (
        [string]$baseDir,
        [Hashtable]$categories
    )
    
    foreach ($category in $categories.Keys) {
        $categoryDir = Join-Path $baseDir $category
        if (-not (Test-Path -Path $categoryDir)) {
            New-Item -ItemType Directory -Force -Path $categoryDir
        }

        $subcategories = $categories[$category]
        if ($subcategories -is [Hashtable]) {
            foreach ($subcategory in $subcategories.Keys) {
                $subcategoryDir = Join-Path $categoryDir $subcategory
                if (-not (Test-Path -Path $subcategoryDir)) {
                    New-Item -ItemType Directory -Force -Path $subcategoryDir
                }
            }
        }
    }

    # Create a "LEFTOVERS" folder if it doesn't exist
    $leftoversDir = Join-Path $baseDir "LEFTOVERS"
    if (-not (Test-Path -Path $leftoversDir)) {
        New-Item -ItemType Directory -Force -Path $leftoversDir
    }
}

# Function to move files to the appropriate categories based on extensions
function Move-FilesToCategories {
    param (
        [string]$sourceDir,
        [string]$destinationRoot,
        [Hashtable]$categories
    )

    $leftoversDir = Join-Path $destinationRoot "LEFTOVERS"

    foreach ($file in Get-ChildItem -Path $sourceDir -Recurse -File) {
        $moved = $false
        
        foreach ($category in $categories.Keys) {
            $categoryDir = Join-Path $destinationRoot $category
            $subcategories = $categories[$category]

            if ($subcategories -is [Hashtable]) {
                foreach ($subcategory in $subcategories.Keys) {
                    $subcategoryDir = Join-Path $categoryDir $subcategory
                    foreach ($extension in $subcategories[$subcategory]) {
                        if ($file.Extension -eq $extension) {
                            $destination = Join-Path $subcategoryDir $file.Name
                            Move-Item -Path $file.FullName -Destination $destination -Force
                            Write-Host "Moved $($file.FullName) to $destination"
                            $moved = $true
                            break
                        }
                    }
                    if ($moved) { break }
                }
            } else {
                foreach ($extension in $subcategories) {
                    if ($file.Extension -eq $extension) {
                        $destination = Join-Path $categoryDir $file.Name
                        Move-Item -Path $file.FullName -Destination $destination -Force
                        Write-Host "Moved $($file.FullName) to $destination"
                        $moved = $true
                        break
                    }
                }
            }
            if ($moved) { break }
        }

        # If no category matched, move to LEFTOVERS
        if (-not $moved) {
            $destination = Join-Path $leftoversDir $file.Name
            Move-Item -Path $file.FullName -Destination $destination -Force
            Write-Host "Moved $($file.FullName) to LEFTOVERS"
        }
    }
}

# Function to delete empty folders
function Delete-EmptyFolders {
    param (
        [string]$directory
    )
    
    Get-ChildItem -Path $directory -Recurse -Directory | Sort-Object FullName -Descending | ForEach-Object {
        if (-not (Get-ChildItem -Path $_.FullName)) {
            Remove-Item -Path $_.FullName -Force
            Write-Host "Removed empty folder: $($_.FullName)"
        }
    }
}

# Function to organize files and clean up empty folders
function Organize-Files {
    param (
        [string]$sourceDir,
        [string]$destinationRoot,
        [Hashtable]$categories
    )

    try {
        Create-CategoryDirs -baseDir $destinationRoot -categories $categories
        Move-FilesToCategories -sourceDir $sourceDir -destinationRoot $destinationRoot -categories $categories
        Delete-EmptyFolders -directory $sourceDir
        Delete-EmptyFolders -directory $destinationRoot

        # Repeat until the source directory is empty
        while ((Get-ChildItem -Path $sourceDir).Count -gt 0) {
            Write-Host "Source directory is not empty, continuing to move files..."
            Move-FilesToCategories -sourceDir $sourceDir -destinationRoot $destinationRoot -categories $categories
            Delete-EmptyFolders -directory $sourceDir
            Delete-EmptyFolders -directory $destinationRoot
        }

        Write-Host "Organizing complete. Source directory is empty."
    } catch {
        Write-Error "An error occurred: $_"
    }
}

# Call Organize-Files with source and destination
Organize-Files -sourceDir $sourceDirectory -destinationRoot $destinationRoot -categories $categories
