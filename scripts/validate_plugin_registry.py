#!/usr/bin/env python3
"""Validate registry/registry.json without third-party dependencies.

Mirrors the checks CLIProxyAPI performs before accepting a store source, plus
the parts of registry/schema.json that JSON Schema cannot express (GitHub
repository shape, direct installs only in schema v2, unique plugin ids).
"""
from __future__ import annotations

import json
import re
import sys
from pathlib import Path
from urllib.parse import urlparse

ROOT = Path(__file__).resolve().parent.parent
REGISTRY = ROOT / "registry" / "registry.json"
PLUGIN_ID = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$")
VERSION = re.compile(r"^[0-9][0-9A-Za-z.+-]*$")
SHA256 = re.compile(r"^[a-fA-F0-9]{64}$")
GOOS = {"darwin", "windows", "linux", "freebsd"}
GOARCH = {"arm64", "amd64"}
URL_FIELDS = ("logo", "homepage")
TOP_LEVEL_KEYS = {"schema_version", "plugins"}
PLUGIN_KEYS = {
    "id",
    "name",
    "description",
    "author",
    "version",
    "repository",
    "logo",
    "homepage",
    "license",
    "tags",
    "auth_required",
    "install",
    "versions",
}


def fail(message: str) -> None:
    print(f"registry: {message}", file=sys.stderr)
    raise SystemExit(1)


def require_string(plugin: dict, key: str, index: int) -> str:
    value = plugin.get(key)
    if not isinstance(value, str) or not value.strip():
        fail(f"plugins[{index}]: missing required field {key}")
    return value.strip()


def check_url(value: str, where: str, schemes: tuple[str, ...] = ("https",)) -> None:
    parsed = urlparse(value)
    if parsed.scheme not in schemes or not parsed.hostname:
        fail(f"{where}: expected one of {', '.join(schemes)} URLs, got {value!r}")
    if parsed.query and any(
        key in parsed.query.lower()
        for key in ("token", "key", "secret", "signature", "password")
    ):
        fail(f"{where}: URL contains a sensitive query parameter")


def check_repository(value: str, where: str) -> None:
    parsed = urlparse(value)
    if (
        parsed.scheme != "https"
        or parsed.hostname != "github.com"
        or parsed.query
        or parsed.fragment
        or len([part for part in parsed.path.split("/") if part]) != 2
        or parsed.path.rstrip("/").endswith(".git")
    ):
        fail(f"{where}: repository must be https://github.com/owner/repo")


def check_install(plugin: dict, where: str, schema_version: int) -> str:
    install = plugin.get("install") or {}
    if not isinstance(install, dict):
        fail(f"{where}.install: must be an object")
    install_type = install.get("type") or "github-release"
    if install_type not in ("github-release", "direct"):
        fail(f"{where}.install.type: unsupported {install_type!r}")
    if install_type == "direct":
        if schema_version != 2:
            fail(f"{where}: direct install requires schema_version 2")
        if not plugin.get("version"):
            fail(f"{where}: direct install requires version")
        artifacts = install.get("artifacts")
        if not isinstance(artifacts, list) or not artifacts:
            fail(f"{where}.install: direct install requires artifacts")
        seen = set()
        for artifact_index, artifact in enumerate(artifacts):
            artifact_where = f"{where}.install.artifacts[{artifact_index}]"
            if not isinstance(artifact, dict):
                fail(f"{artifact_where}: must be an object")
            goos = artifact.get("goos")
            goarch = artifact.get("goarch")
            if goos not in GOOS or goarch not in GOARCH:
                fail(f"{artifact_where}: unsupported platform {goos}/{goarch}")
            if (goos, goarch) in seen:
                fail(f"{artifact_where}: duplicate platform {goos}/{goarch}")
            seen.add((goos, goarch))
            check_url(str(artifact.get("url") or ""), artifact_where)
            if not SHA256.match(str(artifact.get("sha256") or "")):
                fail(f"{artifact_where}: sha256 must be 64 hex characters")
    return install_type


def main() -> None:
    # The path used to be hardcoded, so `validate_plugin_registry.py broken.json`
    # validated the good file and exited 0. Take the argument, and refuse
    # anything that is not the registry shape.
    target = Path(sys.argv[1]).resolve() if len(sys.argv) > 1 else REGISTRY
    try:
        registry = json.loads(target.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        fail(f"{target}: {error}")
    if not isinstance(registry, dict):
        fail("top level must be an object")
    unknown = sorted(set(registry) - TOP_LEVEL_KEYS)
    if unknown:
        fail(f"unknown top level fields: {', '.join(unknown)}")
    schema_version = registry.get("schema_version")
    if schema_version not in (1, 2):
        fail(f"unsupported schema_version {schema_version!r}")
    plugins = registry.get("plugins")
    if not isinstance(plugins, list):
        fail("plugins must be an array")

    seen: set[str] = set()
    for index, plugin in enumerate(plugins):
        if not isinstance(plugin, dict):
            fail(f"plugins[{index}]: must be an object")
        plugin_id = require_string(plugin, "id", index)
        if not PLUGIN_ID.match(plugin_id):
            fail(f"plugins[{index}]: invalid plugin id {plugin_id!r}")
        if plugin_id in seen:
            fail(f"plugins[{index}]: duplicate plugin id {plugin_id!r}")
        seen.add(plugin_id)
        unknown = sorted(set(plugin) - PLUGIN_KEYS)
        if unknown:
            fail(f"plugins[{index}]: unknown fields: {', '.join(unknown)}")
        for key in ("name", "description", "author"):
            require_string(plugin, key, index)
        version = plugin.get("version")
        if version is not None and (not isinstance(version, str) or not VERSION.match(version)):
            fail(f"plugins[{index}]: invalid version {version!r}")
        for key in URL_FIELDS:
            value = plugin.get(key)
            if value:
                if not isinstance(value, str):
                    fail(f"plugins[{index}].{key}: must be a string")
                check_url(value, f"plugins[{index}].{key}", schemes=("https", "http"))
        tags = plugin.get("tags", [])
        if not isinstance(tags, list) or not all(isinstance(tag, str) and tag for tag in tags):
            fail(f"plugins[{index}].tags: must be a list of non-empty strings")
        if len(set(tags)) != len(tags):
            fail(f"plugins[{index}].tags: duplicate tag")
        if "auth_required" in plugin and not isinstance(plugin["auth_required"], bool):
            fail(f"plugins[{index}].auth_required: must be a boolean")
        versions = plugin.get("versions")
        if versions is not None:
            if not isinstance(versions, list) or not versions:
                fail(f"plugins[{index}].versions: must be a non-empty array")
            for version_index, item in enumerate(versions):
                where = f"plugins[{index}].versions[{version_index}]"
                if not isinstance(item, dict):
                    fail(f"{where}: must be an object")
                version = item.get("version")
                if not isinstance(version, str) or not VERSION.match(version):
                    fail(f"{where}.version: invalid version {version!r}")
                if "install" in item:
                    check_install(item, where, schema_version)
        install_type = check_install(plugin, f"plugins[{index}]", schema_version)
        if install_type == "github-release":
            repository = require_string(plugin, "repository", index)
            check_repository(repository, f"plugins[{index}].repository")

    noun = "plugin" if len(plugins) == 1 else "plugins"
    print(f"registry: {len(plugins)} {noun}, schema {schema_version}, OK")


if __name__ == "__main__":
    main()
