# ExtensionMap.psm1 - File extension to category mapping module

# Module-level variable to store the extension map
$script:ExtensionMap = @{}

function Import-MediaCopyExtensionMap {
    <#
    .SYNOPSIS
        Imports extension-to-category mappings from an XML file.
    
    .DESCRIPTION
        Parses the extensions.xml file and creates a hashtable mapping file extensions to category names.
        Implements security measures to prevent XML injection and DoS attacks.
    
    .PARAMETER MapPath
        Path to the XML file containing extension mappings.
    
    .RETURNS
        Hashtable with extension as key and category name as value.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$MapPath
    )
    
    if (-not (Test-Path -LiteralPath $MapPath)) {
        throw "Extension map file not found: $MapPath"
    }
    
    # Validate file size to prevent DoS attacks
    $fileInfo = Get-Item -LiteralPath $MapPath
    if ($fileInfo.Length -gt 10MB) {
        throw "Extension map file is too large (max 10MB): $($fileInfo.Length) bytes"
    }
    
    try {
        # Use secure XML reader settings to prevent injection attacks
        $settings = [System.Xml.XmlReaderSettings]::new()
        $settings.DtdProcessing = [System.Xml.DtdProcessing]::Prohibit
        $settings.XmlResolver = $null
        $settings.MaxCharactersFromEntities = 1024
        $settings.MaxCharactersInDocument = 10000000  # 10MB in characters
        
        $reader = [System.Xml.XmlReader]::Create($MapPath, $settings)
        try {
            [xml]$xml = [System.Xml.XmlDocument]::new()
            $xml.Load($reader)
        }
        finally {
            $reader.Close()
        }
        
        # Validate XML structure
        if (-not $xml.categories) {
            throw "Invalid XML: Missing 'categories' root element"
        }
        
        # Build the extension map
        $map = @{}
        $extensionCount = 0
        $duplicateCount = 0
        
        foreach ($category in $xml.categories.category) {
            $categoryName = $category.name
            
            if ([string]::IsNullOrWhiteSpace($categoryName)) {
                Write-Warning "Skipping category with empty name"
                continue
            }
            
            foreach ($ext in $category.ext) {
                $extName = $ext.name
                
                if ([string]::IsNullOrWhiteSpace($extName)) {
                    continue
                }
                
                # Normalize extension (lowercase, no leading dot)
                $extName = $extName.ToLowerInvariant().TrimStart('.')
                
                # Check for duplicates
                if ($map.ContainsKey($extName)) {
                    Write-Verbose "Duplicate extension '$extName': '$($map[$extName])' -> '$categoryName' (keeping first)"
                    $duplicateCount++
                    continue
                }
                
                $map[$extName] = $categoryName
                $extensionCount++
            }
        }
        
        if ($extensionCount -eq 0) {
            throw "No valid extensions found in XML file"
        }
        
        Write-Verbose "Loaded $extensionCount extensions from $($xml.categories.category.Count) categories"
        if ($duplicateCount -gt 0) {
            Write-Warning "Found $duplicateCount duplicate extension definitions (first occurrence kept)"
        }
        
        return $map
    }
    catch [System.Xml.XmlException] {
        throw "Failed to parse extension map XML: $($_.Exception.Message)"
    }
    catch {
        throw "Error loading extension map: $($_.Exception.Message)"
    }
}

function Set-MediaCopyExtensionMap {
    <#
    .SYNOPSIS
        Sets the module-level extension map for use by other functions.
    
    .DESCRIPTION
        Stores the extension map hashtable in module scope so Get-MediaCopyCategory can access it.
    
    .PARAMETER Map
        Hashtable containing extension-to-category mappings.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateNotNull()]
        [hashtable]$Map
    )
    
    $script:ExtensionMap = $Map
    Write-Verbose "Extension map set with $($Map.Count) entries"
}

function Get-MediaCopyCategory {
    <#
    .SYNOPSIS
        Gets the category name for a given file extension.
    
    .DESCRIPTION
        Looks up the category associated with a file extension.
        Returns 'uncategorized' if the extension is not mapped.
    
    .PARAMETER Extension
        File extension to look up (with or without leading dot).
    
    .RETURNS
        Category name as string.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string]$Extension
    )
    
    # Normalize extension
    $ext = $Extension.ToLowerInvariant().TrimStart('.')
    
    # Handle empty/whitespace extensions
    if ([string]::IsNullOrWhiteSpace($ext)) {
        return 'no_extension'
    }
    
    # Look up in map
    if ($script:ExtensionMap.ContainsKey($ext)) {
        return $script:ExtensionMap[$ext]
    }
    
    # Default category for unmapped extensions
    return 'uncategorized'
}

function Get-MediaCopySanitizedName {
    <#
    .SYNOPSIS
        Sanitizes a string to be safe for use as a directory/file name.
    
    .DESCRIPTION
        Removes or replaces invalid filesystem characters, normalizes spaces and underscores.
        Ensures the result is a valid Windows filename.
    
    .PARAMETER Value
        String to sanitize.
    
    .RETURNS
        Sanitized string safe for filesystem use.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string]$Value
    )
    
    if ([string]::IsNullOrWhiteSpace($Value)) {
        return 'unnamed'
    }
    
    $sanitized = $Value.Trim()
    
    # Get invalid filename characters
    $invalidChars = [System.IO.Path]::GetInvalidFileNameChars()
    
    # Replace each invalid character with underscore
    foreach ($char in $invalidChars) {
        $sanitized = $sanitized.Replace($char, '_')
    }
    
    # Replace spaces with underscores
    $sanitized = $sanitized.Replace(' ', '_')
    
    # Remove multiple consecutive underscores
    while ($sanitized.Contains('__')) {
        $sanitized = $sanitized.Replace('__', '_')
    }
    
    # Trim leading/trailing underscores
    $sanitized = $sanitized.Trim('_')
    
    # Handle reserved Windows names
    $reservedNames = @('CON', 'PRN', 'AUX', 'NUL', 'COM1', 'COM2', 'COM3', 'COM4', 
                       'COM5', 'COM6', 'COM7', 'COM8', 'COM9', 'LPT1', 'LPT2', 
                       'LPT3', 'LPT4', 'LPT5', 'LPT6', 'LPT7', 'LPT8', 'LPT9')
    
    if ($reservedNames -contains $sanitized.ToUpperInvariant()) {
        $sanitized = "_$sanitized"
    }
    
    # Ensure not empty after sanitization
    if ([string]::IsNullOrWhiteSpace($sanitized)) {
        return 'unnamed'
    }
    
    # Limit length to safe filesystem limit (255 chars for most filesystems)
    if ($sanitized.Length -gt 200) {
        $sanitized = $sanitized.Substring(0, 200)
    }
    
    return $sanitized
}

# Export module functions
Export-ModuleMember -Function Import-MediaCopyExtensionMap, Set-MediaCopyExtensionMap, Get-MediaCopyCategory, Get-MediaCopySanitizedName
