import base64
import copy
from datetime import datetime, timezone
import importlib.util
import json
from pathlib import Path
import plistlib
import tempfile
import unittest
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parents[1]


def load(name, filename):
    spec = importlib.util.spec_from_file_location(name, ROOT / "tools" / filename)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


release = load("release", "release.py")
publisher = load("publisher", "publish-release.py")


class ReleasePipelineTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.config = release.configuration()
        self.archive = self.root / release.archive_name(self.config)
        self.archive.write_bytes(b"synthetic archive")
        self.signature = base64.b64encode(bytes(64)).decode()

    def test_feed_uses_exact_archive_length_version_and_signature(self):
        xml = release.appcast(self.config, self.archive, self.signature, "14.0",
                              datetime(2026, 1, 1, tzinfo=timezone.utc))
        root = ET.fromstring(xml)
        enclosure = root.find("./channel/item/enclosure")
        self.assertEqual(int(enclosure.get("length")), self.archive.stat().st_size)
        self.assertEqual(enclosure.get(f"{{{release.SPARKLE}}}edSignature"), self.signature)
        self.assertEqual(publisher.feed_build(xml), self.config["build"])
        self.assertTrue(enclosure.get("url").endswith("/" + self.archive.name))

    def test_invalid_signature_is_rejected(self):
        for signature in ["", "not-base64", base64.b64encode(bytes(32)).decode()]:
            with self.subTest(signature=signature), self.assertRaises(ValueError):
                release.appcast(self.config, self.archive, signature, "14.0")

    def test_wrong_archive_name_is_rejected(self):
        other = self.root / "wrong.dmg"
        other.write_bytes(b"fixture")
        with self.assertRaises(ValueError):
            release.appcast(self.config, other, self.signature, "14.0")

    def test_feed_rejects_rollback_and_duplicate_builds(self):
        xml = release.appcast(self.config, self.archive, self.signature, "14.0")
        with self.assertRaises(ValueError):
            publisher.combine_feeds(xml, xml)
        old = copy.deepcopy(self.config)
        old["build"] -= 1
        older_xml = release.appcast(old, self.archive, self.signature, "14.0")
        with self.assertRaises(ValueError):
            publisher.combine_feeds(older_xml, xml)

    def test_feed_retains_previous_compatible_release(self):
        old = copy.deepcopy(self.config)
        old["build"] -= 1
        prior = release.appcast(old, self.archive, self.signature, "14.0")
        current = release.appcast(self.config, self.archive, self.signature, "15.0")
        combined = publisher.combine_feeds(current, prior)
        versions = ET.fromstring(combined).findall("./channel/item")
        self.assertEqual(len(versions), 2)
        self.assertEqual(versions[1].find(f"{{{release.SPARKLE}}}minimumSystemVersion").text, "14.0")

    def test_configuration_rejects_nonmatching_feed_and_invalid_key(self):
        for field, value in [("feedURL", "http://example.com/feed.xml"),
                             ("publicKey", "invalid"), ("version", "v1.0"),
                             ("build", True), ("repository", "../invalid")]:
            config = dict(self.config, **{field: value})
            path = self.root / "release.json"
            path.write_text(json.dumps(config))
            with self.subTest(field=field), self.assertRaises(ValueError):
                release.configuration(path)

    def test_bundle_versions_and_feed_share_one_configuration(self):
        bundle = self.root / "Goat Voice.app"
        for relative in ["Contents/Info.plist", "Contents/XPCServices/GoatVoiceSTT.xpc/Contents/Info.plist"]:
            path = bundle / relative
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(plistlib.dumps({"LSMinimumSystemVersion": "14.0"}))
        resources = bundle / "Contents/Resources"
        resources.mkdir()
        for name in ["LICENSE", "THIRD_PARTY_NOTICES.txt"]:
            (resources / name).write_text("fixture")
        release.configure_bundle(bundle, self.config)
        self.assertEqual(release.validate_bundle(bundle, self.config), "14.0")
        values = plistlib.loads((bundle / "Contents/Info.plist").read_bytes())
        self.assertFalse(values["SUEnableAutomaticChecks"])
        self.assertFalse(values["SUAutomaticallyUpdate"])
        self.assertEqual(values["SUPublicEDKey"], self.config["publicKey"])

    def test_missing_private_key_does_not_sign(self):
        import unittest.mock
        with unittest.mock.patch.dict("os.environ", {}, clear=True), self.assertRaises(ValueError):
            release.sign_release(self.root, Path("missing-signer"), Path("missing-verifier"), self.config)

