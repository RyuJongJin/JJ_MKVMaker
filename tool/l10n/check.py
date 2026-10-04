"""화면 글자 사전 점검: 코드의 tr('…') / trf('…') 열쇠 중 assets/l10n/*.json 에 없는 것을 보여 준다.

사용 (app 폴더에서):
  python tool/l10n/codemod.py lib lib/l10n/tr.dart lib/core/languages.dart lib/core/youtube_ads.dart
      → 새로 쓴 한글 문자열을 tr() / trf() 로 감싼다
  python tool/l10n/check.py
      → 사전에 없는 열쇠를 보여 준다 (있으면 en · ja · zh-Hans 사전에 번역을 더한다)
"""
import json
import os
import subprocess
import sys
import tempfile

here = os.path.dirname(os.path.abspath(__file__))
out = os.path.join(tempfile.gettempdir(), 'jj_l10n_keys.json')
subprocess.run([sys.executable, os.path.join(here, 'extract_keys.py'), out], check=True)
keys = json.load(open(out, encoding='utf-8'))
missing = 0
for lang in ['en', 'ja', 'zh-Hans']:
    d = json.load(open(os.path.join('assets', 'l10n', lang + '.json'), encoding='utf-8'))
    miss = [k for k in keys if k not in d]
    missing += len(miss)
    for k in miss:
        print('%s 사전에 없음: %r' % (lang, k))
print('열쇠 %d개, 빠진 번역 %d개' % (len(keys), missing))
sys.exit(1 if missing else 0)
