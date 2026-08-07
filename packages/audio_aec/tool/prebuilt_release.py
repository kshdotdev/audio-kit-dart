#!/usr/bin/env python3
"""Build-independent packaging contract for audio_aec native releases.

Every staged artifact is loaded and asked to create/destroy a 16 kHz mono AEC3
instance on its own target runner. The aggregate manifest is then generated
from those exact bytes and verified before upload or optional publication.
Nothing in this tool populates the Dart hook's built-in pins automatically: a
maintainer must review the generated manifest and commit the rendered pins in a
later package change, so the package never advertises an artifact merely
because a workflow was configured to build one.
"""

from __future__ import annotations

import argparse
import ctypes
import hashlib
import json
import os
from pathlib import Path
import platform
import re
import shutil
import sys
from typing import Any, Iterable


PACKAGE_ROOT = Path(__file__).resolve().parent.parent
RELEASE_ENV = PACKAGE_ROOT / "tool" / "native_release.env"
HOOK_MANIFEST = PACKAGE_ROOT / "hook" / "prebuilt_manifest.dart"
NOTICE_SOURCE = PACKAGE_ROOT / "NOTICE"
NOTICE_FILE = "audio_aec-NOTICE.txt"
MANIFEST_FILE = "audio_aec-prebuilt-manifest.json"

TARGETS: dict[str, dict[str, Any]] = {
    "macos-arm64": {
        "system": "Darwin",
        "machines": {"arm64", "aarch64"},
        "installed": "libaec_ffi.dylib",
        "artifact": "aec_ffi-macos-arm64.dylib",
    },
    "macos-x64": {
        "system": "Darwin",
        "machines": {"x86_64", "amd64"},
        "installed": "libaec_ffi.dylib",
        "artifact": "aec_ffi-macos-x64.dylib",
    },
    "linux-x64": {
        "system": "Linux",
        "machines": {"x86_64", "amd64"},
        "installed": "libaec_ffi.so",
        "artifact": "aec_ffi-linux-x64.so",
    },
    "windows-x64": {
        "system": "Windows",
        "machines": {"x86_64", "amd64"},
        "installed": "aec_ffi.dll",
        "artifact": "aec_ffi-windows-x64.dll",
    },
}

ENTRY_KEYS = {
    "schemaVersion",
    "artifactVersion",
    "engineVersion",
    "target",
    "file",
    "sha256",
    "sizeBytes",
    "runtimeProbe",
}
ARTIFACT_KEYS = {"target", "file", "sha256", "sizeBytes"}
MANIFEST_KEYS = {
    "schemaVersion",
    "artifactVersion",
    "engineVersion",
    "source",
    "notice",
    "artifacts",
}


class ContractError(RuntimeError):
    """A release input would create a false or unverifiable claim."""


def load_release_config() -> dict[str, str]:
    values: dict[str, str] = {}
    for raw_line in RELEASE_ENV.read_text(encoding="utf-8").splitlines():
        line = raw_line.strip()
        if not line or line.startswith("#"):
            continue
        if "=" not in line:
            raise ContractError(f"Malformed release config line: {raw_line}")
        key, value = line.split("=", 1)
        if not key or not value:
            raise ContractError(f"Empty release config field: {raw_line}")
        values[key] = value
    required = {
        "AUDIO_AEC_ARTIFACT_VERSION",
        "AUDIO_AEC_ENGINE_VERSION",
        "AUDIO_AEC_WAP_REPO",
        "AUDIO_AEC_WAP_REF",
    }
    missing = required.difference(values)
    if missing:
        raise ContractError(f"Release config is missing: {sorted(missing)}")
    return values


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for block in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def assert_host_target(target: str) -> None:
    spec = target_spec(target)
    actual_system = platform.system()
    actual_machine = platform.machine().lower()
    if actual_system != spec["system"] or actual_machine not in spec["machines"]:
        raise ContractError(
            f"Target {target} cannot be staged on {actual_system}-{actual_machine}. "
            "Cross-target naming is intentionally unsupported."
        )


def target_spec(target: str) -> dict[str, Any]:
    try:
        return TARGETS[target]
    except KeyError as error:
        raise ContractError(
            f"Unsupported target {target!r}; expected one of {sorted(TARGETS)}."
        ) from error


