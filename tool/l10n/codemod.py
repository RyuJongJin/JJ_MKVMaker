"""한글 문자열을 tr('…') / trf('…{0}…', [x]) 로 감싸는 코드 변환.

- 원시 문자열 (r'…') 은 건드리지 않는다 (정규식 등).
- 붙어 있는 문자열 ('a' 'b') 은 하나로 묶는다.
- 보간 ($x, ${expr}) 은 {0}, {1} … 로 바꾸고 인자 목록으로 넘긴다 (식 안의 문자열도 다시 변환).
- 이미 tr( / trf( 안에 있는 문자열은 건드리지 않는다.
"""
import os
import re
import sys

HANGUL = re.compile('[가-힣]')
IDENT = re.compile(r'[A-Za-z_][A-Za-z0-9_]*')


class Lit:
    def __init__(self, raw, quote, parts, src):
        self.raw = raw          # r'' 여부
        self.quote = quote      # ' " ''' """
        self.parts = parts      # [('text', src_text) | ('expr', expr_src, is_brace)]
        self.src = src          # 원래 소스


def skip_ws_comments(s, i):
    n = len(s)
    while i < n:
        if s[i].isspace():
            i += 1
        elif s.startswith('//', i):
            j = s.find('\n', i)
            i = n if j < 0 else j + 1
        elif s.startswith('/*', i):
            i = skip_block_comment(s, i)
        else:
            break
    return i


def skip_block_comment(s, i):
    depth = 0
    n = len(s)
    while i < n:
        if s.startswith('/*', i):
            depth += 1
            i += 2
        elif s.startswith('*/', i):
            depth -= 1
            i += 2
            if depth == 0:
                return i
        else:
            i += 1
    return n


def string_start(s, i):
    """i 에서 문자열이 시작하면 (raw, quote, 본문 시작) 아니면 None"""
    raw = False
    j = i
    if s[j] in 'rR' and j + 1 < len(s) and s[j + 1] in '\'"':
        if j > 0 and (s[j - 1].isalnum() or s[j - 1] in '_$'):
            return None
        raw = True
        j += 1
    if j >= len(s) or s[j] not in '\'"':
        return None
    q = s[j]
    if s.startswith(q * 3, j):
        return raw, q * 3, j + 3
    return raw, q, j + 1


def parse_string(s, i):
    """i 는 문자열 시작 (r 포함). (Lit, 끝 위치)"""
    raw, quote, j = string_start(s, i)
    parts = []
    buf = []
    n = len(s)
    while j < n:
        if s.startswith(quote, j):
            if buf:
                parts.append(('text', ''.join(buf)))
            j += len(quote)
            return Lit(raw, quote, parts, s[i:j]), j
        c = s[j]
        if c == '\\' and not raw:
            buf.append(s[j:j + 2])
            j += 2
            continue
        if c == '$' and not raw:
            if j + 1 < n and s[j + 1] == '{':
                end = match_brace(s, j + 1)
                if buf:
                    parts.append(('text', ''.join(buf)))
                    buf = []
                parts.append(('expr', s[j + 2:end], True))
                j = end + 1
                continue
            m = IDENT.match(s, j + 1)
            if m:
                if buf:
                    parts.append(('text', ''.join(buf)))
                    buf = []
                parts.append(('expr', m.group(0), False))
                j = m.end()
                continue
        buf.append(c)
        j += 1
    raise ValueError('끝나지 않은 문자열 at %d' % i)


def match_brace(s, i):
    """s[i] == '{' 에 맞는 '}' 위치 (안의 문자열 · 주석 고려)"""
    depth = 0
    n = len(s)
    j = i
    while j < n:
        c = s[j]
        if s.startswith('//', j) or s.startswith('/*', j):
            j = skip_ws_comments(s, j)
            continue
        st = string_start(s, j)
        if st:
            _, j = parse_string(s, j)
            continue
        if c == '{':
            depth += 1
        elif c == '}':
            depth -= 1
            if depth == 0:
                return j
        j += 1
    raise ValueError('괄호가 맞지 않음')


def has_hangul_text(lits):
    return any(p[0] == 'text' and HANGUL.search(p[1]) for l in lits for p in l.parts)


