#!/usr/bin/env python3
"""DMG release pipeline. prepare is local; publish explicitly performs remote mutations."""
import argparse
import base64
import contextlib
import fcntl
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import shutil
import subprocess
import sys
import tempfile
import urllib.parse
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parents[1]
REPO_ROOT = ROOT.parent
REPOSITORY = "jojocys/Shiori"
FEED = "https://jojocys.github.io/Shiori/appcast.xml"
SPARKLE = ROOT / ".build/artifacts/sparkle/Sparkle"
NS = "http://www.andymatuschak.org/xml-namespaces/sparkle"
ET.register_namespace("sparkle", NS)
PUBLIC_KEY = ROOT / "config/sparkle_public_key.txt"
DIST = Path(os.environ.get("DIST_DIR", str(ROOT / "dist"))).resolve()
MAX_SIZE = 2 * 1024 ** 3


def require(condition, message):
    if not condition:
        raise ValueError(message)


def run(args, **kwargs):
    # Do not log argv: a caller may be using a private-key file path.
    return subprocess.run([str(a) for a in args], check=True, **kwargs)


def capture(args):
    return run(args, stdout=subprocess.PIPE, text=True).stdout.strip()


def sha(path):
    h = hashlib.sha256()
    with Path(path).open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            h.update(block)
    return h.hexdigest()


def source_digest():
    paths = [ROOT / "Package.swift", ROOT / "Package.resolved", ROOT / "version.json"]
    for directory in ("Sources", "scripts", "config", "Resources"):
        paths += [p for p in (ROOT / directory).rglob("*") if p.is_file() and p.suffix in (".swift", ".sh", ".py", ".json", ".txt", ".strings")]
    paths += [p for p in (ROOT / "assets").glob("*") if p.suffix.lower() in (".png", ".svg", ".jpg", ".jpeg")]
    version = json.loads((ROOT / "version.json").read_text())["version"]
    notes = REPO_ROOT / f"Shiori-{version}-变更说明.md"
    paths.append(notes)
    digest = hashlib.sha256()
    for path in sorted(paths):
        digest.update(str(path.relative_to(REPO_ROOT)).encode())
        digest.update(bytes.fromhex(sha(path)))
    return digest.hexdigest()


def tree_hash(path):
    path = Path(path)
    if path.is_file():
        return sha(path)
    require(path.is_dir(), f"Missing build input: {path}")
    digest = hashlib.sha256()
    for entry in sorted(path.rglob("*")):
        digest.update(str(entry.relative_to(path)).encode())
        digest.update(str(entry.lstat().st_mode & 0o7777).encode())
        if entry.is_symlink():
            digest.update(b"link:" + os.readlink(entry).encode())
        elif entry.is_file():
            digest.update(bytes.fromhex(sha(entry)))
        else:
            digest.update(b"directory")
    return digest.hexdigest()


def record_inputs(output, wine, xquartz, emulator):
    inputs = {}
    for name, source in (("wine", wine), ("xquartz", xquartz), ("emulator", emulator)):
        if source:
            path = Path(source).resolve()
            record = {"path": str(path), "sha256": tree_hash(path)}
            if path.suffix == ".app":
                info = metadata(path)
                record["version"] = info.get("CFBundleShortVersionString")
                record["build"] = info.get("CFBundleVersion")
            inputs[name] = record
    atomic_write(output, json.dumps(inputs, indent=2) + "\n")


def verify_inputs(path):
    for record in json.loads(Path(path).read_text()).values():
        require(tree_hash(record["path"]) == record["sha256"], "External build input changed during assembly")


def validate_release_origin(release, source_commit, allowed_assets, resolve_commit):
    require(resolve_commit(release["target_commitish"]) == source_commit, "Draft target does not identify prepared source commit")
    # An existing tag takes precedence over target_commitish in GitHub Releases.
    tag_commit = resolve_commit(release["tag_name"], optional=True)
    if tag_commit:
        require(tag_commit == source_commit, "Existing release tag points to different source")
    require({a["name"] for a in release["assets"]}.issubset(allowed_assets), "Release contains unexpected assets; refusing to publish multiple installation packages")


