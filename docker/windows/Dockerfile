# escape=`
#───────────────────────────────────────────────────────────────────────────────
# Custom GitHub Actions Runner — Windows Server 2022 LTSC (ARC v2 compatible)
#
# Build essentials included:
#   - Windows Server Core LTSC 2022
#   - .NET SDK 8.0 + MSBuild
#   - Visual Studio Build Tools 2022
#   - Node.js 20 LTS + pnpm + yarn
#   - Git for Windows
#   - PowerShell 7
#   - Azure CLI
#   - Docker CLI (accesses host Docker via named pipe — no DinD on Windows)
#   - kubectl + Helm
#   - NuGet CLI
#   - Chocolatey package manager
#
# Note: Windows containers use process isolation on AKS.
#       Docker-in-Docker is NOT supported. Docker builds use the host
#       Docker daemon via named pipe mount in the pod spec.
#───────────────────────────────────────────────────────────────────────────────

FROM mcr.microsoft.com/windows/servercore:ltsc2022

ARG RUNNER_VERSION=2.321.0
ARG NODE_VERSION=20.14.0

SHELL ["powershell", "-Command", "$ErrorActionPreference = 'Stop'; $ProgressPreference = 'SilentlyContinue';"]

LABEL org.opencontainers.image.source="https://github.com/srivasthava/github-action-runners-aks-v2"
LABEL description="GitHub Actions Runner for Windows AKS nodes (ARC v2)"

#───────────────────────────────────────────────────────────────────────────────
# Chocolatey
#───────────────────────────────────────────────────────────────────────────────
RUN Set-ExecutionPolicy Bypass -Scope Process -Force; `
    [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.ServicePointManager]::SecurityProtocol -bor 3072; `
    iex ((New-Object System.Net.WebClient).DownloadString('https://community.chocolatey.org/install.ps1'))

#───────────────────────────────────────────────────────────────────────────────
# Git for Windows
#───────────────────────────────────────────────────────────────────────────────
RUN choco install git -y --params "'/GitAndUnixToolsOnPath /NoAutoCrlf /DefaultBranchName:main'" `
    && refreshenv

#───────────────────────────────────────────────────────────────────────────────
# Core tools
#───────────────────────────────────────────────────────────────────────────────
RUN choco install -y `
    7zip `
    jq `
    curl `
    wget `
    make `
    vim

#───────────────────────────────────────────────────────────────────────────────
# PowerShell 7
#───────────────────────────────────────────────────────────────────────────────
RUN choco install pwsh -y

#───────────────────────────────────────────────────────────────────────────────
# .NET SDK 8.0
#───────────────────────────────────────────────────────────────────────────────
RUN choco install dotnet-sdk -y --version=8.0

#───────────────────────────────────────────────────────────────────────────────
# Node.js 20 LTS + pnpm + yarn
#───────────────────────────────────────────────────────────────────────────────
RUN choco install nodejs-lts -y `
    && refreshenv `
    && npm install -g pnpm@latest yarn@latest

#───────────────────────────────────────────────────────────────────────────────
# Azure CLI
#───────────────────────────────────────────────────────────────────────────────
RUN Invoke-WebRequest -Uri https://aka.ms/installazurecliwindowsx64 -OutFile .\AzureCLI.msi; `
    Start-Process msiexec.exe -ArgumentList '/I AzureCLI.msi /quiet' -Wait; `
    Remove-Item .\AzureCLI.msi

#───────────────────────────────────────────────────────────────────────────────
# Visual Studio Build Tools 2022
#───────────────────────────────────────────────────────────────────────────────
RUN Invoke-WebRequest -Uri 'https://aka.ms/vs/17/release/vs_buildtools.exe' -OutFile vs_buildtools.exe; `
    Start-Process -FilePath .\vs_buildtools.exe -ArgumentList `
      '--quiet', '--wait', '--norestart', '--nocache', `
      '--add', 'Microsoft.VisualStudio.Workload.AzureBuildTools', `
      '--add', 'Microsoft.VisualStudio.Workload.WebBuildTools', `
      '--add', 'Microsoft.VisualStudio.Workload.ManagedDesktopBuildTools', `
      '--add', 'Microsoft.VisualStudio.Workload.NetCoreBuildTools', `
      '--add', 'Microsoft.Component.MSBuild' `
    -Wait; `
    Remove-Item vs_buildtools.exe

#───────────────────────────────────────────────────────────────────────────────
# Docker CLI (for host Docker daemon via named pipe — no DinD on Windows)
#───────────────────────────────────────────────────────────────────────────────
RUN choco install docker-cli -y

#───────────────────────────────────────────────────────────────────────────────
# kubectl + Helm + NuGet
#───────────────────────────────────────────────────────────────────────────────
RUN choco install kubernetes-cli -y `
    && choco install kubernetes-helm -y `
    && choco install nuget.commandline -y

#───────────────────────────────────────────────────────────────────────────────
# GitHub Actions Runner
#───────────────────────────────────────────────────────────────────────────────
WORKDIR C:\actions-runner

RUN Invoke-WebRequest `
      -Uri "https://github.com/actions/runner/releases/download/v${env:RUNNER_VERSION}/actions-runner-win-x64-${env:RUNNER_VERSION}.zip" `
      -OutFile runner.zip; `
    Expand-Archive -Path runner.zip -DestinationPath .; `
    Remove-Item runner.zip

#───────────────────────────────────────────────────────────────────────────────
# Entrypoint
# ARC v2 sets command to \actions-runner\run.cmd — entrypoint.ps1 exec's into it
#───────────────────────────────────────────────────────────────────────────────
COPY entrypoint.ps1 C:\actions-runner\entrypoint.ps1

ENV RUNNER_ALLOW_RUNASROOT=1
ENV DOTNET_NOLOGO=1
ENV DOTNET_CLI_TELEMETRY_OPTOUT=1

ENTRYPOINT ["pwsh", "-File", "C:\\actions-runner\\entrypoint.ps1"]
CMD ["C:\\actions-runner\\run.cmd"]
