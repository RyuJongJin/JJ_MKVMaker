"""lib 의 tr('…') / trf('…') 열쇠와 한국어 이름 (언어 · 선택 목록 · 모델) 을 모아 JSON 으로 쓴다.

두 번째 인자를 주면 tr 로 감싸지 않은 한글 글 ([경로, 줄, 글]) 도 쓴다 (60: tr(변수) 로 나중에 번역되거나 아예 번역이 빠진 글).
번역하지 않는 자료 (말버릇 목록 · 정규식 · 스크립트 · 실제 폴더 이름 등) 는 그 줄이나 바로 위 줄에 `// l10n-skip`,
파일 전체면 맨 위쪽에 `// l10n-skip-file`. raw 문자열 (r'…') 은 정규식이라 보지 않는다.
"""
import json
import os
import re
import sys

sys.path.insert(0, os.path.dirname(__file__))
from codemod import parse_string, string_start, skip_ws_comments, HANGUL  # noqa: E402


def decode(lit_src_parts):
    """Dart 문자열 본문 (escape 포함) → 실제 글자"""
    out = []
    s = lit_src_parts
    i = 0
    while i < len(s):
        c = s[i]
        if c == '\\':
            n = s[i + 1]
            if n == 'n':
                out.append('\n')
            elif n == 't':
                out.append('\t')
            elif n == 'r':
                out.append('\r')
            elif n == 'u':
                if s[i + 2] == '{':
                    j = s.index('}', i)
                    out.append(chr(int(s[i + 3:j], 16)))
                    i = j + 1
                    continue
                out.append(chr(int(s[i + 2:i + 6], 16)))
                i += 6
                continue
            elif n == 'x':
                out.append(chr(int(s[i + 2:i + 4], 16)))
                i += 4
                continue
            else:
                out.append(n)
            i += 2
            continue
        out.append(c)
        i += 1
    return ''.join(out)


def group_text(lits):
    text = []
    k = 0
    for l in lits:
        for p in l.parts:
            if p[0] == 'text':
                text.append(decode(p[1]) if not l.raw else p[1])
            else:
                text.append('{%d}' % k)
                k += 1
    return ''.join(text)


def literal_groups(src):
    """(시작 위치, 문자열 묶음) 전부"""
    i = 0
    n = len(src)
    while i < n:
        if src.startswith('//', i) or src.startswith('/*', i):
            i = skip_ws_comments(src, i)
            continue
        st = string_start(src, i)
        if st and not (src[i] in 'rR' and i > 0 and (src[i - 1].isalnum() or src[i - 1] in '_$')):
            start = i
            lits = []
            lit, j = parse_string(src, i)
            lits.append(lit)
            while True:
                k = skip_ws_comments(src, j)
                if k < n and string_start(src, k):
                    lit, j = parse_string(src, k)
                    lits.append(lit)
                else:
                    break
            yield start, lits
            i = j
            continue
        i += 1


keys = set()
unwrapped = []
NAMED = {'lib/core/languages.dart', 'lib/core/download_detect.dart', 'lib/core/encode_options.dart',
         'lib/core/playlist.dart', 'lib/services/model_store.dart'}
for root, _, files in os.walk('lib'):
    for f in files:
        if not f.endswith('.dart'):
            continue
        path = os.path.join(root, f).replace('\\', '/')
        src = open(path, encoding='utf-8').read()
        # (그 글이 들어 있는 소스, 위치, 문자열 묶음). 문자열 안의 ${...} 식에 든 문자열도
        # (예: '${n}%${x ? tr(' (보통)') : ''}') 다시 찾는다.
        todo = [(src, st, lits) for st, lits in literal_groups(src)]
        k = 0
        while k < len(todo):
            for l in todo[k][2]:
                for part in l.parts:
                    if part[0] == 'expr':
                        todo.extend((part[1], st, ls) for st, ls in literal_groups(part[1]))
            k += 1
        skip_file = '// l10n-skip-file' in src
        lines = src.split('\n')
        for text_src, start, lits in todo:
            # 60: trf( 뒤에서 줄을 바꾼 것도 (예전에는 앞 8글자만 봐서 놓쳤다)
            before = text_src[max(0, start - 200):start]
            wrapped = re.search(r'\btrf?\(\s*$', before) is not None
            text = group_text(lits)
            if not HANGUL.search(text):
                continue
            if wrapped or (path in NAMED and not any(l.raw for l in lits)):
                keys.add(text)
            elif not skip_file and not any(l.raw for l in lits) and text_src is src:
                line = src.count('\n', 0, start)
                near = lines[line] + (lines[line - 1] if line > 0 else '')
                if '// l10n-skip' not in near:
                    unwrapped.append([path, line + 1, text])
# 광고 건너뛰기 표시 (youtube_ads.dart 는 스크립트라 따로)
keys.add('광고 건너뛰는 중…')
out = sorted(keys)
json.dump(out, open(sys.argv[1], 'w', encoding='utf-8'), ensure_ascii=False, indent=1)
if len(sys.argv) > 2:
    json.dump(unwrapped, open(sys.argv[2], 'w', encoding='utf-8'), ensure_ascii=False, indent=1)
print(len(out), sum(len(k) for k in out))
