# Fork Maintenance & Release

This checkout is a personal fork of [`onevcat/Prowl`](https://github.com/onevcat/Prowl).
Fork-only customizations (the TraeCode CLI support) live on a long-lived branch, while
`main` stays a clean mirror of upstream so new upstream work is trivial to pull in.

| Remote | URL | Role |
| --- | --- | --- |
| `origin` | `https://github.com/XFoxer/Prowl.git` | your fork: pushed branches, releases |
| `upstream` | `https://github.com/onevcat/Prowl.git` | source of truth (read-only) |

## 1. Branch model

- `main` — mirrors `upstream/main`, fast-forward only. Never carry customizations here.
- `fork/trae-cli` — long-lived branch with the fork's customizations, kept current by
  periodically merging `upstream/main` into it.

Release from `fork/trae-cli` (the branch that carries the customizations), never from
`main`.

## 2. One-time setup

```bash
git fetch origin --prune
git fetch upstream --prune
git config rerere.enabled true      # reuse conflict resolutions
git config rerere.autoupdate true
# Push over SSH (HTTPS has no stored credentials in this checkout)
git remote set-url --push origin git@github.com:XFoxer/Prowl.git
```

## 3. Daily / periodic sync

```bash
git fetch upstream --prune

# a) keep main a clean mirror of upstream
git checkout main
git merge --ff-only upstream/main
git push origin main

# b) fold upstream into the fork branch
git checkout fork/trae-cli
git merge upstream/main
make build-app && make check
git push origin fork/trae-cli
```

`fork/trae-cli` should always contain the current `origin/main`; that is also what the
release script's freshness check requires, so run step (a) before step (b).

### Merge conflicts

`docs-ai/README.md` conflicts on nearly every sync because the fork and upstream share the
`docs-ai/` numbering space. Resolve by keeping upstream's row and renumbering the fork's
entry to the next free number (e.g. upstream took `081-canvas-layout-modes`, so the fork's
Trae record moved to `082-trae-cli-support`), then update the link in that row. With
`rerere` on, later syncs replay the resolution.

Keep every fork `docs-ai/` addition on a number upstream has not used yet.

## 4. Producing a release build

### 4.1 One-time prerequisites (release machine)

- **Developer ID Application** certificate in the login keychain.
- **Notary credentials** stored for `notarytool`:

  ```bash
  xcrun notarytool store-credentials supacode-notary \
    --apple-id <email> --password <app-specific-password> --team-id <team-id>
  ```

  (override the profile name with `APPLE_NOTARY_KEYCHAIN_PROFILE`.)
- **Sparkle EdDSA key pair** for the fork. The app ships upstream's key, so before the first
  fork release point it at your own pair, otherwise auto-update will reject your appcast:
  - `App/Config/Info.plist` → `SUFeedURL` = `https://github.com/XFoxer/Prowl/releases/latest/download/appcast.xml`
  - `App/Config/Info.plist` → `SUPublicEDKey` = your public key
  - private key at `~/.prowl-sparkle-private-key` (or set `SPARKLE_PRIVATE_KEY_FILE`)
- **Tools**: `gh` (authenticated), `jq`, `create-dmg`, and the bundled
  `scripts/bin/generate_appcast`.
- Optional: `Config/Secrets.env` (copy `Config/Secrets.env.template`) for analytics; `.env`
  (copy `.env.example`) for release environment variables. Both are gitignored.

### 4.2 Local release build (no publish)

Builds a Release archive, signs it locally, installs to `/Applications`:

```bash
make install-release
```

### 4.3 Full notarized release (publish)

Run from `fork/trae-cli` with a clean tree:

```bash
./scripts/release-notes.sh <VERSION>   # generates build/release-notes.md — review it
./scripts/release.sh <VERSION>         # bump, archive, sign, notarize, DMG, appcast, GitHub Release
```

`release.sh` derives the target repository from the `origin` remote, so it publishes to
`XFoxer/Prowl`. It requires `build/release-notes.md` to exist and a clean working tree, and
verifies the checkout already contains `origin/main`.

The script performs:

1. Date-based version bump + signed git tag
2. Release archive (`xcodebuild` Release)
3. dSYM upload / Sentry release (skipped with `SKIP_SENTRY=1`)
4. Re-sign Sparkle/Sentry frameworks and the bundled `prowl` CLI
5. Signed DMG (LZMA) via `create-dmg` + `recompress-dmg.sh`
6. Notarization (`notarytool`) + stapling
7. Sparkle appcast generation (EdDSA)
8. `git push --follow-tags` and a GitHub Release with `Prowl.dmg`, `Prowl.app.zip`, and
   `appcast.xml`

Fork releases must be notarized; never publish a non-notarized build.

### 4.4 Environment variables

| Variable | Default | Purpose |
| --- | --- | --- |
| `APPLE_SIGNING_IDENTITY` | auto-detected | Developer ID Application identity |
| `APPLE_TEAM_ID` | from identity | Apple Team ID |
| `APPLE_NOTARY_KEYCHAIN_PROFILE` | `supacode-notary` | `notarytool` keychain profile |
| `SPARKLE_PRIVATE_KEY_FILE` | `~/.prowl-sparkle-private-key` | EdDSA private key for the appcast |
| `SKIP_SENTRY` | unset | `1` to skip dSYM upload and Sentry tracking |
| `GH_REPO` | from `origin` | override the GitHub repository to publish to |
| `FORCE_RERELEASE` | unset | `1` to replace an existing GitHub Release |
| `NETLIFY_BUILD_HOOK` | unset | leave unset for the fork (no site rebuild) |

### 4.5 Verifying a release

- Download the DMG and install it.
- Launch the app and run **Check for Updates** to confirm Sparkle sees the new appcast.

## 5. Notes

- Version scheme is date-based (`YYYY.M.DD`, with `.N` for same-day re-releases).
- The bundled `/release` skill targets upstream's `main` and onevcat's release
  infrastructure (agent-contract attestation, Prowl-Site). For fork releases, cut from
  `fork/trae-cli` and call `scripts/release.sh` directly; `make install-release` is the
  local, publish-free equivalent.