def probe_library(path: Path, expected_version: str) -> str:
    if not path.is_file() or path.stat().st_size == 0:
        raise ContractError(f"Native library is missing or empty: {path}")
    try:
        library = ctypes.CDLL(str(path.resolve()))
        create = library.aec_create
        create.argtypes = [ctypes.c_int32, ctypes.c_int32]
        create.restype = ctypes.c_void_p
        destroy = library.aec_destroy
        destroy.argtypes = [ctypes.c_void_p]
        destroy.restype = None
        version = library.aec_version
        version.argtypes = []
        version.restype = ctypes.c_char_p
        # Resolve every remaining symbol before creating an engine. ctypes only
        # resolves on attribute access, just like Dart FFI lookupFunction.
        for symbol in (
            "aec_process_reverse",
            "aec_process_capture",
            "aec_get_metrics",
        ):
            getattr(library, symbol)
    except (AttributeError, OSError) as error:
        raise ContractError(f"{path} is not a loadable six-symbol AEC ABI: {error}") from error

    raw_version = version()
    if raw_version is None:
        raise ContractError(f"{path} returned a null aec_version pointer.")
    actual_version = raw_version.decode("utf-8")
    if actual_version != expected_version:
        raise ContractError(
            f"{path} has engine version {actual_version!r}; "
            f"expected {expected_version!r}."
        )

    # The package default remains 16 kHz, while Concepta Copilot's capture graph
    # runs at 48 kHz. A release must instantiate both before it can claim to be
    # a usable desktop runtime.
    for sample_rate in (16000, 48000):
        handle = create(sample_rate, 1)
        if not handle:
            raise ContractError(
                f"{path} loaded but aec_create({sample_rate}, 1) returned null."
            )
        destroy(handle)
    return actual_version


def artifact_entry(
    target: str,
    artifact: Path,
    *,
    config: dict[str, str],
    runtime_probed: bool,
) -> dict[str, Any]:
    spec = target_spec(target)
    if artifact.name != spec["artifact"]:
        raise ContractError(
            f"Artifact for {target} must be named {spec['artifact']}, got {artifact.name}."
        )
    return {
        "schemaVersion": 1,
        "artifactVersion": config["AUDIO_AEC_ARTIFACT_VERSION"],
        "engineVersion": config["AUDIO_AEC_ENGINE_VERSION"],
        "target": target,
        "file": artifact.name,
        "sha256": sha256_file(artifact),
        "sizeBytes": artifact.stat().st_size,
        "runtimeProbe": runtime_probed,
    }


def stage_artifact(target: str, library: Path, output: Path) -> tuple[Path, Path]:
    assert_host_target(target)
    config = load_release_config()
    expected_version = config["AUDIO_AEC_ENGINE_VERSION"]
    probe_library(library, expected_version)

    output.mkdir(parents=True, exist_ok=True)
    artifact = output / target_spec(target)["artifact"]
    shutil.copyfile(library, artifact)
    entry = artifact_entry(
        target,
        artifact,
        config=config,
        runtime_probed=True,
    )
    entry_path = output / f"{target}.entry.json"
    write_json(entry_path, entry)
    return artifact, entry_path


