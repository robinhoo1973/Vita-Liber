#!/usr/bin/env python3
"""ITMS-90208: reconcile metadata with actual Mach-O minos before signing; verify final IPA."""
import argparse
import os
from pathlib import Path
import plistlib
import re
import subprocess
import tempfile
import zipfile


def version(text):
    if not isinstance(text, str) or not re.fullmatch(r"\d+(?:\.\d+){0,2}", text):
        raise ValueError(f"Invalid deployment version: {text!r}")
    parts = tuple(map(int, text.split(".")))
    return parts + (0,) * (3 - len(parts))


def binary_minimum(output):
    versions = re.findall(r"^\s*(?:minos|version)\s+(\d+(?:\.\d+){0,2})\s*$", output, re.MULTILINE)
    # vtool's ntools version lines are not minos; request only LC_BUILD_VERSION/LC_VERSION_MIN_*.
    preferred = re.findall(r"^\s*minos\s+(\d+(?:\.\d+){0,2})\s*$", output, re.MULTILINE)
    candidates = preferred or versions
    if not candidates:
        raise ValueError("No minimum OS load command found")
    return max(candidates, key=version)


def inspect_app(app, repair=False):
    with (app / "Info.plist").open("rb") as handle:
        app_info = plistlib.load(handle)
    app_minimum = version(app_info["MinimumOSVersion"])
    frameworks = app / "Frameworks"
    for framework in sorted(frameworks.glob("*.framework")):
        plist = framework / "Info.plist"
        with plist.open("rb") as handle:
            info = plistlib.load(handle)
        binary = framework / info["CFBundleExecutable"]
        output = subprocess.check_output(["xcrun", "vtool", "-show-build", str(binary)], text=True)
        required = binary_minimum(output)
        if version(required) > app_minimum:
            raise ValueError(f"{framework.name} requires {required}, newer than the app deployment target")
        declared = info.get("MinimumOSVersion")
        if declared is None or version(declared) < version(required):
            if not repair:
                raise ValueError(f"ITMS-90208: {framework.name}: plist={declared} Mach-O={required}")
            info["MinimumOSVersion"] = required
            with plist.open("wb") as handle:
                plistlib.dump(info, handle)
            if os.environ.get("CODE_SIGNING_ALLOWED") != "NO":
                identity = os.environ.get("EXPANDED_CODE_SIGN_IDENTITY")
                if not identity:
                    raise ValueError("A signing identity is required after modifying an embedded framework")
                subprocess.run(["codesign", "--force", "--sign", identity,
                    "--preserve-metadata=identifier,entitlements,flags", str(framework)], check=True)
            print(f"Reconciled {framework.name}: {declared} -> {required}")
        else:
            print(f"Verified {framework.name}: plist={declared}, Mach-O={required}")


def main():
    parser = argparse.ArgumentParser()
    source = parser.add_mutually_exclusive_group(required=True)
    source.add_argument("--app", type=Path)
    source.add_argument("--ipa", type=Path)
    parser.add_argument("--repair", action="store_true")
    args = parser.parse_args()
    if args.ipa:
        if args.repair:
            raise ValueError("Exported IPA is verification-only")
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            with zipfile.ZipFile(args.ipa) as archive:
                for name in archive.namelist():
                    if not (root / name).resolve().is_relative_to(root):
                        raise ValueError("Invalid IPA path")
                archive.extractall(root)
            apps = list((root / "Payload").glob("*.app"))
            if len(apps) != 1:
                raise ValueError("Expected one app in IPA")
            inspect_app(apps[0])
            subprocess.run(["python3", str(Path(__file__).with_name("fetch-asr-models.py")),
                "--root", str(apps[0] / "ASRModels"), "--check"], check=True)
    else:
        inspect_app(args.app, args.repair)


if __name__ == "__main__":
    main()
