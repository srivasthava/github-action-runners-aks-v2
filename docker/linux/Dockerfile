#───────────────────────────────────────────────────────────────────────────────
# Custom GitHub Actions Runner — Linux (ARC v2 compatible)
#
# Build essentials included:
#   - Docker Engine + BuildKit + Compose v2
#   - Node.js 20 LTS + npm + pnpm
#   - Python 3 + pip
#   - Azure CLI
#   - kubectl + Helm
#   - git, curl, jq, make, gcc, zip, unzip, and more
#   - Trivy (container vulnerability scanner)
#───────────────────────────────────────────────────────────────────────────────

FROM ubuntu:22.04

# Versions — pin for reproducibility
ARG RUNNER_VERSION=2.332.0
ARG DOCKER_VERSION=26.1.4
ARG DOCKER_COMPOSE_VERSION=2.27.1
ARG NODE_VERSION=20
ARG HELM_VERSION=3.15.1
ARG TRIVY_VERSION=0.69.3

ENV DEBIAN_FRONTEND=noninteractive
ENV RUNNER_ALLOW_RUNASROOT=1
ENV DOCKER_BUILDKIT=1

LABEL org.opencontainers.image.source="https://github.com/srivasthava/github-action-runners-aks-v2"
LABEL description="GitHub Actions Runner with Docker-in-Docker for AKS (ARC v2)"

#───────────────────────────────────────────────────────────────────────────────
# Base packages + build essentials
#───────────────────────────────────────────────────────────────────────────────
RUN apt-get update && apt-get install -y --no-install-recommends \
    # Core utilities
    ca-certificates \
    curl \
    wget \
    git \
    jq \
    unzip \
    zip \
    tar \
    gzip \
    gnupg \
    lsb-release \
    software-properties-common \
    apt-transport-https \
    # Build essentials
    build-essential \
    gcc \
    g++ \
    make \
    cmake \
    pkg-config \
    # Runner runtime dependencies
    libicu70 \
    libssl3 \
    libkrb5-3 \
    zlib1g \
    # Networking
    iputils-ping \
    dnsutils \
    net-tools \
    openssh-client \
    # Process management
    tini \
    # Python
    python3 \
    python3-pip \
    python3-venv \
    # Misc
    rsync \
    gettext-base \
    && rm -rf /var/lib/apt/lists/*

#───────────────────────────────────────────────────────────────────────────────
# Docker Engine (for DinD)
#───────────────────────────────────────────────────────────────────────────────
RUN curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
    | gpg --dearmor -o /usr/share/keyrings/docker-archive-keyring.gpg \
    && echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/docker-archive-keyring.gpg] \
       https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" \
       > /etc/apt/sources.list.d/docker.list \
    && apt-get update \
    && apt-get install -y --no-install-recommends \
       docker-ce docker-ce-cli containerd.io docker-buildx-plugin \
    && rm -rf /var/lib/apt/lists/*

# Docker Compose v2
RUN curl -fsSL "https://github.com/docker/compose/releases/download/v${DOCKER_COMPOSE_VERSION}/docker-compose-linux-$(uname -m)" \
    -o /usr/local/bin/docker-compose \
    && chmod +x /usr/local/bin/docker-compose \
    && ln -s /usr/local/bin/docker-compose /usr/local/lib/docker/cli-plugins/docker-compose 2>/dev/null || true

#───────────────────────────────────────────────────────────────────────────────
# Node.js 20 LTS + pnpm
#───────────────────────────────────────────────────────────────────────────────
RUN curl -fsSL https://deb.nodesource.com/setup_${NODE_VERSION}.x | bash - \
    && apt-get install -y nodejs \
    && npm install -g pnpm@latest yarn@latest \
    && rm -rf /var/lib/apt/lists/*

#───────────────────────────────────────────────────────────────────────────────
# Azure CLI
#───────────────────────────────────────────────────────────────────────────────
RUN curl -sL https://aka.ms/InstallAzureCLIDeb | bash \
    && rm -rf /var/lib/apt/lists/*

#───────────────────────────────────────────────────────────────────────────────
# kubectl (latest stable)
#───────────────────────────────────────────────────────────────────────────────
RUN curl -fsSL "https://dl.k8s.io/release/$(curl -sL https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl" \
    -o /usr/local/bin/kubectl \
    && chmod +x /usr/local/bin/kubectl

#───────────────────────────────────────────────────────────────────────────────
# Helm
#───────────────────────────────────────────────────────────────────────────────
RUN curl -fsSL https://get.helm.sh/helm-v${HELM_VERSION}-linux-amd64.tar.gz \
    | tar xz -C /usr/local/bin --strip-components=1 linux-amd64/helm

#───────────────────────────────────────────────────────────────────────────────
# Trivy (vulnerability scanner)
#───────────────────────────────────────────────────────────────────────────────
RUN curl -fsSL "https://github.com/aquasecurity/trivy/releases/download/v${TRIVY_VERSION}/trivy_${TRIVY_VERSION}_Linux-64bit.deb" \
    -o /tmp/trivy.deb \
    && dpkg -i /tmp/trivy.deb \
    && rm /tmp/trivy.deb

#───────────────────────────────────────────────────────────────────────────────
# GitHub Actions Runner
#───────────────────────────────────────────────────────────────────────────────
WORKDIR /home/runner

RUN curl -fsSL "https://github.com/actions/runner/releases/download/v${RUNNER_VERSION}/actions-runner-linux-x64-${RUNNER_VERSION}.tar.gz" \
    | tar xz \
    && ./bin/installdependencies.sh \
    && rm -rf /var/lib/apt/lists/*

#───────────────────────────────────────────────────────────────────────────────
# Entrypoint
# ARC v2 injects /home/runner/run.sh as the container command.
# entrypoint.sh starts Docker first, then exec's into the ARC command.
#───────────────────────────────────────────────────────────────────────────────
COPY entrypoint.sh /home/runner/entrypoint.sh
RUN chmod +x /home/runner/entrypoint.sh

VOLUME /var/lib/docker

HEALTHCHECK --interval=30s --timeout=10s --start-period=60s --retries=3 \
    CMD pgrep -f "Runner.Listener" > /dev/null || exit 1

ENTRYPOINT ["tini", "--", "/home/runner/entrypoint.sh"]
CMD ["/home/runner/run.sh"]
