# ARC v2 Deployment Commands

GitHub Actions Runner Controller (ARC v2) on AKS — step-by-step reference.

---

## Prerequisites

```bash
# macOS
brew install helm kubectl azure-cli

# Connect to AKS
az aks get-credentials --resource-group <your-rg> --name <your-aks-name>

# Verify connection
kubectl get nodes
```

---

## Environment Variables

Set these before running any deployment commands:

```bash
export GITHUB_APP_ID="3058665"
export GITHUB_APP_INSTALLATION_ID="115428920"
export GITHUB_APP_PRIVATE_KEY_PATH="./your-private-key.pem"

# Org URL:  https://github.com/your-org       (runners for all repos in org)
# Repo URL: https://github.com/your-org/repo  (runners scoped to one repo)
# Personal accounts MUST use repo URL — no org runner API on personal accounts
export GITHUB_CONFIG_URL="https://github.com/srivasthava/github-action-runners-aks-v2"

export GHCR_USERNAME="srivasthava"
export GHCR_TOKEN="<github-pat-with-read:packages-and-write:packages>"
```

---

## Fresh Install

### 1. Create namespaces and RBAC

```bash
kubectl create namespace github-controller
kubectl create namespace github-runners
kubectl create namespace github-runners-windows
kubectl apply -f helm/service-account.yaml
```

### 2. Install ARC controller

```bash
helm upgrade --install arc \
  oci://ghcr.io/actions/actions-runner-controller-charts/gha-runner-scale-set-controller \
  --namespace github-controller \
  --version 0.11.0 \
  --values helm/controller-values.yaml \
  --wait --timeout 8m
```

### 3. Create secrets (Linux runner namespace)

```bash
# GHCR pull secret — allows pods to pull the private runner image
kubectl create secret docker-registry ghcr-pull-secret \
  --namespace github-runners \
  --docker-server=ghcr.io \
  --docker-username="$GHCR_USERNAME" \
  "--docker-password=$GHCR_TOKEN"

# GitHub App credentials — used by runner to authenticate with GitHub
kubectl create secret generic github-app-secret \
  --namespace github-runners \
  --from-literal=github_app_id="$GITHUB_APP_ID" \
  --from-literal=github_app_installation_id="$GITHUB_APP_INSTALLATION_ID" \
  --from-file=github_app_private_key="$GITHUB_APP_PRIVATE_KEY_PATH"
```

### 4. Deploy Linux runner scale set

```bash
helm upgrade --install arc-runner-linux \
  oci://ghcr.io/actions/actions-runner-controller-charts/gha-runner-scale-set \
  --namespace github-runners \
  --version 0.11.0 \
  --values helm/linux-values.yaml \
  --set githubConfigSecret=github-app-secret \
  --set githubConfigUrl="$GITHUB_CONFIG_URL" \
  --wait --timeout 10m
```

### 5. Deploy Windows runner scale set (optional)

```bash
# Create secrets in windows namespace
kubectl create secret docker-registry ghcr-pull-secret \
  --namespace github-runners-windows \
  --docker-server=ghcr.io \
  --docker-username="$GHCR_USERNAME" \
  "--docker-password=$GHCR_TOKEN"

kubectl create secret generic github-app-secret \
  --namespace github-runners-windows \
  --from-literal=github_app_id="$GITHUB_APP_ID" \
  --from-literal=github_app_installation_id="$GITHUB_APP_INSTALLATION_ID" \
  --from-file=github_app_private_key="$GITHUB_APP_PRIVATE_KEY_PATH"

helm upgrade --install arc-runner-windows \
  oci://ghcr.io/actions/actions-runner-controller-charts/gha-runner-scale-set \
  --namespace github-runners-windows \
  --version 0.11.0 \
  --values helm/windows-values.yaml \
  --set githubConfigSecret=github-app-secret \
  --set githubConfigUrl="$GITHUB_CONFIG_URL" \
  --wait --timeout 10m
```

---

## Using the Script (Alternative)

```bash
# Linux only
export GITHUB_APP_ID="..." GITHUB_APP_INSTALLATION_ID="..." \
  GITHUB_APP_PRIVATE_KEY_PATH="./key.pem" \
  GITHUB_CONFIG_URL="https://github.com/org/repo" \
  GHCR_USERNAME="srivasthava" GHCR_TOKEN="..."

chmod +x helm-release.sh
./helm-release.sh linux latest

# Fresh install (tears down everything first)
./helm-release.sh linux latest fresh

# PowerShell equivalent
$env:GITHUB_APP_ID="..."; $env:GITHUB_APP_INSTALLATION_ID="..."
$env:GITHUB_APP_PRIVATE_KEY_PATH="./key.pem"
$env:GITHUB_CONFIG_URL="https://github.com/org/repo"
$env:GHCR_TOKEN="..."
.\helm-release.ps1 -RunnerType linux -FreshInstall
```

---

## Monitoring

```bash
# Check controller pod
kubectl get pods -n github-controller

# Check listener pod (always running when scale set is deployed)
kubectl get pods -n github-runners

# Check runner scale set status
kubectl get AutoscalingRunnerSet -A

# Watch runner pods appear/disappear during jobs
kubectl get pods -n github-runners -w

# Controller logs (most useful for debugging)
kubectl logs -n github-controller deployment/arc-gha-rs-controller -f

# Check ephemeral runner status
kubectl get ephemeralrunner -n github-runners

# Check runner events
kubectl get events -n github-runners --sort-by='.lastTimestamp'
```

---

## Triggering a Test Job

Add to any workflow file in a repo registered with this runner:

```yaml
jobs:
  test:
    runs-on: arc-runner-linux   # or arc-runner-windows
    steps:
      - run: echo "Hello from ARC runner!"
```

> **Note:** With `minRunners: 0`, runner pods only appear while a job is running.
> They scale to 0 when idle — this is **expected behavior**, not a problem.

---

## Tear Down / Fresh Install

```bash
# Uninstall runner scale sets
helm uninstall arc-runner-linux -n github-runners
helm uninstall arc-runner-windows -n github-runners-windows

# Uninstall controller
helm uninstall arc -n github-controller

# Force delete stuck pods
kubectl delete pods --all -n github-runners --grace-period=0 --force
kubectl delete pods --all -n github-controller --grace-period=0 --force

# Remove ARC CRDs
kubectl get crd | grep 'actions.github.com' | awk '{print $1}' | xargs kubectl delete crd

# Delete namespaces
kubectl delete namespace github-runners github-runners-windows github-controller
```

---

## Workflow Uses

```yaml
# In your GitHub Actions workflow:
runs-on: arc-runner-linux    # Linux runner
runs-on: arc-runner-windows  # Windows runner
```

Runners appear in GitHub under:
**Settings → Actions → Runners** (repo or org level depending on your `githubConfigUrl`)
