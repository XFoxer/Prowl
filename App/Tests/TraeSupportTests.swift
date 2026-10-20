import Foundation
import Testing

@testable import Prowl

struct TraeSupportTests {
  private func agent() throws -> DetectedAgent {
    try #require(DetectedAgent(rawValue: "trae"))
  }

  private let home = URL(fileURLWithPath: "/Users/me", isDirectory: true)
  private let now = Date(timeIntervalSince1970: 1_783_800_000)

  // MARK: - Process detection

  @Test func recognizesTheCLIEntrypointsAndLeavesTheDesktopLauncherUnmapped() throws {
    let expected = try agent()
    #expect(identifyAgent(processName: "traecli") == expected)
    #expect(identifyAgent(processName: "traex") == expected)
    #expect(identifyAgent(processName: "trae-cli") == expected)
    #expect(identifyAgent(processName: "trae-agent") == expected)
    // The Trae desktop IDE ships a `trae` launcher; only the CLI entrypoints map.
    #expect(identifyAgent(processName: "trae") == nil)

    // A native executable's name in a wrapper's argv is a prompt token or an
    // install path, never the TUI (score-40 guard, shared with grok/devin/agy).
    let wrapped = ForegroundProcess(
      pid: 400, name: "node", argv0: "node", cmdline: "node /tmp/app.js --model traecli")
    #expect(identifyAgentInJob(ForegroundJob(processGroupID: 400, processes: [wrapped])) == nil)
  }

  // MARK: - Runtime adapter

  /// traecli's TUI notification defaults to off, so a turn completion only
  /// reaches Prowl through Ghostty's OSC 9 callback if the adapter asks for it.
  private static let notificationOptions = [
    "-c", "tui.notifications=true",
    "-c", "tui.notification_method=osc9",
    "-c", "tui.notification_condition=always",
  ]

