# Screen manifests: schema and rule policy

- Status: Current — stage 7 (detection pipeline), per architecture notes
  §6.7. Describes the versioned TOML manifest format shipped at
  `Packages/Sources/AgentCore/Resources/Detection/<agent>.toml`, the loader's
  strictness, matcher semantics, hysteresis, conflict resolution, safety law,
  and the bundled inventory.
- Behavioral proof: `Packages/Tests/AgentCoreTests/DetectionFixtureTests.swift`
  evaluates the anonymized screen fixtures in
  `Tests/Fixtures/Detection/<agent>/` through the real loader → evaluator →
  engine stack (§3.23 snapshot fixtures).

## Binding decisions

1. Manifests describe detection evidence only; they can never trigger actions
   on behalf of the agent.
2. Unknown state beats unsafe false positive: unmatched or ambiguous screens
   resolve to `unknown`, never a guessed lifecycle.

---

## Manifest schema (§3.7)

```toml
manifestVersion = 1                      # required, only 1 is accepted
agentKind = "claude-code"                # required; AgentKind raw value
adapterVersionRange = ">=1.0 <3.0"       # optional; informational pin per CLI release
foregroundExecutables = ["claude", "node"] # required, non-empty
snapshotRows = 32                        # optional, default 32, range 1…64
fallback = "unknown"                     # optional, default/only "unknown"

[[rules]]                                # at least one required
id = "permission-prompt"
resultingLifecycle = "waitingForInput"   # see lifecycle table
priority = 100                           # higher evaluates first
requestKind = "approval"                 # REQUIRED iff resultingLifecycle = waitingForInput
stabilityMilliseconds = 150              # optional; drives the hysteresis window
allMatchers = [ … ]                      # every pattern must match
anyMatchers  = [ … ]                     # at least one must match (empty = no constraint)
noneMatchers = [ … ]                     # evaluated FIRST; any hit vetoes the rule
```

### Matcher syntax

```toml
{ kind = "literal" | "regex",
  pattern = "…",
  caseSensitive = false,                 # optional, default false
  region = "wholeSnapshot" }             # or lastLine / lastLines (+ required lines = N ≥ 1)
```

`region = "lastLines"` takes a separate mandatory integer field
`lines = N` (N ≥ 1) selecting the last N snapshot lines as the region text.
Shipped examples, quoted verbatim from the bundled manifests:

```toml
# claude-code.toml — approval prompt in the last 6 lines:
anyMatchers = [
  { kind = "regex", pattern = "Do you want to (proceed|create|make|run|allow)", region = "lastLines", lines = 6 },
]

# codex.toml — veto the approval rule while "cancelled" is anywhere on screen:
noneMatchers = [
  { kind = "literal", pattern = "cancelled", region = "wholeSnapshot" },
]
```

- Regexes use `NSRegularExpression` with `.anchorsMatchLines`; `^`/`$` anchor
  per line of the region text. Case-insensitive by default.
