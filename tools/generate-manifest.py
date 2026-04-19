#!/usr/bin/env python3
"""
generate-manifest.py
Scans the repo for .ps1 and .sh script files and adds stub entries to
docs/data/scripts.json for any scripts not already in the manifest.

Usage:
    python3 tools/generate-manifest.py

Run this after adding new scripts. Then fill in the description and tags
for any new stubs that appear in scripts.json.
"""

import json
import re
import sys
from pathlib import Path

REPO_ROOT  = Path(__file__).parent.parent
MANIFEST   = REPO_ROOT / "docs" / "data" / "scripts.json"
GITHUB_URL = "https://github.com/lachlanalston/SupportTools/blob/main"

# Folders to scan. Set "category" to None to derive it from the immediate
# subdirectory name (e.g. Windows/Diagnostics → category "Diagnostics").
SCAN_DIRS = {
    "Windows": {"platform": "windows", "category": None},
    "MacOS":   {"platform": "macos",   "category": "MacOS"},
    "M365":    {"platform": "m365",    "category": "M365"},
    "3CX":     {"platform": "api",     "category": "API"},
    "Apps":    {"platform": "windows", "category": None},
}

EXTENSIONS = {".ps1", ".sh"}

WIP_PATTERN = re.compile(r'^WIP[_\-]', re.IGNORECASE)


def extract_synopsis(path: Path) -> str:
    """Try to pull a .SYNOPSIS or first comment line from a script."""
    try:
        text = path.read_text(encoding="utf-8", errors="ignore")
    except Exception:
        return ""

    # PowerShell .SYNOPSIS
    m = re.search(r'\.SYNOPSIS\s*\n\s*(.+)', text, re.IGNORECASE)
    if m:
        return m.group(1).strip()

    # Bash: first non-shebang comment line
    for line in text.splitlines():
        line = line.strip()
        if line.startswith('#!'):
            continue
        if line.startswith('#'):
            desc = line.lstrip('#').strip()
            if desc:
                return desc
        elif line:
            break

    return ""


def main():
    if not MANIFEST.exists():
        print(f"ERROR: Manifest not found at {MANIFEST}")
        sys.exit(1)

    with MANIFEST.open(encoding="utf-8") as f:
        existing = json.load(f)

    existing_files = {e["file"] for e in existing}

    new_entries = []

    for folder, meta in SCAN_DIRS.items():
        scan_path = REPO_ROOT / folder
        if not scan_path.is_dir():
            continue

        for ext in EXTENSIONS:
            for script in sorted(scan_path.rglob(f"*{ext}")):
                rel_path = script.relative_to(REPO_ROOT).as_posix()
                if rel_path in existing_files:
                    continue

                is_wip = bool(WIP_PATTERN.match(script.stem))
                synopsis = extract_synopsis(script)

                category = meta["category"] or script.parent.name

                entry = {
                    "name":        script.stem,
                    "file":        rel_path,
                    "platform":    meta["platform"],
                    "category":    category,
                    "description": synopsis or "",
                    "tags":        [],
                    "wip":         is_wip,
                    "github_url":  f"{GITHUB_URL}/{rel_path}",
                }
                new_entries.append(entry)
                print(f"  + {rel_path}")

    if not new_entries:
        print("No new scripts found. Manifest is up to date.")
        return

    existing.extend(new_entries)

    with MANIFEST.open("w", encoding="utf-8") as f:
        json.dump(existing, f, indent=2, ensure_ascii=False)
        f.write("\n")

    print(f"\nAdded {len(new_entries)} new stub(s) to {MANIFEST.relative_to(REPO_ROOT)}")
    print("Fill in the 'description' and 'tags' fields for each new entry.")


if __name__ == "__main__":
    main()