def assemble_manifest(directory: Path, output: Path) -> dict[str, Any]:
    # A stale manifest beside missing artifacts is more dangerous than no
    # manifest. Remove only the explicitly requested output before validation.
    if output.exists():
        output.unlink()
    config = load_release_config()
    artifacts: list[dict[str, Any]] = []
    for target in sorted(TARGETS):
        spec = target_spec(target)
        artifact = directory / spec["artifact"]
        entry_path = directory / f"{target}.entry.json"
        if not artifact.is_file() or not entry_path.is_file():
            raise ContractError(
                f"Cannot assemble a release: {target} has no staged binary and entry."
            )
        entry = read_object(entry_path)
        if set(entry) != ENTRY_KEYS:
            raise ContractError(f"Unexpected keys in {entry_path}: {sorted(entry)}")
        expected_entry = artifact_entry(
            target,
            artifact,
            config=config,
            runtime_probed=True,
        )
        if entry != expected_entry:
            raise ContractError(f"Staged entry does not match exact bytes: {entry_path}")
        if entry["runtimeProbe"] is not True:
            raise ContractError(f"{target} was not runtime-probed on its target runner.")
        artifacts.append({key: entry[key] for key in sorted(ARTIFACT_KEYS)})

    notice_path = directory / NOTICE_FILE
    shutil.copyfile(NOTICE_SOURCE, notice_path)
    manifest: dict[str, Any] = {
        "schemaVersion": 1,
        "artifactVersion": config["AUDIO_AEC_ARTIFACT_VERSION"],
        "engineVersion": config["AUDIO_AEC_ENGINE_VERSION"],
        "source": {
            "repository": config["AUDIO_AEC_WAP_REPO"],
            "revision": config["AUDIO_AEC_WAP_REF"],
        },
        "notice": {
            "file": NOTICE_FILE,
            "sha256": sha256_file(notice_path),
            "sizeBytes": notice_path.stat().st_size,
        },
        "artifacts": artifacts,
    }
    write_json(output, manifest)
    return manifest


def verify_manifest(manifest_path: Path, directory: Path) -> dict[str, Any]:
    config = load_release_config()
    manifest = read_object(manifest_path)
    if set(manifest) != MANIFEST_KEYS:
        raise ContractError(f"Unexpected manifest keys: {sorted(manifest)}")
    if manifest["schemaVersion"] != 1:
        raise ContractError("Unsupported prebuilt manifest schemaVersion.")
    if manifest["artifactVersion"] != config["AUDIO_AEC_ARTIFACT_VERSION"]:
        raise ContractError("Manifest artifactVersion does not match native_release.env.")
    if manifest["engineVersion"] != config["AUDIO_AEC_ENGINE_VERSION"]:
        raise ContractError("Manifest engineVersion does not match native_release.env.")
    if manifest["source"] != {
        "repository": config["AUDIO_AEC_WAP_REPO"],
        "revision": config["AUDIO_AEC_WAP_REF"],
    }:
        raise ContractError("Manifest source pin does not match native_release.env.")

    raw_artifacts = manifest["artifacts"]
    if not isinstance(raw_artifacts, list):
        raise ContractError("Manifest artifacts must be an array.")
    by_target: dict[str, dict[str, Any]] = {}
    for raw in raw_artifacts:
        if not isinstance(raw, dict) or set(raw) != ARTIFACT_KEYS:
            raise ContractError("Manifest artifact entry has unexpected shape.")
        target = raw.get("target")
        if not isinstance(target, str) or target in by_target:
            raise ContractError(f"Duplicate or invalid target in manifest: {target!r}")
        by_target[target] = raw
    if set(by_target) != set(TARGETS):
        raise ContractError(
            f"Manifest target set is {sorted(by_target)}; expected {sorted(TARGETS)}."
        )

    for target, spec in TARGETS.items():
        entry = by_target[target]
        if entry["file"] != spec["artifact"]:
            raise ContractError(f"Manifest misnames the {target} artifact.")
        artifact = directory / spec["artifact"]
        if not artifact.is_file():
            raise ContractError(f"Manifest claims an absent artifact: {artifact}")
        if entry["sizeBytes"] != artifact.stat().st_size:
            raise ContractError(f"Size mismatch for {artifact}.")
        if entry["sha256"] != sha256_file(artifact):
            raise ContractError(f"SHA-256 mismatch for {artifact}.")

    notice = manifest["notice"]
    if not isinstance(notice, dict) or set(notice) != {
        "file",
        "sha256",
        "sizeBytes",
    }:
        raise ContractError("Manifest notice entry has unexpected shape.")
    if notice["file"] != NOTICE_FILE:
        raise ContractError("Manifest notice filename is not canonical.")
    notice_path = directory / NOTICE_FILE
    if not notice_path.is_file():
        raise ContractError("Manifest claims a missing third-party notice.")
    if notice["sizeBytes"] != notice_path.stat().st_size:
        raise ContractError("Third-party notice size mismatch.")
    if notice["sha256"] != sha256_file(notice_path):
        raise ContractError("Third-party notice SHA-256 mismatch.")
    return manifest


