"""Launch the actual release APK on a disposable CI emulator, with no account/key."""
import json
from pathlib import Path
import subprocess
import sys
import time

package = "com.example.cryptoloop_tr"
out = Path("build/qa/device")
out.mkdir(parents=True, exist_ok=True)

def adb(*args):
    return subprocess.check_output(["adb", *args], text=True, timeout=60)

subprocess.run(["adb", "uninstall", package], capture_output=True, timeout=30)
adb("install", "-r", str(Path(sys.argv[1]).resolve()))
adb("logcat", "-c")
launch = adb("shell", "am", "start", "-W", "-n", package + "/.MainActivity")
assert "Status: ok" in launch, launch
time.sleep(12)
pid = adb("shell", "pidof", package).strip()
assert pid, "Release process exited"
crash = adb("logcat", "-b", "crash", "-d")
assert package not in crash, crash
adb("shell", "uiautomator", "dump", "/sdcard/cryptoloop-smoke.xml")
xml = adb("shell", "cat", "/sdcard/cryptoloop-smoke.xml")
(out / "release-ui.xml").write_text(xml)
assert "CryptoLoop TR" in xml and "PAPER" in xml, "Release dashboard did not render"
services = adb("shell", "dumpsys", "activity", "services", package)
assert "BotService" not in services, "A bot started without user action"
with (out / "release.png").open("wb") as target:
    subprocess.run(["adb", "exec-out", "screencap", "-p"], stdout=target, check=True, timeout=15)
(out / "release-logcat.txt").write_text(adb("logcat", "-d", "--pid=" + pid))
report = {
    "releaseLaunch": True,
    "dashboardRendered": True,
    "defaultPaperMode": True,
    "noAutomaticBotStart": True,
    "apiLevel": adb("shell", "getprop", "ro.build.version.sdk").strip(),
    "device": adb("shell", "getprop", "ro.product.model").strip(),
    "marketVerified": False,
    "marketNote": "Market/private API end-to-end confirmation is separate from device smoke tests.",
}
(out / "release-smoke.json").write_text(json.dumps(report, indent=2))
print(json.dumps(report))
adb("shell", "am", "force-stop", package)
