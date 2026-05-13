#!/usr/bin/env python3
"""
generate-docs.py
Reads docs/data/scripts.json and auto-generates:
  - The scenario index section of COPILOT.md (between <!-- GEN:START --> and <!-- GEN:END -->)
  - Folder README.md files for each script category

Run manually:  python3 tools/generate-docs.py
Also runs via GitHub Actions on every push that changes scripts.json.
"""

import json
from pathlib import Path
from collections import defaultdict

REPO_ROOT = Path(__file__).parent.parent
MANIFEST  = REPO_ROOT / "docs" / "data" / "scripts.json"

GEN_START = "<!-- GEN:START -->"
GEN_END   = "<!-- GEN:END -->"

# Maps a script's file prefix to the README it belongs to and a display label.
# Order matters for COPILOT.md section order.
FOLDER_MAP = [
    ("Windows/Diagnostics", REPO_ROOT / "Windows/Diagnostics/README.md", "Windows — Diagnostics"),
    ("Windows/Security",    REPO_ROOT / "Windows/Security/README.md",    "Windows — Security"),
    ("Windows/Network",     REPO_ROOT / "Windows/Network/README.md",     "Windows — Network"),
    ("Windows/Updates",     REPO_ROOT / "Windows/Updates/README.md",     "Windows — Updates"),
    ("Windows/Users",       REPO_ROOT / "Windows/Users/README.md",       "Windows — Users"),
    ("MacOS",               REPO_ROOT / "MacOS/README.md",               "macOS"),
    ("M365",                REPO_ROOT / "M365/README.md",                "Microsoft 365"),
    ("Apps",                REPO_ROOT / "Apps/README.md",                "Apps"),
    ("3CX",                 None,                                         "3CX"),
]


def load_scripts():
    with MANIFEST.open(encoding="utf-8") as f:
        return json.load(f)


def scripts_for_prefix(scripts, prefix):
    return [s for s in scripts if s["file"].startswith(prefix + "/")]


def flag_table(script):
    flags = script.get("flags", [])
    if not flags:
        return ""
    rows = []
    for fl in flags:
        rows.append(f"| `{fl['flag']}` | {fl['when']} |")
    header = "\n| Flag | When to use |\n|------|-------------|\n"
    return header + "\n".join(rows)


# ─── COPILOT.md scenario section ─────────────────────────────────

def build_copilot_section(scripts):
    lines = []

    for prefix, _readme_path, label in FOLDER_MAP:
        group = scripts_for_prefix(scripts, prefix)
        if not group:
            continue

        lines.append(f"## Scenario Index — {label}\n")

        for s in group:
            name = s["name"]
            desc = s.get("description", "")
            symptoms = s.get("symptoms", [])
            flags = s.get("flags", [])

            lines.append(f"### `{name}`")
            lines.append(f"{desc}\n")

            if symptoms:
                lines.append("**Use when:**")
                for sym in symptoms:
                    lines.append(f"- {sym}")
                lines.append("")

            if flags:
                lines.append("**Flags:**")
                lines.append("| Flag | When to use |")
                lines.append("|------|-------------|")
                for fl in flags:
                    lines.append(f"| `{fl['flag']}` | {fl['when']} |")
                lines.append("")

        lines.append("")

    return "\n".join(lines)


def update_copilot_md(scripts):
    copilot_path = REPO_ROOT / "COPILOT.md"
    if not copilot_path.exists():
        print("  SKIP: COPILOT.md not found")
        return

    content = copilot_path.read_text(encoding="utf-8")

    start_idx = content.find(GEN_START)
    end_idx   = content.find(GEN_END)

    if start_idx == -1 or end_idx == -1:
        print("  SKIP: COPILOT.md missing <!-- GEN:START --> / <!-- GEN:END --> markers")
        return

    generated = build_copilot_section(scripts)
    new_content = (
        content[:start_idx + len(GEN_START)]
        + "\n\n"
        + generated
        + "\n"
        + content[end_idx:]
    )

    copilot_path.write_text(new_content, encoding="utf-8")
    print("  UPDATED: COPILOT.md")


# ─── Folder READMEs ──────────────────────────────────────────────

FOLDER_README_INTROS = {
    "Windows/Diagnostics": (
        "General-purpose diagnostic scripts for Windows endpoints. "
        "Safe to paste into any remote terminal — RMM, RDP, or PowerShell remoting."
    ),
    "Windows/Security": (
        "Scripts for checking and troubleshooting Windows security "
        "configuration, encryption, and device identity."
    ),
    "Windows/Network": (
        "Scripts for diagnosing and fixing Windows network configuration issues."
    ),
    "Windows/Updates": (
        "Scripts for checking Windows Update state and history."
    ),
    "Windows/Users": (
        "Scripts for managing local user accounts on Windows endpoints."
    ),
    "MacOS": (
        "Diagnostic and remediation scripts for macOS endpoints. "
        "Written in bash — use in SSH, Kandji/Jamf remote commands, or terminal paste."
    ),
    "M365": (
        "PowerShell scripts for Microsoft 365 administration via the Microsoft Graph API. "
        "All scripts use OAuth client credentials flow."
    ),
    "Apps": (
        "Scripts for checking and remediating specific third-party application "
        "health on Windows endpoints."
    ),
}

FOLDER_USAGE_NOTES = {
    "MacOS": (
        "## Usage\n\n"
        "```bash\n"
        "bash get-EndpointHealth.sh\n"
        "bash get-printer-health.sh --fix\n"
        "```\n"
    ),
    "M365": (
        "## Prerequisites\n\n"
        "All scripts require an Azure AD app registration with appropriate "
        "Microsoft Graph API permissions. See each script's `.NOTES` block for details.\n"
    ),
}


def build_folder_readme(prefix, label, scripts):
    group = scripts_for_prefix(scripts, prefix)
    if not group:
        return None

    intro = FOLDER_README_INTROS.get(prefix, "")
    lines = [f"# {label}\n"]

    if intro:
        lines.append(f"{intro}\n")

    lines.append("## Scripts\n")
    lines.append("| Script | When to use |")
    lines.append("|--------|-------------|")

    for s in group:
        name    = s["name"]
        desc    = s.get("description", "").split(".")[0]  # first sentence
        symptoms = s.get("symptoms", [])
        when    = symptoms[0] if symptoms else desc
        lines.append(f"| `{name}` | {when} |")

    lines.append("")

    extra = FOLDER_USAGE_NOTES.get(prefix, "")
    if extra:
        lines.append(extra)

    return "\n".join(lines) + "\n"


def update_folder_readmes(scripts):
    for prefix, readme_path, label in FOLDER_MAP:
        if readme_path is None:
            continue

        content = build_folder_readme(prefix, label, scripts)
        if content is None:
            continue

        readme_path.write_text(content, encoding="utf-8")
        print(f"  UPDATED: {readme_path.relative_to(REPO_ROOT)}")


# ─── Entry point ─────────────────────────────────────────────────

def main():
    scripts = load_scripts()
    print(f"Loaded {len(scripts)} scripts from scripts.json\n")
    update_copilot_md(scripts)
    update_folder_readmes(scripts)
    print("\nDone.")


if __name__ == "__main__":
    main()