- Every regex is validated and compiled once at manifest load (§3.7: "Regex
  компилируются один раз") — an invalid pattern fails the load, never a
  detection tick.

## Loader strictness

`ScreenManifestLoader` is deliberately strict: anything outside the schema or
the supported TOML subset is a load error, never a silent default:

| Violation | Error |
|---|---|
| Unknown `manifestVersion` | `unsupportedManifestVersion` |
| Unknown `agentKind` | `agentKindMismatch` |
| Missing/empty `foregroundExecutables` | `missingField` |
| `snapshotRows` outside 1…64 | `invalidSnapshotRows` |
| `lastNLines` with lines ≤ 0 | `invalidLastLinesCount` — silently degrading to "last 1 line" would hide authoring mistakes |
| `waitingForInput` rule without `requestKind` | `waitingRuleWithoutRequestKind` |
| Invalid regex | `invalidRegex` (at load) |
| Unknown lifecycle / request kind / region / matcher kind | matching `unknown*` error |

The TOML subset itself rejects multi-line strings, duplicate keys, dotted
keys, hex integers, unterminated strings, and bare invalid booleans
(`TOMLParser` tests in `ScreenManifestTests`). Bundled lookup accepts both
SwiftPM's stripped (`Detection/`) and Xcode's full (`Resources/Detection/`)
subdirectory layouts.

## Lifecycle values

| `resultingLifecycle` | Notes |
|---|---|
| `unknown`, `starting`, `idle`, `working`, `stopping` | plain phases |
| `stopped` | decodes as `stopped(.userRequested)` |
| `failed` | decodes as `failed(FailureDescriptor(reason: "screen rule"))` |
| `waitingForInput` | requires `requestKind`: `freeText`, `approval`, `selection`, `unknown` |

## Evaluation semantics (§3.7 steps 6–9)

1. Rules are grouped by descending `priority`; within one priority group all
   matchers run, `noneMatchers` first (a veto skips the rule).
2. A rule matches when all `allMatchers` match AND (`anyMatchers` empty or at
   least one matches). Regions are evaluated against the normalized snapshot:
   whole text, last line, or last N lines.
3. Equal-priority rules that agree are merged (`supportingRules`); equal-
   priority rules that disagree on the resulting lifecycle yield
   `.unknown(reason: [ruleIDs])` immediately — never a random pick.
4. Hysteresis (`ScreenDetectionEngine`, §3.5 flicker protection):
   - `waitingForInput` needs the SAME rule matched on two snapshots at least
     its stability window apart (bundled: 150 ms);
   - `idle` after `working` needs a stable screen with no newer
     `outputRevision` for the idle rule's window (bundled: 400 ms);
   - everything else emits immediately;
   - conflicts emit `unknown` immediately — hysteresis cannot rescue
     ambiguity.

### stabilityRequirement behavior (post-577a0a8)

The winning rule's own `stabilityMilliseconds` governs its hysteresis window.
Rules without a declaration keep the legacy engine constants (150 ms waiting
confirmation, 400 ms idle stabilization) — which are exactly the values the
bundled manifests declare, so bundled behavior is unchanged while custom
manifests may declare longer windows (e.g. a 2000 ms approval window is no
longer wrongly confirmed at 150 ms; covered by
`testWaitingWindowUsesWinningRuleStabilityMilliseconds`).

## Safety law (§3.4)

- Screen-sourced request descriptors are ALWAYS
  `safeReplyMode = .terminalOnly` (`InputRequestDescriptor.screenSourced`).
- `composerAllowed` can never come from a screen rule: it requires an explicit
  freeText grant elsewhere in the system; no bundled manifest produces it.
- Approval/selection prompts are never auto-answered; queued prompts are not
  delivered while waiting; `unknown` never triggers automatic delivery.
- No bundled manifest rule may exist that maps a screen to a safe action —
  manifests produce evidence only.

## Authoring checklist

1. Start from a real screen shape; capture ≤32 rows, strip user content —
   fixtures must stay anonymized synthetic text (§3.23: no full terminal
   recordings are stored).
2. Prefer narrow regions (`lastLine`, `lastLines`) over whole-snapshot
   patterns; they survive scrollback noise.
3. Give every waiting rule a `requestKind`; ask what a safe reply mode is —
   the answer is always terminalOnly from screens.
4. Add a `noneMatchers` veto for known overlapping markers (e.g. Claude's
   permission prompt vetoes "esc to cancel").
5. Check equal-priority collisions: two rules that can fire on the same
   screen with different lifecycles will classify that screen `unknown`.
6. Declare `stabilityMilliseconds` explicitly even when using the default
   value — it documents intent and survives constant changes.
7. Add a fixture under `Tests/Fixtures/Detection/<agent>/` plus an entry in
   `DetectionFixtureTests.fixtures`, including a negative case proving the
   rule does NOT fire on lookalike screens.

## Bundled manifest inventory

All three manifests ship in `AgentCore` resources
(`Resources/Detection/*.toml`), `manifestVersion = 1`, fallback `unknown`.

### claude-code.toml — agentKind `claude-code`, executables `claude`, `node`

| Rule ID | Priority | Result | Signals |
|---|---:|---|---|
| `permission-prompt` | 100 | waitingForInput(approval) | "Do you want to (proceed\|create\|make\|run\|allow)" in last 6 lines; veto "esc to cancel" anywhere |
| `trust-dialog` | 100 | waitingForInput(selection) | `^[❯>]…(Yes\|No\|Allow\|Deny\|Always)` in last 4 lines |
| `free-text-question` | 90 | waitingForInput(freeText) | question ends one of the last 2 rows AND bare composer marker on last row (post-fix regression: both signals across the two-row window; see §4.8 note) |
| `spinner-working` | 50 | working | spinner/`thinking`/`esc to interrupt` marker on last line |
| `idle-prompt` | 10 | idle | `>` on last line, no question in last 4 lines |

Known ambiguity (accepted): a screen showing both a "Do you want…" question
and a `❯ Allow…` option line matches both priority-100 rules → classified
`unknown`. This is intentional conservatism; covered by fixture
`Tests/Fixtures/Detection/claude/ambiguous.txt`.

### codex.toml — agentKind `codex`, executables `codex`, `node`

| Rule ID | Priority | Result | Signals |
|---|---:|---|---|
| `approval-prompt` | 100 | waitingForInput(approval) | "Allow command?"/`^(Allow\|Approve\|Reject\|Cancel)\s*\[` in last 5 lines; veto "cancelled" anywhere |
| `plan-approval` | 100 | waitingForInput(selection) | literal "Approve plan?" in last 6 lines |
| `codex-working` | 50 | working | `(thinking\|working\|running)…$` or braille spinner on last line |
| `codex-idle` | 10 | idle | `›` on last line, no "Allow" in last 4 lines |

### opencode.toml — agentKind `opencode`, executables `opencode`, `node`, `bun`

Fallback path only: OpenCode's plugin normally owns lifecycle authority
(integration evidence outranks screens, §3.6); these rules apply when the
plugin is absent or degraded.

| Rule ID | Priority | Result | Signals |
|---|---:|---|---|
| `permission-request` | 100 | waitingForInput(approval) | "Permission (required\|needed)" in last 6 lines OR `^(allow\|deny\|once\|always)` on last line |
| `question-prompt` | 90 | waitingForInput(freeText) | last row ends with `?` AND "type your answer" within last 3 lines |
| `opencode-working` | 50 | working | `(building\|running\|scanning\|editing)…$` or half-circle spinner on last line |
| `opencode-idle` | 10 | idle | bare `❯`/`>` composer row, no "Permission" in last 5 lines |

## Fixture coverage (§3.23)

| Fixture | Expected outcome (rule → lifecycle) |
|---|---|
| `claude/idle.txt` | `idle-prompt` → idle |
| `claude/working.txt` | `spinner-working` → working |
| `claude/permission.txt` | `permission-prompt` → waitingForInput(approval) |
| `claude/question.txt` | `free-text-question` → waitingForInput(freeText) |
| `claude/ambiguous.txt` | `permission-prompt`+`trust-dialog` → unknown |
| `codex/idle.txt` | `codex-idle` → idle |
| `codex/working.txt` | `codex-working` → working |
| `codex/approval.txt` | `approval-prompt` → waitingForInput(approval) |
| `codex/plan.txt` | `plan-approval` → waitingForInput(selection) |
| `codex/noise.txt` | no rule → unknown |
| `opencode/idle.txt` | `opencode-idle` → idle |
| `opencode/working.txt` | `opencode-working` → working |
| `opencode/permission.txt` | `permission-request` → waitingForInput(approval) |
| `opencode/question.txt` | `question-prompt` → waitingForInput(freeText) |

`DetectionFixtureTests` additionally sweeps every non-waiting fixture through
a full hysteresis timeline (past the 150 ms confirmation interval, with
interleaved output revisions) and asserts zero false `waitingForInput` states
— the §6.7 gate "не создаёт ложный waiting state на fixtures".

After CLI updates, bump `adapterVersionRange` together with re-recorded
fixtures; screens that stop classifying fall back to `unknown` (risk table
§5.1: "Unknown вместо unsafe false positive").
