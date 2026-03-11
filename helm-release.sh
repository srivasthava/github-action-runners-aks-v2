#!/bin/bash

set -e

#===============================================================================
# CONFIGURATION - UPDATE THESE VALUES
#===============================================================================
CONTROLLER_NAMESPACE="github-controller"
LINUX_NAMESPACE="github-runners"
WINDOWS_NAMESPACE="github-runners-windows"

GITHUB_APP_ID="${GITHUB_APP_ID:-<YOUR_GITHUB_APP_ID>}"
GITHUB_APP_INSTALLATION_ID="${GITHUB_APP_INSTALLATION_ID:-<YOUR_INSTALLATION_ID>}"
GITHUB_APP_PRIVATE_KEY_PATH="${GITHUB_APP_PRIVATE_KEY_PATH:-./private-key.pem}"
GITHUB_CONFIG_URL="${GITHUB_CONFIG_URL:-https://github.com/<YOUR_ORG_OR_REPO>}"

#===============================================================================
# ARC v2 HELM CHART (OCI - no repo add needed)
#===============================================================================
ARC_VERSION="0.11.0"
CONTROLLER_CHART="oci://ghcr.io/actions/actions-runner-controller-charts/gha-runner-scale-set-controller"
RUNNER_CHART="oci://ghcr.io/actions/actions-runner-controller-charts/gha-runner-scale-set"
CONTROLLER_RELEASE="arc"

# Parse arguments
RUNNER_TYPE="${1:-linux}"
VERSION="${2:-latest}"
FRESH_INSTALL="${3:-}"

usage() {
    echo "Usage: $0 [linux|windows|all] [version] [fresh]"
    echo ""
    echo "Examples:"
    echo "  $0 linux latest          # Deploy/update Linux runner"
    echo "  $0 windows latest        # Deploy/update Windows runner"
    echo "  $0 all latest            # Deploy both Linux and Windows runners"
    echo "  $0 all latest fresh      # Fresh install: delete and reinstall everything"
    echo ""
    echo "Environment variables:"
    echo "  GITHUB_APP_ID               - GitHub App ID"
    echo "  GITHUB_APP_INSTALLATION_ID  - GitHub App Installation ID"
    echo "  GITHUB_APP_PRIVATE_KEY_PATH - Path to private key .pem file"
    echo "  GITHUB_CONFIG_URL           - https://github.com/your-org (or .../your-repo)"
    echo ""
    exit 1
}

if [[ "$RUNNER_TYPE" != "linux" && "$RUNNER_TYPE" != "windows" && "$RUNNER_TYPE" != "all" ]]; then
    echo "Error: Invalid runner type '$RUNNER_TYPE'"
    usage
fi

# Set image based on runner type
LINUX_IMAGE="ghcr.io/srivasthava/arc-linux-runner:$VERSION"
WINDOWS_IMAGE="ghcr.io/srivasthava/arc-windows-runner:$VERSION"

GHCR_USERNAME="${GHCR_USERNAME:-srivasthava}"
GHCR_TOKEN="${GHCR_TOKEN:-}"

echo "=========================================="
echo "GitHub Actions Runner Deployment (ARC v2)"
echo "=========================================="
echo "Runner Type:    $RUNNER_TYPE"
echo "Version:        $VERSION"
echo "Controller NS:  $CONTROLLER_NAMESPACE"
echo "Linux NS:       $LINUX_NAMESPACE"
echo "Windows NS:     $WINDOWS_NAMESPACE"
echo "GitHub URL:     $GITHUB_CONFIG_URL"
echo "Fresh Install:  ${FRESH_INSTALL:-no}"
echo ""

# Validate private key
if [[ ! -f "$GITHUB_APP_PRIVATE_KEY_PATH" ]]; then
    echo "Error: Private key file not found at '$GITHUB_APP_PRIVATE_KEY_PATH'"
    exit 1
fi

#===============================================================================
# FRESH INSTALL: tear down existing releases and CRDs
#===============================================================================
if [[ "$FRESH_INSTALL" == "fresh" ]]; then
    echo "--- Fresh Install: removing existing releases ---"

    for release in arc-runner-linux arc-runner-windows; do
        ns=$LINUX_NAMESPACE
        [[ "$release" == "arc-runner-windows" ]] && ns=$WINDOWS_NAMESPACE
        if helm list -n $ns -q 2>/dev/null | grep -q "^${release}$"; then
            echo "Uninstalling $release..."
            helm uninstall $release -n $ns
        fi
    done

    if helm list -n $CONTROLLER_NAMESPACE -q 2>/dev/null | grep -q "^${CONTROLLER_RELEASE}$"; then
        echo "Uninstalling controller..."
        helm uninstall $CONTROLLER_RELEASE -n $CONTROLLER_NAMESPACE
    fi

    echo "Waiting for pods to terminate..."
    kubectl delete pods --all -n $LINUX_NAMESPACE --grace-period=0 --force 2>/dev/null || true
    kubectl delete pods --all -n $WINDOWS_NAMESPACE --grace-period=0 --force 2>/dev/null || true
    kubectl delete pods --all -n $CONTROLLER_NAMESPACE --grace-period=0 --force 2>/dev/null || true
    sleep 10

    # Delete ARC v2 CRDs
    echo "Removing ARC v2 CRDs..."
    kubectl get crd | grep 'actions.github.com' | awk '{print $1}' | xargs kubectl delete crd 2>/dev/null || true
