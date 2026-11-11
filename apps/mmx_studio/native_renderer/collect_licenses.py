#!/usr/bin/env python3
"""Collect the resolved Rust dependency notices for the actual target platform."""
from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path
import shutil
import subprocess


def collect(output: Path, target: str | None = None) -> dict:
    root = Path(__file__).resolve().parent
    if target is None:
        version = subprocess.check_output(["rustc", "-vV"], cwd=root, text=True)
        target = next(line.split(": ", 1)[1] for line in version.splitlines() if line.startswith("host: "))
    data = json.loads(subprocess.check_output([
        "cargo", "metadata", "--locked", "--format-version=1", "--filter-platform", target,
    ], cwd=root, text=True))
    reachable = {node["id"] for node in data["resolve"]["nodes"]}
    output.mkdir(parents=True, exist_ok=True)
    records = []
    for package in data["packages"]:
        if package["id"] not in reachable or package["name"] == "mmx_gpu":
            continue
        source = Path(package["manifest_path"]).parent
        files = set()
        for candidate in source.iterdir():
            name = candidate.name.lower()
            if candidate.is_file() and name.startswith(("license", "licence", "copying", "notice", "unlicense")):
                files.add(candidate)
            elif candidate.is_dir() and name in ("licenses", "license"):
                files.update(f for f in candidate.rglob("*") if f.is_file())
        if package.get("license_file"):
            files.add(source / package["license_file"])
        provenance = None
        if not files:
            # A few workspace crates omit root notices from their published
            # archive. These exact-commit upstream notices are vendored, so
            # release builds do not fetch mutable license text from the web.
            source = root / "vendor_licenses" / f"{package['name']}-{package['version']}"
            index = json.loads((root / "vendor_licenses" / "provenance.json").read_text())
            provenance = [entry for entry in index if entry["package"] == package["name"] and entry["version"] == package["version"]]
            for entry in provenance:
                candidate = root / "vendor_licenses" / entry["file"]
                if hashlib.sha256(candidate.read_bytes()).hexdigest() != entry["sha256"]:
                    raise RuntimeError(f"Vendored notice checksum mismatch: {candidate}")
                files.add(candidate)
            if not files:
                raise RuntimeError(f"Missing license text for {package['name']} {package['version']}")
        folder = output / f"{package['name']}-{package['version']}"
        folder.mkdir(exist_ok=True)
        notices = []
        for source_file in sorted(files):
            relative = source_file.relative_to(source)
            destination = folder / relative
            destination.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(source_file, destination)
            notices.append({"path": destination.relative_to(output).as_posix(),
                            "sha256": hashlib.sha256(destination.read_bytes()).hexdigest()})
        records.append({"name": package["name"], "version": package["version"],
                        "license": package["license"], "repository": package["repository"],
                        "notices": notices, "vendoredProvenance": provenance})
    report = {"schema": 1, "target": target, "cargoLockSha256": hashlib.sha256((root / "Cargo.lock").read_bytes()).hexdigest(),
              "packages": sorted(records, key=lambda record: record["name"])}
    (output / "index.json").write_text(json.dumps(report, indent=2) + "\n")
    return report


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--target")
    options = parser.parse_args()
    collect(options.output, options.target)
