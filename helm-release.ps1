#Requires -Version 5.1

param(
    [ValidateSet("linux", "windows", "all")]
    [string]$RunnerType = "linux",

    [string]$Version = "latest",

    [switch]$FreshInstall
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

#===============================================================================
# CONFIGURATION - UPDATE THESE VALUES
#===============================================================================
$CONTROLLER_NAMESPACE = "github-controller"
$LINUX_NAMESPACE      = "github-runners"
$WINDOWS_NAMESPACE    = "github-runners-windows"

$GITHUB_APP_ID               = $env:GITHUB_APP_ID               ?? "<YOUR_GITHUB_APP_ID>"
$GITHUB_APP_INSTALLATION_ID  = $env:GITHUB_APP_INSTALLATION_ID  ?? "<YOUR_INSTALLATION_ID>"
$GITHUB_APP_PRIVATE_KEY_PATH = $env:GITHUB_APP_PRIVATE_KEY_PATH ?? "./private-key.pem"
$GITHUB_CONFIG_URL           = $env:GITHUB_CONFIG_URL           ?? "https://github.com/<YOUR_ORG_OR_REPO>"

#===============================================================================
# ARC v2 HELM CHART (OCI - no repo add needed)
#===============================================================================
$ARC_VERSION       = "0.11.0"
$CONTROLLER_CHART  = "oci://ghcr.io/actions/actions-runner-controller-charts/gha-runner-scale-set-controller"
$RUNNER_CHART      = "oci://ghcr.io/actions/actions-runner-controller-charts/gha-runner-scale-set"
$CONTROLLER_RELEASE = "arc"

$LINUX_IMAGE   = "ghcr.io/srivasthava/github-action-runners-aks/linux-github-runner:$Version"
$WINDOWS_IMAGE = "ghcr.io/srivasthava/github-action-runners-aks/windows-github-runner:$Version"

Write-Host "=========================================="
Write-Host "GitHub Actions Runner Deployment (ARC v2)"
Write-Host "=========================================="
Write-Host "Runner Type:   $RunnerType"
Write-Host "Version:       $Version"
Write-Host "Controller NS: $CONTROLLER_NAMESPACE"
Write-Host "Linux NS:      $LINUX_NAMESPACE"
Write-Host "Windows NS:    $WINDOWS_NAMESPACE"
Write-Host "GitHub URL:    $GITHUB_CONFIG_URL"
Write-Host "Fresh Install: $FreshInstall"
Write-Host ""

# Validate private key
if (-not (Test-Path $GITHUB_APP_PRIVATE_KEY_PATH)) {
    throw "Private key file not found at '$GITHUB_APP_PRIVATE_KEY_PATH'"
}

#===============================================================================
# FRESH INSTALL: tear down existing releases and CRDs
#===============================================================================
if ($FreshInstall) {
    Write-Host "--- Fresh Install: removing existing releases ---"

    foreach ($entry in @(@{release="arc-runner-linux"; ns=$LINUX_NAMESPACE}, @{release="arc-runner-windows"; ns=$WINDOWS_NAMESPACE})) {
        $exists = helm list -n $entry.ns -q 2>$null | Where-Object { $_ -eq $entry.release }
        if ($exists) {
            Write-Host "Uninstalling $($entry.release)..."
            helm uninstall $entry.release -n $entry.ns
        }
    }

    $controllerExists = helm list -n $CONTROLLER_NAMESPACE -q 2>$null | Where-Object { $_ -eq $CONTROLLER_RELEASE }
    if ($controllerExists) {
        Write-Host "Uninstalling controller..."
        helm uninstall $CONTROLLER_RELEASE -n $CONTROLLER_NAMESPACE
    }

    Write-Host "Waiting for pods to terminate..."
    kubectl delete pods --all -n $LINUX_NAMESPACE --grace-period=0 --force 2>$null
    kubectl delete pods --all -n $WINDOWS_NAMESPACE --grace-period=0 --force 2>$null
    kubectl delete pods --all -n $CONTROLLER_NAMESPACE --grace-period=0 --force 2>$null
    Start-Sleep -Seconds 10

    # Delete ARC v2 CRDs
    Write-Host "Removing ARC v2 CRDs..."
    $arcCrds = kubectl get crd 2>$null | Select-String 'actions.github.com' | ForEach-Object { ($_ -split '\s+')[0] }
    foreach ($crd in $arcCrds) {
        kubectl delete crd $crd 2>$null
    }
}

#===============================================================================
# CREATE NAMESPACES AND APPLY SERVICE ACCOUNTS
#===============================================================================
Write-Host ""
Write-Host "--- Creating namespaces and applying service accounts ---"

foreach ($ns in @($CONTROLLER_NAMESPACE, $LINUX_NAMESPACE, $WINDOWS_NAMESPACE)) {
    kubectl create namespace $ns --dry-run=client -o yaml | kubectl apply -f -
    if ($LASTEXITCODE -ne 0) { throw "Failed to create namespace $ns" }
}

kubectl apply -f helm/service-account.yaml
if ($LASTEXITCODE -ne 0) { throw "Failed to apply service accounts" }

#===============================================================================
# INSTALL ARC CONTROLLER
#===============================================================================
Write-Host ""
Write-Host "--- Installing ARC v2 Controller in '$CONTROLLER_NAMESPACE' ---"

helm upgrade --install $CONTROLLER_RELEASE $CONTROLLER_CHART `
    --namespace $CONTROLLER_NAMESPACE `
    --version $ARC_VERSION `
    --values helm/controller-values.yaml `
    --wait --timeout 5m
if ($LASTEXITCODE -ne 0) { throw "Controller installation failed" }

Write-Host "Controller installed successfully."

#===============================================================================
# DEPLOY FUNCTIONS
#===============================================================================
function Deploy-Linux {
    Write-Host ""
    Write-Host "--- Installing Linux Runner Scale Set in '$LINUX_NAMESPACE' ---"

    # Patch image and githubConfigUrl into values file
    $values = Get-Content helm/linux-values.yaml -Raw
    $values = $values -replace 'image:.*linux-github-runner:.*', "image: `"$LINUX_IMAGE`""
    $values = $values -replace 'githubConfigUrl:.*', "githubConfigUrl: `"$GITHUB_CONFIG_URL`""
    Set-Content helm/linux-values.yaml -Value $values -NoNewline

    # Create GitHub App secret in linux runner namespace
    kubectl create secret generic github-app-secret `
        --namespace $LINUX_NAMESPACE `
        --from-literal=github_app_id="$GITHUB_APP_ID" `
        --from-literal=github_app_installation_id="$GITHUB_APP_INSTALLATION_ID" `
        --from-file=github_app_private_key="$GITHUB_APP_PRIVATE_KEY_PATH" `
        --dry-run=client -o yaml | kubectl apply -f -
    if ($LASTEXITCODE -ne 0) { throw "Failed to apply linux github-app-secret" }

    helm upgrade --install arc-runner-linux $RUNNER_CHART `
        --namespace $LINUX_NAMESPACE `
        --version $ARC_VERSION `
        --values helm/linux-values.yaml `
        --set githubConfigSecret=github-app-secret `
        --wait --timeout 10m
    if ($LASTEXITCODE -ne 0) { throw "Linux runner deployment failed" }

    Write-Host "Linux runner scale set deployed."
}

function Deploy-Windows {
    Write-Host ""
    Write-Host "--- Installing Windows Runner Scale Set in '$WINDOWS_NAMESPACE' ---"

    # Patch image and githubConfigUrl into values file
    $values = Get-Content helm/windows-values.yaml -Raw
    $values = $values -replace 'image:.*windows-github-runner:.*', "image: `"$WINDOWS_IMAGE`""
    $values = $values -replace 'githubConfigUrl:.*', "githubConfigUrl: `"$GITHUB_CONFIG_URL`""
    Set-Content helm/windows-values.yaml -Value $values -NoNewline

    # Create GitHub App secret in windows runner namespace
    kubectl create secret generic github-app-secret `
        --namespace $WINDOWS_NAMESPACE `
        --from-literal=github_app_id="$GITHUB_APP_ID" `
        --from-literal=github_app_installation_id="$GITHUB_APP_INSTALLATION_ID" `
        --from-file=github_app_private_key="$GITHUB_APP_PRIVATE_KEY_PATH" `
        --dry-run=client -o yaml | kubectl apply -f -
    if ($LASTEXITCODE -ne 0) { throw "Failed to apply windows github-app-secret" }

    helm upgrade --install arc-runner-windows $RUNNER_CHART `
        --namespace $WINDOWS_NAMESPACE `
        --version $ARC_VERSION `
        --values helm/windows-values.yaml `
        --set githubConfigSecret=github-app-secret `
        --wait --timeout 10m
    if ($LASTEXITCODE -ne 0) { throw "Windows runner deployment failed" }

    Write-Host "Windows runner scale set deployed."
}

# Deploy based on runner type
if ($RunnerType -eq "linux" -or $RunnerType -eq "all")   { Deploy-Linux }
if ($RunnerType -eq "windows" -or $RunnerType -eq "all") { Deploy-Windows }

Write-Host ""
Write-Host "=========================================="
Write-Host "Deployment completed successfully!"
Write-Host "=========================================="
Write-Host ""
Write-Host "Runners will appear in GitHub under:"
Write-Host "  Settings -> Actions -> Runners"
Write-Host "  runs-on: arc-runner-linux"
Write-Host "  runs-on: arc-runner-windows"
Write-Host ""
Write-Host "To monitor:"
Write-Host "  kubectl get AutoscalingRunnerSet -A"
Write-Host "  kubectl get pods -n $LINUX_NAMESPACE -w"
Write-Host "  kubectl logs -n $CONTROLLER_NAMESPACE deployment/arc-gha-rs-controller -f"
