import base64
import importlib.util
import json
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch
import xml.etree.ElementTree as ET

spec = importlib.util.spec_from_file_location("release", Path(__file__).with_name("release.py"))
r = importlib.util.module_from_spec(spec)
spec.loader.exec_module(r)


class ReleaseTests(unittest.TestCase):
    def item(self, build="3", version="1.1.1"):
        return ET.fromstring(f'''<item xmlns:sparkle="{r.NS}"><sparkle:version>{build}</sparkle:version>
          <sparkle:shortVersionString>{version}</sparkle:shortVersionString>
          <enclosure url="{r.download_url(version)}" type="application/octet-stream" length="100" sparkle:edSignature="test"/></item>''')

    def testExactBuildSelectionIsIndependentOfOrder(self):
        root = ET.Element("rss"); channel = ET.SubElement(root, "channel")
        channel.extend([self.item("4", "1.1.2"), self.item()])
        self.assertEqual(r.target_item(root, "3").findtext(f"{{{r.NS}}}shortVersionString"), "1.1.1")
        channel.append(self.item())
        with self.assertRaises(ValueError): r.target_item(root, "3")

    def testLinkOnlyOrDeltaCannotPassAsDMGUpdate(self):
        for name in ("informationalUpdate", "deltas"):
            item = self.item(); ET.SubElement(item, f"{{{r.NS}}}{name}")
            with self.assertRaises(ValueError): r.check_item(item, "1.1.1", "3", r.download_url("1.1.1"))

    def testWrongVersionURLAndArchiveSizeAreRejected(self):
        for attribute, value in [("url", r.download_url("1.1.0")), ("length", "0"), ("length", str(r.MAX_SIZE)), ("length", "bad")]:
            item = self.item(); item.find("enclosure").set(attribute, value)
            with self.assertRaises(ValueError): r.check_item(item, "1.1.1", "3", r.download_url("1.1.1"))

    def testReleaseVersionsCannotInjectPathsOrCommands(self):
        for version in ("../1.1", "v1.1.1", "1.1.1;echo", "1.1"):
            with self.assertRaises(ValueError): r.version_fields({"CFBundleShortVersionString": version, "CFBundleVersion": "3"})
        for build in ("0", "-1", "1.2", "abc"):
            with self.assertRaises(ValueError): r.version_fields({"CFBundleShortVersionString": "1.1.1", "CFBundleVersion": build})

    def testHTMLAndEntitiesAreRejected(self):
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / "feed"
            for text in ("<html><body>404</body></html>", '<!DOCTYPE rss [<!ENTITY x "text">]><rss><channel/></rss>'):
                path.write_text(text)
                with self.assertRaises(ValueError): r.parse_feed(path)

    def testHTTPAllowedOnlyForExplicitLoopbackTesting(self):
        for url in ("http://github.com/a", "file:///tmp/app.dmg", "https://user:password@github.com/a"):
            with self.assertRaises(ValueError): r.validate_url(url, True)
        with self.assertRaises(ValueError): r.validate_url("http://127.0.0.1/app.dmg")
        r.validate_url("http://127.0.0.1/app.dmg", True)

    def testSignatureUsesPublicKeyAndActualFileBytes(self):
        # RFC 8032 test vector 1. No private key or publisher Keychain is involved.
        key = base64.b64encode(bytes.fromhex("d75a980182b10ab7d54bfed3c964073a0ee172f3daa62325af021a68f707511a")).decode()
        sig = base64.b64encode(bytes.fromhex("e5564300c360ac729086e2cc806e828a84877f1eb8e5d974d873e065224901555fb8821590a33bacc61e39701cf9b46bd25bf5f0595bbe24655141438e7a100b")).decode()
        with tempfile.TemporaryDirectory() as temporary:
            file = Path(temporary) / "data"; file.write_bytes(b"")
            r.verify_signature(file, key, sig)
            file.write_bytes(b"tampered")
            with self.assertRaises(Exception): r.verify_signature(file, key, sig)
            file.write_bytes(b"")
            wrong_key = base64.b64encode(bytes(32)).decode()
            with self.assertRaises(Exception): r.verify_signature(file, wrong_key, sig)

    def testRemoteFailurePreventsSuccessfulOnlineVerification(self):
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / "feed.xml"
            root = ET.Element("rss"); ET.SubElement(root, "channel").append(self.item())
            path.write_bytes(ET.tostring(root))
            with patch.object(r, "fetch", side_effect=OSError("offline")), self.assertRaises(OSError):
                r.online(path, "key", "3")

    def testReleaseOriginRequiresPreparedCommitAndOnlyExpectedAssets(self):
        expected = "a" * 40
        release = {
            "target_commitish": expected,
            "tag_name": "v1.1.1",
            "assets": [{"name": "Shiori-1.1.1.dmg"}],
        }
        commits = {expected: expected, "v1.1.1": expected}
        resolve = lambda ref, optional=False: commits.get(ref)
        allowed = {"Shiori-1.1.1.dmg", "Shiori-1.1.1.dmg.sha256.txt"}
        r.validate_release_origin(release, expected, allowed, resolve)

        for field, value in (("target_commitish", "b" * 40), ("tag_name", "v-wrong")):
            changed = dict(release, **{field: value})
            commits[value] = "b" * 40
            with self.assertRaises(ValueError):
                r.validate_release_origin(changed, expected, allowed, resolve)

        with self.assertRaises(ValueError):
            r.validate_release_origin(
                dict(release, assets=release["assets"] + [{"name": "Shiori.app.zip"}]),
                expected, allowed, resolve,
            )

    def testOptionalDraftTagAcceptsGitHubNoCommitResponse(self):
        missing = subprocess.CompletedProcess([], 1, stdout="", stderr="gh: No commit found for SHA: v0.2.1 (HTTP 422)\n")
        with patch.object(r.subprocess, "run", return_value=missing):
            self.assertIsNone(r.resolve_remote_commit("v0.2.1", optional=True))
            with self.assertRaises(ValueError):
                r.resolve_remote_commit("v0.2.1", optional=False)

    def testDraftReleaseIsFoundFromReleaseCollection(self):
        draft = {"tag_name": "v0.2.2", "draft": True}
        published = {"tag_name": "v0.2.1", "draft": False}
        self.assertIs(r.find_release([published, draft], "0.2.2"), draft)
        self.assertIsNone(r.find_release([published], "0.2.2"))
        with self.assertRaises(ValueError):
            r.find_release([draft, dict(draft)], "0.2.2")

    def testSameVisibleVersionCanReplaceAnOlderInternalBuild(self):
        root = ET.Element("rss"); channel = ET.SubElement(root, "channel")
        channel.extend([self.item("5", "0.2.3"), self.item("4", "0.2.2"), self.item("3", "0.2.1")])
        self.assertEqual(r.remove_items_for_short_version(root, "0.2.3"), 1)
        self.assertEqual(
            [item.findtext(f"{{{r.NS}}}version") for item in channel.findall("item")],
            ["4", "3"],
        )

    def testRecordedExternalInputsDetectFileAndTreeChanges(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            wine = root / "Wine.app"
            wine_info = wine / "Contents/Info.plist"
            wine_info.parent.mkdir(parents=True)
            import plistlib
            wine_info.write_bytes(plistlib.dumps({"CFBundleShortVersionString": "9.0", "CFBundleVersion": "1"}))
            runtime = wine / "Contents/MacOS/wine"
            runtime.parent.mkdir()
            runtime.write_bytes(b"wine-v1")
            xquartz = root / "XQuartz.pkg"
            xquartz.write_bytes(b"pkg-v1")
            inputs = root / "build-inputs.json"

            r.record_inputs(inputs, wine, xquartz, "")
            recorded = json.loads(inputs.read_text())
            self.assertEqual(recorded["wine"]["version"], "9.0")
            self.assertEqual(recorded["xquartz"]["sha256"], r.sha(xquartz))
            r.verify_inputs(inputs)

            runtime.write_bytes(b"wine-v2")
            with self.assertRaises(ValueError):
                r.verify_inputs(inputs)


if __name__ == "__main__": unittest.main()
