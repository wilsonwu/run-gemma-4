[CmdletBinding()]
param(
    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$InstallerArgs
)

$ErrorActionPreference = 'Stop'

$scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
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

if ($bashPath) {
    & $bashPath "$scriptRoot/install.sh" @InstallerArgs
    exit $LASTEXITCODE
}

$wslCommand = Get-Command wsl.exe -ErrorAction SilentlyContinue
if ($wslCommand) {
    $linuxScriptPath = (& $wslCommand.Source wslpath -a "$scriptRoot/install.sh").Trim()
    if (-not $linuxScriptPath) {
        throw 'Failed to convert install.sh to a WSL path.'
    }

    & $wslCommand.Source bash $linuxScriptPath @InstallerArgs
    exit $LASTEXITCODE
}

throw 'Neither Git Bash nor WSL was found. Install Git for Windows or enable WSL, then rerun install.ps1.'