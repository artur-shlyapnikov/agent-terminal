@testable import AgentCore
import XCTest

// Adapter contract coverage (architecture §3.10): the four built-in adapters,
// their capability table, executable candidates, adapter-generated resume
// commands, bundled manifests and declarative integration plans.

@MainActor
final class AdapterProfileTests: XCTestCase {
    private func reference(_ kind: AgentKind) -> SessionReference {
        SessionReference(agentKind: kind, opaquePayload: "session-42")
    }

    // MARK: Resume commands (§3.10 built-in adapters table)

    func testClaudeResumeCommand() {
        let spec = ClaudeCodeAdapter().buildResumeSpec(sessionReference: reference(.claudeCode))
        XCTAssertEqual(spec?.argv, ["claude", "--resume", "session-42"])
    }

    func testCodexResumeCommand() {
        let spec = CodexAdapter().buildResumeSpec(sessionReference: reference(.codex))
        XCTAssertEqual(spec?.argv, ["codex", "resume", "session-42"])
    }

    func testOpenCodeResumeCommand() {
        let spec = OpenCodeAdapter().buildResumeSpec(sessionReference: reference(.openCode))
        XCTAssertEqual(spec?.argv, ["opencode", "--session", "session-42"])
    }

    func testGenericShellHasNoResume() {
        XCTAssertNil(GenericShellAdapter().buildResumeSpec(sessionReference: reference(.genericShell)))
    }

    func testResumeRejectsForeignSessionReferences() {
        XCTAssertNil(ClaudeCodeAdapter().buildResumeSpec(sessionReference: reference(.codex)))
        XCTAssertNil(CodexAdapter().buildResumeSpec(sessionReference: reference(.openCode)))
        XCTAssertNil(OpenCodeAdapter().buildResumeSpec(sessionReference: reference(.claudeCode)))
    }

    // MARK: Capability table (§3.10 / §3.6)

    func testClaudeAndCodexUseScreenAuthorityWithIdentityHooks() {
        for capabilities in [ClaudeCodeAdapter().capabilities, CodexAdapter().capabilities] {
            XCTAssertTrue(capabilities.sessionIdentity)
            XCTAssertEqual(capabilities.lifecycle, .none)
            XCTAssertTrue(capabilities.screenFallback)
        }
    }

    func testOpenCodeOwnsCompleteLifecycle() {
        let capabilities = OpenCodeAdapter().capabilities
        XCTAssertTrue(capabilities.sessionIdentity)
        guard case let .complete(lease) = capabilities.lifecycle else {
            return XCTFail("OpenCode must report a complete lifecycle, got \(capabilities.lifecycle)")
        }
        XCTAssertEqual(lease, .explicitRelease)
        XCTAssertTrue(capabilities.screenFallback)
    }

    func testGenericShellIsProcessOnly() {
        let capabilities = GenericShellAdapter().capabilities
        XCTAssertFalse(capabilities.sessionIdentity)
        XCTAssertEqual(capabilities.lifecycle, .none)
        XCTAssertFalse(capabilities.screenFallback)
        XCTAssertTrue(capabilities.isProcessOnly)
        XCTAssertFalse(ClaudeCodeAdapter().capabilities.isProcessOnly)
    }

    // MARK: Executable candidates

    func testExecutableCandidates() {
        XCTAssertEqual(ClaudeCodeAdapter().executableCandidates, ["claude"])
        XCTAssertEqual(CodexAdapter().executableCandidates, ["codex"])
        XCTAssertEqual(OpenCodeAdapter().executableCandidates, ["opencode"])
        XCTAssertFalse(GenericShellAdapter().executableCandidates.isEmpty)
    }

    // MARK: Catalog (§4.2 AgentCatalog)

    func testStandardCatalogExposesAllFourBuiltIns() {
        let catalog = AgentCatalog.standard()
        XCTAssertEqual(catalog.allAdapters.count, 4)
        for kind in AgentKind.allCases {
            XCTAssertNotNil(catalog.adapter(for: kind), "missing adapter for \(kind)")
        }
        XCTAssertEqual(catalog.adapter(id: "claude-code")?.displayName, "Claude Code")
        XCTAssertEqual(catalog.adapter(id: "generic-shell")?.displayName, "Shell")
    }

