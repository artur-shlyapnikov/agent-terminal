// AgentLauncher — fixed helper executable consuming one-shot launch tickets
// (architecture §3.9). Plain POSIX Foundation process: no AppKit, no UI.
//
// Pipeline:
//   1. argv[1] = absolute ticket file path (missing → stderr + exit 126)
//   2. Secure acquisition & validation   (TicketConsumer, §3.9 rules table)
//   3. chdir(ticket.cwd)                 (§3.9 step 2)
//   4. setpgid(0,0) — new process group  (§3.9 step 3)
//   5. best-effort launcher.started NDJSON report with PID/PGID (step 4)
//   6. envp built STRICTLY from ticket.environment (the producer already
//      merged the login environment and AGENT_TERMINAL_* injections; DYLD_*
//      filtering is the writer's responsibility per §3.9 Environment rules)
//   7. execve(argv[0], argv, envp) — exact argv, no shell (step 6)
//   8. execve failure → one short stderr line (lands on the PTY), best-effort
//      launcher.failed report, exit 127 (ENOENT/ENOTDIR: not found) else 126
//      (EACCES/ELOOP/ETXTBSY: found but not executable) — POSIX convention.
//
// Reporting policy: launcher.failed is sent for any post-parse failure
// (validation rejection, chdir failure, execve failure) because only then do
// we hold a parsed controlSocketPath. Pre-parse acquisition failures cannot
// report — the socket path has not been read yet — so they exit silently.
// Every socket interaction is bounded (≤250 ms connect) and can never block
// or abort the exec path.

import AgentCore
import Foundation

func exit(with failure: TicketConsumer.Failure, from ticket: LaunchTicket?) -> Never {
    FileHandle.standardError.write(Data("agentlauncher: \(failure)\n".utf8))
    // Pre-parse failures have no ticket yet: no socket path, no identity —
    // they exit silently (§3.9 reporting policy).
    if let ticket {
        ControlReporter.failed(
            reason: "\(failure)",
            agentID: ticket.agentID,
            surfaceGeneration: ticket.surfaceGeneration,
            token: ticket.integrationToken,
            socketPath: ticket.controlSocketPath
        )
    }
    exit(126)
}

let arguments = CommandLine.arguments
guard arguments.count >= 2, !arguments[1].isEmpty else {
    exit(with: .missingArgument, from: nil)
}

/// Steps 1–2: acquire + delete ticket, then validate semantics.
let acquired: TicketConsumer.Acquired
switch TicketConsumer.acquire(argumentPath: arguments[1]) {
case let .success(a): acquired = a
case let .failure(f): exit(with: f, from: nil)
}
let ticket = acquired.ticket
if let rejection = TicketConsumer.validate(ticket) {
    exit(with: .rejected(reason: rejection), from: ticket)
}

/// Step 3: working directory.
let cwd = ticket.cwd
guard chdir(cwd) == 0 else {
    exit(with: .rejected(reason: "chdir failed (errno \(errno))"), from: ticket)
}

