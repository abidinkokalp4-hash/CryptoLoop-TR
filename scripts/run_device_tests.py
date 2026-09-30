"""Run the paper integration test and lock the CI emulator after service startup."""
import json
from pathlib import Path
import subprocess
import time

command = ["flutter", "drive", "--driver", "test_driver/integration_test.dart",
    "--target", "integration_test/background_test.dart",
    "--use-application-binary=build/app/outputs/flutter-apk/app-debug.apk",
    "--timeout=180", "--no-pub"]
out = Path("build/qa/device")
out.mkdir(parents=True, exist_ok=True)
locked = False
lines = []
started = time.monotonic()
try:
    with subprocess.Popen(command, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, bufsize=1) as run:
        for line in run.stdout:
            print(line, end="", flush=True)
            lines.append(line)
            if "CRYPTOLOOP_PAPER_SERVICE_READY" in line and not locked:
                subprocess.run(["adb", "shell", "input", "keyevent", "223"], check=True, timeout=10)
                for _ in range(30):
                    power = subprocess.check_output(["adb", "shell", "dumpsys", "power"], text=True, timeout=10)
                    if "mWakefulness=Asleep" in power or "mWakefulness=Dozing" in power:
                        break
                    time.sleep(0.1)
                (out / "power-during-test.txt").write_text(power)
                assert "mWakefulness=Asleep" in power or "mWakefulness=Dozing" in power, "Emulator did not lock"
                locked = True
                print("Emulator screen locked; paper engine must continue.", flush=True)
        assert run.wait(timeout=10) == 0, "Native paper test failed"
    assert locked, "Screen lock marker was not observed"
    assert any("CRYPTOLOOP_TEN_COIN_PAPER_EXITS_VERIFIED" in line for line in lines), "Ten coin exits were not verified"
    (out / "background-test.json").write_text(json.dumps({
        "passed": True, "screenLocked": True, "realForegroundService": True,
        "paperOnly": True, "simultaneousPositions": 10, "profitablePaperExits": 10, "prices": "test fixture", "seconds": time.monotonic() - started,
    }, indent=2))
finally:
    (out / "integration-log.txt").write_text("".join(lines))
    subprocess.run(["adb", "shell", "input", "keyevent", "224"], capture_output=True, timeout=10)
    subprocess.run(["adb", "shell", "wm", "dismiss-keyguard"], capture_output=True, timeout=10)
