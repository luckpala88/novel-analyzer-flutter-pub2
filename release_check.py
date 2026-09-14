#!/usr/bin/env python3
"""发版特征串验证（根治静默失配）：python3 release_check.py "特征串1" "特征串2" ...
检查1：源码中存在；检查2（--apk）：libapp.so中UTF-16LE存在。任一失败exit 1。"""
import sys, zipfile, io
FEATS = [a for a in sys.argv[1:] if not a.startswith('--')]
APK = None
for a in sys.argv[1:]:
    if a.startswith('--apk='): APK = a.split('=',1)[1]
src = ''
import glob
for f in glob.glob('/home/z/novel-analyzer-flutter-repo/lib/**/*.dart', recursive=True):
    src += open(f, encoding='utf-8').read()
fails = [s for s in FEATS if s not in src]
if fails:
    print('❌ 源码缺特征串（改动静默丢失！）:'); [print('  -', s[:50]) for s in fails]; sys.exit(1)
print(f'✓ 源码 {len(FEATS)}/{len(FEATS)} 特征串在位')
if APK:
    so = None
    with zipfile.ZipFile(APK) as z:
        data = z.read('lib/arm64-v8a/libapp.so')
    for s in FEATS:
        if s.encode('utf-16-le') not in data:
            print(f'❌ APK缺: {s[:50]}'); sys.exit(1)
    print(f'✓ APK {len(FEATS)}/{len(FEATS)} 特征串在位')
print('=== 发版验证通过 ===')
