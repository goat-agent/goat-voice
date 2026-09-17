import importlib.util
import json
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
TOOL = ROOT / "tools" / "collect-third-party-notices.py"

spec = importlib.util.spec_from_file_location(
    "collect_third_party_notices", TOOL)
notices = importlib.util.module_from_spec(spec)
spec.loader.exec_module(notices)


def run_tool(*argv):
    return notices.main([str(arg) for arg in argv])


class ThirdPartyNoticesTests(unittest.TestCase):
    def test_committed_notices_are_up_to_date(self):
        self.assertEqual(run_tool("--check"), 0)

    def test_output_is_deterministic(self):
        with tempfile.TemporaryDirectory() as tmp:
            first = Path(tmp) / "first.txt"
            second = Path(tmp) / "second.txt"
            self.assertEqual(run_tool("--out", first), 0)
            self.assertEqual(run_tool("--out", second), 0)
            self.assertEqual(first.read_bytes(), second.read_bytes())

    def test_every_pin_is_classified(self):
        document = json.loads(
            (ROOT / "Package.resolved").read_text())
        identities = {pin["identity"] for pin in document["pins"]}
        covered = {c.pin for c in notices.COMPONENTS if c.pin}
        uncovered = identities - covered - set(notices.NOT_DISTRIBUTED)
        self.assertEqual(uncovered, set())
        unknown = (covered | set(notices.NOT_DISTRIBUTED)) - identities
        self.assertEqual(unknown, set())

    def test_unclassified_pin_fails(self):
        with tempfile.TemporaryDirectory() as tmp:
            resolved = Path(tmp) / "Package.resolved"
            document = json.loads(
                (ROOT / "Package.resolved").read_text())
            document["pins"].append({
                "identity": "mystery-package",
                "kind": "remoteSourceControl",
                "location": "https://example.com/mystery-package.git",
                "state": {"revision": "0" * 40, "version": "1.0.0"},
            })
            resolved.write_text(json.dumps(document))
            with self.assertRaises(RuntimeError):
                run_tool("--package-resolved", resolved,
                         "--out", Path(tmp) / "out.txt")

    def test_missing_license_fails(self):
        with tempfile.TemporaryDirectory() as tmp:
            with self.assertRaises(RuntimeError):
                run_tool("--checkouts", Path(tmp),
                         "--out", Path(tmp) / "out.txt")

    def test_output_mentions_pins_and_revisions(self):
        document = json.loads(
            (ROOT / "Package.resolved").read_text())
        with tempfile.TemporaryDirectory() as tmp:
            out = Path(tmp) / "notices.txt"
            self.assertEqual(run_tool("--out", out), 0)
            text = out.read_text()
        for pin in document["pins"]:
            identity = pin["identity"]
            if identity in notices.NOT_DISTRIBUTED:
                continue
            revision = pin["state"]["revision"]
            self.assertIn(revision, text, identity)
            self.assertIn(pin["location"].removesuffix(".git"), text, identity)

    def test_qwen_tokenizer_provenance(self):
        with tempfile.TemporaryDirectory() as tmp:
            out = Path(tmp) / "notices.txt"
            self.assertEqual(run_tool("--out", out), 0)
            text = out.read_text()
        catalog = json.loads(
            (ROOT / "Resources" / "Models" / "catalog.json").read_text())
        bundled = None
        for manifest in catalog:
            for artifact in manifest["artifacts"]:
                if artifact["downloadURL"] == "bundle://Models/qwen3-tokenizer.json":
                    bundled = artifact
        self.assertIsNotNone(bundled)
        self.assertIn(bundled["sha256Hex"], text)
        self.assertIn("mlx-community/Qwen3-ASR-1.7B-8bit@a8379a2e", text)


if __name__ == "__main__":
    unittest.main()