class PublicationOrderingTests(unittest.TestCase):
    def setUp(self):
        from unittest.mock import patch
        self.patch = patch
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.directory = Path(self.temp.name)
        self.config = release.configuration()
        self.archive = self.directory / release.archive_name(self.config)
        self.archive.write_bytes(b"synthetic archive")
        (self.directory / "release-info.json").write_text(json.dumps({
            "version": self.config["version"], "build": self.config["build"], "commit": "source-commit",
        }))
        (self.directory / "appcast.xml").write_bytes(release.appcast(
            self.config, self.archive, base64.b64encode(bytes(64)).decode(), "14.0"))
        (self.directory / "SHA256SUMS").write_text("fixture")
        self.events = []
        self.existing = None
        self.tag_commit = "source-commit"

    def api(self, *arguments, payload=None, allow_missing=False):
        endpoint = arguments[1]
        if "/commits/v" in endpoint:
            return {"sha": self.tag_commit}
        if endpoint.endswith("/git/ref/heads/updates"):
            return None
        if "/releases/tags/" in endpoint:
            return self.existing
        if endpoint.endswith("/releases"):
            self.events.append("draft")
            return {"id": 1}
        if endpoint.endswith("/releases/1"):
            self.events.append("publish")
            return {"id": 1, "html_url": "https://example.com/release"}
        if endpoint.endswith("/git/trees"):
            self.events.append("feed-tree")
            return {"sha": "tree"}
        if endpoint.endswith("/git/commits"):
            return {"sha": "feed-commit"}
        if endpoint.endswith("/git/refs"):
            self.events.append("feed-published")
            return {}
        raise AssertionError(endpoint)

    def run_publication(self, fail_download=False):
        def verify(url, digest):
            self.events.append("verified-download")
            if fail_download:
                raise ValueError("Download unavailable")
        with self.patch.object(publisher, "gh", side_effect=self.api), \
             self.patch.object(publisher, "verify_download", side_effect=verify), \
             self.patch.object(publisher.subprocess, "run") as command, \
             self.patch("sys.argv", ["publish-release.py", str(self.directory)]):
            publisher.main()
            return command

    def test_feed_is_published_only_after_archive_download_verifies(self):
        self.run_publication()
        self.assertLess(self.events.index("publish"), self.events.index("verified-download"))
        self.assertLess(self.events.index("verified-download"), self.events.index("feed-published"))

    def test_failed_download_does_not_publish_feed(self):
        with self.assertRaises(ValueError):
            self.run_publication(fail_download=True)
        self.assertNotIn("feed-tree", self.events)
        self.assertNotIn("feed-published", self.events)

    def test_changed_tag_cannot_publish_a_different_build(self):
        self.tag_commit = "changed-commit"
        with self.assertRaises(ValueError):
            self.run_publication()
        self.assertEqual(self.events, [])

    def test_existing_public_release_is_not_overwritten_when_repairing_feed(self):
        self.existing = {"id": 1, "draft": False, "html_url": "https://example.com/release"}
        command = self.run_publication()
        command.assert_not_called()
        self.assertNotIn("draft", self.events)
        self.assertNotIn("publish", self.events)
        self.assertIn("feed-published", self.events)


if __name__ == "__main__":
    unittest.main()
