#!/usr/bin/env python3
"""검토한 이 프로젝트 정리 목록만 적용한다. 앱은 휴지통, 설정 원본은 결과 폴더에 보존한다."""
import argparse
import datetime
import hashlib
import json
import os
import pathlib
import plistlib
import re
import shutil
import subprocess
import uuid

PRODUCT = "com.sharknia.ClaudeSessionWarmer"
APP_IDS = {PRODUCT, PRODUCT + ".UpdateTestDriver", PRODUCT + ".UpdateVerification"}
LSREGISTER = "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
ROOT = pathlib.Path(__file__).resolve().parent.parent
COMMON = pathlib.Path(subprocess.check_output(["git", "rev-parse", "--path-format=absolute", "--git-common-dir"], cwd=ROOT, text=True).strip()).parent


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def processes():
    rows = subprocess.check_output(["ps", "-ww", "-axo", "pid=,comm="], text=True).splitlines()
    return [line.strip().split(None, 1)[1] for line in rows if len(line.strip().split(None, 1)) == 2]


def registry():
    text = subprocess.check_output([LSREGISTER, "-dump"], text=True)
    result = {}
    for block in re.split(r"\n-{30,}\n", text):
        path = re.search(r"^path:\s+(.+?) \(0x[0-9a-f]+\)$", block, re.M)
        identity = re.search(r"^identifier:\s+(\S+)", block, re.M)
        if path and identity:
            result[path[1]] = identity[1]
    return result


def app_identity(entry):
    path = pathlib.Path(entry["path"])
    info_file = path / "Contents/Info.plist"
    info = plistlib.loads(info_file.read_bytes())
    executable = path / "Contents/MacOS" / info["CFBundleExecutable"]
    assert info["CFBundleIdentifier"] == entry["bundleID"] in APP_IDS
    assert digest(info_file) == entry["infoSHA256"] and digest(executable) == entry["executableSHA256"]
    assert any(path.is_relative_to(root / area) for root in (ROOT, COMMON) for area in ("dist", ".build"))
    assert not path.is_symlink()
    assert not any(value.startswith(str(path) + "/") for value in processes()), "실행 중인 앱은 이동할 수 없음"
    return path


def preference_identity(entry):
    path = pathlib.Path(entry["path"])
    assert path.parent == pathlib.Path.home() / "Library/Preferences"
    assert path.name == entry["domain"] + ".plist"
    prefix = "ClaudeSessionWarmer.SleepProbe."
    assert entry["domain"].startswith(prefix)
    uuid.UUID(entry["domain"][len(prefix):])
    assert not path.is_symlink() and path.stat().st_uid == os.getuid() == entry["uid"]
    assert plistlib.loads(path.read_bytes()) == {} and digest(path) == entry["sha256"]
    return path


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("manifest", type=pathlib.Path)
    parser.add_argument("--apply", action="store_true")
    args = parser.parse_args()
    manifest = json.loads(args.manifest.read_text())
    for entry in manifest["apps"]:
        app_identity(entry)
    for entry in manifest["preferences"]:
        preference_identity(entry)
    live = processes()
    assert not any("ClaudeSessionWarmerTests" in path or path.endswith("/xctest") for path in live), "테스트 종료 후 정리해야 함"
    registered = registry()
    app_paths = [entry["path"] for entry in manifest["apps"]]
    for entry in manifest["unregister"]:
        path = entry["path"]
        assert registered.get(path) == entry["bundleID"], "등록 목록이 바뀌었으므로 다시 검토해야 함"
        owned_child = any(path == parent or path.startswith(parent + "/") for parent in app_paths)
        absent_product = not pathlib.Path(path).exists() and entry["bundleID"] == PRODUCT
        assert owned_child or absent_product
        assert path != "/Applications/ClaudeSessionWarmer.app"
    if not args.apply:
        print("검증 완료: --apply로 검토한 목록만 적용할 수 있습니다.")
        return

    result_dir = args.manifest.parent / ("recovery-" + datetime.datetime.now().strftime("%Y%m%d-%H%M%S"))
    result_dir.mkdir(mode=0o700)
    shutil.copy2(args.manifest, result_dir / "manifest.json")
    results = []

    def record(value):
        results.append(value)
        (result_dir / "results.json").write_text(json.dumps(results, ensure_ascii=False, indent=2))

    # 남은 빈 파일까지 추적할 수 있도록 defaults 삭제 전에 원본을 보존한다.
    for entry in manifest["preferences"]:
        path = preference_identity(entry)
        shutil.copy2(path, result_dir / path.name)
        completed = subprocess.run(["defaults", "delete", entry["domain"]], capture_output=True, text=True)
        if path.exists():
            preference_identity(entry)
            destination = pathlib.Path.home() / ".Trash" / (str(uuid.uuid4()) + "-" + path.name)
            shutil.move(str(path), str(destination))
        record({"kind": "preferences", "domain": entry["domain"], "defaultsExit": completed.returncode,
                "remaining": path.exists(), "backup": str(result_dir / path.name)})

    for entry in sorted(manifest["unregister"], key=lambda entry: len(entry["path"]), reverse=True):
        completed = subprocess.run([LSREGISTER, "-u", entry["path"]], capture_output=True, text=True)
        record({"kind": "unregister", **entry, "exit": completed.returncode, "output": completed.stdout + completed.stderr})

    for entry in manifest["apps"]:
        path = app_identity(entry)
        destination = pathlib.Path.home() / ".Trash" / (path.stem + "-" + entry["version"] + "-" + str(uuid.uuid4()) + ".app")
        shutil.move(str(path), str(destination))
        record({"kind": "application", "from": str(path), "to": str(destination)})

    after = registry()
    remaining = [entry for entry in manifest["unregister"] if entry["path"] in after]
    record({"kind": "verification", "remainingRegisteredPaths": remaining})
    print(json.dumps({"resultDirectory": str(result_dir), "movedApps": len(manifest["apps"]),
                      "cleanedPreferences": len(manifest["preferences"]), "remainingRegisteredPaths": remaining}, ensure_ascii=False))


if __name__ == "__main__":
    main()
