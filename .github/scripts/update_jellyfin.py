#!/usr/bin/env python3
"""Bump this repository to a Jellyfin server release.

Usage:
    update_jellyfin.py current             print the Jellyfin version the repo targets
    update_jellyfin.py latest              print the latest stable Jellyfin release tag
    update_jellyfin.py ready <tag>         exit 0 if the Docker image and NuGet packages for <tag> are published
    update_jellyfin.py apply <tag>         update every version-bearing file (and the jellyfin submodule) to <tag>

Only the Python standard library is used. Network calls go to api.github.com, raw.githubusercontent.com,
hub.docker.com and api.nuget.org. Set GH_TOKEN/GITHUB_TOKEN to avoid GitHub API rate limits.
"""

from __future__ import annotations

import json
import os
import re
import subprocess
import sys
import urllib.error
import urllib.request
import xml.etree.ElementTree as ET
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
DOCKERFILE = ROOT / "docker" / "Dockerfile"
CSPROJ = ROOT / "Jellyfin.Plugin.Pgsql" / "Jellyfin.Plugin.Pgsql.csproj"
UPSTREAM = "jellyfin/jellyfin"


def http_get(url: str, *, github: bool = False) -> bytes:
    headers = {"User-Agent": "jellyfin-pgsql-updater"}
    token = os.environ.get("GH_TOKEN") or os.environ.get("GITHUB_TOKEN")
    if github and token:
        headers["Authorization"] = f"Bearer {token}"
    with urllib.request.urlopen(urllib.request.Request(url, headers=headers), timeout=60) as resp:
        return resp.read()


def version_key(version: str) -> tuple[int, ...]:
    return tuple(int(p) for p in re.findall(r"\d+", version))


def tag_to_version(tag: str) -> str:
    return tag[1:] if tag.startswith("v") else tag


def current_version() -> str:
    match = re.search(r"^FROM jellyfin/jellyfin:(\S+)", DOCKERFILE.read_text(), re.M)
    if not match:
        sys.exit("Could not find 'FROM jellyfin/jellyfin:<version>' in docker/Dockerfile")
    return match.group(1)


def latest_tag() -> str:
    try:
        release = json.loads(http_get(f"https://api.github.com/repos/{UPSTREAM}/releases/latest", github=True))
        return release["tag_name"]
    except urllib.error.HTTPError as err:
        # Fall back to the highest stable vX.Y[.Z] tag (e.g. when the API is rate limited).
        print(f"GitHub API failed ({err.code}), falling back to git tags", file=sys.stderr)
        out = subprocess.run(["git", "ls-remote", "--tags", "--refs", f"https://github.com/{UPSTREAM}.git"],
                             check=True, capture_output=True, text=True).stdout
        tags = re.findall(r"refs/tags/(v\d+\.\d+(?:\.\d+)?)$", out, re.M)
        return max(tags, key=version_key)


def nuget_versions(package: str) -> list[str]:
    data = json.loads(http_get(f"https://api.nuget.org/v3-flatcontainer/{package.lower()}/index.json"))
    return [v for v in data["versions"] if "-" not in v]


def nuget_version_for(package: str, version: str) -> str | None:
    """The stable NuGet version of a Jellyfin package that matches a release version (12.1 -> 12.1.0)."""
    wanted = version_key(version)
    for candidate in nuget_versions(package):
        key = version_key(candidate)
        if key[: len(wanted)] == wanted and all(p == 0 for p in key[len(wanted):]):
            return candidate
    return None


def docker_tag_exists(version: str) -> bool:
    try:
        http_get(f"https://hub.docker.com/v2/repositories/jellyfin/jellyfin/tags/{version}")
        return True
    except urllib.error.HTTPError as err:
        if err.code == 404:
            return False
        raise


def ready(tag: str) -> bool:
    version = tag_to_version(tag)
    checks = {
        f"docker image jellyfin/jellyfin:{version}": docker_tag_exists(version),
        f"NuGet Jellyfin.Controller {version}": nuget_version_for("Jellyfin.Controller", version) is not None,
        f"NuGet Jellyfin.Model {version}": nuget_version_for("Jellyfin.Model", version) is not None,
    }
    for name, ok in checks.items():
        print(f"{'ok' if ok else 'MISSING'}: {name}", file=sys.stderr)
    return all(checks.values())


def upstream_package_versions(tag: str) -> dict[str, str]:
    raw = http_get(f"https://raw.githubusercontent.com/{UPSTREAM}/{tag}/Directory.Packages.props")
    return {
        el.get("Include"): el.get("Version")
        for el in ET.fromstring(raw).iter("PackageVersion")
        if el.get("Include") and el.get("Version")
    }


def upstream_sdk_major(tag: str) -> int:
    data = json.loads(http_get(f"https://raw.githubusercontent.com/{UPSTREAM}/{tag}/global.json"))
    return int(data["sdk"]["version"].split(".")[0])


def latest_npgsql_efcore(ef_major: int) -> str | None:
    candidates = [v for v in nuget_versions("Npgsql.EntityFrameworkCore.PostgreSQL") if version_key(v)[0] == ef_major]
    return max(candidates, key=version_key) if candidates else None


def edit(path: Path, pattern: str, replacement, *, count: int = 0, required: bool = True) -> None:
    text = path.read_text()
    new_text, n = re.subn(pattern, replacement, text, count=count, flags=re.M)
    if n == 0 and required:
        sys.exit(f"Pattern {pattern!r} not found in {path.relative_to(ROOT)}")
    if new_text != text:
        path.write_text(new_text)
        print(f"updated {path.relative_to(ROOT)}", file=sys.stderr)


def set_package_version(package: str, version: str) -> None:
    edit(CSPROJ, rf'(<PackageReference Include="{re.escape(package)}" Version=")[^"]+(")', rf"\g<1>{version}\g<2>")


