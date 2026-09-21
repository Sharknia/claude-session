#!/usr/bin/env python3
"""실제 두 프로세스의 워밍/기록 1회 및 강제 종료 뒤 불확실한 재전송 차단 검증."""
import json
import pathlib
import os
import select
import subprocess
import tempfile
import time

ROOT = pathlib.Path(__file__).resolve().parent.parent
binary = subprocess.check_output(["bash", str(ROOT / "scripts/verify-scheduler.sh"), "--build-only"], text=True).strip()
processes = []


def start(root, action="worker"):
    process = subprocess.Popen([binary, "concurrent", action, str(root)], stdin=subprocess.PIPE,
                               stdout=subprocess.PIPE, text=True, bufsize=1)
    processes.append(process)
    assert line(process) == "ready"
    return process


def line(process):
    deadline = time.monotonic() + 10
    data = bytearray()
    while True:
        remaining = deadline - time.monotonic()
        assert remaining > 0 and select.select([process.stdout], [], [], remaining)[0], "프로세스 응답 시간 초과"
        byte = os.read(process.stdout.fileno(), 1)
        assert byte, "프로세스가 응답 전에 종료됨"
        if byte == b"\n":
            return data.decode().strip()
        data.extend(byte)


def release(process):
    process.stdin.write("start\n")
    process.stdin.flush()


with tempfile.TemporaryDirectory(prefix="ClaudeSessionWarmerTests-Concurrent-") as temporary:
    root = pathlib.Path(temporary)
    try:
        for index in range(3):
            trial = root / f"concurrent-{index}"
            subprocess.run([binary, "concurrent", "seed", str(trial)], check=True)
            pair = [start(trial), start(trial)]
            for process in pair:
                release(process)
            output = [process.communicate(timeout=10)[0] for process in pair]
            assert sorted(process.returncode for process in pair) == [0, 2], output
            records = [json.loads(line) for text in output for line in text.splitlines() if line.startswith("{")]
            assert records == [{"handled": 1, "pending": False, "requests": 1, "status": "succeeded"}], records
            assert json.loads((trial / "runtime-state.json").read_text())["value"]["handledWindows"] == 1

        crash = root / "crash"
        subprocess.run([binary, "concurrent", "seed", str(crash)], check=True)
        process = start(crash, "pause")
        release(process)
        assert line(process) == "owner"
        assert line(process) == "before_send"
        process.kill()
        process.wait(timeout=5)
        pending = json.loads((crash / "runtime-state.json").read_text())["value"]
        assert "lastWarmupAttemptAt" in pending
        restarted = start(crash)
        release(restarted)
        output = restarted.communicate(timeout=10)[0]
        result = json.loads(next(line for line in output.splitlines() if line.startswith("{")))
        assert result["requests"] == 0 and result["handled"] == 0 and result["pending"], result
        print("passed: 3 concurrent runs = 1 request/1 completion each; SIGKILL pending record survived; resend 0")
    finally:
        for process in processes:
            if process.poll() is None:
                process.kill()
            process.wait(timeout=5)