// Step 4: take over the terminal. A login shell can only run in the
// FOREGROUND of its controlling terminal's session; whatever the spawner
// set up, this helper must guarantee all three invariants itself, in this
// order (each is best-effort — the exec'd shell inherits whatever holds):
//   ctty check — TIOCGSID tells whether fd 0 is ALREADY the controlling
//                terminal of our session. libghostty's pty.childPreExec
//                (fork child) does setsid + TIOCSCTTY before spawning this
//                helper, so the claim usually exists and must be KEPT:
//                an unconditional setsid here creates a fresh session that
//                abandons that claim, and the follow-up TIOCSCTTY then
//                fails with EPERM (cross-session steal) — the shell ends
//                up ctty-less: no SIGWINCH on resize, no job control
//                (observed 2026-08-26, zsh with tty=?).
//   setsid     — only when the claim is missing (plain fork arrival):
//                fresh session + process group; must precede TIOCSCTTY,
//                which needs session leadership.
//   TIOCSCTTY  — claim fd 0 for the new session (claim-missing path only).
//   setpgid    — own process group (claim-missing and no-tty paths) so
//                teardown (stage 8) can always signal the agent subtree
//                without touching the app or the spawner's session anchor;
//                skipped on the inherited-claim path (see below).
//   tcsetpgrp  — make the helper's group the tty foreground; a shell that
//                starts background stops on SIGTTIN at its first read
//                (wedge: black canvas, lifecycle stuck in Starting).
// Skipping the claim check and always setsid-ing reproduces the ctty loss
// whenever the spawner pre-claimed the tty (observed 2026-08-25/26).
// TIOCGSID does not import into Swift (IOKit-style macro); raw Darwin
// encoding of _IOR('t', 99, int) — note 99, not Linux's 63.
private let TIOCGSID_IOCTL: UInt = 0x4004_7463
if isatty(0) == 1 {
    var cttySessionLeader: Int32 = -1
    let claimIsOurs = ioctl(0, TIOCGSID_IOCTL, &cttySessionLeader) == 0
        && cttySessionLeader == getsid(0)
    if claimIsOurs {
        // Spawned into the session that already owns the ctty (the spawner's
        // fork child claimed it; /usr/bin/login anchors the session on Darwin
        // and keeps its own group foreground). Touch NOTHING here:
        //   setpgid    — strands the shell behind the anchor's foreground
        //                group → SIGTTIN stop on first read (T state wedge,
        //                observed 2026-08-26);
        //   tcsetpgrp  — deadlocks against the still-suspended spawner
        //                (observed 2026-08-26).
        // The reported pgid is the anchor's group; teardown signals to it
        // reach the whole agent session (login + shell subtree) only.
    } else {
        // Plain-fork arrival with no claim yet: build the session ourselves.
        if getsid(0) != getpid(), setsid() < 0 { /* best-effort */ }
        var zero: Int32 = 0
        if ioctl(0, TIOCSCTTY, &zero) < 0 { /* best-effort */ }
        setpgid(0, 0)
        _ = tcsetpgrp(0, getpgrp())
    }
} else {
    setpgid(0, 0)
}

// Step 5: report started with the final PID/PGID.
ControlReporter.started(
    agentID: ticket.agentID,
    terminalID: ticket.terminalID,
    surfaceGeneration: ticket.surfaceGeneration,
    token: ticket.integrationToken,
    socketPath: ticket.controlSocketPath
)

// Steps 6–7: exact-argv execve with environment strictly from the ticket.
var envPairs = ticket.environment.map { "\($0.key)=\($0.value)" }.sorted()
var cArgv: [UnsafeMutablePointer<CChar>?] = ticket.argv.map { strdup($0) }
var cEnvp: [UnsafeMutablePointer<CChar>?] = envPairs.map { strdup($0) }
cArgv.append(nil)
cEnvp.append(nil)
defer {
    for p in cArgv where p != nil {
        free(p!)
    }
    for p in cEnvp where p != nil {
        free(p!)
    }
}

/// Signal hygiene immediately before execve: POSIX preserves the signal mask
/// and SIG_IGN dispositions across exec, so anything the spawner left blocked
/// or ignored would silently leak into the agent shell (a blocked SIGTERM
/// defeats teardown signalling; an ignored SIGHUP breaks job control). Reset
/// both to a clean slate — the shell then installs its own handlers. This
/// subsumes ControlReporter's SIGPIPE restore and is pinned by the smoke
/// test's SIGPIPE-disposition probe (testExecedChildObservesDefault…).
var emptyMask = sigset_t()
sigemptyset(&emptyMask)
_ = sigprocmask(SIG_SETMASK, &emptyMask, nil)
for jobControlSignal in [SIGINT, SIGTERM, SIGHUP, SIGQUIT, SIGPIPE,
                         SIGTSTP, SIGTTIN, SIGTTOU, SIGCHLD]
{
    _ = signal(jobControlSignal, SIG_DFL)
}

let execResult = cArgv.withUnsafeMutableBufferPointer { argvBuf in
    cEnvp.withUnsafeMutableBufferPointer { envBuf in
        execve(ticket.argv[0], argvBuf.baseAddress, envBuf.baseAddress)
    }
}

let execErrno = errno
FileHandle.standardError.write(Data("agentlauncher: cannot execute \(ticket.argv[0]) (errno \(execErrno))\n".utf8))

ControlReporter.failed(
    reason: "execve errno \(execErrno)",
    agentID: ticket.agentID,
    surfaceGeneration: ticket.surfaceGeneration,
    token: ticket.integrationToken,
    socketPath: ticket.controlSocketPath
)
// POSIX convention: 127 = command not found, 126 = found but not
// executable. LaunchTicket's wire contract is unchanged — this only picks
// the helper's own exit status so shells and supervisors can distinguish
// the two failure classes.
exit(execErrno == ENOENT || execErrno == ENOTDIR ? 127 : 126)
