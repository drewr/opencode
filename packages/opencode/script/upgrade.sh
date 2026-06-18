#!/usr/bin/env bash
set -euo pipefail

# upgrade.sh — Upgrade opencode from upstream and build via nix
# Usage: bun run script/upgrade.sh [--dry-run] [--no-build]

REPO_ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
UPSTREAM="upstream"
BRANCH="dev"

# Ensure SSH agent socket is available (stable symlink from sshd rc)
if [[ -L "$HOME/.ssh/ssh_auth_sock" ]]; then
  export SSH_AUTH_SOCK="$HOME/.ssh/ssh_auth_sock"
fi

# ── helpers ──────────────────────────────────────────────────────────
info()  { echo "[upgrade] $*"; }
warn()  { echo "[upgrade] WARNING: $*" >&2; }
die()   { echo "[upgrade] ERROR: $*" >&2; exit 1; }

# ── flags ────────────────────────────────────────────────────────────
DRY_RUN=false
NO_BUILD=false
while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run)  DRY_RUN=true;   shift ;;
    --no-build) NO_BUILD=true;  shift ;;
    *)          die "Unknown argument: $1" ;;
  esac
done

cd "$REPO_ROOT"

# ── 1. Validate state ───────────────────────────────────────────────
current_branch="$(git branch --show-current)"
if [[ "$current_branch" != "$BRANCH" ]]; then
  warn "Not on $BRANCH (on $current_branch); switching..."
  git switch "$BRANCH"
fi

if [[ -n "$(git status --porcelain -u no)" ]]; then
  die "Working tree is dirty. Commit or stash changes before upgrading."
fi

# ── 2. Fetch upstream ───────────────────────────────────────────────
if ! git remote get-url "$UPSTREAM" &>/dev/null; then
  die "No '$UPSTREAM' remote configured. Add it with:"
  die "  git remote add upstream https://github.com/opencode-ai/opencode.git"
fi

info "Fetching upstream..."
git fetch "$UPSTREAM" "$BRANCH"

upstream_commit="$(git rev-parse "$UPSTREAM/$BRANCH")"
local_commit="$(git rev-parse "HEAD")"

if [[ "$upstream_commit" == "$local_commit" ]]; then
  info "Already at upstream commit $upstream_commit — nothing to do."
  exit 0
fi

info "Upstream is at $upstream_commit; local is at $local_commit"

# ── 3. Read upstream packageManager version ─────────────────────────
upstream_pkg_manager="$(git show "$UPSTREAM/$BRANCH:package.json" | \
  grep -o '"packageManager"[[:space:]]*:[[:space:]]*"[^"]*"' | \
  grep -o 'bun@[^"]*')"
upstream_bun_version="${upstream_pkg_manager#bun@}"

info "Upstream packageManager: $upstream_pkg_manager"

# ── 4. Read local packageManager version ────────────────────────────
local_pkg_manager="$(grep -o '"packageManager"[[:space:]]*:[[:space:]]*"[^"]*"' package.json | \
  grep -o 'bun@[^"]*')"
local_bun_version="${local_pkg_manager#bun@}"

# ── 5. Read nixpkgs bun version ─────────────────────────────────────
nixpkgs_bun_version="$(nix eval --impure --raw --expr \
  '(import <nixpkgs> { system = "x86_64-linux"; }).bun.version' 2>/dev/null || echo "unknown")"

info "Local packageManager: $local_pkg_manager"
info "nixpkgs bun version:  $nixpkgs_bun_version"

# ── 6. Determine if changes are needed ──────────────────────────────
needs_pkg_json_update=false
needs_version_check_update=false

if [[ "$local_bun_version" != "$upstream_bun_version" ]]; then
  needs_pkg_json_update=true
fi

# If nixpkgs bun < upstream bun, the version check needs relaxing
if [[ "$nixpkgs_bun_version" != "unknown" ]] && \
   [[ "$(printf '%s\n%s' "$nixpkgs_bun_version" "$upstream_bun_version" | sort -V | head -1)" != "$upstream_bun_version" ]]; then
  needs_version_check_update=true
fi

if [[ "$needs_pkg_json_update" == false && "$needs_version_check_update" == false ]]; then
  info "No version changes needed. Upstream packageManager already matches."
fi

# ── 7. Apply changes ────────────────────────────────────────────────
if [[ "$DRY_RUN" == true ]]; then
  info "[dry-run] Would update packageManager from $local_pkg_manager → $upstream_pkg_manager"
  if [[ "$needs_version_check_update" == true ]]; then
    info "[dry-run] Would relax bun version check in packages/script/src/index.ts"
  fi
  exit 0
fi

# Update package.json
if [[ "$needs_pkg_json_update" == true ]]; then
  info "Updating packageManager to $upstream_pkg_manager..."
  sed -i "s/\"packageManager\"[[:space:]]*:[[:space:]]*\"bun@${local_bun_version}\"/\"packageManager\": \"bun@${upstream_bun_version}\"/" package.json
fi

# Update version check in packages/script/src/index.ts
if [[ "$needs_version_check_update" == true ]]; then
  if grep -q 'const expectedBunVersionRange = `^1`' packages/script/src/index.ts; then
    info "Bun version check already relaxed to ^1, skipping."
  else
    info "Relaxing bun version check to ^1..."
    sed -i 's/const expectedBunVersionRange = `\\^${expectedBunVersion}`/const expectedBunVersionRange = `^1`/' \
      packages/script/src/index.ts
  fi
fi

# ── 8. Commit ───────────────────────────────────────────────────────
git add package.json packages/script/src/index.ts packages/opencode/script/upgrade.sh
git -c user.signingkey= commit -m "chore: upgrade to upstream $upstream_commit (bun@$upstream_bun_version)"

# ── 9. Build via nix ────────────────────────────────────────────────
if [[ "$NO_BUILD" == true ]]; then
  info "Skipping nix build (--no-build). Commit was:"
  git log -1 --oneline
  exit 0
fi

info "Building via nix..."
nix run .#opencode -- --version

# ── 10. Verify ──────────────────────────────────────────────────────
info "Verifying..."
version="$(nix run .#opencode -- --version)"
info "Version: $version"

info "Upgrade complete!"
info "  Commit: $(git log -1 --oneline)"
info "  Upstream: $upstream_commit"
info "  Bun: $upstream_bun_version"