  @Test func launchBuildsCodexShapedInvocations() throws {
    let runtime = try #require(AgentProfileRuntime(rawValue: "trae"))
    #expect(AgentRuntimeAdapterRegistry.displayName(for: runtime) == "TraeCode CLI")
    #expect(runtime.defaultHomeDirectoryName == ".trae")

    let options =
      ["--model", "gpt-5.6-sol", "-c", "model_reasoning_effort=high"] + Self.notificationOptions
    for (intent, expected) in [
      (AgentStartIntent.interactive, options),
      (.prompt("Review this."), options + ["Review this."]),
      // Headless runs the `exec` subcommand, so it leads the arguments.
      (.headless("Review this."), ["exec"] + options + ["Review this."]),
    ] {
      let invocation = try AgentRuntimeAdapterRegistry.makeStartInvocation(
        AgentStartRequest(
          runtime: runtime, intent: intent,
          configuration: .init(model: "gpt-5.6-sol", reasoningEffort: "high")))
      #expect(invocation.executable == "traecli")
      #expect(invocation.arguments == expected)
    }

    let unrestricted = try AgentRuntimeAdapterRegistry.makeStartInvocation(
      AgentStartRequest(
        runtime: runtime, intent: .interactive, configuration: .init(executionMode: .unrestricted)))
    #expect(
      unrestricted.arguments
        == ["--dangerously-bypass-approvals-and-sandbox"] + Self.notificationOptions)
  }

  @Test func launchEnablesOsc9CompletionNotifications() throws {
    let runtime = try #require(AgentProfileRuntime(rawValue: "trae"))
    let invocation = try AgentRuntimeAdapterRegistry.makeStartInvocation(
      AgentStartRequest(runtime: runtime, intent: .interactive, configuration: .init()))
    // OSC 9 (not `bel`): Prowl's inbox is fed by Ghostty's desktop-notification
    // callback, and its bell counter drives no inbox entry.
    #expect(
      invocation.arguments == [
        "-c", "tui.notifications=true",
        "-c", "tui.notification_method=osc9",
        "-c", "tui.notification_condition=always",
      ])
  }

  @Test func observesModelAndBothUnrestrictedSpellings() throws {
    let runtime = try #require(AgentProfileRuntime(rawValue: "trae"))
    #expect(
      AgentRuntimeAdapterRegistry.observe(
        runtime: runtime,
        arguments: ["traecli", "--model", "gpt-5.6-sol", "--dangerously-bypass-approvals-and-sandbox"])
        == AgentLaunchObservation(model: "gpt-5.6-sol", executionMode: .unrestricted))
    #expect(
      AgentRuntimeAdapterRegistry.observe(runtime: runtime, arguments: ["traecli", "-m", "gpt-5.6-sol", "-y"])
        == AgentLaunchObservation(model: "gpt-5.6-sol", executionMode: .unrestricted))
    #expect(
      AgentRuntimeAdapterRegistry.observe(
        runtime: runtime, arguments: ["traecli", "--permission-mode", "bypass_permissions"]
      )
      .executionMode == .unrestricted)
    // A different permission preset is not unrestricted.
    #expect(
      AgentRuntimeAdapterRegistry.observe(runtime: runtime, arguments: ["traecli", "--permission-mode", "auto"])
        .executionMode == nil)
  }

  @Test func accountIsolationRelocatesTheTraeHome() throws {
    let runtime = try #require(AgentProfileRuntime(rawValue: "trae"))
    let adapter = try #require(AgentRuntimeAdapterRegistry.profileAdapter(for: runtime))
    #expect(adapter.supportsModelSelection)
    #expect(adapter.supportsReasoningEffort)
    #expect(adapter.executionModeOptions == [.standard, .unrestricted])
    #expect(adapter.supportsAccountIsolation)
    #expect(adapter.accountHomeEnvironmentVariable == "TRAE_HOME")
    #expect(adapter.accountIsolation?.sessionRootRelativePath == "cli")
    #expect(adapter.signalHooks == nil)
    // TRAE_HOME points at the managed home; traecli stores sessions under its
    // `cli` child, so the session config root is the managed home plus `cli`.
    let managedHome = URL(fileURLWithPath: "/Users/me/.prowl/agent-profiles/trae", isDirectory: true)
    let isolation = try #require(adapter.accountIsolation)
    #expect(isolation.pathArguments.isEmpty)
    #expect(isolation.sessionConfigRoot(for: managedHome).path == "/Users/me/.prowl/agent-profiles/trae/cli")
  }

  // MARK: - Session ownership

  @Test func sessionOwnershipParsesRolloutJSONLUnderTheTraeHome() throws {
    let profile = AgentSessionProfile.profile(for: try agent())
    let id = "01a1247d-ef57-71f0-b191-88f7a3132dea"
    let path = "/Users/me/.trae/cli/sessions/2026/10/10/rollout-2026-10-10T14-26-35-\(id).jsonl"
    let session = try #require(profile.parsePath(path))
    #expect(session.id == id)
    #expect(session.transcriptPath?.path == path)
    // A rollout file outside the sessions tree must not parse.
    #expect(profile.parsePath("/tmp/rollout-2026-10-10T14-26-35-\(id).jsonl") == nil)
  }

  @Test func sessionRootsNarrowToProcessLifetimeDays() throws {
    let profile = AgentSessionProfile.profile(for: try agent())
    let roots = profile.candidateRoots(home, nil, now, now)
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.calendar = Calendar(identifier: .gregorian)
    formatter.dateFormat = "yyyy/MM/dd"
    // One day before the process start through today — here the same day, so
    // two day directories: yesterday and today.
    let calendar = Calendar(identifier: .gregorian)
    let yesterday = calendar.startOfDay(for: now.addingTimeInterval(-86_400))
    let today = calendar.startOfDay(for: now)
    #expect(
      roots.map(\.path)
        == [
          "/Users/me/.trae/cli/sessions/\(formatter.string(from: yesterday))",
          "/Users/me/.trae/cli/sessions/\(formatter.string(from: today))",
        ])
    #expect(profile.fallbackRoots(home, nil).map(\.path) == ["/Users/me/.trae/cli/sessions"])
  }

  // MARK: - Screen detection

  @Test func trustDialogReadsAsBlocked() throws {
    let agent = try agent()
    let screen = """
      You are in /Users/me/App

      Do you trust the contents of this directory?

      ❯ 1. Yes, continue
        2. No, quit

      Press enter to continue
      """
    #expect(agent.detectState(in: screen) == .blocked)
  }

  @Test func numberedSelectionDialogReadsAsBlocked() throws {
    let agent = try agent()
    let screen = """
      Allow the agent to run this command?

      rm -rf build

      ❯ 1. Approve
        2. Deny

      Press enter to continue
      """
    #expect(agent.detectState(in: screen) == .blocked)
  }

  @Test func interruptHintReadsAsWorking() throws {
    let agent = try agent()
    let screen = """
      ❯ Refactor the parser

      ──────────────────────────────
      ✻ Thinking… (esc to interrupt)
      """
    #expect(agent.detectState(in: screen) == .working)
  }

  @Test func idleFooterUnderTheComposerReadsAsIdle() throws {
    let agent = try agent()
    let screen = """
      Done.

      ❯
      ────────────────────────────────────────────────
      DeepSeek-V4.1-Flash · Context 100% left · /Users/me/App ▧ Workspace Edit
      """
    #expect(agent.detectState(in: screen) == .idle)
  }

  @Test func transcriptNumberedListWithoutSelectionMarkStaysUnknown() throws {
    let agent = try agent()
    // The composer is gone and no selection glyph is present, so a plain
    // numbered list is transcript history, never a live dialog.
    let screen = """
      Here are the steps to follow:
      1. First
      2. Second
      """
    #expect(agent.detectState(in: screen) == .unknown)
  }

  @Test func unrecognizedScreenFailsTowardUnknown() throws {
    let agent = try agent()
    #expect(agent.detectState(in: "screen without a live rule") == .unknown)
  }

  // MARK: - Screen detection: region anchoring (regressions)

  @Test func quotedTrustQuestionUnderARunningIndicatorReadsAsWorking() throws {
    let agent = try agent()
    // The transcript quotes a trust dialog verbatim, but the live composer box
    // below still carries the interrupt hint: the quoted dialog is history and
    // must not outrank the running turn.
    let screen = """
      The CLI once asked:
      Do you trust the contents of this directory?
      ❯ 1. Yes, continue
        2. No, quit

      ❯
      ────────────────────────────────────────────────
      ✻ Thinking… (esc to interrupt)
      """
    #expect(agent.detectState(in: screen) == .working)
  }

  @Test func numberedDraftInsideAnIdleComposerReadsAsIdle() throws {
    let agent = try agent()
    // A two-line numbered draft typed into the composer is the user's input, not
    // a live choice dialog; the status row below it reads idle.
    let screen = """
      ❯ 1. First draft line
        2. Second draft line
      ────────────────────────────────────────────────
      DeepSeek-V4.1-Flash · Context 100% left · /Users/me/App ▧ Workspace Edit
      """
    #expect(agent.detectState(in: screen) == .idle)
  }

  @Test func interruptWordsInsideAnIdleComposerReadAsIdle() throws {
    let agent = try agent()
    // `to interrupt` typed as the draft must not read as a running turn.
    let screen = """
      ❯ Explain how to interrupt a task
      ────────────────────────────────────────────────
      DeepSeek-V4.1-Flash · Context 100% left · /Users/me/App ▧ Workspace Edit
      """
    #expect(agent.detectState(in: screen) == .idle)
  }

  // MARK: - Screen detection: TraeCode CLI 0.201.7 (on-prem) fixtures

  @Test func onPremIdleComposerWithIndentedStatusRowReadsAsIdle() throws {
    let agent = try agent()
    // Captured from the on-prem 0.201.7 TUI: the built-in status row is indented
    // two spaces below the closing border, so it is read by signature, not column.
    let border = String(repeating: "─", count: 120)
    let screen = """
      ➜  CBrain git:(feature/2.36) traecli
      ╭───────────────────────────────────────────────────╮
      │ █ ◆ ◆ █  TraeCode CLI (v0.201.7)                  │
      ╰───────────────────────────────────────────────────╯

        Tip: Use /statusline to configure which items appear in the status line.

      \(border)
      ❯ Explain this codebase
      \(border)
        DeepSeek-V4.1-Flash · Context 100% left · ~/opt/CBrain · feature/2.36 · +1881 -341  ▧ Workspace Edit
      """
    #expect(agent.detectState(in: screen) == .idle)
  }

  @Test func onPremWorkingIndicatorAboveTheComposerReadsAsWorking() throws {
    let agent = try agent()
    // Captured mid-turn on the on-prem 0.201.7 TUI: the status row is identical
    // to the idle one, so only the `◆ Working… (… esc to interrupt)` line above
    // the box — separated from it by the rotating tip — proves the running turn.
    let border = String(repeating: "─", count: 120)
    let screen = """
      ✔ Auto-reviewer approved TraeCode CLI to run mkdir -p /tmp/probe this time

      ◆ Working… (3m 55s • ↑ 20.8K tokens • esc to interrupt)
        └ Tip: Pipe command output into `traecli exec 'summarize this'` to include stdin as context.
      \(border)
      ❯ Find and fix a bug in @filename
      \(border)
        DeepSeek-V4.1-Flash · Context 74% left · ~/opt/Prowl · fork/trae-cli · +1070 -49  ⛉ Auto Mode
      """
    #expect(agent.detectState(in: screen) == .working)
  }

  @Test func todoChecklistBetweenIndicatorAndComposerReadsAsWorking() throws {
    let agent = try agent()
    // Captured mid-turn on the on-prem 0.201.7 TUI while the agent's todo widget
    // was live: the `❖ … (esc to interrupt)` indicator heads a multi-row block —
    // the running turn, then its checklist — that sits several rows above the box,
    // so the block, not a fixed few rows above the prompt, carries the hint. The
    // status row below the box is identical to the idle one, so missing the
    // indicator reads a running turn as idle.
    let border = String(repeating: "─", count: 120)
    let screen = """
      ✔ Auto-reviewer approved TraeCode CLI to run something this time

      ❖ Root-causing the traecli false-Idle bug… (24m 24s • ↑ 131K tokens • esc to interrupt)
        └ ■ Root-cause why the agent shows idle after a long idle
          ◻ Fix the detector in ScreenHeuristics.swift
          ◻ Add fixtures in TraeSupportTests.swift
          ◻ Run make build-app and make check
      \(border)
      ❯ Find and fix a bug in @filename
      \(border)
        DeepSeek-V4.1-Flash · Context 46% left · ~/opt/Prowl · fork/trae-cli · +1252 -52  ⛉ Auto Mode
      """
    #expect(agent.detectState(in: screen) == .working)
  }

  @Test func todoChecklistAndWrappedTipAboveTheComposerReadAsWorking() throws {
    let agent = try agent()
    // The live block may also carry the rotating tip under the indicator, and at
    // a narrow width the indicator and the tip wrap — the hint still heads the
    // same blank-bounded run, so the running turn must not fall back to the idle
    // status row.
    let border = String(repeating: "─", count: 80)
    let screen = """
      ◆ Working… (12s • esc to interrupt) · 1 shell running
      to manage
        └ Tip: Press Tab to queue a message when a task is
      running; otherwise it sends immediately.
      \(border)
      ❯ Improve documentation in @filename
      \(border)
        DeepSeek-V4.1-Flash · Context 96% left · ~/opt/Prowl · fork/trae-cli  ▧ Workspace Edit
      """
    #expect(agent.detectState(in: screen) == .working)
  }

  @Test func mcpServerBootLineAboveAnIdleComposerReadsAsIdle() throws {
    let agent = try agent()
    // Cold start: before the session is ready traecli heads the live block with a
    // boot progress line that reuses the interrupt footer (`✧ Starting MCP servers
    // (1/3): … (0s • esc to interrupt)`) while the composer below is the ordinary
    // idle box. Reading it as a running turn flashed Working through startup and
    // then let the settle to idle earn a spurious Done badge.
    let border = String(repeating: "─", count: 168)
    let screen = """
      ╭───────────────────────────────────────────────────╮
      │ █ ◆ ◆ █  TraeCode CLI (v0.201.7)                  │
      ╰───────────────────────────────────────────────────╯

        Tip: Press Ctrl+O to open the transcript view.

      ✧ Starting MCP servers (1/3): XcodeBuildMCP, code-review-graph (0s • esc to interrupt)
      \(border)
      ❯ Improve documentation in @filename
      \(border)
        DeepSeek-V4.1-Flash · Context 100% left · /private/tmp/trae-cold2  ▧ Workspace Edit
      """
    #expect(agent.detectState(in: screen) == .idle)
  }

  @Test func interruptHintWithAnUnrelatedStartingTitleStillReadsAsWorking() throws {
    let agent = try agent()
    // The boot-line exclusion is scoped to the MCP progress phrase, not to
    // `Starting`: a real turn indicator whose title happens to begin with
    // `Starting` must still read as Working.
    let border = String(repeating: "─", count: 168)
    let screen = """
      ◆ Starting the refactor… (12s • esc to interrupt)
      \(border)
      ❯ Find and fix a bug in @filename
      \(border)
        DeepSeek-V4.1-Flash · Context 74% left · ~/opt/Prowl  ⛉ Auto Mode
      """
    #expect(agent.detectState(in: screen) == .working)
  }

  @Test func statusRowWithoutAComposerStaysUnknown() throws {
    let agent = try agent()
    // The idle signature alone, with no composer box above it, is not evidence of
    // a live idle prompt — the screen must fail toward unknown.
    let screen = """
      Here is the last line of output.
      DeepSeek-V4.1-Flash · Context 100% left · /Users/me/App ▧ Workspace Edit
      """
    #expect(agent.detectState(in: screen) == .unknown)
  }

  @Test func onPremIndentedApprovalDialogReadsAsBlocked() throws {
    let agent = try agent()
    // Captured live on the on-prem 0.201.7 TUI: an MCP tool approval replaces the
    // composer with a dialog rendered inside the live block's two-space gutter, so
    // the `❯` selection mark is indented, not column-0. Requiring column 0 made the
    // real dialog read unknown, and the state machine then kept the running turn's
    // stale Working instead of clearing it to Blocked.
    let border = String(repeating: "─", count: 168)
    let screen = """
      ◆ Calling mobile-mcp.mobile_save_screenshot({"device":"Pixel_10_Pro_XL","saveTo":"/tmp/shot1.png"})
      \(border)
        Field 1/1
        Allow the mobile-mcp MCP server to run tool "mobile_save_screenshot"?

        device: Pixel_10_Pro_XL
        saveTo: /tmp/shot1.png

        ❯ 1. Allow                   Run the tool and continue.
          2. Allow for this session  Run the tool and remember this choice for this session.
          3. Always allow            Run the tool and remember this choice for future tool calls.
          4. Cancel                  Cancel this tool call
        enter to submit | esc to cancel
      """
    #expect(agent.detectState(in: screen) == .blocked)
  }

  @Test func onPremIndentedElicitationFormReadsAsBlocked() throws {
    let agent = try agent()
    // An elicitation form asks the user to type a value, so it carries no numbered
    // options and no `❯` mark — only the indented fields and the live footer. The
    // footer vocabulary (` to submit`, `to navigate fields|questions`) is verified
    // against the 0.201.7 binary; without it the form read unknown and a running
    // turn's Working never cleared.
    let border = String(repeating: "─", count: 168)
    let screen = """
      ◆ Calling some-mcp.some_tool({})
      \(border)
        Field 1/1
        Enter a name for the new workspace

        name:

        ↑/↓ to navigate fields   esc to cancel
      """
    #expect(agent.detectState(in: screen) == .blocked)
  }

  @Test func selectionMarkWithoutAComposerOrSiblingStaysUnknown() throws {
    let agent = try agent()
    // A stray `❯`-marked numbered line with no closing composer border and no
    // unselected sibling is neither a composer nor a live dialog: unknown.
    let screen = """
      Steps to reproduce:
      ❯ 1. Only one option shown
      """
    #expect(agent.detectState(in: screen) == .unknown)
  }

  // MARK: - Screen detection: review fixes (tail budget, convergence, y/n, auth)

  @Test func tallChecklistPushingTheHintPastTheTailStillReadsAsWorking() throws {
    let agent = try agent()
    // The running indicator heads a blank-bounded block whose todo checklist grows
    // without bound. When the block is taller than a 24-line tail, that fixed tail
    // dropped the hint and the idle status row below the box decided the turn. The
    // detector now reads the whole active screen, so the indicator survives.
    let border = String(repeating: "─", count: 120)
    let todo = (1...30).map { "  ◻ Checklist item number \($0) for the running plan" }
      .joined(separator: "\n")
    let screen = """
      ✔ Auto-reviewer approved TraeCode CLI to run something this time

      ❖ Root-causing the traecli false-Idle bug… (24m 24s • ↑ 131K tokens • esc to interrupt)
      \(todo)
      \(border)
      ❯ Find and fix a bug in @filename
      \(border)
        DeepSeek-V4.1-Flash · Context 46% left · ~/opt/Prowl · fork/trae-cli · +1252 -52  ⛉ Auto Mode
      """
    #expect(agent.detectState(in: screen) == .working)
  }

  @Test func composerWithAnUnrecognizedStatusRowReadsAsIdle() throws {
    let agent = try agent()
    // A composer renders only a live prompt. With no running hint above the box and
    // no recognized status row below it, the turn has settled: returning unknown
    // let the state machine retain the previous turn's stale Working.
    let border = String(repeating: "─", count: 120)
    let screen = """
      \(border)
      ❯ Explain this codebase
      \(border)
        Some footer signature the detector does not know
      """
    #expect(agent.detectState(in: screen) == .idle)
  }

  @Test func quotedComposerAboveTheLiveIdleComposerReadsAsIdle() throws {
    let agent = try agent()
    // A quoted composer left in the transcript carries the running hint, but only
    // the bottom-most prompt+border box is live. Its own blank-bounded block has no
    // indicator and its status row is idle, so the live state is idle regardless of
    // the quoted one above.
    let border = String(repeating: "─", count: 120)
    let screen = """
      ◆ Working… (2m 0s • esc to interrupt)
      ❯ A quoted composer echoed in the transcript
      \(border)

      ❯ A real live prompt
      \(border)
        DeepSeek-V4.1-Flash · Context 100% left · ~/opt/Prowl ▧ Workspace Edit
      """
    #expect(agent.detectState(in: screen) == .idle)
  }

  @Test func bracketedYesNoConfirmationReadsAsBlocked() throws {
    let agent = try agent()
    // traecli renders a y/n confirmation as a bracketed token at the end of the
    // prompt line rather than a numbered menu. Missing it left a blocking question
    // reading unknown, so a running turn's Working never cleared to Blocked.
    let screen = """
      The agent wants to write build/output.bin.

      Overwrite build/output.bin? [y/N]
      """
    #expect(agent.detectState(in: screen) == .blocked)
  }

  @Test func loginScreenReadsAsBlocked() throws {
    let agent = try agent()
    // The interactive login/auth screens replace the composer like a dialog but use
    // a `>` menu or free-form fields, so the numbered/`❯` shapes never match them.
    // A distinctive header plus its Enter/Esc chrome is the live signature.
    let screen = """
      Sign in with browser account
      > Sign in with Device Code

      Press Enter to sign in
      Press Esc to cancel
      """
    #expect(agent.detectState(in: screen) == .blocked)
  }

  @Test func transcriptMentioningLoginWithoutChromeStaysUnknown() throws {
    let agent = try agent()
    // The header phrase alone — echoed transcript text — is not a live login screen:
    // without the Enter/Esc chrome it must not read as blocked.
    let screen = """
      The tool printed: Sign in with browser account failed.
      Retrying the request now.
      """
    #expect(agent.detectState(in: screen) == .unknown)
  }

  @Test func blockerTextReadsTheLiveDialogAndIsNilOtherwise() throws {
    let agent = try agent()
    // `agents read` reports the blocked screen's own text. It reuses the detector's
    // shape rules: the blank-bounded run carrying the bottom-most dialog marker.
    let border = String(repeating: "─", count: 168)
    let blocked = """
      ◆ Calling mobile-mcp.mobile_save_screenshot({})
      \(border)
        Field 1/1
        Allow the mobile-mcp MCP server to run tool "mobile_save_screenshot"?

        device: Pixel_10_Pro_XL
        saveTo: /tmp/shot1.png

        ❯ 1. Allow                   Run the tool and continue.
          2. Allow for this session  Run the tool and remember this choice for this session.
          3. Always allow            Run the tool and remember this choice for future tool calls.
          4. Cancel                  Cancel this tool call
        enter to submit | esc to cancel
      """
    let text = try #require(traeBlockerText(in: agent.detectionSnapshot(from: blocked)))
    #expect(text.contains("1. Allow"))
    #expect(text.contains("esc to cancel"))

    let idle = """
      \(border)
      ❯ Explain this codebase
      \(border)
        DeepSeek-V4.1-Flash · Context 100% left · ~/opt/Prowl ▧ Workspace Edit
      """
    #expect(traeBlockerText(in: agent.detectionSnapshot(from: idle)) == nil)
  }

  // MARK: - Clipped live chrome and the title corroboration

  @Test func clippedLiveHeaderKeepingOnlyElapsedChromeReadsAsWorking() throws {
    let agent = try agent()
    // traecli clips live chrome to the pane width before writing it, so a live-block
    // header whose streaming snippet is wide loses its tail: the running footer reaches
    // the terminal as `<glyph> <snippet> (42m 53s • ↑ 183K tokens …`, with neither
    // `esc to interrupt` nor the `/ps` chrome. Reading that frame as a settled composer
    // flipped a running turn to Idle — and earned a spurious Done on an unviewed pane —
    // while the turn was still streaming. The header line below is the one captured live
    // from traecli 0.209.1 at the moment the badge flipped.
    let border = String(repeating: "─", count: 120)
    let clippedHeader =
      "❖ The live block header might be rendered *above* the visible window when the live block is tall "
      + "and the pane is short! (42m 53s • ↑ 183K tokens …"
    let screen = """
      \(clippedHeader)
        └ ■ Fix the false Idle badge
          ◻ Add a regression test
      \(border)
      ❯ Find and fix a bug in @filename
      \(border)
        DeepSeek-V4.1-Flash · Context 64% left · ~/opt/Prowl · feat/traecli-support · +1582 -58  ⛉ Auto Mode
      """
    #expect(agent.detectState(in: screen) == .working)
  }

  @Test func proseMentioningElapsedChromeWithoutALiveGlyphStaysIdle() throws {
    let agent = try agent()
    // Only a column-0 live glyph makes a line the live block's header. Prose, tool
    // output, and quoted chrome (`└ Run finished (2s · timeout 2m)`) must not be able
    // to speak for a settled composer, or the badge would stick on Working.
    let border = String(repeating: "─", count: 120)
    let screen = """
      Teardown took (42m 53s • ↑ 183K tokens) in the previous run.

        └ Run finished (2s • timeout 2m)
      \(border)
      ❯ Find and fix a bug in @filename
      \(border)
        DeepSeek-V4.1-Flash · Context 64% left · ~/opt/Prowl · feat/traecli-support · +1582 -58  ⛉ Auto Mode
      """
    #expect(agent.detectState(in: screen) == .idle)
  }

  @Test func titleSpinnerMarksARunningTurn() throws {
    // The TUI animates a braille spinner ahead of the thread title while a turn runs.
    #expect(traeTitleShowsRunningTurn("⠋ 排查修复traecli状态显示异常 | Prowl"))
    #expect(traeTitleShowsRunningTurn("⠸ Fix iOS H5 input keyboard issue | CBrain-S"))
    // Settled turns, unnamed threads, and shells carry no spinner.
    #expect(!traeTitleShowsRunningTurn("排查修复traecli状态显示异常 | Prowl"))
    #expect(!traeTitleShowsRunningTurn("Run tick loop and report ticks | trae-scrolltest"))
    #expect(!traeTitleShowsRunningTurn(""))
    #expect(!traeTitleShowsRunningTurn(nil))
    // A braille glyph anywhere but the front is not the running mark.
    #expect(!traeTitleShowsRunningTurn("Fix ⠋ the spinner"))
  }

  @Test func titleSpinnerCorroboratesAnIdleScreenVerdict() throws {
    let agent = try agent()
    let idle = AgentScreenDetection(state: .idle, reason: .legacyDetector)
    let working = AgentScreenDetection(state: .working, reason: .legacyDetector)
    let blocked = AgentScreenDetection(state: .blocked, reason: .legacyDetector)

    let corroborated = WorktreeTerminalState.corroboratedScreenDetection(
      idle, agent: agent, title: "⠋ Fix the false Idle badge | Prowl")
    #expect(corroborated.state == .working)
    #expect(corroborated.reason == .titleSpinner)

    // A settled title leaves the screen verdict alone, whatever it says.
    #expect(
      WorktreeTerminalState.corroboratedScreenDetection(
        idle, agent: agent, title: "Fix the false Idle badge | Prowl") == idle)
    #expect(
      WorktreeTerminalState.corroboratedScreenDetection(
        working, agent: agent, title: "⠋ Fix the false Idle badge | Prowl") == working)
    // A dialog the screen reports stays reported while the turn keeps running.
    #expect(
      WorktreeTerminalState.corroboratedScreenDetection(
        blocked, agent: agent, title: "⠋ Fix the false Idle badge | Prowl") == blocked)
    // The corroboration is traecli's: another agent's title spinner is not evidence.
    #expect(
      WorktreeTerminalState.corroboratedScreenDetection(
        idle, agent: .codex, title: "⠋ Codex | Prowl") == idle)
  }
}
