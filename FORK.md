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

  Use the `generate_keys` tool that ships with the resolved Sparkle package (no Homebrew
  install needed). With no existing key it prints the new public key; export the private key
  with `-x`:

  ```bash
  GK="$HOME/Library/Caches/prowl-spm-cache/SourcePackages/artifacts/sparkle/Sparkle/bin/generate_keys"
  "$GK"                          # generate (first time); copy the printed public key into Info.plist
  "$GK" -x "$HOME/.prowl-sparkle-private-key"
  ```

- **Tools**: `gh` (authenticated), `jq`, `create-dmg`, and the bundled
  `scripts/bin/generate_appcast`.

  `create-dmg` comes from mise's npm backend, which installs packages with scripts skipped, so
  its native addons are missing and it dies with `Cannot find module '../build/Release/volume.node'`
  (or `./build/Release/xattr`). Build them once against the mise Node with the local headers:

  ```bash
  MISE_NODE="$HOME/.local/share/mise/installs/node/22.21.1/bin/node"
  NPM_ROOT="$HOME/.local/share/mise/installs/node/22.21.1/lib/node_modules/npm"
  NODEDIR="$HOME/.local/share/mise/installs/node/22.21.1"
  GYP="$NPM_ROOT/node_modules/node-gyp/bin/node-gyp.js"
  MISE_PKGS="$HOME/.local/share/mise/installs/npm-create-dmg/8.1.0/node_modules/.mise"
  # macos-alias needs `nan` resolvable in its own node_modules
  ( cd "$MISE_PKGS/macos-alias@0.2.12/node_modules/macos-alias"
    mkdir -p node_modules
    ln -sf ../../../../nan@2.29.0/node_modules/nan node_modules/nan
    "$MISE_NODE" "$GYP" rebuild --nodedir="$NODEDIR" )
  ( cd "$MISE_PKGS/fs-xattr@0.3.1/node_modules/fs-xattr"
    "$MISE_NODE" "$GYP" rebuild --nodedir="$NODEDIR" )
  ```

  Keep mise's Node (22.21.1) first on `PATH` when running `create-dmg`; if Homebrew's newer
  Node wins the lookup the addons fail with a `NODE_MODULE_VERSION` mismatch.
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

Two fork-specific gotchas on the publish step:

- `make bump-version` creates a **signed** tag (`git tag -s`). Without a GPG key configured
  that fails; `release.sh` recovers by creating a lightweight tag, so the release still
  proceeds with an unsigned tag. Configure a GPG key (`git config user.signingkey`) if you
  want signed tags.
- The script's final `git push --follow-tags` also tries to push every upstream annotated tag
  that is reachable from HEAD. Those tag refs are new on the fork and their commits touch
  `.github/workflows/`, so a fine-grained PAT without `workflow` scope rejects them and the
  push fails. Push the branch and the release tag explicitly instead:

  ```bash
  git push origin fork/trae-cli
  git push origin "refs/tags/v<VERSION>"
  ```

  Then finish the release exactly as the script would — note `scripts/bin/generate_appcast`
  produces `build/appcast.xml` from `build/Prowl.app.zip` + `build/release-notes.md` (copied as
  `Prowl.app.md`), after which the notarized `build/Prowl.dmg`, `build/Prowl.app.zip`, and
  `build/appcast.xml` are uploaded together:

  ```bash
  gh release create "v<VERSION>" build/Prowl.dmg build/Prowl.app.zip build/appcast.xml \
    --repo XFoxer/Prowl --title "Prowl <VERSION>" --notes-file build/release-notes.md
  ```

  (If `generate_appcast` is killed by the machine's security software, just re-run it — it is
  idempotent and rewrites the staging `appcast.xml`.)

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