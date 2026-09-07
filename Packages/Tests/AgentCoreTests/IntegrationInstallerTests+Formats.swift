@testable import AgentCore
import Foundation
import XCTest

extension IntegrationInstallerTests {
    // MARK: TOML format (codex-style config)

    func testTOMLInstallUpgradeAndSelectiveUninstall() throws {
        let tomlPath = "cfg/config.toml"
        try writeUserConfig(tomlPath, content: """
        model = "gpt-9"
        [profile]
        name = "work"

        """)

        func codexPlan(version: Int) -> IntegrationInstallPlan {
            IntegrationInstallPlan(
                adapterID: "codex-test",
                files: [
                    IntegrationFileEdit(
                        targetPathTemplate: tomlPath,
                        format: .toml,
                        entries: [
                            ManagedConfigEntry(
                                keyPath: ["agentterminal"],
                                valueJSON: "{\"marker\":\"\(IntegrationInstallPlan.namespaceMarker)\",\"version\":\(version)}",
                                marker: IntegrationInstallPlan.namespaceMarker
                            ),
                        ]
                    ),
                ]
            )
        }

        // Install appends a delimited managed block; user content untouched.
        let installed = try installer.install(plan: codexPlan(version: 1))
        XCTAssertEqual(installed.outcome, .installed)
        let afterInstall = readUserConfig(tomlPath)
        XCTAssertTrue(afterInstall.contains("model = \"gpt-9\""))
        XCTAssertTrue(afterInstall.contains("[profile]"))
        XCTAssertTrue(afterInstall.contains("[agentterminal]"))
        XCTAssertTrue(IntegrationInstaller.extractManagedBlock(in: afterInstall, adapterID: "codex-test") != nil)

        // Idempotent reinstall is a no-op.
        let again = try installer.install(plan: codexPlan(version: 1))
        XCTAssertEqual(again.outcome, .noChanges)

        // Clean upgrade swaps the block.
        let upgraded = try installer.install(plan: codexPlan(version: 2))
        XCTAssertEqual(upgraded.outcome, .upgraded)
        XCTAssertTrue(readUserConfig(tomlPath).contains("version = 2"))

        // Selective uninstall strips only the block.
        let removed = try installer.uninstall(plan: codexPlan(version: 2))
        XCTAssertEqual(removed.removed.count, 1)
        let afterRemoval = readUserConfig(tomlPath)
        XCTAssertFalse(afterRemoval.contains("[agentterminal]"))
        XCTAssertTrue(afterRemoval.contains("model = \"gpt-9\""))
        XCTAssertTrue(afterRemoval.contains("[profile]"))
    }

    func testTOMLUpgradeConflictsWhenUserEditedManagedBlock() throws {
        try writeUserConfig("cfg/config.toml", content: "")
        let plan: () -> IntegrationInstallPlan = {
            IntegrationInstallPlan(
                adapterID: "codex-test",
                files: [
                    IntegrationFileEdit(
                        targetPathTemplate: "cfg/config.toml",
                        format: .toml,
                        entries: [ManagedConfigEntry(
                            keyPath: ["agentterminal"],
                            valueJSON: "{\"marker\":\"\(IntegrationInstallPlan.namespaceMarker)\"}",
                            marker: IntegrationInstallPlan.namespaceMarker
                        )]
                    ),
                ]
            )
        }
        _ = try installer.install(plan: plan())

        // User hand-edits inside the managed block.
        let edited = readUserConfig("cfg/config.toml").replacingOccurrences(of: "marker =", with: "hand_tuned_marker =")
        try edited.data(using: .utf8)?.write(to: home.appendingPathComponent("cfg/config.toml"))

        let report = try installer.install(plan: plan())
        guard case let .conflict(paths) = report.outcome else { return XCTFail("expected conflict") }
        XCTAssertEqual(paths.count, 1)
    }

    // MARK: JavaScript whole-file format (opencode plugin)

    func testJavaScriptWholeFileInstallUninstallAndConflict() throws {
        // Mirrors the shipped plugin: first line is the AgentTerminal banner.
        let script = "// AgentTerminal — test plugin (\(IntegrationInstallPlan.namespaceMarker))\nexport const p = 1;\n"
        let plan: () -> IntegrationInstallPlan = {
            IntegrationInstallPlan(
                adapterID: "opencode-test",
                files: [
                    IntegrationFileEdit(targetPathTemplate: "plugins/lifecycle.js", format: .javaScript, entries: [
                        ManagedConfigEntry(
                            keyPath: [],
                            valueJSON: script,
                            marker: IntegrationInstallPlan.namespaceMarker
                        ),
                    ]),
                ]
            )
        }

        // Fresh install.
        let report = try installer.install(plan: plan())
        XCTAssertEqual(report.outcome, .installed)
        XCTAssertEqual(readUserConfig("plugins/lifecycle.js"), script)

        // Reinstall unchanged → noChanges.
        XCTAssertEqual(try installer.install(plan: plan()).outcome, .noChanges)

        // Uninstall removes the file we own.
        let removal = try installer.uninstall(plan: plan())
        XCTAssertEqual(removal.removed, [home.appendingPathComponent("plugins/lifecycle.js").path])
        XCTAssertFalse(FileManager.default.fileExists(atPath: home.appendingPathComponent("plugins/lifecycle.js").path))

        let userData = try XCTUnwrap("// mine".data(using: .utf8))
        try userData.write(to: home.appendingPathComponent("plugins/lifecycle.js"))
        let conflictReport = try installer.install(plan: plan())
        guard case .conflict = conflictReport.outcome else { return XCTFail("expected conflict") }
        XCTAssertEqual(readUserConfig("plugins/lifecycle.js"), "// mine")
    }

