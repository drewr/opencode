# Upgrade opencode from upstream

## Quick start

```bash
bash packages/opencode/script/upgrade.sh
```

Flags: `--dry-run` (preview changes), `--no-build` (commit but skip nix build).

## What the script does

1. Fetches `upstream/dev`
2. Updates `package.json` `packageManager` to match upstream's bun version
3. If nixpkgs' bun < upstream's bun, relaxes the version check in `packages/script/src/index.ts` from `^<version>` to `^1`
4. Commits with `chore: upgrade to upstream <commit> (bun@<version>)`
5. Builds via `nix run .#opencode -- --version`

## Manual upgrade (when the script isn't enough)

### 1. Merge upstream

```bash
export SSH_AUTH_SOCK="$HOME/.ssh/ssh_auth_sock"
git fetch upstream dev
git merge upstream/dev --no-ff -m "chore: merge upstream dev <commit>"
```

Use `--no-ff` because the fork has its own commits (upgrade script, hash fixes) that diverge from upstream.

### 2. Update nix hashes

If the build fails with a hash mismatch for `node_modules`, update `nix/hashes.json`:

```json
{
  "nodeModules": {
    "x86_64-linux": "<new hash from build error>",
    ...
  }
}
```

The correct hash appears in the nix build error output as `got: sha256-...`.

### 3. Build

```bash
nix run .#opencode -- --version
```

## Known issues & workarounds

### SSH access

SSH agent is at `~/.ssh/ssh_auth_sock` (stable symlink from sshd rc). Set `SSH_AUTH_SOCK` before any git operations.

### GPG signing

Commits require `-c user.signingkey=` to bypass SSH-based GPG signing (the local key isn't available in the agent).

### Dirty tree check

The `.qwen/` directory is untracked and makes `git status --porcelain` non-empty. Use `git status --porcelain -u no` to ignore untracked files.

### Bun version mismatch

nixpkgs-unstable ships bun@1.3.13; upstream's `packageManager` is bun@1.3.14. The version check in `packages/script/src/index.ts` must be relaxed to `^1` so the nix build doesn't fail. The upgrade script handles this automatically.

### Disk space

The nix build needs ~2GB free. If the build fails with "No space left on device", run `nix-collect-garbage -d` first.