fi

#===============================================================================
# CREATE NAMESPACES AND APPLY SERVICE ACCOUNTS
#===============================================================================
echo ""
echo "--- Creating namespaces and applying service accounts ---"

kubectl create namespace $CONTROLLER_NAMESPACE --dry-run=client -o yaml | kubectl apply -f -
kubectl create namespace $LINUX_NAMESPACE --dry-run=client -o yaml | kubectl apply -f -
kubectl create namespace $WINDOWS_NAMESPACE --dry-run=client -o yaml | kubectl apply -f -
kubectl apply -f helm/service-account.yaml

#===============================================================================
# INSTALL ARC CONTROLLER
#===============================================================================
echo ""
echo "--- Installing ARC v2 Controller in '$CONTROLLER_NAMESPACE' ---"

helm upgrade --install $CONTROLLER_RELEASE $CONTROLLER_CHART \
  --namespace $CONTROLLER_NAMESPACE \
  --version $ARC_VERSION \
  --values helm/controller-values.yaml \
  --wait --timeout 5m

echo "Controller installed successfully."

#===============================================================================
# INSTALL LINUX RUNNER SCALE SET
#===============================================================================
deploy_linux() {
    echo ""
    echo "--- Installing Linux Runner Scale Set in '$LINUX_NAMESPACE' ---"

    # Create GHCR pull secret
    kubectl create secret docker-registry ghcr-pull-secret \
      --namespace $LINUX_NAMESPACE \
      --docker-server=ghcr.io \
      --docker-username="$GHCR_USERNAME" \
      --docker-password="$GHCR_TOKEN" \
      --dry-run=client -o yaml | kubectl apply -f -

    # Patch image and githubConfigUrl into values file
    sed -i.bak "s|image:.*arc-linux-runner:.*|image: \"$LINUX_IMAGE\"|" helm/linux-values.yaml
    sed -i.bak "s|githubConfigUrl:.*|githubConfigUrl: \"$GITHUB_CONFIG_URL\"|" helm/linux-values.yaml
    rm -f helm/linux-values.yaml.bak

    # Create GitHub App secret in linux runner namespace
    kubectl create secret generic github-app-secret \
      --namespace $LINUX_NAMESPACE \
      --from-literal=github_app_id="$GITHUB_APP_ID" \
      --from-literal=github_app_installation_id="$GITHUB_APP_INSTALLATION_ID" \
      --from-file=github_app_private_key="$GITHUB_APP_PRIVATE_KEY_PATH" \
      --dry-run=client -o yaml | kubectl apply -f -

    helm upgrade --install arc-runner-linux $RUNNER_CHART \
      --namespace $LINUX_NAMESPACE \
      --version $ARC_VERSION \
      --values helm/linux-values.yaml \
      --set githubConfigSecret=github-app-secret \
      --wait --timeout 10m

    echo "Linux runner scale set deployed."
}

#===============================================================================
# INSTALL WINDOWS RUNNER SCALE SET
#===============================================================================
deploy_windows() {
    echo ""
    echo "--- Installing Windows Runner Scale Set in '$WINDOWS_NAMESPACE' ---"

    # Patch image and githubConfigUrl into values file
    sed -i.bak "s|image:.*windows-github-runner:.*|image: \"$WINDOWS_IMAGE\"|" helm/windows-values.yaml
    sed -i.bak "s|githubConfigUrl:.*|githubConfigUrl: \"$GITHUB_CONFIG_URL\"|" helm/windows-values.yaml
    rm -f helm/windows-values.yaml.bak

    # Create GitHub App secret in windows runner namespace
    kubectl create secret generic github-app-secret \
      --namespace $WINDOWS_NAMESPACE \
      --from-literal=github_app_id="$GITHUB_APP_ID" \
      --from-literal=github_app_installation_id="$GITHUB_APP_INSTALLATION_ID" \
      --from-file=github_app_private_key="$GITHUB_APP_PRIVATE_KEY_PATH" \
      --dry-run=client -o yaml | kubectl apply -f -

    helm upgrade --install arc-runner-windows $RUNNER_CHART \
      --namespace $WINDOWS_NAMESPACE \
      --version $ARC_VERSION \
      --values helm/windows-values.yaml \
      --set githubConfigSecret=github-app-secret \
      --wait --timeout 10m

    echo "Windows runner scale set deployed."
}

# Deploy based on runner type
if [[ "$RUNNER_TYPE" == "linux" || "$RUNNER_TYPE" == "all" ]]; then
    deploy_linux
fi
if [[ "$RUNNER_TYPE" == "windows" || "$RUNNER_TYPE" == "all" ]]; then
    deploy_windows
fi

echo ""
echo "=========================================="
echo "Deployment completed successfully!"
echo "=========================================="
echo ""
echo "Runners will appear in GitHub under:"
echo "  Settings -> Actions -> Runners"
echo "  runs-on: arc-runner-linux"
echo "  runs-on: arc-runner-windows"
echo ""
echo "To monitor:"
echo "  kubectl get AutoscalingRunnerSet -A"
echo "  kubectl get pods -n $LINUX_NAMESPACE -w"
echo "  kubectl logs -n $CONTROLLER_NAMESPACE deployment/arc-gha-rs-controller -f"