def emit_group(lits, transform):
    """붙어 있는 문자열 묶음 → tr(...) / trf(..., [...])"""
    args = []
    pieces = []
    for l in lits:
        body = []
        for p in l.parts:
            if p[0] == 'text':
                # 템플릿 자리 표시와 헷갈리지 않게 원래 {n} 은 그대로 둔다 (드묾)
                body.append(p[1])
            else:
                body.append('{%d}' % len(args))
                args.append(transform(p[1]).strip())
        pieces.append(l.quote + ''.join(body) + l.quote)
    lit = ' '.join(pieces)
    if args:
        return 'trf(%s, [%s])' % (lit, ', '.join(args))
    return 'tr(%s)' % lit


def transform(s):
    out = []
    i = 0
    n = len(s)
    while i < n:
        c = s[i]
        if s.startswith('//', i):
            j = s.find('\n', i)
            j = n if j < 0 else j
            out.append(s[i:j])
            i = j
            continue
        if s.startswith('/*', i):
            j = skip_block_comment(s, i)
            out.append(s[i:j])
            i = j
            continue
        st = string_start(s, i)
        if st and not (c in 'rR' and i > 0 and (s[i - 1].isalnum() or s[i - 1] in '_$')):
            # 붙어 있는 문자열 모으기
            start = i
            lits = []
            lit, j = parse_string(s, i)
            lits.append(lit)
            end = j
            while True:
                k = skip_ws_comments(s, end)
                if k < n and string_start(s, k):
                    lit, j2 = parse_string(s, k)
                    lits.append(lit)
                    end = j2
                else:
                    break
            already = re.search(r'\btrf?\(\s*$', ''.join(out)[-20:]) is not None
            directive = re.search(r'(^|\n)\s*(import|export|part|library)\b[^;\n]*$', ''.join(out)[-200:]) is not None
            if (not already and not directive and has_hangul_text(lits)
                    and not any(l.raw for l in lits)):
                out.append(emit_group(lits, transform))
            else:
                # 그대로 두되, 보간 식 안의 문자열은 변환
                out.append(rebuild_with_exprs(s[start:end], transform))
            i = end
            continue
        out.append(c)
        i += 1
    return ''.join(out)


def rebuild_with_exprs(src, transform):
    """문자열 (묶음) 원문에서 ${...} 안만 변환"""
    out = []
    i = 0
    n = len(src)
    while i < n:
        st = string_start(src, i)
        if st:
            raw, quote, j = st
            out.append(src[i:j])
            while not src.startswith(quote, j):
                ch = src[j]
                if ch == '\\' and not raw:
                    out.append(src[j:j + 2])
                    j += 2
                elif ch == '$' and not raw and j + 1 < n and src[j + 1] == '{':
                    e = match_brace(src, j + 1)
                    out.append('${' + transform(src[j + 2:e]) + '}')
                    j = e + 1
                else:
                    out.append(ch)
                    j += 1
            out.append(quote)
            i = j + len(quote)
        else:
            out.append(src[i])
            i += 1
    return ''.join(out)


def add_import(src, path):
    rel = os.path.relpath(os.path.join('lib', 'l10n', 'tr.dart'), os.path.dirname(path)).replace('\\', '/')
    line = "import '%s';\n" % rel
    if line in src:
        return src
    imports = list(re.finditer(r"^import '[^']+';\n", src, re.M))
    if imports:
        last = imports[-1]
        return src[:last.end()] + line + src[last.end():]
    return line + src


if __name__ == '__main__':
    skip = {os.path.normpath(p) for p in sys.argv[2:]}
    changed = 0
    for root, _, files in os.walk(sys.argv[1]):
        for f in files:
            if not f.endswith('.dart'):
                continue
            path = os.path.join(root, f)
            if os.path.normpath(path) in skip:
                continue
            src = open(path, encoding='utf-8').read()
            new = transform(src)
            if new != src:
                new = add_import(new, path)
                open(path, 'w', encoding='utf-8', newline='').write(new)
                changed += 1
                print('변환', path)
    print('파일', changed)
