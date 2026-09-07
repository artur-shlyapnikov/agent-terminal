@testable import TerminalKit
import XCTest

// Environment resolver filtering (§3.9): DYLD_* stripped, AGENT_TERMINAL_*
// overridden by the app side, PATH/locale preserved, fallback on probe
// failure. The shell command is constructor-injected for determinism.

final class ShellEnvironmentResolverTests: XCTestCase {
    func testInjectedEnvProbeIsParsedAndFiltered() {
        // A tiny shell script prints fixed NUL-separated KEY=VALUE pairs —
        // a fully deterministic fake login shell.
        let fakeProbe = "printf 'HOME=/fakehome\\0PATH=/fakepath\\0DYLD_X=/evil\\0AGENT_TERMINAL_INJECTED=old\\0SSH_AUTH_SOCK=/fakesock\\0LANG=C\\0'"
        let config = ShellEnvironmentResolver.Configuration(
            command: ["/bin/sh", "-c", fakeProbe],
            timeoutSeconds: 3,
            fallbackPATH: "/fallback/bin",
            baseEnvironment: [
                "HOME": "/Users/tester",
                "PATH": "/stale/path",
                "LANG": "en_US.UTF-8",
                "DYLD_INSERT_LIBRARIES": "/evil.dylib",
                "AGENT_TERMINAL_INJECTED": "old",
                "SSH_AUTH_SOCK": "/tmp/agent.sock",
            ]
        )
        let resolver = ShellEnvironmentResolver(configuration: config)

        let resolved = resolver.resolve(overlays: ["AGENT_TERMINAL_INJECTED": "fresh"])

        XCTAssertNil(resolved["DYLD_INSERT_LIBRARIES"], "DYLD_* must be stripped")
        XCTAssertNil(resolved["AGENT_TERMINAL_OLD"])
        XCTAssertEqual(resolved["AGENT_TERMINAL_INJECTED"], "fresh")
        XCTAssertEqual(resolved["HOME"], "/fakehome")
        XCTAssertEqual(resolved["LANG"], "C")
        XCTAssertEqual(resolved["SSH_AUTH_SOCK"], "/fakesock")
        // PATH/locale/SSH_AUTH_SOCK are preserved from the login shell.
        XCTAssertEqual(resolved["PATH"], "/fakepath")
    }

    func testFallbackPathUsedWhenCommandFails() {
        let config = ShellEnvironmentResolver.Configuration(
            command: ["/bin/false"],
            timeoutSeconds: 3,
            fallbackPATH: "/fallback/bin",
            baseEnvironment: ["HOME": "/Users/tester", "PATH": "/stale"]
        )
        let resolver = ShellEnvironmentResolver(configuration: config)

        let resolved = resolver.resolve()

        XCTAssertEqual(resolved["PATH"], "/fallback/bin")
        XCTAssertEqual(resolved["HOME"], "/Users/tester")
    }

    func testTimeoutTerminatesProbeAndFallsBack() {
        let config = ShellEnvironmentResolver.Configuration(
            command: ["/bin/sleep", "30"],
            timeoutSeconds: 1,
            fallbackPATH: "/fallback/bin",
            baseEnvironment: [:]
        )
        let resolver = ShellEnvironmentResolver(configuration: config)

        let started = Date()
        let resolved = resolver.resolve()
        XCTAssertLessThan(Date().timeIntervalSince(started), 10)
        XCTAssertEqual(resolved["PATH"], "/fallback/bin")
    }

    func testDescriptionRedactsSecrets() {
        let resolver = ShellEnvironmentResolver(
            configuration: .init(command: ["/usr/bin/env"])
        )
        let text = "\(resolver) \(String(describing: resolver)) \(resolver.debugDescription)"
        XCTAssertFalse(text.contains("/usr/bin/env"), "probe command must not leak either")
    }

    // MARK: - Round 16 (test-design-16): base AGENT_TERMINAL_* override survival

