###############################################################################
# entrypoint.ps1 — GitHub Actions Runner for Windows (ARC v2 compatible)
#
# ARC v2 sets the container command to C:\actions-runner\run.cmd.
# This entrypoint logs environment info then exec's into that command.
###############################################################################

$ErrorActionPreference = "Stop"

$RunnerWorkDir = if ($env:RUNNER_WORKDIR) { $env:RUNNER_WORKDIR } else { "C:\actions-runner\_work" }

Write-Host "GitHub Actions Runner - Windows Server 2022 (ARC v2)"
Write-Host ".NET SDK:   $(dotnet --version 2>$null)"
Write-Host "Node.js:    $(node --version 2>$null)"
Write-Host "Git:        $(git --version 2>$null)"
Write-Host "PowerShell: $($PSVersionTable.PSVersion)"

# Create work directory
if (-not (Test-Path $RunnerWorkDir)) {
    New-Item -ItemType Directory -Path $RunnerWorkDir -Force | Out-Null
}

# Graceful shutdown
$null = Register-EngineEvent -SourceIdentifier PowerShell.Exiting -Action {
    Write-Host "Graceful shutdown..."
    if (Test-Path "C:\actions-runner\.runner") {
        & C:\actions-runner\config.cmd remove --token $env:GITHUB_TOKEN 2>$null
    }
}

# ARC v2 passes run.cmd as args — exec into it
if ($args.Count -gt 0) {
    & $args[0] $args[1..($args.Count - 1)]
    exit $LASTEXITCODE
}

# Fallback: manual registration (non-ARC mode)
if ($env:GITHUB_URL -and $env:GITHUB_TOKEN) {
    Write-Host "Configuring runner (manual mode)..."
    & C:\actions-runner\config.cmd `
        --url $env:GITHUB_URL `
        --token $env:GITHUB_TOKEN `
        --name ($env:RUNNER_NAME ?? $env:COMPUTERNAME) `
        --labels ($env:RUNNER_LABELS ?? "self-hosted,windows,x64") `
        --runnergroup ($env:RUNNER_GROUP ?? "Default") `
        --work $RunnerWorkDir `
        --ephemeral --unattended --replace

    & C:\actions-runner\run.cmd
} else {
    Write-Host "Missing GITHUB_URL or GITHUB_TOKEN. Waiting..."
    while ($true) { Start-Sleep -Seconds 3600 }
}
