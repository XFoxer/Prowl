# 082 — TraeCode CLI (`traecli`) Support: Action Log

## Timeline

| Date | Change | Ref |
| --- | --- | --- |
| 2026-10-12 | Verified `traecli` 0.201.7 (`--help`, `exec --help`): `-m/--model`, `-c/--config <key=value>`, `--permission-mode <bypass_permissions\|auto\|default>`, `-y/--dangerously-bypass-approvals-and-sandbox`; `exec [PROMPT]`. Confirmed `TRAE_HOME` relocates the whole `~/.trae` tree (config and `cli/sessions`) | branch `feature/traecli-support` |
| 2026-10-12 | Added `DetectedAgent.trae`, `AgentProfileRuntime.trae`, `TraeRuntimeAdapter`, session profile, legacy screen detector, classifier entries, tab icon, skill target, CLI schema enums, docs, and tests | branch `feature/traecli-support` |
| 2026-10-12 | Green: `make build-app`, `make check`, CLI build/unit/smoke/integration, focused app suites (`TraeSupportTests`, `AgentClassifierTests`, `AgentRuntimeAdapterTests`, `AgentSessionResolverTests`, `ScreenHeuristicsTests`) | branch `feature/traecli-support` |
| 2026-10-14 | Live on-prem 0.201.7 TUI showed the detector missed the two-space-indented status row and the `◆ Working…` line above the composer; rewrote `detectTrae` to match the status row by signature and read the working indicator first | branch `fork/trae-cli` |
| 2026-10-14 | A finished traecli turn never reached Prowl's inbox because the CLI's `tui.notifications` defaults off; `TraeRuntimeAdapter.makeStartInvocation` now injects `-c tui.notifications=true -c tui.notification_method=osc9 -c tui.notification_condition=always` (values verified accepted by the on-prem binary) | branch `fork/trae-cli` |

## Outcome & current state (as of 2026-10-12)

First-class `traecli` support landed at the Antigravity tier (077), with no managed
hook channel. What exists now:

- **Detection** — `DetectedAgent.trae` (rawValue `trae`) in
  `App/Sources/Domain/AgentDetection/DetectedAgent.swift`. `knownAgentBinaries` maps
  `traecli`/`traex`/`trae-cli`/`trae-agent` to it; bare `trae` is deliberately unmapped
  so the IDE launcher is never classified as the CLI. The score-40 native-name guard
  rejects those four names when they appear as prompt/path tokens in a wrapper's argv
  (`App/Sources/Infrastructure/AgentDetection/AgentClassifier.swift`).
- **Profile / runtime** — `AgentProfileRuntime.trae` in
  `App/Sources/Domain/AgentProfile/AgentProfile.swift` (`defaultHomeDirectoryName`
  `.trae`). `TraeRuntimeAdapter` in
  `App/Sources/Domain/AgentRuntime/AgentRuntimeAdapter.swift` reuses Codex's flag
  spellings (`--model`/`-m`; `-c model_reasoning_effort=low|medium|high|xhigh|max`;
  Unrestricted via `--dangerously-bypass-approvals-and-sandbox`, observed from `-y` or
  `--permission-mode bypass_permissions`), launches `traecli` (prompted seeds a trailing
  positional; headless runs `traecli exec <prompt>`), and declares account isolation
  through `TRAE_HOME` with session root `cli`.
- **Session ownership** — inline `AgentSessionProfile.trae` in
  `App/Sources/Infrastructure/AgentDetection/AgentSessionProfile.swift`: marker
  `/.trae/cli/sessions/`, Codex-shaped day-directory candidate roots under
  `~/.trae/cli/sessions`, full-root fallback, and `TRAE_HOME`-rooted variants.
- **Screen state** — legacy detector in
  `App/Sources/Infrastructure/AgentDetection/ScreenHeuristics.swift` (24-line tail):
  directory-trust / numbered choice dialogs marked by a column-0 `❯` read Blocked; an
  `esc to interrupt` hint reads Working; the `❯` composer with a
  `<model> · Context <n>% left · <cwd> ▧ Workspace Edit` status row reads Idle. The
  `detectLegacyScreen` switch was split into a head/tail pair to stay under SwiftLint's
  cyclomatic-complexity budget.
- **Completion notifications** — traecli's TUI notification is off by default and Prowl's
  inbox is fed only by Ghostty's OSC 9 desktop-notification callback, so `traecli` turns
  were silent. `TraeRuntimeAdapter.makeStartInvocation` injects the three `-c` overrides
  above for every Prowl-launched session; a manually launched `traecli` needs the same
  values under `[tui]` in `~/.trae/traecli.toml`.
- **Icon** — `Trae` asset (`App/Sources/Assets.xcassets/CommandIcons/Trae.imageset/`,
  Simple Icons CC0 mark, template rendering), keyed by `trae`/`trae-cli`/`traecli`/`traex`
  in `App/Sources/Features/Terminal/Models/CommandIconMap.swift`.
- **Skill target** — `SkillInstallTarget(id: "trae", …)` in
  `Shared/Sources/ProwlCLIShared/SkillInstallTarget.swift` (user `~/.trae/skills`, project
  `.agents/skills`), with `trae` added to the four enums in
  `CLI/Sources/ProwlCLIContracts/Resources/cli-output-schema.json` and to the
  `skills`/root help copy in `CLI/Sources/prowl/Commands/`.
- **Tests** — `App/Tests/TraeSupportTests.swift` (detection, adapter launch/observe/isolation,
  session ownership + roots, screen detection) plus `trae` rows in
  `App/Tests/AgentClassifierTests.swift`, `App/Tests/AgentRuntimeAdapterTests.swift`, the
  three `CLI/Tests/ProwlCLITests/*` catalogs, and `scripts/make-detection-fixture.py`.
- **Docs** — `docs/components/{cli,settings,agent-detection,agent-profiles,workflows}.md`
  and `skills/prowl-cli/SKILL.md`, `skills/prowl-workflow/references/authoring.md`.

## Deviations from plan

- **Screen detector ships as legacy, not a typed `TraeScreenProfile`.** As anticipated in
  the plan, the working-footer signature could not be captured against a standalone
  `traecli` TUI (the shared TraeCode app-server was serving this session's own pane), so
  the working rule is the binary-verified `to interrupt` hint and no fixture corpus was
  produced.
- **Managed hook channel remains out of scope** (`hook_trae`), unchanged from the plan.
- **`detectLegacyScreen` was restructured** (head/tail split) to keep SwiftLint's
  `cyclomatic_complexity` at or below 15 after the new `.trae` case; behavior is unchanged.

## Open questions

- The precise live working footer (interrupt-hint text and spinner glyph) once a
  standalone `traecli` TUI can be captured without the shared app-server.
- Whether the composer drops a paste-adjacent Enter the way Devin does; add
  `AgentComposerProfile` coverage only if `prowl send` acceptance shows dropped delivery.