def resolve_remote_commit(ref, optional=False):
    result = subprocess.run(["gh", "api", f"repos/{REPOSITORY}/commits/{urllib.parse.quote(ref, safe='')}", "--jq", ".sha"], text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    if result.returncode and optional and "404" in result.stderr:
        return None
    require(result.returncode == 0, "Cannot resolve remote source commit/tag")
    return result.stdout.strip()


def atomic_write(path, content):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.NamedTemporaryFile(dir=path.parent, delete=False) as f:
        temporary = Path(f.name)
        f.write(content.encode() if isinstance(content, str) else content)
    try:
        os.replace(temporary, path)
    finally:
        temporary.unlink(missing_ok=True)


def metadata(app):
    return plistlib.loads((Path(app) / "Contents/Info.plist").read_bytes())


def version_fields(info):
    version, build = info["CFBundleShortVersionString"], str(info["CFBundleVersion"])
    require(re.fullmatch(r"\d+\.\d+\.\d+", version), "Version must be x.y.z")
    require(re.fullmatch(r"[1-9]\d*", build), "Build must be a positive integer")
    return version, build


def download_url(version):
    return f"https://github.com/{REPOSITORY}/releases/download/v{version}/Shiori-{version}.dmg"


def validate_url(url, test_mode=False):
    parsed = urllib.parse.urlparse(url)
    require(not parsed.username and not parsed.password and not parsed.fragment, "Invalid URL credentials/fragment")
    require(parsed.scheme == "https" or (test_mode and parsed.scheme == "http" and parsed.hostname in ("127.0.0.1", "localhost")), "HTTPS required")
    require(bool(parsed.hostname), "Missing URL hostname")


def fetch(url, path):
    validate_url(url)
    run(["curl", "--fail", "--location", "--silent", "--show-error", "--proto", "=https", "--proto-redir", "=https",
         "--connect-timeout", "20", "--max-time", "600", "--max-filesize", str(MAX_SIZE), "--output", path, url])


def verify_signature(path, key, signature):
    require(len(base64.b64decode(key, validate=True)) == 32, "Invalid public key")
    require(len(base64.b64decode(signature, validate=True)) == 64, "Invalid signature")
    if sys.platform == "darwin":
        cache = DIST / "tools"
        cache.mkdir(parents=True, exist_ok=True)
        source = ROOT / "scripts/verify_ed25519.swift"
        binary = cache / ("verify-ed25519-" + sha(source)[:12])
        if not binary.exists():
            run(["xcrun", "swiftc", "-module-cache-path", cache / "module-cache", source, "-o", binary])
        run([binary, key, signature, path])
    else:
        from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PublicKey
        Ed25519PublicKey.from_public_bytes(base64.b64decode(key)).verify(base64.b64decode(signature), Path(path).read_bytes())


def parse_feed(path):
    content = Path(path).read_bytes()
    require(len(content) < 5 * 1024 * 1024, "Feed too large")
    require(b"<!DOCTYPE" not in content.upper() and b"<!ENTITY" not in content.upper(), "DTD/entities are not allowed")
    root = ET.fromstring(content)
    require(root.tag == "rss" and root.find("channel") is not None, "Expected RSS update feed, not an HTML error page")
    return root


def target_item(feed, build):
    items = [i for i in feed.findall("./channel/item") if i.findtext(f"{{{NS}}}version") == str(build)]
    require(len(items) == 1, "Expected exactly one item for target build")
    return items[0]


def check_item(item, version, build, url):
    require(item.findtext(f"{{{NS}}}version") == str(build), "Feed build mismatch")
    require(item.findtext(f"{{{NS}}}shortVersionString") == version, "Feed version mismatch")
    require(item.find(f"{{{NS}}}informationalUpdate") is None, "Informational update cannot install in app")
    require(item.find(f"{{{NS}}}deltas") is None, "Delta updates are disabled in this release")
    enclosures = item.findall("enclosure")
    require(len(enclosures) == 1, "Expected one full DMG enclosure")
    enc = enclosures[0]
    require(enc.get("url") == url and urllib.parse.urlparse(url).path.endswith(".dmg"), "Unexpected DMG URL")
    require(enc.get("type") == "application/octet-stream", "Unexpected enclosure type")
    require(0 < int(enc.get("length", "0")) < MAX_SIZE, "Invalid archive length")
    require(bool(enc.get(f"{{{NS}}}edSignature")), "Missing Ed25519 signature")
    return enc


def sign_app(app, identity):
    app = Path(app).resolve()
    require(app.is_dir() and app.suffix == ".app", "Expected an existing App")
    macho_magic = {b"\xfe\xed\xfa\xce", b"\xce\xfa\xed\xfe", b"\xfe\xed\xfa\xcf", b"\xcf\xfa\xed\xfe", b"\xca\xfe\xba\xbe", b"\xbe\xba\xfe\xca"}
    code = []
    for path in app.rglob("*"):
        if path.is_symlink():
            continue
        if path.is_dir() and path.suffix in (".app", ".framework", ".xpc", ".bundle"):
            # Data-only bundles without executables are not code signing targets.
            if path.suffix != ".bundle" or (path / "Contents/MacOS").is_dir():
                code.append(path)
        elif path.is_file():
            with path.open("rb") as f:
                if f.read(4) in macho_magic:
                    code.append(path)
    for path in sorted(code, key=lambda p: len(p.parts), reverse=True) + [app]:
        args = ["codesign", "--force", "--sign", identity, "--preserve-metadata=entitlements"]
        args += ["--timestamp=none"] if identity == "-" else ["--timestamp", "--options", "runtime"]
        run(args + [path], stdout=subprocess.DEVNULL)
    run(["codesign", "--verify", "--deep", "--strict", app])


@contextlib.contextmanager
def mounted(dmg):
    result = run(["hdiutil", "attach", "-readonly", "-nobrowse", "-plist", dmg], stdout=subprocess.PIPE)
    volumes = [e["mount-point"] for e in plistlib.loads(result.stdout)["system-entities"] if "mount-point" in e]
    try:
        require(len(volumes) == 1, "Expected exactly one DMG volume")
        yield Path(volumes[0])
    finally:
        for volume in volumes:
            run(["hdiutil", "detach", volume], stdout=subprocess.DEVNULL)


def make_dmg(app, destination):
    app, destination = Path(app).resolve(), Path(destination).resolve()
    version_fields(metadata(app))
    require(not destination.exists(), "DMG already exists; use a fresh output directory/version, never overwrite released bytes")
    destination.parent.mkdir(parents=True, exist_ok=True)
    run(["codesign", "--verify", "--deep", "--strict", app])
    with tempfile.TemporaryDirectory(prefix="shiori-dmg-", dir=destination.parent) as temporary:
        folder = Path(temporary) / "volume"
        folder.mkdir()
        run(["ditto", app, folder / "Shiori.app"])
        (folder / "Applications").symlink_to("/Applications")
        temporary_dmg = Path(temporary) / "package.dmg"
        run(["hdiutil", "create", "-volname", "栞 Shiori", "-srcfolder", folder, "-format", "UDZO", temporary_dmg])
        with mounted(temporary_dmg) as volume:
            run(["codesign", "--verify", "--deep", "--strict", volume / "Shiori.app"])
        os.replace(temporary_dmg, destination)
    atomic_write(str(destination) + ".sha256.txt", f"{sha(destination)}  {destination.name}\n")
    print(f"DMG ready: {destination}")


def generate_feed(app, dmg, stage, history=None, test_mode=False, archive_url=None, notes_path=None):
    app, dmg, stage = Path(app), Path(dmg), Path(stage)
    info = metadata(app)
    version, build = version_fields(info)
    require(dmg.name == f"Shiori-{version}.dmg", "Versioned DMG filename mismatch")
    stage.mkdir(parents=True, exist_ok=True)
    # A fresh directory prevents old ZIP/delta artifacts from becoming new feed entries.
    with tempfile.TemporaryDirectory(prefix="appcast-", dir=stage) as temporary:
        workspace = Path(temporary)
        shutil.copy2(dmg, workspace / dmg.name)
        notes = Path(notes_path) if notes_path else REPO_ROOT / f"Shiori-{version}-变更说明.md"
        require(notes.is_file(), f"Missing release notes: {notes.name}")
        shutil.copy2(notes, workspace / f"Shiori-{version}.md")
        if history:
            previous = parse_feed(history)
            require(all(int(i.findtext(f"{{{NS}}}version")) < int(build) for i in previous.findall("./channel/item")), "Build must exceed every previous feed build")
            shutil.copy2(history, workspace / "appcast.xml")
        signing = ["--account", os.environ.get("SPARKLE_ACCOUNT", "shiori-jojocys")]
        if os.environ.get("SPARKLE_PRIVATE_KEY_FILE"):
            signing = ["--ed-key-file", os.environ["SPARKLE_PRIVATE_KEY_FILE"]]
        url = archive_url or download_url(version)
        validate_url(url, test_mode)
        run([SPARKLE / "bin/generate_appcast", *signing, "--download-url-prefix", url.rsplit("/", 1)[0] + "/",
             "--embed-release-notes", "--versions", build, "--maximum-versions", "3", "--maximum-deltas", "0", workspace])
        feed_path = workspace / "appcast.xml"
        feed = parse_feed(feed_path)
        enc = check_item(target_item(feed, build), version, build, url)
        require(int(enc.get("length")) == dmg.stat().st_size, "DMG length mismatch")
        verify_signature(dmg, info["SUPublicEDKey"], enc.get(f"{{{NS}}}edSignature"))
        if history:
            old_urls = {i.findtext(f"{{{NS}}}version"): i.find("enclosure").get("url") for i in parse_feed(history).findall("./channel/item") if i.find("enclosure") is not None}
            for i in feed.findall("./channel/item"):
                b = i.findtext(f"{{{NS}}}version")
                if b in old_urls:
                    require(i.find("enclosure").get("url") == old_urls[b], "Historical archive URL changed")
        atomic_write(stage / "appcast.xml", feed_path.read_bytes())
    print(f"Staged feed: {stage / 'appcast.xml'} (production feed unchanged)")


def verify(app, dmg, feed_path, test_mode=False, feed_url=FEED, archive_url=None):
    app, dmg = Path(app), Path(dmg)
    info = metadata(app)
    version, build = version_fields(info)
    expected_id = "com.jojocys.shiori.update-test" if test_mode else "com.jojocys.shiori"
    require(info["CFBundleIdentifier"] == expected_id, "Unexpected bundle ID/test mode")
    require(app.name == "Shiori.app" and info["CFBundleExecutable"] == "Shiori", "App name/executable mismatch")
    require(info.get("SUFeedURL") == feed_url, "Feed URL mismatch")
    validate_url(feed_url, test_mode)
    require(info["SUPublicEDKey"] == PUBLIC_KEY.read_text().strip(), "App key differs from repository public key")
    for key, expected in {"SUEnableAutomaticChecks": True, "SUAutomaticallyUpdate": False, "SUAllowsAutomaticUpdates": False, "SUVerifyUpdateBeforeExtraction": True}.items():
        require(info.get(key) is expected, f"Incorrect {key}")
    require(info.get("SUScheduledCheckInterval") == 86400, "Unexpected check interval")
    require(info.get("LSMinimumSystemVersion") == "13.0", "Unsupported minimum OS")
    framework = app / "Contents/Frameworks/Sparkle.framework"
    for relative in ("Versions/B/Autoupdate", "Versions/B/Updater.app/Contents/MacOS/Updater", "Versions/B/XPCServices/Installer.xpc/Contents/MacOS/Installer"):
        require(os.access(framework / relative, os.X_OK), f"Missing Sparkle helper: {relative}")
    binary = app / "Contents/MacOS/Shiori"
    require(capture(["lipo", "-archs", binary]) == "arm64", "Only arm64 is currently validated")
    require("Sparkle.framework" in capture(["otool", "-L", binary]), "Sparkle linkage missing")
    require("@executable_path/../Frameworks" in capture(["otool", "-l", binary]), "Framework runpath missing")
    run(["codesign", "--verify", "--deep", "--strict", app])
    item = target_item(parse_feed(feed_path), build)
    enc = check_item(item, version, build, archive_url or download_url(version))
    require(item.findtext(f"{{{NS}}}hardwareRequirements") == "arm64", "Feed architecture mismatch")
    require(item.findtext(f"{{{NS}}}minimumSystemVersion") in ("13.0", "13.0.0"), "Feed minimum OS mismatch")
    require(dmg.name == f"Shiori-{version}.dmg" and dmg.stat().st_size == int(enc.get("length")), "DMG name/length mismatch")
    verify_signature(dmg, info["SUPublicEDKey"], enc.get(f"{{{NS}}}edSignature"))
    with mounted(dmg) as volume:
        require([p.name for p in volume.glob("*.app")] == ["Shiori.app"], "DMG needs exactly one root App")
        require((volume / "Applications").is_symlink() and os.readlink(volume / "Applications") == "/Applications", "Applications link mismatch")
        contained = volume / "Shiori.app"
        require(metadata(contained) == info, "DMG App metadata differs from verified build")
        run(["codesign", "--verify", "--deep", "--strict", contained])
        # CodeResources seals nested content; also compare the signed main executable.
        for relative in ("Contents/_CodeSignature/CodeResources", "Contents/MacOS/Shiori"):
            require(sha(contained / relative) == sha(app / relative), "DMG contains a different signed App")
    print(f"Local verification passed: {version} ({build})")


def online(feed_path, key, expected_build=None, public_feed=False):
    with tempfile.TemporaryDirectory(prefix="shiori-online-") as temporary:
        if public_feed:
            local = Path(temporary) / "appcast.xml"
            fetch(FEED, local)
            require(local.read_bytes() == Path(feed_path).read_bytes(), "Public feed does not match staged feed (deployment/cache pending)")
        feed = parse_feed(feed_path)
        items = feed.findall("./channel/item")
        require(items, "No release items")
        builds = [int(i.findtext(f"{{{NS}}}version")) for i in items]
        require(len(builds) == len(set(builds)), "Duplicate feed builds")
        if expected_build:
            require(max(builds) == int(expected_build), "Target build is not newest")
        newest = target_item(feed, max(builds))
        version = newest.findtext(f"{{{NS}}}shortVersionString")
        version_fields({"CFBundleShortVersionString": version, "CFBundleVersion": max(builds)})
        check_item(newest, version, max(builds), download_url(version))
        for index, item in enumerate(items):
            enc = item.find("enclosure")
            require(enc is not None, "Feed cannot contain link-only updates")
            url = enc.get("url", "")
            # Historical ZIPs can remain; all URLs must stay in this repository's Releases.
            require(url.startswith(f"https://github.com/{REPOSITORY}/releases/download/"), "Unexpected asset host/repository")
            archive = Path(temporary) / f"asset-{index}"
            fetch(url, archive)
            require(archive.stat().st_size == int(enc.get("length", "0")), "Remote asset length mismatch")
            verify_signature(archive, key, enc.get(f"{{{NS}}}edSignature", ""))
    print("Anonymous remote asset verification passed")


def check_production_floor(feed):
    incoming = parse_feed(feed)
    new_build = max(int(i.findtext(f"{{{NS}}}version")) for i in incoming.findall("./channel/item"))
    with tempfile.TemporaryDirectory() as temp:
        previous = Path(temp) / "feed.xml"
        status = capture(["curl", "-sSL", "--proto", "=https", "--proto-redir", "=https", "--max-time", "30", "-o", previous, "-w", "%{http_code}", FEED])
        require(status in ("200", "404"), "Cannot determine current production feed")
        if status == "200":
            builds = [int(i.findtext(f"{{{NS}}}version")) for i in parse_feed(previous).findall("./channel/item")]
            require(not builds or max(builds) <= new_build, "Refusing to replace a newer production feed")
            if builds and max(builds) == new_build:
                require(previous.read_bytes() == Path(feed).read_bytes(), "Same build has a different published feed")


def prepare():
    manifest = json.loads((ROOT / "version.json").read_text())
    version, build = version_fields({"CFBundleShortVersionString": manifest["version"], "CFBundleVersion": manifest["build"]})
    stage = DIST / "releases" / version
    require(not stage.exists(), "Prepared version exists; preserve it or select a new version/output directory")
    stage.mkdir(parents=True)
    sources = source_digest()
    env = dict(os.environ, DIST_DIR=str(stage), APP_VERSION=version, BUILD_NUMBER=build)
    run([ROOT / "scripts/build_release_app.sh"], env=env)
    app, dmg = stage / "Shiori.app", stage / f"Shiori-{version}.dmg"
    make_dmg(app, dmg)
    history = stage / "previous-appcast.xml"
    # Read-only preflight. 404 for a not-yet-created feed must be explicitly acknowledged.
    if os.environ.get("SHIORI_FIRST_FEED") == "1":
        history = None
    else:
        fetch(FEED, history)
    generate_feed(app, dmg, stage, history)
    verify(app, dmg, stage / "appcast.xml")
    require(source_digest() == sources, "Source changed during preparation; rebuild from a stable source snapshot")
    state = {"version": version, "build": build, "dmg": dmg.name, "sha256": sha(dmg), "feed_sha256": sha(stage / "appcast.xml"),
             "source_commit": capture(["git", "-C", REPO_ROOT, "rev-parse", "HEAD"]),
             "source_status": capture(["git", "-C", REPO_ROOT, "status", "--short"]), "source_digest": sources, "phase": "prepared"}
    notes = REPO_ROOT / f"Shiori-{version}-变更说明.md"
    shutil.copy2(notes, stage / "release-notes.md")
    state["notes_sha256"] = sha(notes)
    state["generated_icon_sha256"] = sha(app / "Contents/Resources/Shiori.icns")
    state["build_inputs"] = json.loads((stage / "build-inputs.json").read_text())
    atomic_write(stage / "release.json", json.dumps(state, indent=2, ensure_ascii=False) + "\n")
    print(f"Prepared only. Review {stage / 'release.json'} before publish.")


def publish(stage):
    stage = Path(stage).resolve()
    state = json.loads((stage / "release.json").read_text())
    version, build = state["version"], state["build"]
    require(source_digest() == state["source_digest"], "Implementation changed since prepare; rebuild before publishing")
    require(not capture(["git", "-C", REPO_ROOT, "status", "--porcelain", "--", "Shiori/Sources", "Shiori/scripts", "Shiori/Resources", "Shiori/Package.swift", "Shiori/Package.resolved", "Shiori/config", "Shiori/version.json", "Shiori/assets", f"Shiori-{version}-变更说明.md"]), "Commit the reviewed implementation before publishing so the release tag identifies its source")
    require(capture(["git", "-C", REPO_ROOT, "rev-parse", "HEAD"]) == state["source_commit"], "Source commit changed; prepare from the intended release commit")
    app, dmg, feed = stage / "Shiori.app", stage / state["dmg"], stage / "appcast.xml"
    require(sha(stage / "release-notes.md") == state["notes_sha256"], "Prepared release notes changed")
    require(sha(ROOT / "assets/Shiori.icns") == state["generated_icon_sha256"], "Generated icon changed since preparation")
    require(sha(app / "Contents/Resources/Shiori.icns") == state["generated_icon_sha256"], "App icon differs from prepared input")
    require(sha(dmg) == state["sha256"] and sha(feed) == state["feed_sha256"], "Prepared files changed; prepare again")
    verify(app, dmg, feed)
    check_production_floor(feed)
    def phase(value):
        state["phase"] = value
        atomic_write(stage / "release.json", json.dumps(state, indent=2, ensure_ascii=False) + "\n")
    releases = json.loads(capture(["gh", "api", f"repos/{REPOSITORY}/releases?per_page=100"]))
    existing = next((r for r in releases if r["tag_name"] == "v" + version), None)
    for release in releases:
        tag = release["tag_name"].removeprefix("v")
        if re.fullmatch(r"\d+\.\d+\.\d+", tag) and tag != version:
            require(tuple(map(int, tag.split("."))) < tuple(map(int, version.split("."))), "A newer Release already exists")
    if not existing:
        notes = stage / "release-notes.md"
        run(["gh", "release", "create", "v" + version, "--repo", REPOSITORY, "--draft", "--title", "Shiori " + version,
             "--notes-file", notes, "--target", state["source_commit"]])
        existing = json.loads(capture(["gh", "api", f"repos/{REPOSITORY}/releases/tags/v{version}"]))
    elif existing["draft"]:
        # A maintainer may have prepared a placeholder draft before the signed bytes exist.
        # Keep that draft, but make its review text match the exact prepared candidate.
        notes_body = (stage / "release-notes.md").read_text()
        run(["gh", "api", "--method", "PATCH", f"repos/{REPOSITORY}/releases/{existing['id']}",
             "-f", "tag_name=v" + version, "-f", "name=Shiori " + version,
             "-f", "body=" + notes_body, "-f", "target_commitish=" + state["source_commit"],
             "-F", "draft=true"])
        releases = json.loads(capture(["gh", "api", f"repos/{REPOSITORY}/releases?per_page=100"]))
        existing = next(r for r in releases if r["tag_name"] == "v" + version)
    validate_release_origin(existing, state["source_commit"], {dmg.name, dmg.name + ".sha256.txt"}, resolve_remote_commit)
    # Always reconcile the local record with the remote state before attempting a retry.
    phase("draft-found" if existing["draft"] else "release-published")
    for asset in (dmg, Path(str(dmg) + ".sha256.txt")):
        remote = next((a for a in existing["assets"] if a["name"] == asset.name), None)
        if remote:
            with tempfile.TemporaryDirectory() as temp:
                output = Path(temp) / asset.name
                with output.open("wb") as stream:
                    run(["gh", "api", "-H", "Accept: application/octet-stream", f"repos/{REPOSITORY}/releases/assets/{remote['id']}"], stdout=stream)
                if sha(output) != sha(asset):
                    require(existing["draft"], "Published asset differs; refusing overwrite")
                    run(["gh", "api", "--method", "DELETE", f"repos/{REPOSITORY}/releases/assets/{remote['id']}"])
                    run(["gh", "release", "upload", "v" + version, asset, "--repo", REPOSITORY])
        else:
            require(existing["draft"], "Published release missing expected asset; refusing mutation")
            run(["gh", "release", "upload", "v" + version, asset, "--repo", REPOSITORY])
    phase("draft-assets-uploaded" if existing["draft"] else "release-published")
    if existing["draft"]:
        run(["gh", "api", "--method", "PATCH", f"repos/{REPOSITORY}/releases/{existing['id']}", "-F", "draft=false"])
        phase("release-published")
    online(feed, metadata(app)["SUPublicEDKey"], build)
    phase("assets-verified")
    # Protect against promoting a stale build, even on a retry of an older publication.
    check_production_floor(feed)
    atomic_write(REPO_ROOT / "docs/appcast.xml", feed.read_bytes())
    phase("assets-published-feed-ready")
    print("Assets published and verified. Production feed prepared locally; commit/push and successful Pages deployment are still required.")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="command", required=True)
    p = sub.add_parser("sign-app"); p.add_argument("app", type=Path); p.add_argument("--identity", default="-")
    p = sub.add_parser("record-inputs"); p.add_argument("output", type=Path); p.add_argument("wine"); p.add_argument("xquartz"); p.add_argument("emulator")
    p = sub.add_parser("verify-inputs"); p.add_argument("inputs", type=Path)
    p = sub.add_parser("dmg"); p.add_argument("--app", type=Path, default=DIST / "Shiori.app"); p.add_argument("--output", type=Path)
    for name in ("feed", "verify"):
        p = sub.add_parser(name)
        p.add_argument("--app", type=Path, default=DIST / "Shiori.app")
        p.add_argument("--dmg", type=Path)
        p.add_argument("--stage", type=Path, default=DIST / "dmg-updates")
        p.add_argument("--test-mode", action="store_true")
        p.add_argument("--archive-url")
        p.add_argument("--feed-url", default=FEED)
        p.add_argument("--history", type=Path)
        p.add_argument("--notes", type=Path)
    sub.add_parser("prepare")
    p = sub.add_parser("publish"); p.add_argument("stage", type=Path)
    p = sub.add_parser("verify-online"); p.add_argument("feed", type=Path); p.add_argument("--public-feed", action="store_true"); p.add_argument("--promotion", action="store_true"); p.add_argument("--build"); p.add_argument("--key-file", type=Path, default=PUBLIC_KEY)
    args = parser.parse_args()
    if args.command == "sign-app": sign_app(args.app, args.identity)
    elif args.command == "record-inputs": record_inputs(args.output, args.wine, args.xquartz, args.emulator)
    elif args.command == "verify-inputs": verify_inputs(args.inputs)
    elif args.command == "dmg":
        version, _ = version_fields(metadata(args.app)); make_dmg(args.app, args.output or DIST / f"Shiori-{version}.dmg")
    elif args.command in ("feed", "verify"):
        version, _ = version_fields(metadata(args.app)); dmg = args.dmg or DIST / f"Shiori-{version}.dmg"
        if args.command == "feed": generate_feed(args.app, dmg, args.stage, args.history, args.test_mode, args.archive_url, args.notes)
        else: verify(args.app, dmg, args.stage / "appcast.xml", args.test_mode, args.feed_url, args.archive_url)
    elif args.command == "prepare": prepare()
    elif args.command == "publish":
        DIST.mkdir(parents=True, exist_ok=True)
        with (DIST / ".publish.lock").open("w") as lock:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            publish(args.stage)
    elif args.command == "verify-online":
        online(args.feed, args.key_file.read_text().strip(), args.build, args.public_feed)
        if args.promotion: check_production_floor(args.feed)


if __name__ == "__main__":
    try:
        main()
    except (ValueError, OSError, subprocess.CalledProcessError, ET.ParseError) as error:
        print(f"Release stopped: {error}", file=sys.stderr)
        sys.exit(1)
