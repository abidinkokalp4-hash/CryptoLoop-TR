import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
import zipfile
apk = Path(sys.argv[1]).resolve()
with zipfile.ZipFile(apk) as z:
    names = set(z.namelist())
    required = {'AndroidManifest.xml','classes.dex','lib/arm64-v8a/libflutter.so','lib/arm64-v8a/libapp.so'}
    assert required <= names, 'Incomplete APK payload'
    assert not any(n.endswith('.env') or 'key.properties' in n or n.endswith('.jks') for n in names), 'Unexpected credential file'
sdk = Path(os.environ.get('ANDROID_SDK_ROOT') or os.environ.get('ANDROID_HOME') or '/usr/local/lib/android/sdk')
build_tools = sorted((sdk/'build-tools').glob('*'))
assert build_tools, 'Android build tools missing'
aapt = next((p/'aapt' for p in reversed(build_tools) if (p/'aapt').exists()), None)
signer = next((p/'apksigner' for p in reversed(build_tools) if (p/'apksigner').exists()), None)
assert aapt and signer
signature = subprocess.check_output([str(signer),'verify','--verbose','--print-certs',str(apk)],text=True)
badging = subprocess.check_output([str(aapt),'dump','badging',str(apk)],text=True)
assert "package: name='com.example.cryptoloop_tr'" in badging
assert "versionCode='11'" in badging
assert "android.permission.INTERNET" in badging
for permission in ('FOREGROUND_SERVICE', 'FOREGROUND_SERVICE_SPECIAL_USE', 'POST_NOTIFICATIONS', 'WAKE_LOCK'):
    assert f'android.permission.{permission}' in badging, f'Missing {permission}'
manifest = subprocess.check_output([str(aapt), 'dump', 'xmltree', str(apk), 'AndroidManifest.xml'], text=True)
assert '.BotService' in manifest
assert 'android:foregroundServiceType' in manifest and '0x40000000' in manifest
report = {'file':apk.name,'bytes':apk.stat().st_size,'sha256':hashlib.sha256(apk.read_bytes()).hexdigest(),
    'releasePayload':True,'signatureVerified':True,'internetPermission':True,'paperForegroundService':True,
    'signing':'Android debug certificate for private installation' if 'Android Debug' in signature else 'Configured release certificate'}
Path('build/qa').mkdir(parents=True,exist_ok=True)
Path('build/qa/apk-verification.json').write_text(json.dumps(report,indent=2))
print(json.dumps(report,indent=2))