    func testBaseEnvAgentTerminalOverridesSurviveASuccessfulProbeWithoutCallerOverlays() {
        // fd5417e: base-environment AGENT_TERMINAL_* keys are promoted into
        // effective overlays independent of the caller's `overlays:` map —
        // the login shell's value must lose even when nobody re-declares it.
        let fakeProbe = "printf 'HOME=/fakehome\\0PATH=/fakepath\\0AGENT_TERMINAL_INJECTED=shellside\\0'"
        let config = ShellEnvironmentResolver.Configuration(
            command: ["/bin/sh", "-c", fakeProbe],
            timeoutSeconds: 3,
            fallbackPATH: "/fallback/bin",
            baseEnvironment: [
                "HOME": "/Users/tester",
                "PATH": "/stale/path",
                "AGENT_TERMINAL_INJECTED": "appside",
            ]
        )
        let resolver = ShellEnvironmentResolver(configuration: config)

        let resolved = resolver.resolve(overlays: [:])

        XCTAssertEqual(resolved["AGENT_TERMINAL_INJECTED"], "appside")
        XCTAssertEqual(resolved["PATH"], "/fakepath", "probe succeeded: PATH comes from the login shell")
    }

    func testBaseOverridesSurviveDegradedModeToo() {
        // Same promotion applies on the degraded leg (:77-78): a failed probe
        // must not drop app-side overrides.
        let config = ShellEnvironmentResolver.Configuration(
            command: ["/bin/false"],
            timeoutSeconds: 3,
            fallbackPATH: "/fallback/bin",
            baseEnvironment: [
                "HOME": "/Users/tester",
                "PATH": "/stale/path",
                "AGENT_TERMINAL_MODE": "headless",
            ]
        )
        let resolver = ShellEnvironmentResolver(configuration: config)

        let resolved = resolver.resolve(overlays: [:])

        XCTAssertEqual(resolved["PATH"], "/fallback/bin", "degraded control: fallback PATH in force")
        XCTAssertEqual(resolved["AGENT_TERMINAL_MODE"], "headless")
    }

    func testCallerOverlayBeatsBaseOverrideBeatsProbedValue() {
        // Three-tier precedence pinned per-key: caller overlay > promoted
        // base override > probed shell value; sibling base-only keys survive.
        let fakeProbe = "printf 'HOME=/fakehome\\0PATH=/fakepath\\0AGENT_TERMINAL_INJECTED=shellside\\0'"
        let config = ShellEnvironmentResolver.Configuration(
            command: ["/bin/sh", "-c", fakeProbe],
            timeoutSeconds: 3,
            fallbackPATH: "/fallback/bin",
            baseEnvironment: [
                "HOME": "/Users/tester",
                "PATH": "/stale/path",
                "AGENT_TERMINAL_INJECTED": "appside",
                "AGENT_TERMINAL_ALONE": "onlybase",
            ]
        )
        let resolver = ShellEnvironmentResolver(configuration: config)

        let resolved = resolver.resolve(overlays: ["AGENT_TERMINAL_INJECTED": "callerside"])

        XCTAssertEqual(resolved["AGENT_TERMINAL_INJECTED"], "callerside")
        XCTAssertEqual(resolved["AGENT_TERMINAL_ALONE"], "onlybase",
                       "base-only override key must be promoted even when absent from the caller map")
        XCTAssertEqual(resolved["PATH"], "/fakepath")
    }

    // MARK: - Round 22 (test-design-22): one-pass filter + DYLD-overlay rejection (896c8a0)

