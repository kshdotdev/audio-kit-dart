from __future__ import annotations

import importlib.util
from pathlib import Path
import tempfile
import unittest


MODULE_PATH = Path(__file__).with_name("prebuilt_release.py")
SPEC = importlib.util.spec_from_file_location("audio_aec_prebuilt_release", MODULE_PATH)
assert SPEC is not None and SPEC.loader is not None
release = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(release)


class PrebuiltReleaseContractTest(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        self.directory = Path(self.temporary.name)
        self.config = release.load_release_config()
        for index, target in enumerate(sorted(release.TARGETS)):
            spec = release.target_spec(target)
            artifact = self.directory / spec["artifact"]
            artifact.write_bytes(f"native-{target}-{index}".encode("ascii"))
            entry = release.artifact_entry(
                target,
                artifact,
                config=self.config,
                runtime_probed=True,
            )
            release.write_json(self.directory / f"{target}.entry.json", entry)

    def tearDown(self) -> None:
        self.temporary.cleanup()

    def test_manifest_is_deterministic_and_verifies_exact_bytes(self) -> None:
        manifest_path = self.directory / release.MANIFEST_FILE

        release.assemble_manifest(self.directory, manifest_path)
        first = manifest_path.read_bytes()
        release.assemble_manifest(self.directory, manifest_path)
        second = manifest_path.read_bytes()

        self.assertEqual(first, second)
        verified = release.verify_manifest(manifest_path, self.directory)
        self.assertEqual(
            {item["target"] for item in verified["artifacts"]},
            set(release.TARGETS),
        )

    def test_verification_rejects_artifact_tampering(self) -> None:
        manifest_path = self.directory / release.MANIFEST_FILE
        release.assemble_manifest(self.directory, manifest_path)
        linux = self.directory / release.target_spec("linux-x64")["artifact"]
        linux.write_bytes(linux.read_bytes() + b"tampered")

        with self.assertRaisesRegex(release.ContractError, "Size mismatch"):
            release.verify_manifest(manifest_path, self.directory)

    def test_missing_target_removes_stale_manifest_and_never_claims_release(self) -> None:
        manifest_path = self.directory / release.MANIFEST_FILE
        manifest_path.write_text('{"stale": true}\n', encoding="utf-8")
        missing = self.directory / release.target_spec("windows-x64")["artifact"]
        missing.unlink()

        with self.assertRaisesRegex(release.ContractError, "windows-x64"):
            release.assemble_manifest(self.directory, manifest_path)

        self.assertFalse(manifest_path.exists())

    def test_hook_artifact_version_matches_release_source(self) -> None:
        release.verify_contract()


if __name__ == "__main__":
    unittest.main()