    // MARK: Bundled manifests and launch descriptors

    func testBundledManifestNamesMatchResources() {
        XCTAssertEqual(ClaudeCodeAdapter().bundledManifestName, "claude-code")
        XCTAssertEqual(CodexAdapter().bundledManifestName, "codex")
        XCTAssertEqual(OpenCodeAdapter().bundledManifestName, "opencode")
        XCTAssertNil(GenericShellAdapter().bundledManifestName)
    }

    func testLaunchDescriptorsAreNonSecretAndKinded() throws {
        let request = AgentLaunchRequest(
            agentKind: .claudeCode,
            workingDirectory: "/tmp/proj",
            displayName: "worker"
        )
        let descriptor = try ClaudeCodeAdapter().makeLaunchDescriptor(request: request)
        XCTAssertEqual(descriptor.agentKind, .claudeCode)
        XCTAssertEqual(descriptor.program, "claude")
        XCTAssertEqual(descriptor.workingDirectory, "/tmp/proj")
        XCTAssertTrue(descriptor.environment.isEmpty)

        let spec = ClaudeCodeAdapter().buildLaunchSpec(descriptor: descriptor)
        XCTAssertEqual(spec.argv, ["claude"])
    }

    // MARK: Integration install plans (declarative, marker-namespaced)

    func testInstallPlansCarryManagedMarker() {
        for adapter: any AgentAdapter in [
            ClaudeCodeAdapter(), CodexAdapter(), OpenCodeAdapter(),
        ] {
            let plan = adapter.integrationInstallPlan()
            XCTAssertEqual(plan.adapterID, adapter.id)
            XCTAssertFalse(plan.files.isEmpty)
            for file in plan.files {
                XCTAssertFalse(file.entries.isEmpty)
                for entry in file.entries {
                    XCTAssertEqual(entry.marker, IntegrationInstallPlan.namespaceMarker)
                }
            }
        }
    }

    func testShellInstallPlanIsEmpty() {
        XCTAssertTrue(GenericShellAdapter().integrationInstallPlan().files.isEmpty)
    }

    // MARK: R30-S1 — GenericShell launch descriptor never names an unlaunchable program

    func testBogusSHELLIsSkippedInFavorOfExistingCandidate() throws {
        let saved = ProcessInfo.processInfo.environment["SHELL"]
        setenv("SHELL", "/nonexistent/aterm-r30-bogus-shell", 1)
        defer {
            if let saved {
                setenv("SHELL", saved, 1)
            } else {
                unsetenv("SHELL")
            }
        }

        XCTAssertEqual(GenericShellAdapter().executableCandidates.first, "/nonexistent/aterm-r30-bogus-shell")

        let request = AgentLaunchRequest(
            agentKind: .genericShell,
            workingDirectory: "/tmp/proj-r30",
            displayName: "shell"
        )
        let d = try GenericShellAdapter().makeLaunchDescriptor(request: request)
        XCTAssertNotEqual(d.program, "/nonexistent/aterm-r30-bogus-shell")
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: d.program))
        let expected = ["/bin/zsh", "/bin/bash"].first {
            FileManager.default.isExecutableFile(atPath: $0)
        }
        XCTAssertEqual(d.program, expected)
        XCTAssertEqual(d.agentKind, .genericShell)
        XCTAssertEqual(d.arguments, ["-l"])
        XCTAssertEqual(d.workingDirectory, "/tmp/proj-r30")
    }

    func testShellBuildLaunchSpecPrependsProgramToArguments() throws {
        let request = AgentLaunchRequest(
            agentKind: .genericShell,
            workingDirectory: "/tmp/proj-r30",
            displayName: "shell"
        )
        let d = try GenericShellAdapter().makeLaunchDescriptor(request: request)
        let spec = GenericShellAdapter().buildLaunchSpec(descriptor: d)
        XCTAssertEqual(spec.argv, [d.program, "-l"])
        XCTAssertEqual(spec.workingDirectory, d.workingDirectory)
        XCTAssertEqual(spec.environment, d.environment)
    }
}
