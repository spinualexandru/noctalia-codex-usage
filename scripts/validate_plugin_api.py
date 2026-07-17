#!/usr/bin/env python3
"""Validate plugin_api metadata in manifests and a standalone source catalog."""

from __future__ import annotations

import argparse
import sys
import tomllib
from pathlib import Path
from typing import Any


def load_toml(path: Path, errors: list[str]) -> dict[str, Any] | None:
    try:
        with path.open("rb") as handle:
            value = tomllib.load(handle)
    except FileNotFoundError:
        errors.append(f"{path}: file is missing")
        return None
    except tomllib.TOMLDecodeError as error:
        errors.append(f"{path}: invalid TOML: {error}")
        return None

    if not isinstance(value, dict):
        errors.append(f"{path}: expected a TOML table")
        return None
    return value


def validate_plugin_api(path: Path, context: str, value: Any, errors: list[str]) -> int | None:
    if not isinstance(value, int) or isinstance(value, bool) or value <= 0:
        errors.append(f"{path}: {context} plugin_api must be a positive integer")
        return None
    return value


def validate(root: Path) -> tuple[list[tuple[bool, str]], list[str]]:
    """Run every check, returning (passed/failed step descriptions, errors)."""
    steps: list[tuple[bool, str]] = []
    errors: list[str] = []

    manifests: dict[str, tuple[int, Path]] = {}
    manifest_paths = sorted(root.glob("*/plugin.toml"))
    steps.append((bool(manifest_paths), f"found {len(manifest_paths)} child manifest(s) (*/plugin.toml)"))
    if not manifest_paths:
        errors.append(f"{root}: no child plugin.toml files found")

    parsed: list[tuple[Path, dict[str, Any]]] = []
    for manifest_path in manifest_paths:
        manifest = load_toml(manifest_path, errors)
        if manifest is not None:
            parsed.append((manifest_path, manifest))
    if manifest_paths:
        steps.append((len(parsed) == len(manifest_paths), "all manifests parse as valid TOML"))

    ids_ok = apis_ok = removed_key_ok = unique_ok = True
    for manifest_path, manifest in parsed:
        if "min_noctalia" in manifest:
            errors.append(f"{manifest_path}: min_noctalia was removed; use plugin_api")
            removed_key_ok = False

        plugin_id = manifest.get("id")
        if not isinstance(plugin_id, str) or not plugin_id:
            errors.append(f"{manifest_path}: id must be a non-empty string")
            ids_ok = False
            continue
        plugin_api = validate_plugin_api(manifest_path, f"manifest {plugin_id!r}", manifest.get("plugin_api"), errors)
        if plugin_api is None:
            apis_ok = False
            continue
        if plugin_id in manifests:
            errors.append(f"{manifest_path}: duplicate plugin id {plugin_id!r}")
            unique_ok = False
            continue
        manifests[plugin_id] = (plugin_api, manifest_path)
    if parsed:
        steps.append((ids_ok, "manifest ids are non-empty strings"))
        steps.append((apis_ok, "manifest plugin_api values are positive integers"))
        steps.append((removed_key_ok, "no manifest uses the removed min_noctalia field"))
        steps.append((unique_ok, "manifest ids are unique"))

    catalog_path = root / "catalog.toml"
    catalog = load_toml(catalog_path, errors)
    steps.append((catalog is not None, f"{catalog_path.name} parses as valid TOML"))
    if catalog is None:
        return steps, errors
    rows = catalog.get("plugin")
    rows_ok = isinstance(rows, list) and bool(rows)
    row_count = len(rows) if isinstance(rows, list) else 0
    steps.append((rows_ok, f"{catalog_path.name} declares at least one [[plugin]] row ({row_count} found)"))
    if not rows_ok:
        errors.append(f"{catalog_path}: expected at least one [[plugin]] row")
        return steps, errors

    tables_ok = row_ids_ok = row_apis_ok = row_removed_key_ok = row_unique_ok = True
    rows_have_manifest = apis_match = True
    catalog_ids: set[str] = set()
    for index, row in enumerate(rows, start=1):
        context = f"catalog row {index}"
        if not isinstance(row, dict):
            errors.append(f"{catalog_path}: {context} must be a TOML table")
            tables_ok = False
            continue
        if "min_noctalia" in row:
            errors.append(f"{catalog_path}: {context} uses removed min_noctalia; use plugin_api")
            row_removed_key_ok = False

        plugin_id = row.get("id")
        if not isinstance(plugin_id, str) or not plugin_id:
            errors.append(f"{catalog_path}: {context} id must be a non-empty string")
            row_ids_ok = False
            continue
        if plugin_id in catalog_ids:
            errors.append(f"{catalog_path}: duplicate catalog id {plugin_id!r}")
            row_unique_ok = False
            continue
        catalog_ids.add(plugin_id)

        catalog_api = validate_plugin_api(catalog_path, f"{context} {plugin_id!r}", row.get("plugin_api"), errors)
        if catalog_api is None:
            row_apis_ok = False
        manifest_info = manifests.get(plugin_id)
        if manifest_info is None:
            errors.append(f"{catalog_path}: {context} {plugin_id!r} has no matching child manifest")
            rows_have_manifest = False
            continue
        manifest_api, manifest_path = manifest_info
        if catalog_api is not None and catalog_api != manifest_api:
            errors.append(
                f"{catalog_path}: {context} {plugin_id!r} plugin_api {catalog_api} "
                f"does not match {manifest_path} plugin_api {manifest_api}"
            )
            apis_match = False

    steps.append((tables_ok, "catalog rows are TOML tables"))
    steps.append((row_ids_ok, "catalog row ids are non-empty strings"))
    steps.append((row_unique_ok, "catalog row ids are unique"))
    steps.append((row_apis_ok, "catalog row plugin_api values are positive integers"))
    steps.append((row_removed_key_ok, "no catalog row uses the removed min_noctalia field"))
    steps.append((rows_have_manifest, "every catalog row matches a child manifest"))
    steps.append((apis_match, "catalog plugin_api values match their child manifests"))

    if manifests:
        all_listed = True
        for plugin_id, (_plugin_api, manifest_path) in manifests.items():
            if plugin_id not in catalog_ids:
                errors.append(f"{catalog_path}: missing row for {manifest_path} id {plugin_id!r}")
                all_listed = False
        steps.append((all_listed, "every child manifest has a catalog row"))

    return steps, errors


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--root",
        type=Path,
        default=Path(__file__).resolve().parents[1],
        help="Standalone plugin repository root (defaults to this script's repository)",
    )
    args = parser.parse_args(argv)
    root = args.root.expanduser().resolve()
    steps, errors = validate(root)

    width = len(str(len(steps)))
    for number, (ok, description) in enumerate(steps, start=1):
        mark = "✓" if ok else "✗"
        print(f"step {number:>{width}}/{len(steps)}: {mark} {description}")

    sys.stdout.flush()
    if errors:
        for error in errors:
            print(f"error: {error}", file=sys.stderr)
        return 1

    print(f"\nValidated plugin_api metadata for {len(list(root.glob('*/plugin.toml')))} plugin(s).")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
