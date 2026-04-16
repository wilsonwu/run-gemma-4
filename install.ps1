[CmdletBinding()]
param(
    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$InstallerArgs
)

$ErrorActionPreference = 'Stop'

$repoUrl = 'https://github.com/wilsonwu/run-gemma-4'
$defaultRef = if ($env:RUN_GEMMA_REF) { $env:RUN_GEMMA_REF } else { 'main' }
$assetBaseUrl = if ($env:RUN_GEMMA_ASSET_BASE_URL) { $env:RUN_GEMMA_ASSET_BASE_URL.TrimEnd('/') } else { "https://raw.githubusercontent.com/wilsonwu/run-gemma-4/$defaultRef" }

$scriptPath = $MyInvocation.MyCommand.Path
$scriptRoot = if ($scriptPath) { Split-Path -Parent $scriptPath } else { $null }
$localInstallSh = if ($scriptRoot) { Join-Path $scriptRoot 'install.sh' } else { $null }
$installSource = $localInstallSh
$tempRoot = $null

if (-not $localInstallSh -or -not (Test-Path $localInstallSh)) {
    $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("run-gemma-4-installer-" + [Guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $tempRoot | Out-Null
    $installSource = Join-Path $tempRoot 'install.sh'
    Invoke-WebRequest -UseBasicParsing -Uri "$assetBaseUrl/install.sh" -OutFile $installSource
}

$bashCandidates = @()

$bashCommand = Get-Command bash.exe -ErrorAction SilentlyContinue
if ($bashCommand) {
    $bashCandidates += $bashCommand.Source
}

$bashCandidates += @(
    'C:\Program Files\Git\bin\bash.exe',
    'C:\Program Files\Git\usr\bin\bash.exe',
    'C:\Program Files (x86)\Git\bin\bash.exe',
    'C:\Program Files (x86)\Git\usr\bin\bash.exe'
)

$bashPath = $bashCandidates | Where-Object { $_ -and (Test-Path $_) } | Select-Object -First 1

try {
    if ($bashPath) {
        & $bashPath $installSource @InstallerArgs
        exit $LASTEXITCODE
    }

    $wslCommand = Get-Command wsl.exe -ErrorAction SilentlyContinue
    if ($wslCommand) {
        $linuxScriptPath = (& $wslCommand.Source wslpath -a $installSource).Trim()
        if (-not $linuxScriptPath) {
            throw 'Failed to convert install.sh to a WSL path.'
        }

        & $wslCommand.Source bash $linuxScriptPath @InstallerArgs
        exit $LASTEXITCODE
    }

    throw 'Neither Git Bash nor WSL was found. Install Git for Windows or enable WSL, then rerun install.ps1.'
}
finally {
    if ($tempRoot -and (Test-Path $tempRoot)) {
        Remove-Item -Path $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}