# Configuration module for MediaCopy
# Centralizes hardcoded strings and settings

function Get-MediaCopyConfig {
    [CmdletBinding()]
    param()
    
    return [PSCustomObject]@{
        DefaultExtensionMap = (Join-Path $PSScriptRoot '..' 'extensions.xml')
        DefaultBatchSize = 50
        DefaultMaxRetries = 3
        DefaultRobocopyThreads = 8
        DefaultCategoryParallelism = 1
        LogFolder = (Join-Path $PSScriptRoot '..' 'logs')
        IndexFileName = '.mediacopy_index.csv'
        # Add more config values as needed
    }
}

Export-ModuleMember -Function Get-MediaCopyConfig
