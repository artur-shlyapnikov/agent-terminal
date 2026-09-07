import AgentCore
import Foundation
import TerminalKit

// ACCEPTANCE-ONLY bootstrap (stage-5): builds the TerminalKit stack and
// spawns plain shells BEFORE the full application shell exists. Compiled
// exclusively into the AgentTerminalAcceptance target — the shipping app no
// longer carries scenario/harness code.

// Temp config dir of the most recent bootstrap spawn, removed at process end.
private var bootCfgDirPendingRemoval: String?
private func removeBootCfgDir() {
    if let path = bootCfgDirPendingRemoval {
        try? FileManager.default.removeItem(atPath: path)
    }
}

@MainActor
enum AutomationBootstrap {
    static var pending: AdoptedTerminalStack?

    /// Builds the terminal stack and spawns `count` plain shells. Runs on the
    /// main actor during applicationDidFinishLaunching — the proven-good
    /// ordering (identical to the stage-3 verification harness).
    static func spawnShells(count: Int) throws -> AdoptedTerminalStack {
        try GhosttyEngine.globalInit()
        let cfgDir = NSTemporaryDirectory() + "aterm-boot-\(getpid())"
        try? FileManager.default.createDirectory(atPath: cfgDir, withIntermediateDirectories: true)
        bootCfgDirPendingRemoval = cfgDir
        atexit(removeBootCfgDir)
        let cfgPath = cfgDir + "/config"
        try? "font-size = 13".write(toFile: cfgPath, atomically: true, encoding: .utf8)

        let engine = try GhosttyEngine(configLoader: GhosttyConfigLoader(path: URL(fileURLWithPath: cfgPath)))
        let parkingHost = TerminalParkingHost()
        let sessionManager = TerminalSessionManager(
            engine: engine,
            parkingHost: parkingHost,
            inputBracketedPaste: false
        )

        var sessions: [TerminalSession] = []
        for index in 1 ... count {
            let session = try sessionManager.launchDirect(
                workspaceID: WorkspaceID(),
                spec: TerminalLaunchSpec(
                    workingDirectory: "/tmp",
                    command: "/bin/sh",
                    environment: ["PS1": "aterm-\(index)$ "]
                )
            )
            sessions.append(session)
            print("[LAUNCH] bootstrap: shell \(index) spawned")
        }
        return AdoptedTerminalStack(engine: engine, parkingHost: parkingHost,
                                    sessionManager: sessionManager, sessions: sessions)
    }
}