def apply(tag: str) -> None:
    version = tag_to_version(tag)
    old = current_version()
    abi = ".".join((version.split(".") + ["0", "0", "0"])[:4])

    # Jellyfin packages and base image.
    set_package_version("Jellyfin.Controller", nuget_version_for("Jellyfin.Controller", version) or version)
    set_package_version("Jellyfin.Model", nuget_version_for("Jellyfin.Model", version) or version)
    edit(DOCKERFILE, r"^(FROM jellyfin/jellyfin:)\S+", rf"\g<1>{version}")
    edit(ROOT / "build.yaml", r'^(targetAbi: ")[^"]+(")', rf"\g<1>{abi}\g<2>")

    # Keep Microsoft.* packages on exactly the versions the server ships, so the plugin never loads a
    # different EF Core / Microsoft.Extensions build than the host.
    upstream = upstream_package_versions(tag)
    ef_version = upstream["Microsoft.EntityFrameworkCore.Relational"]
    ext_version = upstream.get("Microsoft.Extensions.Logging") or upstream["Microsoft.Extensions.DependencyInjection"]
    csproj_text = CSPROJ.read_text()
    for package in re.findall(r'<PackageReference Include="(Microsoft\.[^"]+)" Version="[^"]+"', csproj_text):
        family_default = ef_version if package.startswith("Microsoft.EntityFrameworkCore") else ext_version
        set_package_version(package, upstream.get(package, family_default))
    edit(ROOT / ".config" / "dotnet-tools.json", r'("dotnet-ef":\s*\{\s*"version":\s*")[^"]+(")', rf"\g<1>{ef_version}\g<2>")

    # The Npgsql EF Core provider major must match EF Core's major.
    ef_major = version_key(ef_version)[0]
    npgsql_current = re.search(r'Include="Npgsql\.EntityFrameworkCore\.PostgreSQL" Version="([^"]+)"', csproj_text).group(1)
    if version_key(npgsql_current)[0] != ef_major:
        npgsql = latest_npgsql_efcore(ef_major)
        if npgsql is None:
            print(f"WARNING: no stable Npgsql.EntityFrameworkCore.PostgreSQL {ef_major}.x on NuGet yet", file=sys.stderr)
        else:
            set_package_version("Npgsql.EntityFrameworkCore.PostgreSQL", npgsql)

    # .NET SDK / target framework follow the server's global.json.
    sdk = upstream_sdk_major(tag)
    tfm = f"net{sdk}.0"
    edit(CSPROJ, r"(<TargetFramework>)net\d+\.\d+(</TargetFramework>)", rf"\g<1>{tfm}\g<2>")
    edit(ROOT / "build.yaml", r'^(framework: ")net\d+\.\d+(")', rf"\g<1>{tfm}\g<2>")
    edit(DOCKERFILE, r"(mcr\.microsoft\.com/dotnet/sdk:)\d+\.\d+", rf"\g<1>{sdk}.0")
    edit(DOCKERFILE, r"net\d+\.\d+ library", f"{tfm} library", required=False)
    for workflow in (ROOT / ".github" / "workflows").glob("*.yaml"):
        edit(workflow, r'(dotnet-version: ")\d+\.\d+\.x(")', rf"\g<1>{sdk}.0.x\g<2>", required=False)
        edit(workflow, r'(dotnet-target: ")net\d+\.\d+(")', rf"\g<1>{tfm}\g<2>", required=False)
    edit(ROOT / ".devcontainer" / "devcontainer.json", r'("(?:dotnetRuntimeVersions|aspNetCoreRuntimeVersions)": ")\d+\.\d+(")', rf"\g<1>{sdk}.0\g<2>", required=False)
    for path in (ROOT / ".vscode" / "tasks.json", ROOT / ".vscode" / "launch.json", ROOT / "README.md"):
        edit(path, r"(bin/[Dd]ebug/)net\d+\.\d+", rf"\g<1>{tfm}", required=False)

    # Docs and examples point at the moving tag of the new version.
    escaped_old = re.escape(old)
    for path in (ROOT / "README.md", ROOT / "docker" / "docker-compose.yaml", DOCKERFILE):
        edit(path, rf"(jellyfin\.pgsql:){escaped_old}(?:-\d+)?(?![\d.])", rf"\g<1>{version}", required=False)
    edit(ROOT / "README.md", rf"(built on Jellyfin ){escaped_old}\b", rf"\g<1>{version}", required=False)
    if version != old:
        edit(ROOT / "build.yaml", r"^(changelog: >\n  ).*$", rf"\g<1>Jellyfin {version} support", required=False)

    # Source submodule (used for reference and for diffing upstream migrations).
    subprocess.run(["git", "submodule", "update", "--init", "--depth", "1", "jellyfin"], cwd=ROOT, check=True)
    subprocess.run(["git", "-C", "jellyfin", "fetch", "--depth", "1", "origin", "tag", tag], cwd=ROOT, check=True)
    subprocess.run(["git", "-C", "jellyfin", "checkout", "--quiet", tag], cwd=ROOT, check=True)

    print(f"{old} -> {version} (targetAbi {abi}, EF Core {ef_version}, {tfm})", file=sys.stderr)


def main(argv: list[str]) -> None:
    if len(argv) < 2:
        sys.exit(__doc__)
    command = argv[1]
    if command == "current":
        print(current_version())
    elif command == "latest":
        print(latest_tag())
    elif command == "ready" and len(argv) == 3:
        sys.exit(0 if ready(argv[2]) else 1)
    elif command == "apply" and len(argv) == 3:
        apply(argv[2])
    else:
        sys.exit(__doc__)


if __name__ == "__main__":
    main(sys.argv)