    /// §5.3 ownership proof: a user file that merely QUOTES the namespace
    /// marker inside its body is never deleted as an "orphaned" install.
    func testUserFileQuotingMarkerIsNeverDeletedOnUninstall() throws {
        let userScript = "// my own notes about com.agentterminal.managed\nconsole.log('mine');\n"
        try writeUserConfig("plugins/notes.js", content: userScript)

        let plan = IntegrationInstallPlan(
            adapterID: "opencode-test",
            files: [
                IntegrationFileEdit(targetPathTemplate: "plugins/notes.js", format: .javaScript, entries: [
                    ManagedConfigEntry(
                        keyPath: [],
                        valueJSON: userScript,
                        marker: IntegrationInstallPlan.namespaceMarker
                    ),
                ]),
            ]
        )
        let report = try installer.uninstall(plan: plan)
        XCTAssertTrue(report.removed.isEmpty, "a quoting user file must never be removed")
        XCTAssertEqual(report.skippedUserModified, [home.appendingPathComponent("plugins/notes.js").path])
        XCTAssertEqual(readUserConfig("plugins/notes.js"), userScript)
    }

    /// Orphan adoption (marker present, nothing recorded) must CONFLICT when
    /// the entry carries keys we would not contribute ourselves — the merge
    /// below would silently swallow them.
    func testOrphanAdoptionConflictsWhenEntryContainsUserKeys() throws {
        try writeUserConfig("cfg/settings.json", content:
            #"{"hooks":{"agentterminal-marker":"com.agentterminal.managed","user-key":"mine"}}"#)

        let report = try installer.install(plan: claudeLikePlan(configPath: "cfg/settings.json"))
        guard case .conflict = report.outcome else {
            return XCTFail("expected conflict for orphaned entry with user keys, got \(report.outcome)")
        }
        let document = try XCTUnwrap(try JSONSerialization
            .jsonObject(with: Data(readUserConfig("cfg/settings.json").utf8)) as? [String: Any])
        let hooks = try XCTUnwrap(document["hooks"] as? [String: Any])
        XCTAssertEqual(hooks["user-key"] as? String, "mine", "user key must survive untouched")
        XCTAssertNil(hooks["version"], "nothing new may be merged into a conflicted entry")
    }

    // MARK: Repair diagnostics (§3.17 degraded mode)

    func testDiagnoseReportsHealthyNotInstalledAndUserModified() throws {
        let plan = claudeLikePlan(configPath: "cfg/settings.json")
        XCTAssertEqual(installer.diagnose(plan: plan), .notInstalled)

        try writeUserConfig("cfg/settings.json", content: "{}")
        _ = try installer.install(plan: plan)
        XCTAssertEqual(installer.diagnose(plan: plan), .healthy)

        let tamperedData = try XCTUnwrap(#"{"hooks":{"agentterminal-marker":"tampered"}}"#.data(using: .utf8))
        try tamperedData.write(to: home.appendingPathComponent("cfg/settings.json"))
        guard case let .userModified(paths) = installer.diagnose(plan: plan) else {
            return XCTFail("expected userModified")
        }
        XCTAssertEqual(paths, ["\(home.path)/cfg/settings.json#hooks"])

        let corruptData = try XCTUnwrap("not json {{{".data(using: .utf8))
        try corruptData.write(to: home.appendingPathComponent("cfg/settings.json"))
        guard case let .corrupted(reason) = installer.diagnose(plan: plan) else {
            return XCTFail("expected corrupted")
        }
        XCTAssertTrue(reason.contains("does not parse"))
    }

    // MARK: R10-D — uninstall ledger retention on partial skip

    /// §3.17: uninstall where one entry is removed and another is skipped as
    /// user-modified must retain EXACTLY the survivor's fingerprint. Wiping
    /// the ledger unconditionally would let a later install adopt-and-
    /// overwrite the surviving user-modified file.
    func testPartialUninstallKeepsOnlySurvivorFingerprintsInAdoptionLedger() throws {
        let script = "// AgentTerminal — test plugin (\(IntegrationInstallPlan.namespaceMarker))\nexport const p = 1;\n"
        let jsPlan = IntegrationInstallPlan(
            adapterID: "test-adapter",
            files: [
                IntegrationFileEdit(targetPathTemplate: "plugins/lifecycle.js", format: .javaScript, entries: [
                    ManagedConfigEntry(
                        keyPath: [],
                        valueJSON: script,
                        marker: IntegrationInstallPlan.namespaceMarker
                    ),
                ]),
            ]
        )

        // Install both plans; each records its fingerprint.
        try writeUserConfig("cfg/settings.json", content: #"{"v":1}"#)
        _ = try installer.install(plan: claudeLikePlan(configPath: "cfg/settings.json"))
        _ = try installer.install(plan: jsPlan)
        XCTAssertEqual(recording.fingerprints(adapterID: "test-adapter").count, 2)

        // The user replaces the plugin with a script that merely QUOTES the
        // namespace marker — guaranteed user-modified skip on uninstall.
        let userScript = "// my own notes about com.agentterminal.managed\nconsole.log('mine');\n"
        try writeUserConfig("plugins/lifecycle.js", content: userScript)

        let jsPath = home.appendingPathComponent("plugins/lifecycle.js").path
        let combinedPlan = IntegrationInstallPlan(
            adapterID: "test-adapter",
            files: claudeLikePlan(configPath: "cfg/settings.json").files + jsPlan.files
        )
        let report = try installer.uninstall(plan: combinedPlan)

        XCTAssertEqual(report.removed.count, 1, "the settings entry must be removed")
        XCTAssertEqual(report.skippedUserModified, [jsPath])

        // The ledger keeps EXACTLY the survivor's fingerprint.
        let survivors = recording.fingerprints(adapterID: "test-adapter")
        XCTAssertEqual(survivors.count, 1, "the removed settings fingerprint must be gone")
        XCTAssertEqual(survivors.first?.targetPath, jsPath)
        XCTAssertEqual(survivors.first?.entryKeyPath, [])

        // The retained fingerprint still gates orphan adoption: a second
        // uninstall finds the quoting user file and must NOT delete it (with
        // a wiped ledger the empty-recording rule would adopt-and-remove it).
        let second = try installer.uninstall(plan: jsPlan)
        XCTAssertTrue(second.removed.isEmpty, "the retained fingerprint must keep gating deletion")
        XCTAssertEqual(second.skippedUserModified, [jsPath])
        XCTAssertEqual(readUserConfig("plugins/lifecycle.js"), userScript)

        // Once the file is gone from the disk entirely, the next uninstall
        // has nothing to protect and finally clears the ledger.
        try FileManager.default.removeItem(atPath: jsPath)
        _ = try installer.uninstall(plan: jsPlan)
        XCTAssertTrue(recording.fingerprints(adapterID: "test-adapter").isEmpty)
    }

    // MARK: R10-E — expandPath law table

    /// `~` and `~/…` resolve to THIS home, absolute templates pass through,
    /// relative templates anchor to home — and `~user/…` foreign-user forms
    /// are returned VERBATIM (never rewritten into the current user's home).
    func testExpandPathLeavesForeignUserTemplatesVerbatimAndResolvesOwnHomeForms() {
        XCTAssertEqual(installer.expandPath("~"), home.path)
        XCTAssertEqual(installer.expandPath("~/x"), home.path + "/x")
        XCTAssertEqual(installer.expandPath("/abs/path"), "/abs/path")
        XCTAssertEqual(installer.expandPath("x/y"), home.path + "/x/y")
        // The new law: foreign-user templates pass through untouched.
        XCTAssertEqual(installer.expandPath("~alice/x"), "~alice/x")
    }

    // MARK: - Round 16 (test-design-16): JS ownership positional law + mode preservation

    /// 43dd0cf: ownership proof is POSITIONAL — the file must START with the
    /// generated banner. A user wrapper that merely EMBEDS our full managed
    /// content mid-body is `.conflictUserOwned` and left byte-identical.
    func testJavaScriptBodySubstringIsNoLongerOwnershipEvidence() throws {
        let desiredBody = "// AgentTerminal — test plugin (\(IntegrationInstallPlan.namespaceMarker))\nexport const p = 1;\n"
        let plan = IntegrationInstallPlan(
            adapterID: "opencode-test",
            files: [
                IntegrationFileEdit(targetPathTemplate: "plugins/lifecycle.js", format: .javaScript, entries: [
                    ManagedConfigEntry(
                        keyPath: [],
                        valueJSON: desiredBody,
                        marker: IntegrationInstallPlan.namespaceMarker
                    ),
                ]),
            ]
        )

        // The embedded body guarantees the removed prefix(40)-substring
        // adoption branch would have fired on this input.
        let embedded = "// my launcher bootstrap\n" + desiredBody + "// end bootstrap\n"
        try writeUserConfig("plugins/lifecycle.js", content: embedded)

        let diff = try installer.diff(plan: plan)
        XCTAssertEqual(diff.files[0].actions.first?.action, .conflictUserOwned)

        let report = try installer.install(plan: plan)
        guard case .conflict = report.outcome else { return XCTFail("expected conflict") }
        XCTAssertEqual(readUserConfig("plugins/lifecycle.js"), embedded,
                       "a user-owned file must be left byte-identical")

        // Boundary control: prepending the banner line flips the SAME plan to
        // installable — the rejection is positional, not content-based.
        let bannered = "// AgentTerminal — user wrapper\n" + embedded
        try writeUserConfig("plugins/lifecycle.js", content: bannered)
        let adoptable = try installer.install(plan: plan)
        if case .conflict = adoptable.outcome {
            XCTFail("a banner-leading file is ours to manage (adopt/upgrade), not a conflict")
        }
    }

    /// 43dd0cf: a wholesale inode replacement must not downgrade modes — a
    /// chmod-0600 target stays 0600 across a managed rewrite, while freshly
    /// created targets still get the default umask mode.
    func testAtomicRewritePreservesTargetPosixMode() throws {
        /// A scalar drift inside the managed dict is (by design) user-owned,
        /// so the forced rewrite ADDS a new key under our ownership instead.
        func plan(revision: String?) -> IntegrationInstallPlan {
            let marker = IntegrationInstallPlan.namespaceMarker
            var leaf = "{\"agentterminal-marker\":\"\(marker)\""
            if let revision {
                leaf += ",\"revision\":\"\(revision)\""
            }
            leaf += "}"
            return IntegrationInstallPlan(
                adapterID: "test-adapter",
                files: [
                    IntegrationFileEdit(
                        targetPathTemplate: "cfg/settings.json",
                        format: .json,
                        entries: [
                            ManagedConfigEntry(
                                keyPath: ["hooks"],
                                valueJSON: leaf,
                                marker: IntegrationInstallPlan.namespaceMarker
                            ),
                        ]
                    ),
                ]
            )
        }

        // Fresh install, then tighten the target's mode.
        try writeUserConfig("cfg/settings.json", content: #"{"v":1}"#)
        _ = try installer.install(plan: plan(revision: nil))
        let target = home.appendingPathComponent("cfg/settings.json").path
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: target)

        let upgrade = try installer.install(plan: plan(revision: "two"))
        XCTAssertEqual(
            upgrade.outcome,
            .upgraded,
            "changed managed content must force a rewrite, got \(upgrade.planDiff)"
        )
        let permissions = try FileManager.default.attributesOfItem(atPath: target)[.posixPermissions] as? Int
        XCTAssertEqual(permissions, 0o600, "the rewrite must preserve the target's POSIX mode")

        // Negative control: a FRESHLY CREATED target must carry the
        // default-umask mode of a plain file in the same directory —
        // preservation applies to rewrites only. Comparing against a control
        // written under the SAME process umask keeps this assertion
        // umask-independent (an absolute bound like > 0600 would fail under
        // a restrictive 077 runner umask).
        let freshTarget = home.appendingPathComponent("cfg/fresh.json").path
        _ = try installer.install(plan: IntegrationInstallPlan(
            adapterID: "test-adapter",
            files: [
                IntegrationFileEdit(
                    targetPathTemplate: "cfg/fresh.json",
                    format: .json,
                    entries: [
                        ManagedConfigEntry(
                            keyPath: ["hooks"],
                            valueJSON: #"{"agentterminal-marker":"\#(IntegrationInstallPlan.namespaceMarker)","revision":"fresh"}"#,
                            marker: IntegrationInstallPlan.namespaceMarker
                        ),
                    ]
                ),
            ]
        ))
        let controlPath = home.appendingPathComponent("cfg/control.json").path
        try Data("{}".utf8).write(to: URL(fileURLWithPath: controlPath))
        let fresh = try FileManager.default.attributesOfItem(atPath: freshTarget)[.posixPermissions] as? Int
        let control = try XCTUnwrap(
            FileManager.default.attributesOfItem(atPath: controlPath)[.posixPermissions] as? Int,
            "control file must expose its POSIX mode"
        )
        let freshOctal = fresh.map { String($0, radix: 8) } ?? "nil"
        XCTAssertEqual(
            fresh, control,
            "a freshly created managed target must carry the default-umask mode, "
                + "not a blanket 0600 (fresh \(freshOctal) vs control \(String(control, radix: 8)))"
        )
    }

    // MARK: - R20-IV1: the §3.17 step-6 syntax gate (validator facade)

    /// Complements IntegrationScriptTests' validator block (which pins the
    /// isValid booleans and the JS structural scanner): this pins the
    /// per-format DIAGNOSTIC CONTRACT of `validateSyntax` and
    /// `validateFile`'s missing-path defense — the install plan's only
    /// guard against pointing at a nonexistent config.
    func testValidateSyntaxGateAcceptsWellFormedAndRejectsBrokenConfigsPerFormat() {
        // JSON: well-formed accepted; broken rejected with a prefixed diagnostic.
        XCTAssertTrue(IntegrationValidator.validateSyntax(#"{"a": [1, 2]}"#, format: .json).isValid)
        let brokenJSON = IntegrationValidator.validateSyntax(#"{"a": }"#, format: .json)
        XCTAssertFalse(brokenJSON.isValid)
        XCTAssertEqual(brokenJSON.diagnostics.count, 1)
        XCTAssertTrue(brokenJSON.diagnostics[0].hasPrefix("invalid JSON"),
                      "JSON failures must name the format: \(brokenJSON.diagnostics)")

        // TOML: the strictness the parser suite pins, through the VALIDATOR
        // facade consumers actually call.
        XCTAssertTrue(IntegrationValidator.validateSyntax("key = \"v\"\nn = 42", format: .toml).isValid)
        let brokenTOML = IntegrationValidator.validateSyntax("s = \"unterminated", format: .toml)
        XCTAssertFalse(brokenTOML.isValid)
        XCTAssertTrue(brokenTOML.diagnostics.contains { $0.hasPrefix("invalid TOML") },
                      "TOML failures must name the format: \(brokenTOML.diagnostics)")

        // JavaScript: balanced source passes the structural checker;
        // whitespace-only source hits the empty guard AFTER trimming.
        XCTAssertTrue(
            IntegrationValidator.validateSyntax("// x\n(function(){})()", format: .javaScript).isValid
        )
        let blank = IntegrationValidator.validateSyntax("   \n\t ", format: .javaScript)
        XCTAssertFalse(blank.isValid)
        XCTAssertTrue(blank.diagnostics.contains { $0.contains("empty plugin source") },
                      "whitespace-only plugin source must hit the empty guard: \(blank.diagnostics)")

        // A missing file reports the cannot-read diagnostic verbatim.
        let missing = IntegrationValidator.validateFile(at: "/nonexistent/aterm-r20/config.json",
                                                        format: .json)
        XCTAssertFalse(missing.isValid)
        XCTAssertEqual(missing.diagnostics, ["cannot read /nonexistent/aterm-r20/config.json"])
    }

    // MARK: Round 22 — TOML numbers, deep merge, fingerprint propagation (c2361cd)

    /// c2361cd number-rendering law: JSONSerialization hands every JSON
    /// number to renderTOMLValue as NSNumber, and a conditional `as? Bool`
    /// cast succeeds for ANY NSNumber — so NSNumber must be matched FIRST and
    /// branch-split on objCType (:1030-1042). Reverting to the Bool-first
    /// switch renders `timeout = true` for every numeric managed value.
    func testManagedTOMLRendersNumbersAsNumbersAndBooleansAsBooleans() {
        let entry = ManagedConfigEntry(
            keyPath: ["t"],
            valueJSON: #"{"timeout":30,"ratio":1.5,"neg":-7,"flag":true,"off":false,"name":"x\"y","tags":[1,"a"],"inline":{"b":2,"a":true}}"#,
            marker: IntegrationInstallPlan.namespaceMarker
        )

        let block = IntegrationInstaller.renderTOMLManagedBlock(entries: [entry], adapterID: "toml-numbers")

        XCTAssertTrue(
            block.hasPrefix("# BEGIN \(IntegrationInstallPlan.namespaceMarker) toml-numbers\n"),
            block
        )
        XCTAssertTrue(
            block.hasSuffix("# END \(IntegrationInstallPlan.namespaceMarker) toml-numbers\n"),
            block
        )
        // Numbers stay numbers (pre-fix ALL of these rendered `true`).
        XCTAssertTrue(block.contains("timeout = 30"), block)
        XCTAssertTrue(block.contains("ratio = 1.5"), block)
        XCTAssertTrue(block.contains("neg = -7"), block)
        // Real booleans still render as booleans — guards an over-correction.
        XCTAssertTrue(block.contains("flag = true"), block)
        XCTAssertTrue(block.contains("off = false"), block)
        // Escaping, array, and sorted inline-table arms.
        XCTAssertTrue(block.contains(#"name = "x\"y""#), block)
        XCTAssertTrue(block.contains(#"tags = [ 1, "a" ]"#), block)
        XCTAssertTrue(block.contains("{ a = true, b = 2 }"), block)
        // Explicit per-key negative: no numeric key ever renders as a Bool.
        for key in ["timeout", "ratio", "neg"] {
            XCTAssertFalse(
                block.components(separatedBy: "\n").contains { $0 == "\(key) = true" },
                "\(key) must render as a number, never a boolean"
            )
        }
    }

    /// Section-emission loop (:1013-1028): the keyPath joins with "." into a
    /// dotted section header, markers wrap the block, and an entry whose
    /// valueJSON does not parse is SKIPPED without poisoning the rest
    /// (:1016 guard-continue). Honest deviation from test-design-22: the
    /// `value =` scalar fallback (:1022-1024) is UNREACHABLE through this
    /// seam — JSONSerialization rejects top-level fragments (`"30"`) unless
    /// .fragmentsAllowed is passed, which renderTOMLManagedBlock does not —
    /// so no scalar arrange can exist without a production change.
    func testManagedTOMLEmitsSectionPerKeyPathTable() {
        let entries = [
            ManagedConfigEntry(
                keyPath: ["agentterminal"],
                valueJSON: "{\"marker\":\"\(IntegrationInstallPlan.namespaceMarker)\",\"version\":3}",
                marker: IntegrationInstallPlan.namespaceMarker
            ),
            ManagedConfigEntry(
                keyPath: ["hooks", "session_start"],
                valueJSON: "{\"cmd\":\"run\"}",
                marker: IntegrationInstallPlan.namespaceMarker
            ),
            ManagedConfigEntry(
                keyPath: ["broken"],
                valueJSON: "{not json",
                marker: IntegrationInstallPlan.namespaceMarker
            ),
        ]

        let block = IntegrationInstaller.renderTOMLManagedBlock(entries: entries, adapterID: "toml-sections")

        XCTAssertTrue(
            block.contains("[agentterminal]\nmarker = \"\(IntegrationInstallPlan.namespaceMarker)\"\nversion = 3"),
            block
        )
        XCTAssertTrue(block.contains("[hooks.session_start]\ncmd = \"run\""), block)
        XCTAssertFalse(block.contains("value ="), "no scalar fallback line can be produced here: \(block)")
        func position(_ needle: String) -> Int {
            guard let range = block.range(of: needle) else { return Int.max }
            return block.distance(from: block.startIndex, to: range.lowerBound)
        }
        XCTAssertLessThan(position("[agentterminal]"), position("[hooks.session_start]"))
        XCTAssertTrue(
            block.hasPrefix("# BEGIN \(IntegrationInstallPlan.namespaceMarker) toml-sections\n"),
            block
        )
        XCTAssertTrue(
            block.hasSuffix("# END \(IntegrationInstallPlan.namespaceMarker) toml-sections\n"),
            block
        )
    }

    /// Deep-merge law (:846-872): when BOTH the stored leaf and the incoming
    /// value are dictionaries the merge RECURSES — nested user content under
    /// a key we contribute is never destroyed. Any other shape replaces
    /// wholesale. The empty-keyPath precondition trap cannot be observed in
    /// XCTest (process abort, not a thrown error), so that contract is
    /// documented here rather than asserted.
    func testSetValueDeepMergesNestedDictionariesButReplacesScalars() throws {
        // Merge arm: sibling user content under our key survives.
        var document: [String: Any] = ["hooks": ["session_start": ["user_cmd": "u"], "other": "keep"]]
        IntegrationInstaller.setValue(
            ["session_start": ["our_marker": "m"], "added": 1],
            at: ["hooks"],
            in: &document
        )
        let hooks = try XCTUnwrap(document["hooks"] as? [String: Any])
        let sessionStart = try XCTUnwrap(hooks["session_start"] as? [String: Any])
        XCTAssertEqual(sessionStart["user_cmd"] as? String, "u", "nested user content must survive")
        XCTAssertEqual(sessionStart["our_marker"] as? String, "m")
        XCTAssertEqual(hooks["other"] as? String, "keep")
        XCTAssertEqual(hooks["added"] as? Int, 1)

        // Deep arm: recursion descends three levels.
        var deep: [String: Any] = ["top": ["a": ["b": ["c": ["deep": "user"]]]]]
        IntegrationInstaller.setValue(["a": ["b": ["c": ["ours": 1]]]], at: ["top"], in: &deep)
        let topA = try XCTUnwrap(deep["top"] as? [String: Any])
        let topAB = try XCTUnwrap(topA["a"] as? [String: Any])
        let topABC = try XCTUnwrap(topAB["b"] as? [String: Any])
        let leafC = try XCTUnwrap(topABC["c"] as? [String: Any])
        XCTAssertEqual(leafC["deep"] as? String, "user")
        XCTAssertEqual(leafC["ours"] as? Int, 1)

        // Replace arm: scalar over an occupied dict replaces it wholesale.
        var replaced: [String: Any] = ["hooks": ["theirs": "x"]]
        IntegrationInstaller.setValue("ours", at: ["hooks"], in: &replaced)
        XCTAssertEqual(replaced["hooks"] as? String, "ours")

        // Scalar-over-scalar overwrite works.
        var scalars: [String: Any] = ["k": "1"]
        IntegrationInstaller.setValue("2", at: ["k"], in: &scalars)
        XCTAssertEqual(scalars["k"] as? String, "2")
    }

    /// Fingerprint-failure propagation law (:509-527): on a partial uninstall
    /// the §5.3 ledger rebuild runs removeAll + record(survivors), and record
    /// THROWING now propagates (:527 — was `try?`). Without propagation the
    /// ledger is ALREADY gone when the throw surfaces (removeAll ran first),
    /// so the next install adopts-and-overwrites the user-modified survivor.
    func testUninstallFingerprintRestoreFailurePropagatesInsteadOfSilentWipe() throws {
        try writeUserConfig("cfg/settings.json", content: #"{"v":1}"#)
        _ = try installer.install(plan: claudeLikePlan(configPath: "cfg/settings.json"))

        // Hand-edit the managed leaf so uninstall SKIPS it as user-modified —
        // exactly the branch that wipes and re-records the ledger.
        try writeUserConfig(
            "cfg/settings.json",
            content: #"{"v":1,"hooks":{"agentterminal-marker":"tampered"}}"#
        )

        let throwing = ThrowingInstallRecording(seed: recording.fingerprints(adapterID: "test-adapter"))
        throwing.failNextRecord = true
        let flakyInstaller = IntegrationInstaller(recording: throwing, homeDirectory: home.path)

        // The record(survivors) failure aborts the uninstall loudly; no
        // UninstallReport can mask it.
        XCTAssertThrowsError(
            try flakyInstaller.uninstall(plan: claudeLikePlan(configPath: "cfg/settings.json"))
        ) { error in
            XCTAssertTrue(
                error is ThrowingInstallRecording.RecordFailure,
                "expected the recorder's failure, got \(error)"
            )
        }
        XCTAssertTrue(
            throwing.removeAllObserved,
            "removeAll ran before the throw — precisely why propagation matters"
        )
    }

    /// Positive control for the propagation test: a partial uninstall
    /// persists EXACTLY the survivor's fingerprint byte-for-byte, and the
    /// retained fingerprint gates a later install into a conflict instead of
    /// an adopt-and-overwrite of the user's edits.
    func testPartialUninstallPersistsExactlyTheSurvivorFingerprints() throws {
        func entry(side: String) -> IntegrationFileEdit {
            IntegrationFileEdit(
                targetPathTemplate: "cfg/\(side).json",
                format: .json,
                entries: [
                    ManagedConfigEntry(
                        keyPath: ["hooks"],
                        valueJSON: "{\"agentterminal-marker\":\"\(IntegrationInstallPlan.namespaceMarker)\",\"side\":\"\(side)\"}",
                        marker: IntegrationInstallPlan.namespaceMarker
                    ),
                ]
            )
        }
        let plan = IntegrationInstallPlan(adapterID: "test-adapter", files: [entry(side: "a"), entry(side: "b")])
        try writeUserConfig("cfg/a.json", content: "{}")
        try writeUserConfig("cfg/b.json", content: "{}")
        _ = try installer.install(plan: plan)
        XCTAssertEqual(recording.fingerprints(adapterID: "test-adapter").count, 2)

        let pathA = home.appendingPathComponent("cfg/a.json").path
        let fingerprintA = try XCTUnwrap(
            recording.fingerprints(adapterID: "test-adapter").first { $0.targetPath == pathA }
        )

        // User edits target A only; B stays ours.
        try writeUserConfig("cfg/a.json", content: #"{"hooks":{"agentterminal-marker":"user-touched"}}"#)

        let report = try installer.uninstall(plan: plan)
        XCTAssertEqual(report.removed, [home.appendingPathComponent("cfg/b.json").path + "#hooks"])
        XCTAssertEqual(report.skippedUserModified, [pathA + "#hooks"])

        let survivors = recording.fingerprints(adapterID: "test-adapter")
        XCTAssertEqual(survivors.count, 1, "exactly the survivor's fingerprint persists")
        XCTAssertEqual(survivors.first?.targetPath, pathA)
        XCTAssertEqual(survivors.first?.managedContent, fingerprintA.managedContent)

        // Adoption ledger intact end-to-end: reinstalling the SAME plan
        // conflicts on A rather than overwriting the user's edits.
        let reinstall = try installer.install(plan: plan)
        guard case let .conflict(paths) = reinstall.outcome else {
            return XCTFail("expected conflict on the user-modified survivor, got \(reinstall.outcome)")
        }
        XCTAssertEqual(paths, [pathA + "#hooks"])
    }

    // MARK: R22 — §3.17 data-loss hardening

    /// A backup copy that fails MID-COPY must never leave a PARTIAL backup
    /// behind: rollback re-derives `path + backupSuffix` and would move the
    /// torn file over the ORIGINAL, destroying user data.
    func testFailedBackupCopyLeavesOriginalUntouchedAndNoPartialBackup() throws {
        let original = #"{"model":"opus","v":1}"#
        try writeUserConfig("cfg/settings.json", content: original)

        let fm = PartialCopyFileManager()
        fm.failDestinations = [
            home.appendingPathComponent("cfg/settings.json" + IntegrationInstaller.backupSuffix).path
        ]
        let broken = IntegrationInstaller(recording: recording, homeDirectory: home.path, fileManager: fm)

        XCTAssertThrowsError(try broken.install(plan: claudeLikePlan(configPath: "cfg/settings.json")))
        // The original survives byte-for-byte…
        XCTAssertEqual(readUserConfig("cfg/settings.json"), original)
        // …and no torn backup remains for a later rollback to mistake for a
        // complete snapshot.
        XCTAssertFalse(
            FileManager.default
                .fileExists(atPath: home.appendingPathComponent("cfg/settings.json" + IntegrationInstaller.backupSuffix)
                    .path)
        )
    }

    /// An existing config that fails to parse as JSON is a CONFLICT: install
    /// must throw instead of silently starting from an empty document and
    /// wholesale-replacing the user's file (§3.17).
    func testCorruptExistingJSONConflictsInsteadOfWholesaleReplacement() throws {
        let corrupt = #"{not json!!"#
        try writeUserConfig("cfg/settings.json", content: corrupt)

        XCTAssertThrowsError(try installer.install(plan: claudeLikePlan(configPath: "cfg/settings.json"))) { error in
            guard case let IntegrationInstallError.validationFailed(_, diagnostic) = error else {
                return XCTFail("expected validationFailed, got \(error)")
            }
            XCTAssertTrue(diagnostic.contains("does not parse"), "diagnostic must name the conflict: \(diagnostic)")
        }
        XCTAssertEqual(readUserConfig("cfg/settings.json"), corrupt, "the corrupt user file must survive untouched")
    }

    /// Orphan deletion on uninstall requires PROOF the content is EXACTLY
    /// what the plan generates: a crashed install wrote it verbatim, while a
    /// user-modified orphan is a conflict and survives (§3.17).
    func testUserModifiedTOMLOrphanSurvivesUninstall() throws {
        let tomlPath = "cfg/config.toml"
        try writeUserConfig(tomlPath, content: "model = \"gpt-9\"\n")
        let plan = IntegrationInstallPlan(
            adapterID: "codex-test",
            files: [
                IntegrationFileEdit(
                    targetPathTemplate: tomlPath,
                    format: .toml,
                    entries: [
                        ManagedConfigEntry(
                            keyPath: ["agentterminal"],
                            valueJSON: "{\"marker\":\"\(IntegrationInstallPlan.namespaceMarker)\",\"version\":1}",
                            marker: IntegrationInstallPlan.namespaceMarker
                        ),
                    ]
                ),
            ]
        )

        // Positive control: an UNMODIFIED orphan (crash between rename and
        // record) is adopted and removed exactly.
        _ = try installer.install(plan: plan)
        recording.removeAll(adapterID: "codex-test")
        let orphanRemoval = try installer.uninstall(plan: plan)
        XCTAssertEqual(orphanRemoval.removed.count, 1, "an exact-match orphan is ours to remove")

        // Now the defect scenario: orphan + user edit afterwards.
        _ = try installer.install(plan: plan)
        recording.removeAll(adapterID: "codex-test")
        let tampered = readUserConfig(tomlPath).replacingOccurrences(of: "version = 1", with: "version = 99")
        try writeUserConfig(tomlPath, content: tampered)

        let report = try installer.uninstall(plan: plan)
        XCTAssertEqual(report.skippedUserModified.count, 1, "a user-modified orphan must be skipped")
        XCTAssertEqual(readUserConfig(tomlPath), tampered, "the modified orphan must survive byte-for-byte")
    }

    func testUserModifiedJavaScriptOrphanSurvivesUninstall() throws {
        let script = "// AgentTerminal — test plugin (\(IntegrationInstallPlan.namespaceMarker))\nexport const p = 1;\n"
        let plan = IntegrationInstallPlan(
            adapterID: "opencode-test",
            files: [
                IntegrationFileEdit(targetPathTemplate: "plugins/lifecycle.js", format: .javaScript, entries: [
                    ManagedConfigEntry(
                        keyPath: [],
                        valueJSON: script,
                        marker: IntegrationInstallPlan.namespaceMarker
                    ),
                ]),
            ]
        )

        // Positive control: an exact crashed-install orphan is removed.
        try writeUserConfig("plugins/lifecycle.js", content: script)
        let orphanRemoval = try installer.uninstall(plan: plan)
        XCTAssertEqual(orphanRemoval.removed, [home.appendingPathComponent("plugins/lifecycle.js").path])

        // Defect scenario: banner-leading orphan the user edited afterwards.
        let edited = script + "\n// user tweak\nconsole.log('mine');\n"
        try writeUserConfig("plugins/lifecycle.js", content: edited)
        let report = try installer.uninstall(plan: plan)
        XCTAssertTrue(report.removed.isEmpty, "a user-modified orphan must never be deleted")
        XCTAssertEqual(report.skippedUserModified, [home.appendingPathComponent("plugins/lifecycle.js").path])
        XCTAssertEqual(readUserConfig("plugins/lifecycle.js"), edited)
    }
}
