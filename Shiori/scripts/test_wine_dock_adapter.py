#!/usr/bin/env python3
"""Test per-prefix Dock ownership and exact EXE icons without any UI actions."""
import base64
import json
import os
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
with tempfile.TemporaryDirectory(prefix="shiori-wine-dock-") as temp:
    temp = Path(temp)
    probe = temp / "probe"
    subprocess.run(["clang", "-fobjc-arc", "-framework", "AppKit",
                    str(ROOT / "Tests/Native/WineDockProbe.m"), "-o", str(probe)], check=True)
    image = temp / "icon.png"
    image.write_bytes(base64.b64decode("iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aKqkAAAAASUVORK5CYII="))
    config = temp / "icons.json"
    game = "c:/program files (x86)/steam/steamapps/common/test/game.exe"
    document = {"icons": {game: str(image)}, "steamRoots": ["c:/program files (x86)/steam/"],
                "steamLockPath": str(temp / "steam.lock")}
    config.write_text(json.dumps(document))
    env = dict(os.environ, SHIORI_WINE_DOCK_ICONS=str(config))
    steam = r"C:\Program Files (x86)\Steam\Steam.exe"
    helper = r"C:\Program Files (x86)\Steam\bin\cef\cef.win64\steamwebhelper.exe"
    def check(command, policy, icon=False, environment=env, cwd=None):
        result = json.loads(subprocess.check_output([str(probe), command], env=environment, cwd=cwd))
        assert result["policy"] == policy and result["gameIcon"] == icon, (command, result)
        return result
    owner = subprocess.Popen([str(probe), steam, "3"], env=env, stdout=subprocess.PIPE, text=True)
    try:
        assert json.loads(owner.stdout.readline())["policy"] == 0
        check(helper, 1)  # Only one client/helper entry per prefix.
        check(r"C:\Program Files (x86)\Steam\gameoverlayui.exe", 1)
        check(r"C:\Program Files (x86)\Steam\steamapps\common\test\Game.EXE", 0, True)
        check(r"C:\Other Steam\Steam.exe", 0)
        check(helper + " -steampath=" + game, 1)  # Child arguments never become game identity.
        other = temp / "other.json"
        other.write_text(json.dumps(dict(document, steamLockPath=str(temp / "other.lock"))))
        check(steam, 0, environment=dict(env, SHIORI_WINE_DOCK_ICONS=str(other)))
    finally:
        owner.wait(timeout=5)
    check(helper, 0)  # Ownership is released automatically on exit.
    check(game, 0, True)
    check(steam, 0, environment={k: v for k, v in env.items() if k != "SHIORI_WINE_DOCK_ICONS"})
    document["steamIconPath"] = str(image)
    document["icons"][str((temp / "relative.exe").resolve()).lower()] = str(image)
    config.write_text(json.dumps(document))
    check(helper, 0, True)  # Helper uses Steam's icon, never a game's cover.
    check("relative.exe", 0, True, cwd=temp)
    invalid = temp / "invalid.json"
    invalid.write_text('{"icons":[]}')
    check(game, 0, environment=dict(env, SHIORI_WINE_DOCK_ICONS=str(invalid)))
    check("--truncated", 0)
    print("Native Wine Dock: 14 headless scenarios passed; no windows or Dock entries created.")
