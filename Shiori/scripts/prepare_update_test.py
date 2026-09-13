#!/usr/bin/env python3
"""Build two isolated REAL Shiori apps for UI-driven Sparkle update testing.

No publishing, installation into /Applications, quarantine changes or game termination.
Run a loopback HTTP server in the printed feed directory, then launch A/Shiori.app.
"""
import argparse
import importlib.util
import json
import os
from pathlib import Path
import subprocess

spec = importlib.util.spec_from_file_location("release", Path(__file__).with_name("release.py"))
r = importlib.util.module_from_spec(spec)
spec.loader.exec_module(r)

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("directory", type=Path)
parser.add_argument("--port", type=int, default=18761)
args = parser.parse_args()
root = args.directory.resolve()
r.require(not root.exists(), "Use a new disposable test directory")
root.mkdir(parents=True)
feed_url = f"http://127.0.0.1:{args.port}/appcast.xml"
data = root / "isolated-user-data"
data.mkdir()
fixture = data / "prefixes/验收游戏/drive_c/save.dat"
fixture.parent.mkdir(parents=True)
fixture.write_text("Shiori update preservation fixture\n")
for name, version, build in (("A", "0.0.1", "1"), ("B", "0.0.2", "2")):
    env = dict(os.environ, DIST_DIR=str(root / name), APP_VERSION=version, BUILD_NUMBER=build,
               BUNDLE_ID="com.jojocys.shiori.update-test", SPARKLE_FEED_URL=feed_url, SHIORI_TEST_DATA_DIR=str(data))
    subprocess.run([str(r.ROOT / "scripts/build_release_app.sh")], env=env, check=True)
feed_dir = root / "feed"
feed_dir.mkdir()
archive = feed_dir / "Shiori-0.0.2.dmg"
notes = root / "test-notes.md"
notes.write_text("# 更新验收 B\n\n这是隔离测试版本，检查安装、替换、重启及数据保留。\n")
r.make_dmg(root / "B/Shiori.app", archive)
r.generate_feed(root / "B/Shiori.app", archive, feed_dir, test_mode=True,
                archive_url=f"http://127.0.0.1:{args.port}/{archive.name}", notes_path=notes)
r.verify(root / "B/Shiori.app", archive, feed_dir / "appcast.xml", test_mode=True,
         feed_url=feed_url, archive_url=f"http://127.0.0.1:{args.port}/{archive.name}")
(root / "evidence.json").write_text(json.dumps({"test_app": str(root / "A/Shiori.app"), "feed": feed_url,
    "archive_sha256": r.sha(archive), "save_fixture": str(fixture), "save_sha256_before": r.sha(fixture),
    "source_digest": r.source_digest(), "state": "ready-for-ui-test"}, indent=2))
print(f"Ready: serve {feed_dir} on 127.0.0.1:{args.port}; launch {root / 'A/Shiori.app'}")