    /// 896c8a0: DYLD_* stripping and inherited AGENT_TERMINAL_* removal happen
    /// in ONE filter pass (:84-86); the pre-fix removeValue-during-iteration
    /// skipped members intermittently whenever several AGENT_TERMINAL_* keys
    /// were present — exactly on nested launches. `command: []` forces the
    /// degraded path deterministically. Every key is asserted individually; a
    /// count cannot pin WHICH member a skip bug dropped. Note the app-side
    /// base overrides are re-promoted as effective overlays (:62), so the six
    /// AGENT_TERMINAL_* keys legitimately survive WITH their base values —
    /// only the DYLD_* keys must vanish.
    func testManyAgentTerminalAndDyldKeysAreStrippedInOnePassWithoutSkipping() {
        let agentTerminalKeys = [
            "AGENT_TERMINAL_MODE", "AGENT_TERMINAL_SESSION", "AGENT_TERMINAL_INJECTED",
            "AGENT_TERMINAL_TRACE", "AGENT_TERMINAL_FLAGS", "AGENT_TERMINAL_EXTRA_BASE",
        ]
        let dyldKeys = ["DYLD_INSERT_LIBRARIES", "DYLD_FRAMEWORK_PATH", "DYLD_LIBRARY_PATH"]
        var base: [String: String] = [
            "HOME": "/Users/tester",
            "USER": "tester",
            "TERM": "xterm-256color",
        ]
        for (index, key) in agentTerminalKeys.enumerated() {
            base[key] = "appside-\(index)"
        }
        for (index, key) in dyldKeys.enumerated() {
            base[key] = "/evil-\(index)"
        }

        let config = ShellEnvironmentResolver.Configuration(
            command: [],
            timeoutSeconds: 3,
            fallbackPATH: "/fallback/se1",
            baseEnvironment: base
        )
        let resolver = ShellEnvironmentResolver(configuration: config)

        let resolved = resolver.resolve()
        for key in dyldKeys {
            XCTAssertNil(resolved[key], "\(key) must be stripped")
        }
        for key in agentTerminalKeys {
            XCTAssertEqual(resolved[key], base[key], "\(key) survives as an app-side override with its base value")
        }
        XCTAssertEqual(resolved["HOME"], "/Users/tester")
        XCTAssertEqual(resolved["USER"], "tester")
        XCTAssertEqual(resolved["TERM"], "xterm-256color")
        XCTAssertEqual(resolved["PATH"], "/fallback/se1", "degraded control: fallback PATH in force")

        // Caller overlays land on top; a DYLD_-prefixed OVERLAY is itself
        // rejected by the :87 where-clause — uncovered anywhere before now.
        let overlaid = resolver.resolve(overlays: [
            "AGENT_TERMINAL_EXTRA": "fresh",
            "DYLD_FRAMEWORK_PATH": "/evil-overlay",
        ])
        for key in dyldKeys {
            XCTAssertNil(overlaid[key], "\(key) must never leak through the overlay loop")
        }
        XCTAssertEqual(overlaid["AGENT_TERMINAL_EXTRA"], "fresh")
        for key in agentTerminalKeys {
            XCTAssertEqual(overlaid[key], base[key], "\(key) keeps its promoted value under caller overlays")
        }
    }

    /// Same one-pass filter on the PROBE-SUCCESS path (:72): shell-side
    /// AGENT_TERMINAL_*/DYLD_* values are stripped BEFORE overlays merge, so
    /// the precedence chain caller > base > probed holds even when the shell
    /// injects its own override under a name the app also declares.
    func testProbeSuccessPathAlsoStripsInheritedOverridesBeforeOverlayApplication() {
        let fakeProbe = "printf 'PATH=/probed\\0AGENT_TERMINAL_INJECTED=shellside\\0DYLD_X=/evil\\0LEGIT=yes\\0'"
        let config = ShellEnvironmentResolver.Configuration(
            command: ["/bin/sh", "-c", fakeProbe],
            timeoutSeconds: 3,
            fallbackPATH: "/fallback/se2",
            baseEnvironment: [
                "HOME": "/Users/tester",
                "PATH": "/stale/path",
                "AGENT_TERMINAL_BASE": "appside",
            ]
        )
        let resolver = ShellEnvironmentResolver(configuration: config)

        let resolved = resolver.resolve(overlays: ["AGENT_TERMINAL_INJECTED": "caller"])

        XCTAssertEqual(resolved["AGENT_TERMINAL_INJECTED"], "caller",
                       "caller overlay beats the probed shell-side value")
        XCTAssertNil(resolved["DYLD_X"], "probed DYLD_* must be stripped on the success path too")
        XCTAssertEqual(resolved["LEGIT"], "yes")
        XCTAssertEqual(resolved["PATH"], "/probed")
        XCTAssertEqual(resolved["AGENT_TERMINAL_BASE"], "appside",
                       "base-only override is promoted independently of the caller map")
    }
}
