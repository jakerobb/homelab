# The ARC runner image: the stock Actions runner plus everything lint.yml
# needs, so a job doesn't spend ~60s downloading Python, Node, Renovate, helm
# and friends on every run. Built and pushed by .github/workflows/runner-image.yml;
# used by the scale set in argocd/apps/arc-runners/application.yaml.
#
# Build context is the repo root (it copies docs-site/requirements.txt), e.g.:
#   docker build -f images/arc-runner/Dockerfile -t arc-runner-test .
#
# amd64 and arm64 both work (TARGETARCH), so the image can follow the cluster
# when the Pi worker joins; the workflow only builds amd64 for now.
#
# Every tool version below is an ARG with a Renovate annotation (renovate.json,
# "Dockerfile tool versions"), so bumps arrive as PRs like everything else.
# The workflow's own checks would catch a bad bump at the next lint run.

FROM ghcr.io/actions/actions-runner:2.337.0

LABEL org.opencontainers.image.source="https://github.com/jakerobb/homelab" \
      org.opencontainers.image.description="ARC runner for jakerobb/homelab lint: Actions runner + python, node, renovate, helm, kubectl, kubeconform, shellcheck, actionlint"

ARG TARGETARCH

# renovate: datasource=github-releases depName=helm/helm
ARG HELM_VERSION=v4.3.0
# renovate: datasource=github-releases depName=yannh/kubeconform
ARG KUBECONFORM_VERSION=v0.8.0
# renovate: datasource=github-releases depName=kubernetes/kubernetes
ARG KUBECTL_VERSION=v1.37.1
# renovate: datasource=github-releases depName=koalaman/shellcheck
ARG SHELLCHECK_VERSION=v0.11.0
# renovate: datasource=github-releases depName=rhysd/actionlint
ARG ACTIONLINT_VERSION=v1.7.12
# renovate: datasource=node-version depName=node
ARG NODE_VERSION=24.21.0
# renovate: datasource=npm depName=renovate
ARG RENOVATE_VERSION=44.132.4

USER root

# python3-venv: Ubuntu's Python is externally managed (PEP 668), so the
# packages below go in a venv, put first on PATH further down.
RUN apt-get update \
 && apt-get install -y --no-install-recommends python3-venv xz-utils \
 && rm -rf /var/lib/apt/lists/*

# Static binaries, checksum-verified where upstream publishes checksums.
# shellcheck doesn't, so that one rides on TLS to GitHub alone.
RUN set -eux; \
    cd /tmp; \
    case "$TARGETARCH" in \
      amd64) sc_arch=x86_64; node_arch=x64 ;; \
      arm64) sc_arch=aarch64; node_arch=arm64 ;; \
      *) echo "unsupported arch: $TARGETARCH" >&2; exit 1 ;; \
    esac; \
    \
    f="helm-${HELM_VERSION}-linux-${TARGETARCH}.tar.gz"; \
    curl -fsSLO "https://get.helm.sh/$f"; \
    curl -fsSL "https://get.helm.sh/$f.sha256sum" | sha256sum -c -; \
    tar -xzf "$f" --strip-components=1 -C /usr/local/bin "linux-${TARGETARCH}/helm"; \
    \
    f="kubeconform-linux-${TARGETARCH}.tar.gz"; \
    base="https://github.com/yannh/kubeconform/releases/download/${KUBECONFORM_VERSION}"; \
    curl -fsSLO "$base/$f"; \
    curl -fsSL "$base/CHECKSUMS" | grep " $f\$" | sha256sum -c -; \
    tar -xzf "$f" -C /usr/local/bin kubeconform; \
    \
    base="https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/${TARGETARCH}"; \
    curl -fsSLo /usr/local/bin/kubectl "$base/kubectl"; \
    echo "$(curl -fsSL "$base/kubectl.sha256")  /usr/local/bin/kubectl" | sha256sum -c -; \
    chmod +x /usr/local/bin/kubectl; \
    \
    curl -fsSL "https://github.com/koalaman/shellcheck/releases/download/${SHELLCHECK_VERSION}/shellcheck-${SHELLCHECK_VERSION}.linux.${sc_arch}.tar.gz" \
      | tar -xz --strip-components=1 -C /usr/local/bin "shellcheck-${SHELLCHECK_VERSION}/shellcheck"; \
    \
    f="actionlint_${ACTIONLINT_VERSION#v}_linux_${TARGETARCH}.tar.gz"; \
    base="https://github.com/rhysd/actionlint/releases/download/${ACTIONLINT_VERSION}"; \
    curl -fsSLO "$base/$f"; \
    curl -fsSL "$base/actionlint_${ACTIONLINT_VERSION#v}_checksums.txt" | grep " $f\$" | sha256sum -c -; \
    tar -xzf "$f" -C /usr/local/bin actionlint; \
    \
    f="node-v${NODE_VERSION}-linux-${node_arch}.tar.xz"; \
    base="https://nodejs.org/dist/v${NODE_VERSION}"; \
    curl -fsSLO "$base/$f"; \
    curl -fsSL "$base/SHASUMS256.txt" | grep " $f\$" | sha256sum -c -; \
    tar -xJf "$f" --strip-components=1 -C /usr/local --exclude='*.md' --exclude=LICENSE; \
    \
    rm -f /tmp/*.tar.gz /tmp/*.tar.xz

# renovate-config-validator, for lint.yml's "Renovate config" step.
RUN npm install -g --no-fund --no-audit "renovate@${RENOVATE_VERSION}" \
 && npm cache clean --force

# Python: PyYAML (the scripts/ci checks), pyflakes (actionlint's `run: python`
# checks), and the docs build's own pins, so `pip install -r
# docs-site/requirements.txt` in lint.yml is a no-op unless a PR changes them.
COPY images/arc-runner/requirements.txt /tmp/requirements.txt
COPY docs-site/requirements.txt /tmp/docs-requirements.txt
RUN python3 -m venv /opt/lint-venv \
 && /opt/lint-venv/bin/pip install --no-cache-dir -r /tmp/requirements.txt -r /tmp/docs-requirements.txt \
 && rm /tmp/requirements.txt /tmp/docs-requirements.txt

ENV PATH=/opt/lint-venv/bin:$PATH

USER runner
