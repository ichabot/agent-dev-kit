#!/usr/bin/env bash
# Pinned versions of everything the agent VPS services download (sourced, no side effects).
# Images are pinned by tag AND digest (multi-arch index digest), binaries by sha256.
# Update procedure: docs/agent-vps.md, section "Versionen aktualisieren".
# shellcheck disable=SC2034  # consumed by the scripts that source this file

# Gitea (rootful image: its entrypoint writes app.ini from GITEA__* variables as root,
# then runs gitea as uid 1000 inside the container).
ADK_GITEA_IMAGE="docker.io/gitea/gitea:28.3.0@sha256:8967bf9deaf3c5c4adae13519436dc1b20c646ac83fe37ae810c933a1045227d"

# Caddy: stock image for http01, builder (contains xcaddy) + base for the dns01 image.
ADK_CADDY_VERSION="2.11.9"
ADK_CADDY_IMAGE="docker.io/library/caddy:2.11.9-alpine@sha256:0bbb055bda6793c999bde78b1b5ce3e89f829fb031af2cf50056ea1246559fee"
ADK_CADDY_BUILDER_IMAGE="docker.io/library/caddy:2.11.9-builder-alpine@sha256:646fee578e680989ca5c7fd1ce6f1de574d19fd71ef2221810cc0510a9f40c86"

# caddy-dns modules with a pinned version. Only providers whose Caddyfile syntax takes a
# single API token ("acme_dns <name> <token>") are listed; others need a kit change.
declare -A ADK_CADDY_DNS_MODULES=(
  [hetzner]="github.com/caddy-dns/hetzner/v2@v2.0.1"
  [cloudflare]="github.com/caddy-dns/cloudflare@v0.2.4"
  [ionos]="github.com/caddy-dns/ionos@v1.3.0"
  [desec]="github.com/caddy-dns/desec@v1.1.0"
)

# Gitea runner (formerly act_runner), static binary from dl.gitea.com.
ADK_RUNNER_VERSION="5.4.1"
declare -A ADK_RUNNER_SHA256=(
  [amd64]="7c4b1bd1fbc0d0dfb5a09bfa70b89e550a0af15fc90a911df7ccaeb348143508"
  [arm64]="3ba021458e7a7ea4e8b685451caaea77de0e1aeaca1448d2501c46ec270eae1e"
)
# Job image behind the runner label ubuntu-latest (Node, git, Docker CLI with Buildx).
ADK_RUNNER_JOB_IMAGE="docker.io/gitea/runner-images:ubuntu-24.04-v26.11.03@sha256:b96ba465021b1a4c6a1c9e79220c2b9bfad0f29b09dbb528bbfb35411443a3a4"
