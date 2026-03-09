# GitHub Actions Runners on AKS — ARC v2

Self-hosted GitHub Actions runners on Azure Kubernetes Service using **Actions Runner Controller v2** (GitHub's official scale-set based controller).

## Architecture

```
GitHub Actions Job
       │
       ▼
ARC Controller (github-controller namespace)
       │  watches AutoscalingRunnerSet CRDs
       ▼
Listener Pod (scales runners based on queue depth)
       │
       ▼
Runner Pods (github-runners / github-runners-windows namespaces)
  - Ephemeral: one pod per job, deleted after completion
  - Scale to zero when no jobs queued
```

## Project Structure

```
├── .github/workflows/
│   └── build-and-push.yml      # CI: builds and pushes runner images to GHCR
├── docker/
│   ├── linux/
│   │   ├── Dockerfile           # Ubuntu 22.04 + Docker + build tools
│   │   └── entrypoint.sh        # Starts DinD, then exec's ARC run.sh
│   └── windows/
│       ├── Dockerfile           # Windows Server 2022 + VS Build Tools
│       └── entrypoint.ps1       # Logs info, then exec's ARC run.cmd
├── helm/
│   ├── controller-values.yaml   # ARC v2 controller Helm values
│   ├── linux-values.yaml        # Linux runner scale set values
│   ├── windows-values.yaml      # Windows runner scale set values
│   └── service-account.yaml     # All service accounts and RBAC
├── helm-release.sh              # Bash deploy script
└── helm-release.ps1             # PowerShell deploy script
```

---

## Prerequisites

- AKS cluster with Linux and Windows node pools
- `kubectl` configured against your cluster
- `helm` v3.8+ (OCI support required)
- GitHub App with required permissions (see below)

---

## Step 1 — Create a GitHub App

1. Go to: `https://github.com/organizations/<YOUR_ORG>/settings/apps`
2. Click **New GitHub App**
3. Set **Repository permissions**:
   - Actions: Read
   - Administration: Read & Write
   - Metadata: Read
4. Set **Organization permissions**:
   - Self-hosted runners: Read & Write
5. Uncheck **Webhook → Active**
6. Click **Create GitHub App**
7. Note the **App ID** from the app settings page
8. Click **Generate a private key** → download the `.pem` file
9. Click **Install App** → install on your org → note the **Installation ID** from the URL

---

## Step 2 — Configure Values

Edit the top of `helm-release.sh` (or set environment variables):

```bash
GITHUB_APP_ID="123456"                          # From Step 1
GITHUB_APP_INSTALLATION_ID="12345678"           # From Step 1
GITHUB_APP_PRIVATE_KEY_PATH="./private-key.pem" # Path to downloaded .pem
GITHUB_CONFIG_URL="https://github.com/your-org" # Org-level or repo-level URL
```

Or export as environment variables:

```bash
export GITHUB_APP_ID="123456"
export GITHUB_APP_INSTALLATION_ID="12345678"
export GITHUB_APP_PRIVATE_KEY_PATH="./private-key.pem"
export GITHUB_CONFIG_URL="https://github.com/your-org"
```

---

## Step 3 — Deploy

### Fresh install (first time or full reset):

```bash
# Linux runners only
./helm-release.sh linux latest fresh

# Windows runners only
./helm-release.sh windows latest fresh

# Both Linux and Windows
./helm-release.sh all latest fresh
```

### Update existing deployment (no teardown):

```bash
./helm-release.sh linux latest
./helm-release.sh windows latest
./helm-release.sh all latest
```

### PowerShell equivalent:

```powershell
# Fresh install
.\helm-release.ps1 -RunnerType all -Version latest -FreshInstall

# Update only
.\helm-release.ps1 -RunnerType linux -Version latest
```

---

## Step 4 — Verify

```bash
# Check controller is running
kubectl get pods -n github-controller

# Check runner scale sets are registered
kubectl get AutoscalingRunnerSet -A

# Watch runner pods scale up (trigger a job to see them appear)
kubectl get pods -n github-runners -w
kubectl get pods -n github-runners-windows -w

# Controller logs
kubectl logs -n github-controller deployment/arc-gha-rs-controller -f
```

Runners appear in GitHub under:
**Settings → Actions → Runners** (org-level or repo-level depending on your `GITHUB_CONFIG_URL`)

---

## Step 5 — Use in Workflows

```yaml
jobs:
  build-linux:
    runs-on: arc-runner-linux       # matches runnerScaleSetName in linux-values.yaml
    steps:
      - uses: actions/checkout@v4
      - run: docker build -t myapp .

  build-windows:
    runs-on: arc-runner-windows     # matches runnerScaleSetName in windows-values.yaml
    steps:
      - uses: actions/checkout@v4
      - run: dotnet build
```

---

## CI — Building and Pushing Images

The workflow in `.github/workflows/build-and-push.yml` automatically:

1. Builds the Linux image on `ubuntu-latest`
2. Builds the Windows image on `windows-latest` (Windows containers require a Windows build host)
3. Pushes both to GHCR with tags: `latest`, `sha-{short}`, semver (on git tags)
4. Commits the updated image tag back to `helm/linux-values.yaml` and `helm/windows-values.yaml`

### Trigger manually:

Go to **Actions → Build and Push Runner Images → Run workflow**

### Trigger on release:

```bash
git tag v1.0.0
git push origin v1.0.0
```

---

## What's Installed in the Images

### Linux (`docker/linux/Dockerfile`)

| Tool | Version |
|------|---------|
| Ubuntu | 22.04 LTS |
| Docker Engine + BuildKit | 26.1.4 |
| Docker Compose v2 | 2.27.1 |
| Node.js + npm + pnpm + yarn | 20 LTS |
| Python 3 + pip | system |
| Azure CLI | latest |
| kubectl | latest stable |
| Helm | 3.15.1 |
| Trivy | 0.52.1 |
| gcc, g++, make, cmake, build-essential | system |
| git, curl, jq, zip, unzip, rsync | system |

### Windows (`docker/windows/Dockerfile`)

| Tool | Version |
|------|---------|
| Windows Server Core | LTSC 2022 |
| .NET SDK | 8.0 |
| Visual Studio Build Tools 2022 | MSBuild, WebBuild, NetCore |
| Node.js + npm + pnpm + yarn | 20 LTS |
| PowerShell | 7 |
| Azure CLI | latest |
| kubectl + Helm | latest |
| Git for Windows | latest |
| Docker CLI | latest (no DinD — uses host pipe) |
| NuGet CLI | latest |
| 7zip, jq, curl, make | via Chocolatey |

> **Note on Windows Docker builds:** Windows containers do not support Docker-in-Docker.
> To run `docker build` in Windows runner jobs, mount the host Docker named pipe in your pod spec:
> ```yaml
> volumes:
>   - name: docker-pipe
>     hostPath:
>       path: \\.\pipe\docker_engine
>       type: ""
> ```

---

## Namespaces

| Namespace | Purpose |
|-----------|---------|
| `github-controller` | ARC v2 controller pod |
| `github-runners` | Linux runner pods (ephemeral) |
| `github-runners-windows` | Windows runner pods (ephemeral) |

---

## Troubleshooting

### Runners not appearing in GitHub
```bash
kubectl logs -n github-controller deployment/arc-gha-rs-controller --tail=50
kubectl describe AutoscalingRunnerSet -n github-runners
```
- Verify `GITHUB_CONFIG_URL` matches the org/repo the GitHub App is installed on
- Verify all three GitHub App secret fields are correct in `github-runners` namespace:
  ```bash
  kubectl get secret github-app-secret -n github-runners -o jsonpath='{.data}' | python3 -m json.tool | grep -o '"[^"]*":'
  ```

### Pods stuck in Pending
```bash
kubectl describe pod -n github-runners <pod-name>
```
- Check node selectors match available nodes (`kubernetes.io/os: linux`)
- Check resource requests don't exceed node capacity

### Image pull errors
```bash
kubectl get events -n github-runners --sort-by='.lastTimestamp'
```
- Ensure the GHCR package visibility is set to **public**, or create an image pull secret

### Full reset
```bash
./helm-release.sh all latest fresh
```