def verify_contract() -> None:
    config = load_release_config()
    source = HOOK_MANIFEST.read_text(encoding="utf-8")
    version_match = re.search(r"const String artifactVersion = '([^']+)';", source)
    if version_match is None:
        raise ContractError("Could not find artifactVersion in prebuilt_manifest.dart.")
    if version_match.group(1) != config["AUDIO_AEC_ARTIFACT_VERSION"]:
        raise ContractError(
            "hook/prebuilt_manifest.dart artifactVersion differs from native_release.env."
        )
    pins = dict(
        re.findall(r"^\s*'([^']+)':\s*'([0-9a-fA-F]{64})',\s*$", source, re.MULTILINE)
    )
    unknown = set(pins).difference(TARGETS)
    if unknown:
        raise ContractError(f"Hook manifest pins unsupported targets: {sorted(unknown)}")


def render_pins(manifest_path: Path, directory: Path) -> str:
    manifest = verify_manifest(manifest_path, directory)
    lines = ["const Map<String, String> pinnedSha256 = <String, String>{"]
    for entry in manifest["artifacts"]:
        lines.append(f"  '{entry['target']}': '{entry['sha256']}',")
    lines.append("};")
    return "\n".join(lines)


def read_object(path: Path) -> dict[str, Any]:
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        raise ContractError(f"Could not read JSON object {path}: {error}") from error
    if not isinstance(value, dict):
        raise ContractError(f"Expected a JSON object in {path}.")
    return value


def write_json(path: Path, value: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    encoded = json.dumps(value, indent=2, sort_keys=True, ensure_ascii=True) + "\n"
    temporary = path.with_name(f".{path.name}.tmp")
    with temporary.open("w", encoding="utf-8", newline="\n") as handle:
        handle.write(encoded)
    os.replace(temporary, path)


def parser() -> argparse.ArgumentParser:
    root = argparse.ArgumentParser(description=__doc__)
    commands = root.add_subparsers(dest="command", required=True)

    host = commands.add_parser("host", help="assert this runner matches a target")
    host.add_argument("--target", required=True, choices=sorted(TARGETS))

    probe = commands.add_parser("probe", help="load, create, and destroy an AEC engine")
    probe.add_argument("--library", required=True, type=Path)

    stage = commands.add_parser("stage", help="probe and stage one target artifact")
    stage.add_argument("--target", required=True, choices=sorted(TARGETS))
    stage.add_argument("--library", required=True, type=Path)
    stage.add_argument("--output", required=True, type=Path)

    assemble = commands.add_parser("assemble", help="create the four-target manifest")
    assemble.add_argument("--directory", required=True, type=Path)
    assemble.add_argument("--output", type=Path)

    verify = commands.add_parser("verify", help="verify all manifest bytes and hashes")
    verify.add_argument("--manifest", required=True, type=Path)
    verify.add_argument("--directory", required=True, type=Path)

    commands.add_parser("contract", help="verify source pins and Dart hook metadata")

    pins = commands.add_parser("render-pins", help="render reviewed Dart SHA-256 pins")
    pins.add_argument("--manifest", required=True, type=Path)
    pins.add_argument("--directory", required=True, type=Path)
    return root


def main(argv: Iterable[str] | None = None) -> int:
    args = parser().parse_args(argv)
    try:
        if args.command == "host":
            assert_host_target(args.target)
        elif args.command == "probe":
            config = load_release_config()
            version = probe_library(args.library, config["AUDIO_AEC_ENGINE_VERSION"])
            print(version)
        elif args.command == "stage":
            artifact, entry = stage_artifact(args.target, args.library, args.output)
            print(artifact)
            print(entry)
        elif args.command == "assemble":
            output = args.output or args.directory / MANIFEST_FILE
            assemble_manifest(args.directory, output)
            print(output)
        elif args.command == "verify":
            verify_manifest(args.manifest, args.directory)
            print("audio_aec prebuilt manifest verified")
        elif args.command == "contract":
            verify_contract()
            print("audio_aec release contract verified")
        elif args.command == "render-pins":
            print(render_pins(args.manifest, args.directory))
        else:
            raise AssertionError(f"Unhandled command: {args.command}")
    except ContractError as error:
        print(f"Error: {error}", file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
