#!/usr/bin/env python3
"""Check source size, duplicate sources, and synchronized Sparkle pins."""
import hashlib
import json
from pathlib import Path
import re
import subprocess
import sys


APP = Path(__file__).resolve().parents[1]
ROOT = APP.parent
MAX_SWIFT_LINES = 500


def main():
    errors = []
    hashes = {}
    sources = sorted((APP / "Perch").rglob("*.swift"))
    sources += sorted((APP / "PerchTests").rglob("*.swift"))
    for source in sources:
        data = source.read_bytes()
        count = len(data.splitlines())
        relative = source.relative_to(ROOT)
        if count > MAX_SWIFT_LINES:
            errors.append(f"{relative}: {count} lines exceeds {MAX_SWIFT_LINES}; split by responsibility")
        digest = hashlib.sha256(data).hexdigest()
        if digest in hashes:
            errors.append(f"{relative}: duplicates {hashes[digest]}")
        hashes[digest] = relative

    project = (APP / "project.yml").read_text()
    match = re.search(r'exactVersion: "([0-9.]+)"', project)
    if not match:
        errors.append("project.yml: missing exact Sparkle version")
    else:
        version = match[1]
        package = json.loads((APP / "Perch.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved").read_text())
        pin = next((p for p in package["pins"] if p["identity"] == "sparkle"), None)
        if not pin or pin["state"].get("version") != version:
            errors.append("Package.resolved: Sparkle version differs from project.yml")
        tools = (APP / "script/sparkle_tools.sh").read_text()
        if f'SPARKLE_VERSION="{version}"' not in tools:
            errors.append("sparkle_tools.sh: Sparkle version differs from project.yml")
        license_name = f"Sparkle-{version}-LICENSE.txt"
        licenses = sorted(p.name for p in (APP / "Perch/Resources/ThirdPartyLicenses").glob("Sparkle-*-LICENSE.txt"))
        if licenses != [license_name]:
            errors.append(f"Keep exactly the pinned Sparkle license: {license_name}")
        for path in [ROOT / "NOTICE", APP / "script/build_release.sh", APP / "docs/release-checklist.md"]:
            if license_name not in path.read_text():
                errors.append(f"{path.relative_to(ROOT)}: missing current license reference")

    for script in sorted((APP / "script").glob("*.sh")):
        result = subprocess.run(["bash", "-n", str(script)], capture_output=True, text=True)
        if result.returncode:
            errors.append(result.stderr.strip())
    if errors:
        print("\n".join(errors), file=sys.stderr)
        return 1
    print(f"Repository checks passed: {len(sources)} Swift files, maximum {MAX_SWIFT_LINES} lines, Sparkle {version}.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
