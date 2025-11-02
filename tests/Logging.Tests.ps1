# Pester tests for Logging module
$moduleFile = Join-Path -Path (Split-Path -Parent $PSCommandPath) -ChildPath '..\modules\Logging.psm1'
Import-Module (Resolve-Path -Path $moduleFile) -Force

Describe 'Write-MediaCopyLog' {
    It 'writes to the log file and supports DEBUG level' {
        $tmp = Join-Path $env:TEMP ("mediacopy_test_" + [guid]::NewGuid().ToString() + ".log")
        try {
            Set-MediaCopyLogPath -Path $tmp
            Write-MediaCopyLog -Message 'test debug message' -Level 'DEBUG'
            Start-Sleep -Milliseconds 50
            (Test-Path -LiteralPath $tmp) | Should -BeTrue
            $content = Get-Content -LiteralPath $tmp -Raw
            $content | Should -Match 'DEBUG'
        } finally {
            if (Test-Path $tmp) { Remove-Item -LiteralPath $tmp -Force }
        }
    }
}
