import Foundation

// The closed control method set (architecture §3.16). Any method string not
// in this list yields `unknownMethod`; there is no extension mechanism in v1.

public enum ControlMethod: String, CaseIterable, Sendable {
    case systemPing = "system.ping"

    case workspaceList = "workspace.list"

    case agentCreate = "agent.create"
    case agentList = "agent.list"
    case agentGet = "agent.get"
    case agentPrompt = "agent.prompt"
    case agentCancelQueuedPrompt = "agent.cancelQueuedPrompt"
    case agentFocus = "agent.focus"
    case agentRead = "agent.read"
    case agentWait = "agent.wait"
    case agentInterrupt = "agent.interrupt"
    case agentStop = "agent.stop"
    case agentResume = "agent.resume"

    case eventsSubscribe = "events.subscribe"

    case integrationReport = "integration.report"
    case integrationRelease = "integration.release"

    case launcherStarted = "launcher.started"
    case launcherFailed = "launcher.failed"
}
