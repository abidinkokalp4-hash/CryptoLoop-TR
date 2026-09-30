"""Collect evidence while the disposable emulator is still alive, even on failure."""
from pathlib import Path
import subprocess
import sys

out = Path('build/qa/device')
out.mkdir(parents=True, exist_ok=True)
try:
    subprocess.run([sys.executable, 'scripts/run_device_tests.py'], check=True)
    subprocess.run([sys.executable, 'scripts/device_release_smoke.py', sys.argv[1]], check=True)
finally:
    commands = {
        'emulator-logcat.txt': ['adb', 'logcat', '-d'],
        'emulator-crash.txt': ['adb', 'logcat', '-b', 'crash', '-d'],
        'emulator-window.txt': ['adb', 'shell', 'dumpsys', 'window'],
        'runner-memory.txt': ['free', '-m'],
        'runner-processes.txt': ['ps', '-eo', 'pid,rss,comm', '--sort=-rss'],
    }
    for name, command in commands.items():
        try:
            result = subprocess.run(command, capture_output=True, text=True, timeout=8)
            (out/name).write_text(result.stdout + result.stderr)
        except subprocess.TimeoutExpired:
            (out/name).write_text('Diagnostic timed out; original test failure remains.')
