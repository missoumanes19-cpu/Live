#!/usr/bin/env python3
"""Patch the Flutter-generated Android project so ANES TV works in release builds:
INTERNET permission, cleartext (http) streams, external-player visibility,
Android TV launcher, app label, and branding resources."""
import pathlib, re, shutil

root = pathlib.Path(__file__).resolve().parent.parent
manifest = root / 'android/app/src/main/AndroidManifest.xml'
s = manifest.read_text(encoding='utf-8')

perms = ['android.permission.INTERNET', 'android.permission.ACCESS_NETWORK_STATE',
         'android.permission.WAKE_LOCK']
for p in perms:
    if p not in s:
        s = s.replace('<application', f'<uses-permission android:name="{p}"/>\n    <application', 1)

features = '''<uses-feature android:name="android.software.leanback" android:required="false"/>
    <uses-feature android:name="android.hardware.touchscreen" android:required="false"/>
    '''
if 'software.leanback' not in s:
    s = s.replace('<application', features + '<application', 1)

query_body = '''<intent>
            <action android:name="android.intent.action.VIEW"/>
            <data android:scheme="http"/>
        </intent>
        <intent>
            <action android:name="android.intent.action.VIEW"/>
            <data android:scheme="https"/>
        </intent>
        <intent>
            <action android:name="android.intent.action.VIEW"/>
            <data android:mimeType="video/*"/>
        </intent>
        <package android:name="com.mxtech.videoplayer.ad"/>
        <package android:name="com.mxtech.videoplayer.pro"/>
        <package android:name="com.ytv.pronew"/>
    '''
if 'com.ytv.pronew' not in s:
    if '</queries>' in s:  # Flutter's default manifest already has a <queries> block
        s = s.replace('</queries>', '    ' + query_body + '</queries>', 1)
    else:
        s = s.replace('<application', '<queries>\n        ' + query_body + '</queries>\n    <application', 1)

if 'usesCleartextTraffic' not in s:
    s = s.replace('<application', '<application android:usesCleartextTraffic="true"', 1)
s = re.sub(r'android:label="[^"]*"', 'android:label="ANES TV"', s, count=1)
if 'android:icon=' not in s:
    s = s.replace('<application', '<application android:icon="@mipmap/ic_launcher"', 1)

if 'LEANBACK_LAUNCHER' not in s:
    s = s.replace('<category android:name="android.intent.category.LAUNCHER"/>',
        '<category android:name="android.intent.category.LAUNCHER"/>\n'
        '                <category android:name="android.intent.category.LEANBACK_LAUNCHER"/>', 1)

if 'android:banner' not in s:
    s = s.replace('<application', '<application android:banner="@drawable/tv_banner"', 1)
if 'largeHeap' not in s:
    s = s.replace('<application', '<application android:largeHeap="true"', 1)

if 'screenOrientation' not in s:
    s = s.replace('<activity', '<activity android:screenOrientation="sensorLandscape"', 1)

manifest.write_text(s, encoding='utf-8')

res_src = root / 'branding/android-res'
res_dst = root / 'android/app/src/main/res'
if res_src.is_dir():
    shutil.copytree(res_src, res_dst, dirs_exist_ok=True)


# ---- أداة lint (lintVital) تنهار في بيئة البناء بخطأ داخلي منها (ليس في التطبيق): نعطّلها
# 1) سكربت init عام لـ Gradle  2) سطر في ملف Gradle الجذري للمشروع (احتياط)
init_dir = pathlib.Path.home() / '.gradle' / 'init.d'
init_dir.mkdir(parents=True, exist_ok=True)
(init_dir / 'no-lint-vital.gradle').write_text(
    "allprojects {\n  tasks.configureEach { t ->\n    if (t.name.startsWith('lintVital')) { t.enabled = false }\n  }\n}\n",
    encoding='utf-8')
for fname, block in (
    ('build.gradle.kts', '\nsubprojects {\n    tasks.configureEach {\n        if (name.startsWith("lintVital")) {\n            enabled = false\n        }\n    }\n}\n'),
    ('build.gradle', "\nsubprojects {\n    tasks.configureEach { t ->\n        if (t.name.startsWith('lintVital')) { t.enabled = false }\n    }\n}\n"),
):
    f = root / 'android' / fname
    if f.is_file():
        txt = f.read_text(encoding='utf-8')
        if 'lintVital' not in txt:
            f.write_text(txt + block, encoding='utf-8')
        break

print('Android project patched OK')
print(s)
