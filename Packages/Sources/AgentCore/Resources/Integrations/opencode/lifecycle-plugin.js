// AgentTerminal — OpenCode lifecycle plugin (architecture §3.10/§3.16/§3.17).
//
import { pathToFileURL } from "node:url";
import fs from "node:fs";
import path from "node:path";
import os from "node:os";
import { spawn } from "node:child_process";

// Installed into the OpenCode config's `plugins.agentterminal` entry by the
// IntegrationInstaller (managed + fingerprinted). Reports full integration
// capability: session identity capture, lifecycle reports and explicit
// release semantics via `agentctl integration release`.
//
// Required environment (injected by the ephemeral launch ticket, §3.16):
//   AGENT_TERMINAL_TOKEN              scoped hook token for this generation
//   AGENT_TERMINAL_AGENT_ID           agent identifier
//   AGENT_TERMINAL_SURFACE_GENERATION surface generation number
// Optional:
//   AGENT_TERMINAL_SOCKET             socket path (default below)
//   AGENT_TERMINAL_AGENTCTL           agentctl binary (default: `agentctl` on PATH)
//   AGENT_TERMINAL_SEQ_STATE_DIR      dir for the file-backed monotonic seq counter
//   AGENT_TERMINAL_DRY_RUN            =1 prints report NDJSON to stdout instead of
//                                     connecting (validator self-test)
//
// Safety law: failures are ALWAYS best-effort and silent — the plugin must
// never break the host CLI.

const DEFAULT_SOCKET = () =>
  (process.env.HOME || "") +
  "/Library/Application Support/AgentTerminal/runtime/control.sock";

const SOURCE = "opencode-plugin";

function nextSeq(stateDir, agentID) {
  // File-backed monotonic counter keyed by agentID (§3.6 ordering rules),
  // using exclusive-create as a lock so concurrent events stay ordered.
  // Bounded retry (5 attempts): the lock holder runs for microseconds
  // (read+write+unlink), so a tight retry loop without sleep is sufficient.
  // On persistent contention/failure we return null and the report simply
  // omits `seq` — nil sequences bypass the ledger's duplicate rule, while a
  // fallback of 0 would get real reports silently dropped. If the retry
  // budget is spent, a lock older than the 10s grace window must be an
  // orphan (killed plugin) — break it exactly once and retry; anything
  // failing along the way still degrades to omit-seq.
  if (!stateDir) return null;
  try {
    fs.mkdirSync(stateDir, { recursive: true });
    const lockPath = path.join(stateDir, `${agentID}.lock`);
    const seqPath = path.join(stateDir, `${agentID}.seq`);
    const STALE_LOCK_GRACE_MS = 10 * 1000;
    let fd = null;
    let brokeStaleLock = false;
    let attemptsLeft = 5;
    while (fd === null && attemptsLeft > 0) {
      attemptsLeft--;
      try {
        fd = fs.openSync(lockPath, "wx");
        // Ownership marker: only THIS process may unlink at release, so a
        // stale-breaker's replacement lock can never be clobbered by our
        // exit (two holders would duplicate seq → EvidenceLedger drops).
        fs.writeFileSync(fd, String(process.pid));
      } catch (err) {
        if (err.code !== "EEXIST") throw err; // real failure: bail to outer handler
        if (!brokeStaleLock && attemptsLeft === 0) {
          brokeStaleLock = true;
          attemptsLeft++; // one extra pass after the stale-break
          try {
            if (Date.now() - fs.statSync(lockPath).mtimeMs >= STALE_LOCK_GRACE_MS) {
              try { fs.unlinkSync(lockPath); } catch {}
            }
          } catch {} // lock vanished mid-probe: fall through to omit-seq
        }
      }
    }
    if (fd === null) return null; // lock still held after retries: skip ordering
    try {
      let seq = 0;
      try {
        seq = parseInt(fs.readFileSync(seqPath, "utf8").trim(), 10) || 0;
      } catch {}
      seq += 1;
      fs.writeFileSync(seqPath, String(seq));
      return seq;
    } finally {
      fs.closeSync(fd);
      // Release ONLY if we still own the lock: a stale-breaker may have
      // unlinked it mid-section and handed the slot to a newer holder.
      try {
        if (fs.readFileSync(lockPath, "utf8") === String(process.pid)) {
          fs.unlinkSync(lockPath);
        }
      } catch {}
    }
  } catch {
    return null;
  }
}

