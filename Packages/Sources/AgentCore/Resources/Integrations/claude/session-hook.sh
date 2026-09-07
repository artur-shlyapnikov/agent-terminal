#!/bin/sh
# AgentTerminal — Claude Code session-report shim (architecture §3.10/§3.16/§3.17).
#
# Wired as a Claude Code hook (SessionStart/UserPromptSubmit/Stop/...). Reads
# the hook JSON payload on stdin, maps it to a control-protocol report and
# forwards it via `agentctl integration report` NDJSON over the app's unix
# socket.
#
# Required environment (injected by the ephemeral launch ticket, §3.16):
#   AGENT_TERMINAL_TOKEN             scoped hook token for this generation
#   AGENT_TERMINAL_AGENT_ID          agent identifier
#   AGENT_TERMINAL_SURFACE_GENERATION surface generation number
# Optional:
#   AGENT_TERMINAL_SOCKET            socket path (default below)
#   AGENT_TERMINAL_AGENTCTL          agentctl binary (default: `agentctl` on PATH)
#   AGENT_TERMINAL_SEQ_STATE_DIR     dir for the file-backed monotonic seq counter
#   AGENT_TERMINAL_DRY_RUN           =1 prints the report NDJSON to stdout instead
#                                    of connecting (used by the validator self-test)
#
# Safety law: failures here are ALWAYS best-effort and silent — this shim must
# never break the host CLI. Every path exits 0.

set -u

AGENT_ID="${AGENT_TERMINAL_AGENT_ID:-}"
SURFACE_GENERATION="${AGENT_TERMINAL_SURFACE_GENERATION:-0}"
TOKEN="${AGENT_TERMINAL_TOKEN:-}"
AGENTCTL="${AGENT_TERMINAL_AGENTCTL:-agentctl}"
SOCKET="${AGENT_TERMINAL_SOCKET:-$HOME/Library/Application Support/AgentTerminal/runtime/control.sock}"
SOURCE="claude-hook"

# --- read hook payload -------------------------------------------------------
payload=""
if [ ! -t 0 ]; then
    payload="$(cat 2>/dev/null || true)"
fi

json_string_field() {
    # $1 = key, $2 = json text; extracts the TOP-LEVEL "key":"value" string.
    # Nested {...} payloads are peeled off first (innermost braces outward),
    # so a key inside a nested object can never shadow the real field.
    local text
    text="$2"
    while :; do
        case "$text" in
            # Peel ONLY when braces are genuinely nested ({...{...}); a flat
            # object's own braces must survive to serve as the key boundary.
            *{[!{}]*{*}*) text="$(printf '%s' "$text" | sed 's/{[^{}]*}//g')" ;;
            *) break ;;
        esac
    done
    printf '%s' "$text" \
        | sed -n 's/.*[{},][[:space:]]*"'"$1"'"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' \
        | head -n 1
}

json_escape() {
    # Escape backslash then double-quote so an interpolated value stays
    # valid inside hand-built JSON (NDJSON must never break on quotes).
    printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'
}

event="$(json_string_field hook_event_name "$payload")"
session_id="$(json_string_field session_id "$payload")"

# --- map hook event to lifecycle tag (closed vocabulary, §3.16) ---------------
lifecycle=""
case "$event" in
    SessionStart)         lifecycle="" ;;                 # identity report below
    UserPromptSubmit)     lifecycle="working" ;;
    PreToolUse)           lifecycle="working" ;;
    PostToolUse)          lifecycle="working" ;;
    Stop)                 lifecycle="idle" ;;
    SubagentStop)         lifecycle="idle" ;;
    Notification)         lifecycle="waitingForInput" ;;
    SessionEnd)           lifecycle="stopped" ;;
    *)                    lifecycle="" ;;
esac

# --- monotonic sequence counter (§3.6 ordering), file-backed per agent -------
SEQ_STATE_DIR="${AGENT_TERMINAL_SEQ_STATE_DIR:-${TMPDIR:-/tmp}/agentterminal-seq}"
# Release the seq lock ONLY if this shell still owns it: a stale-lock
# breaker may have removed what LOOKED like an orphan and handed the slot
# to a newer holder; unconditionally rmdir'ing at section exit would delete
# the breaker's lock and let two holders run read-increment-write
# concurrently (duplicate seq → EvidenceLedger drops reports).
release_seq_lock() {
    local lock="$1"
    if [ "$(cat "$lock/pid" 2>/dev/null)" = "$$" ]; then
        # Rename-atomic dismantle: a stale-breaker that recreates the lock
        # at the original path mid-release can never have its replacement
        # destroyed by our cleanup, because we only ever touch the private
        # rename target.
        if mv "$lock" "$lock.releasing.$$" 2>/dev/null; then
            rm -rf "$lock.releasing.$$"
        fi
    fi
}

