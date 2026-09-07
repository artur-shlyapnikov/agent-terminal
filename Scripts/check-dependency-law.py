#!/usr/bin/env python3
"""Dependency-law gate (architecture notes §3.2).

Scans `import` declarations of first-party Swift sources and fails on any
module importing beyond its allowed set. The law, encoded:

    AgentCore     → Foundation (+ Apple system frameworks it already uses)
    AgentStore    → AgentCore + GRDB
    AgentControl  → AgentCore
    TerminalKit   → AgentCore + GhosttyBridge + AppKit
    GhosttyBridge → (C target; no Swift imports)
    App           → all package modules
    Helpers       → AgentControl protocol models only, no AppKit

First-party module names are derived from Packages/Sources/*, so a new target
fails loudly here until its law is written down — exactly the point.
"""

from __future__ import annotations

import re
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
SOURCES = REPO / "Packages" / "Sources"

IMPORT_RE = re.compile(r"^\s*(?:@_implementationOnly\s+)?import\s+([\w.]+)", re.M)

# System frameworks considered "free" everywhere (no architecture boundary).
SYSTEM_OK = {
    "Foundation", "FoundationEssentials", "Dispatch", "os", "OSLog",
    "Carbon", "Metal", "UniformTypeIdentifiers", "CryptoKit", "Security",
    "SystemPackage", "Darwin",
}

# Test-only modules never appear in product sources but keep the matrix honest.
TEST_ONLY = {"Testing", "XCTest"}

FIRST_PARTY = sorted(p.name for p in SOURCES.iterdir() if p.is_dir())

LAW: dict[str, set[str]] = {
    "AgentCore": set(),
    "AgentStore": {"AgentCore", "GRDB"},
    "AgentControl": {"AgentCore"},
    "TerminalKit": {"AgentCore", "GhosttyBridge", "AppKit"},
    # C target: no Swift sources; entry exists so its law is written down.
    "GhosttyBridge": set(),
    "AgentLauncher": {"AgentCore", "AgentControl"},
    "agentctl": {"AgentCore", "AgentControl"},
}


def violations_for(module: str) -> list[tuple[Path, str]]:
    root = SOURCES / module
    if not root.is_dir():
        return []
    allowed = LAW.get(module)
    if allowed is None:
        return [(root, "UNDECLARED-MODULE (add an entry to LAW in check-dependency-law.py)")]
    bad: list[tuple[Path, str]] = []
    for swift in root.rglob("*.swift"):
        text = swift.read_text(encoding="utf-8", errors="replace")
        for imported in IMPORT_RE.findall(text):
            top = imported.split(".")[0]
            if top in SYSTEM_OK or top in TEST_ONLY:
                continue
            if top == module:
                continue
            if top not in FIRST_PARTY and top not in allowed and top in LAW or (
                top in FIRST_PARTY and top not in allowed
            ):
                bad.append((swift, f"{top} (allowed: {sorted(allowed) or 'system only'})"))
                continue
            if top not in FIRST_PARTY and top not in allowed:
                bad.append((swift, f"'{top}' is neither first-party nor allowlisted "
                                   f"(allowed: {sorted(allowed) or 'system only'})"))
    return bad


def main() -> int:
    failures = 0
    for module in FIRST_PARTY:
        for path, reason in violations_for(module):
            rel = path.relative_to(REPO)
            print(f"DEPENDENCY-LAW VIOLATION [{module}] {rel}: imports {reason}", file=sys.stderr)
            failures += 1
    if failures:
        print(f"\n{failures} violation(s). See architecture notes §3.2 before relaxing.",
              file=sys.stderr)
        return 1
    print(f"dependency-law: OK ({len(FIRST_PARTY)} modules scanned)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