function buildReport(agentID, surfaceGeneration, extra) {
  const token = process.env.AGENT_TERMINAL_TOKEN;
  const stateDir =
    process.env.AGENT_TERMINAL_SEQ_STATE_DIR ||
    `${os.tmpdir()}/agentterminal-seq`;
  const report = {
    agentID,
    source: SOURCE,
    surfaceGeneration: Number(surfaceGeneration) || 0,
    ...extra,
  };
  const seq = nextSeq(stateDir, agentID);
  if (seq !== null) report.seq = seq;
  if (token) report.tokenPresent = true;
  return report;
}

function runAgentctl(args, envOverrides) {
  const agentctl = process.env.AGENT_TERMINAL_AGENTCTL || "agentctl";
  const socket =
    process.env.AGENT_TERMINAL_SOCKET || DEFAULT_SOCKET();
  const child = spawn(
    agentctl,
    ["--socket", socket, ...args],
    {
      env: { ...process.env, ...envOverrides },
      stdio: "ignore",
      detached: false,
    },
  );
  // Best-effort: swallow every failure, never propagate to the host CLI.
  child.on("error", () => {});
}

function emitReport(params) {
  if (process.env.AGENT_TERMINAL_DRY_RUN === "1") {
    // Dry-run: NDJSON on stdout, no socket, no raw token.
    process.stdout.write(JSON.stringify(params) + "\n");
    return;
  }
  if (!process.env.AGENT_TERMINAL_TOKEN) return;
  const args = [
    "integration", "report",
    "--agent-id", params.agentID,
    "--surface-generation", String(params.surfaceGeneration),
    "--source", params.source,
  ];
  if (params.seq !== undefined && params.seq !== null) {
    args.push("--seq", String(params.seq));
  }
  if (params.lifecycle) args.push("--lifecycle", params.lifecycle);
  if (params.sessionReference) {
    args.push("--session-reference", JSON.stringify(params.sessionReference));
  }
  runAgentctl(args);
}

export const LifecyclePlugin = async ({ project }) => {
  const agentID = process.env.AGENT_TERMINAL_AGENT_ID || "";
  const surfaceGeneration = process.env.AGENT_TERMINAL_SURFACE_GENERATION || "0";
  const seenSessions = new Set();

  const reportSessionIdentity = (sessionID) => {
    if (!sessionID || seenSessions.has(sessionID)) return;
    seenSessions.add(sessionID);
    emitReport(buildReport(agentID, surfaceGeneration, {
      sessionReference: {
        agentKind: "opencode",
        opaquePayload: sessionID,
        capturedAtRevision: 0,
      },
    }));
  };

  const reportLifecycle = (tag) => {
    emitReport(buildReport(agentID, surfaceGeneration, { lifecycle: tag }));
  };

  const releaseIntegration = () => {
    if (process.env.AGENT_TERMINAL_DRY_RUN === "1") {
      process.stdout.write(JSON.stringify({
        agentID,
        source: SOURCE,
        release: true,
        tokenPresent: Boolean(process.env.AGENT_TERMINAL_TOKEN),
      }) + "\n");
      return;
    }
    if (!process.env.AGENT_TERMINAL_TOKEN || !agentID) return;
    runAgentctl([
      "integration", "release",
      "--agent-id", agentID,
      "--surface-generation", String(surfaceGeneration),
      "--source", SOURCE,
    ]);
  };

  return {
    event: async ({ event }) => {
      try {
        const type = event && event.type;
        const props = (event && event.properties) || {};
        switch (type) {
          case "session.updated":
            reportSessionIdentity(props.info && props.info.id);
            break;
          case "session.idle":
            reportSessionIdentity(props.sessionID || (props.info && props.info.id));
            reportLifecycle("idle");
            break;
          case "message.updated":
            reportLifecycle("working");
            break;
          case "session.error":
            reportLifecycle("failed");
            break;
          case "session.deleted":
            releaseIntegration(); // explicit release semantics (§3.10 table)
            break;
          default:
            break;
        }
      } catch {
        // Never break the host CLI.
      }
    },
  };
};

export default LifecyclePlugin;

// Direct execution (`node lifecycle-plugin.js`) emits one synthetic dry-run
// report so IntegrationValidator can self-test the plugin without OpenCode.
if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  const agentID = process.env.AGENT_TERMINAL_AGENT_ID || "";
  const surfaceGeneration = process.env.AGENT_TERMINAL_SURFACE_GENERATION || "0";
  process.stdout.write(
    JSON.stringify(
      buildReport(agentID, surfaceGeneration, {
        sessionReference: {
          agentKind: "opencode",
          opaquePayload: "self-test-session",
          capturedAtRevision: 0,
        },
      }),
    ) + "\n",
  );
}