next_seq() {
    [ -n "$AGENT_ID" ] || return 0
    mkdir -p "$SEQ_STATE_DIR" 2>/dev/null || return 0
    local lock="$SEQ_STATE_DIR/$AGENT_ID.lock"
    local tries=0
    local broke_stale=0
    until mkdir "$lock" 2>/dev/null; do
        tries=$((tries + 1))
        if [ "$tries" -ge 20 ]; then
            # Retry budget spent. Break a stale lock exactly once before
            # giving up: an orphaned lock from a killed shim would
            # otherwise disable seq ordering permanently, while a live
            # holder's critical section runs for microseconds — well
            # inside the 10s grace window. Anything that fails here still
            # degrades to omit-seq below.
            if [ "$broke_stale" -eq 0 ] && \
               [ -z "$(find "$lock" -maxdepth 0 -newermt '-10 seconds' 2>/dev/null)" ]; then
                broke_stale=1
                # The stale dir carries the holder's pid marker; remove
                # the whole directory, not just the (now non-empty) top.
                rm -rf "$lock" 2>/dev/null || true
                tries=0
                continue
            fi
            return 0   # contention/staleness: omit seq (never wedge the host CLI)
        fi
        sleep 0.025
    done
    # Ownership marker consumed by release_seq_lock above. If this write
    # fails the lock simply becomes a future stale-break victim — the
    # omit-seq degradation below stays intact either way.
    printf '%s\n' "$$" > "$lock/pid" 2>/dev/null || true
    local seq
    seq="$(cat "$SEQ_STATE_DIR/$AGENT_ID.seq" 2>/dev/null || echo 0)"
    case "$seq" in
        ''|*[!0-9]*) seq=0 ;;
    esac
    seq=$((seq + 1))
    if ! echo "$seq" > "$SEQ_STATE_DIR/$AGENT_ID.seq" 2>/dev/null; then
        # Counter state unwritable: the monotonic guarantee is broken, so
        # emit nothing — the report omits `seq` instead of risking a
        # duplicate that EvidenceLedger would silently drop.
        release_seq_lock "$lock"
        return 0
    fi
    release_seq_lock "$lock"
    echo "$seq"
}

SEQ="$(next_seq)"

# --- build report params ------------------------------------------------------
# A failed counter yields empty SEQ; nil sequences bypass the ledger's
# duplicate rule, so the field is omitted rather than falling back to 0.
params="{\"agentID\":\"$AGENT_ID\",\"source\":\"$SOURCE\",\"surfaceGeneration\":$SURFACE_GENERATION"

if [ -n "$SEQ" ]; then
    params="$params,\"seq\":$SEQ"
fi

if [ -n "$lifecycle" ]; then
    params="$params,\"lifecycle\":\"$lifecycle\""
fi
if [ -n "$session_id" ]; then
    # Session identity travels on EVERY report that carries a parsed id
    # (§3.10), alongside — not instead of — any lifecycle tag.
    params="$params,\"sessionReference\":{\"agentKind\":\"claude-code\",\"opaquePayload\":\"$(json_escape "$session_id")\",\"capturedAtRevision\":0}"
fi

if [ -n "$TOKEN" ]; then
    params="$params,\"tokenPresent\":true"
fi
params="$params}"

# agentctl parses --session-reference as JSON (a bare id is rejected as a
# bad request, which would silently kill real-mode identity capture), so
# the real path carries the SAME object shape the dry-run params build.
session_ref=""
if [ -n "$session_id" ]; then
    session_ref="{\"agentKind\":\"claude-code\",\"opaquePayload\":\"$(json_escape "$session_id")\",\"capturedAtRevision\":0}"
fi

# --- dry-run: emit NDJSON, no socket ------------------------------------------
if [ "${AGENT_TERMINAL_DRY_RUN:-0}" = "1" ]; then
    printf '%s\n' "$params"
    exit 0
fi

# --- real report: best-effort, silent failure ---------------------------------
[ -n "$AGENT_ID" ] || exit 0
[ -n "$TOKEN" ] || exit 0

# Args are accumulated positionally so every element stays individually
# quoted: the fully-quoted "${var:+--flag "$var"}" idiom merges flag and
# value into ONE argv word on this platform's /bin/sh, which agentctl
# cannot parse. Positional accumulation is split-proof either way.
set -- \
    --agent-id "$AGENT_ID" \
    --surface-generation "$SURFACE_GENERATION" \
    --source "$SOURCE"
[ -n "$SEQ" ] && set -- "$@" --seq "$SEQ"
[ -n "$lifecycle" ] && set -- "$@" --lifecycle "$lifecycle"
[ -n "$session_ref" ] && set -- "$@" --session-reference "$session_ref"

"$AGENTCTL" --socket "$SOCKET" integration report "$@" \
    >/dev/null 2>&1 || true

exit 0
