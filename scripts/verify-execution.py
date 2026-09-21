#!/usr/bin/env python3
"""운영 앱을 실행하지 않고 실제 OS 프로세스 잠금·종료·구버전 탐지를 검증한다."""
import pathlib
import plistlib
import shutil
import subprocess
import tempfile
import select
import time

ROOT = pathlib.Path(__file__).resolve().parent.parent
with tempfile.TemporaryDirectory(prefix="ClaudeSessionWarmerTests-Execution-") as temporary:
    work = pathlib.Path(temporary).resolve()
    executable = work / "probe"
    subprocess.run(["swiftc", "-parse-as-library", "-swift-version", "6",
                    str(ROOT / "Sources/ClaudeSessionWarmer/ExecutionOwnership.swift"),
                    str(ROOT / "scripts/VerifyExecution.swift"), "-o", str(executable)], check=True)
    processes = []

    def start(binary, directory, *arguments):
        process = subprocess.Popen([str(binary), str(directory), *arguments], stdin=subprocess.PIPE,
                                   stdout=subprocess.PIPE, text=True)
        processes.append(process)
        return process

    def line(process):
        assert select.select([process.stdout], [], [], 5)[0], "프로세스 시작 시간 초과"
        return process.stdout.readline().strip()

    try:
        first = start(executable, work / "state")
        assert line(first) == "owner"
        # 다른 경로의 실행 파일도 같은 잠금 파일을 사용한다.
        copy = work / "copy"
        shutil.copy2(executable, copy)
        second = start(copy, work / "state")
        assert second.communicate(timeout=5)[0].strip() == "blocked"
        assert second.returncode == 2
        first.kill()
        first.wait(timeout=5)
        assert (work / "state/execution.lock").exists()
        replacement = start(copy, work / "state")
        assert line(replacement) == "owner"
        replacement.communicate("\n", timeout=5)
        assert replacement.returncode == 0

        for _ in range(10):
            pair = [start(executable, work / "state"), start(copy, work / "state")]
            outcomes = [line(process) for process in pair]
            assert sorted(outcomes) == ["blocked", "owner"]
            for process in pair:
                process.communicate("\n", timeout=5)

        inherited = start(executable, work / "state", "exec")
        assert line(inherited) == "owner"
        deadline = time.monotonic() + 2
        while True:
            successor = start(copy, work / "state")
            outcome = line(successor)
            successor.communicate("\n", timeout=5)
            if outcome == "owner":
                break
            assert time.monotonic() < deadline, "exec 이후 잠금이 자식 실행 파일에 남음"
            time.sleep(0.01)
        assert inherited.poll() is None, "exec 된 sleep이 실행 중이어야 함"

        # 제품 복사본 대신 가짜 bundle을 직접 실행한다. Launch Services 등록은 하지 않는다.
        bundle = work / "Legacy.app"
        macos = bundle / "Contents/MacOS"
        macos.mkdir(parents=True)
        shutil.copy2(executable, macos / "ClaudeSessionWarmer")
        (bundle / "Contents/Info.plist").write_bytes(plistlib.dumps({
            "CFBundleIdentifier": "com.sharknia.ClaudeSessionWarmer",
            "CFBundleExecutable": "ClaudeSessionWarmer", "CFBundleShortVersionString": "0.1.6"
        }))
        legacy = start(macos / "ClaudeSessionWarmer", work / "legacy-state")
        assert line(legacy) == "owner"
        detected = subprocess.check_output([str(executable), "legacy"], text=True)
        assert f"{legacy.pid}:{bundle}" in detected
        legacy.communicate("\n", timeout=5)
        print("passed: 10 simultaneous starts; direct copy blocked; SIGKILL recovery; CLOEXEC; legacy detection")
    finally:
        for process in processes:
            if process.poll() is None:
                process.kill()
            process.wait(timeout=5)
