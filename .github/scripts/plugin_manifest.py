#!/usr/bin/env python3
"""Maintain manifest.json, the Jellyfin plugin repository manifest of this fork.

    plugin_manifest.py next-version MANIFEST JELLYFIN_VERSION BUILD
        Print the plugin version of image build <JELLYFIN_VERSION>-<BUILD>: <major>.<minor>.<BUILD>.0, or a higher
        third number if the manifest already lists one that high for that major.minor (a Jellyfin patch release
        starts its builds at 1 again), so versions only go up.

    plugin_manifest.py add MANIFEST --version V --target-abi A --source-url U --checksum MD5 --changelog TEXT
        Add a version (newest first), or replace one with the same version number.

Jellyfin installs a listed version by downloading source-url, checking its MD5 checksum and extracting it to
<data dir>/plugins/<name>_<version>; it offers versions whose targetAbi is not newer than the server.
"""
import argparse
import datetime
import json
import re
import sys
from pathlib import Path

PLUGIN = {
    "guid": "27e7ad18-ea71-4b19-b1a9-6e4c2e4d5e18",
    "name": "PostgreSQL Database",
    "description": "PostgreSQL database provider for Jellyfin, maintained in the pastel0510/Jellyfin.Pgsql fork. "
    "Needs the PostgreSQL client tools (pg_dump, psql) on the server and a database.xml that selects the provider; "
    "see https://github.com/pastel0510/Jellyfin.Pgsql#installing-without-docker.",
    "overview": "Store the Jellyfin database in PostgreSQL",
    "owner": "pastel0510",
    "category": "General",
}


def load(path: Path) -> list[dict]:
    manifest = json.loads(path.read_text()) if path.exists() and path.read_text().strip() else []
    entry = next((p for p in manifest if p.get("guid") == PLUGIN["guid"]), {})
    # One plugin per manifest; anything else (the upstream placeholder with another GUID) is dropped.
    return [{**PLUGIN, "versions": entry.get("versions", [])}]


def next_version(path: Path, jellyfin_version: str, build: int) -> str:
    parts = re.findall(r"\d+", jellyfin_version)
    if len(parts) < 2:
        sys.exit(f"Unexpected Jellyfin version {jellyfin_version!r}")
    prefix = f"{int(parts[0])}.{int(parts[1])}."
    builds = [v["version"] for v in load(path)[0]["versions"] if v["version"].startswith(prefix)]
    highest = max((int(v.split(".")[2]) for v in builds), default=0)
    return f"{prefix}{max(build, highest + 1)}.0"


def add(path: Path, args: argparse.Namespace) -> None:
    manifest = load(path)
    versions = [v for v in manifest[0]["versions"] if v["version"] != args.version]
    versions.append({
        "version": args.version,
        "changelog": args.changelog,
        "targetAbi": args.target_abi,
        "sourceUrl": args.source_url,
        "checksum": args.checksum.lower(),
        "timestamp": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
    })
    versions.sort(key=lambda v: tuple(int(p) for p in v["version"].split(".")), reverse=True)
    manifest[0]["versions"] = versions
    path.write_text(json.dumps(manifest, indent=4) + "\n")


def main() -> None:
    parser = argparse.ArgumentParser()
    sub = parser.add_subparsers(dest="command", required=True)
    nv = sub.add_parser("next-version")
    nv.add_argument("manifest", type=Path)
    nv.add_argument("jellyfin_version")
    nv.add_argument("build", type=int)
    ad = sub.add_parser("add")
    ad.add_argument("manifest", type=Path)
    for name in ("--version", "--target-abi", "--source-url", "--checksum", "--changelog"):
        ad.add_argument(name, required=True)
    args = parser.parse_args()
    if args.command == "next-version":
        print(next_version(args.manifest, args.jellyfin_version, args.build))
    else:
        add(args.manifest, args)


if __name__ == "__main__":
    main()
