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
}
