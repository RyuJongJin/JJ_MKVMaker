"""JJ_MKVMaker 아이콘 만들기 (환경 설정 > 일반 > 앱 아이콘 에서 고르는 여러 가지)

아이콘 종류 (id):
  yellow   노란 바탕 + 검은 J · J + 검은 재생 버튼 (두 가지 색만, 기본)
  black    검은 바탕 + 노란 J · J + 흰 재생 버튼 + 필름 띠
  film_jj  빨강 → 주황 바탕 + 노란 J · J + 흰 재생 버튼 + 필름 띠
  film     빨강 → 주황 바탕 + 큰 흰 재생 버튼 + 필름 띠
  blue     청록 → 보라 바탕 + 흰 JJ + 재생 표시 (처음 아이콘)

사용법: python tool/make_icon.py
결과:   assets/icon/variants/<id>_256.png (설정 미리보기) · <id>_button.png (앱 안 왼쪽 위 버튼) · <id>.ico (Windows 창 · 트레이)
        assets/icon/app_icon_1024.png · windows/runner/resources/app_icon.ico · assets/tray_icon.ico (기본 아이콘)
        android/app/src/main/res/mipmap-*/ic_launcher[_<id>].png · ic_launcher[_<id>]_bg.png · _fg.png
        + mipmap-anydpi-v26/ic_launcher[_<id>].xml (Android 8 이상 adaptive icon)
        build/icon_preview.png (한눈에 보기)
"""
from pathlib import Path

from PIL import Image, ImageDraw, ImageFilter, ImageFont

ROOT = Path(__file__).resolve().parent.parent
S = 1024  # 원본 크기
FONT = 'C:/Windows/Fonts/seguibl.ttf'  # Segoe UI Black
DEFAULT = 'yellow'
IDS = ['yellow', 'black', 'film_jj', 'film', 'blue']

WHITE = (255, 255, 255)
BLACK = (0, 0, 0)
YELLOW = (255, 210, 0)     # 노란 아이콘 바탕
JJ_YELLOW = (255, 214, 0)  # 검은 · 빨간 아이콘의 JJ 글자


def lerp(a, b, t):
    return tuple(round(a[i] + (b[i] - a[i]) * t) for i in range(3))


def rounded_mask(radius):
    m = Image.new('L', (S, S), 0)
    ImageDraw.Draw(m).rounded_rectangle((0, 0, S - 1, S - 1), radius=int(S * radius), fill=255)
    return m


def gradient(c1, c2, glow=0):
    """대각선 그라데이션 (왼쪽 위 c1 → 오른쪽 아래 c2) + 왼쪽 위의 은은한 빛"""
    g = Image.new('RGB', (S, S))
    px = g.load()
    for y in range(S):
        for x in range(S):
            px[x, y] = lerp(c1, c2, (x + y) / (2 * (S - 1)))
    if glow:
        m = Image.new('L', (S, S), 0)
        ImageDraw.Draw(m).ellipse((-S * 0.4, -S * 0.5, S * 0.8, S * 0.45), fill=glow)
        m = m.filter(ImageFilter.GaussianBlur(S * 0.15))
        g = Image.composite(Image.new('RGB', (S, S), WHITE), g, m)
    return g


def play(scale=1.0, cx=0.5, cy=0.5, color=WHITE, shadow=(0, 0, 0, 200)):
    """재생 버튼 (모서리가 둥근 굵은 삼각형). shadow=None: 그림자 없음 (단색 아이콘)"""
    layer = Image.new('RGBA', (S, S), (0, 0, 0, 0))
    h = S * 0.46 * scale
    w = h * 0.92
    x0 = S * cx - w * 0.40  # 무게 중심이 가운데 오도록 약간 오른쪽으로
    y0 = S * cy - h / 2
    pts = [(x0, y0), (x0, y0 + h), (x0 + w, y0 + h / 2)]
    r = S * 0.05 * scale

    def draw(img, fill, off=(0, 0)):
        d = ImageDraw.Draw(img)
        p = [(x + off[0], y + off[1]) for x, y in pts]
        d.polygon(p, fill=fill)
        d.line(p + [p[0]], fill=fill, width=int(r * 2), joint='curve')
        for x, y in p:
            d.ellipse((x - r, y - r, x + r, y + r), fill=fill)

    if shadow:
        sh = Image.new('RGBA', (S, S), (0, 0, 0, 0))
        draw(sh, shadow, off=(S * 0.012 * scale, S * 0.028 * scale))
        layer = Image.alpha_composite(layer, sh.filter(ImageFilter.GaussianBlur(S * 0.025 * scale)))
    draw(layer, color + (255,))
    return layer


def jj(cx, top, bottom, color, outline=None, shadow=True):
    """J 를 위 · 아래로 하나씩. outline: 테두리 색 (글자와 같은 색이면 더 굵게), shadow: 그림자"""
    layer = Image.new('RGBA', (S, S), (0, 0, 0, 0))
    h = (bottom - top) / 2
    font = ImageFont.truetype(FONT, int(h * 1.18))
    # 글자와 같은 색 테두리는 살짝만 (위아래 J 가 붙지 않게)
    stroke = 0 if not outline else int(h * (0.03 if outline == color else 0.09))
    sh = Image.new('RGBA', (S, S), (0, 0, 0, 0))
    for i in range(2):
        d = ImageDraw.Draw(layer)
        l, t, r, b = d.textbbox((0, 0), 'J', font=font, stroke_width=stroke)
        x = cx - (l + r) / 2
        y = top + h * i + (h - (b - t)) / 2 - t
        if outline and shadow:
            ImageDraw.Draw(sh).text((x + h * 0.04, y + h * 0.07), 'J', font=font, fill=(0, 0, 0, 200),
                                    stroke_width=stroke, stroke_fill=(0, 0, 0, 200))
        d.text((x, y), 'J', font=font, fill=color + (255,), stroke_width=stroke,
               stroke_fill=(outline or color) + (255,))
    if outline and shadow:
        layer = Image.alpha_composite(sh.filter(ImageFilter.GaussianBlur(h * 0.05)), layer)
    return layer


def film_bands(top, band, film, hole, holes=6):
    """위아래 필름 띠 (어두운 띠 + 밝은 구멍)"""
    layer = Image.new('RGBA', (S, S), (0, 0, 0, 0))
    d = ImageDraw.Draw(layer)
    for y0 in (top, S - top - band):
        d.rectangle((0, y0, S, y0 + band), fill=film + (255,))
        hw, hh = S / (holes * 2.2), band * 0.46
        gap = S / holes
        for i in range(holes):
            cx, cy = gap * (i + 0.5), y0 + band / 2
            d.rounded_rectangle((cx - hw / 2, cy - hh / 2, cx + hw / 2, cy + hh / 2), radius=hh * 0.3,
                                fill=hole + (255,))
    return layer


def on(bg, *layers, radius=0.22):
    """둥근 사각형 바탕 위에 그림들을 겹친다 (바깥으로 나간 부분은 자름)"""
    mask = rounded_mask(radius)
    img = Image.new('RGBA', (S, S), (0, 0, 0, 0))
    img.paste(bg, (0, 0), mask)
    for l in layers:
        img = Image.alpha_composite(img, Image.composite(l, Image.new('RGBA', (S, S)), mask))
    return img


def big_jj(color, outline=None, size=0.62):
    """가운데 큰 JJ (앱 안 26px 버튼처럼 작아도 또렷하게)"""
    layer = Image.new('RGBA', (S, S), (0, 0, 0, 0))
    font = ImageFont.truetype(FONT, int(S * size))
    d = ImageDraw.Draw(layer)
    stroke = int(S * 0.035) if outline else 0
    l, t, r, b = d.textbbox((0, 0), 'JJ', font=font, stroke_width=stroke)
    d.text(((S - (r - l)) / 2 - l, (S - (b - t)) / 2 - t), 'JJ', font=font, fill=color + (255,),
           stroke_width=stroke, stroke_fill=(outline or color) + (255,))
    return layer


def variant(vid):
    """아이콘 하나: (큰 아이콘, 16~32px 용, 앱 안 버튼, Android 바탕, Android 앞)"""
    if vid == 'yellow':
        # 노랑 + 검정 두 가지 색만: 그림자 · 테두리 없이 단순하게
        bg = Image.new('RGB', (S, S), YELLOW)
        master = on(bg, jj(S * 0.215, S * 0.2, S * 0.8, BLACK, BLACK, shadow=False), play(0.95, cx=0.6, color=BLACK, shadow=None))
        small = on(bg, play(1.3, color=BLACK, shadow=None))
        button = on(bg, big_jj(BLACK))
        fg = Image.alpha_composite(jj(S * 0.345, S * 0.3, S * 0.7, BLACK, BLACK, shadow=False),
                                   play(0.55, cx=0.575, color=BLACK, shadow=None))
        return master, small, button, bg.convert('RGBA'), fg

    if vid in ('black', 'film_jj', 'film'):
        if vid == 'black':
            bg, film, hole, outline = gradient((58, 58, 66), (6, 6, 8), glow=22), BLACK, (235, 235, 240), BLACK
        else:
            bg, film, hole, outline = gradient((255, 45, 85), (255, 149, 0), glow=45), (25, 10, 30), WHITE, (60, 0, 30)
        bands = film_bands(int(S * 0.055), int(S * 0.13), film, hole)
        if vid == 'film':
            master = on(bg, bands, play(1.0))
            fg = play(0.62)
        else:
            master = on(bg, bands, jj(S * 0.19, S * 0.23, S * 0.77, JJ_YELLOW, outline), play(0.92, cx=0.6))
            fg = Image.alpha_composite(jj(S * 0.335, S * 0.31, S * 0.69, JJ_YELLOW, outline), play(0.55, cx=0.57))
        small = on(bg, play(1.25))
        button = on(bg, big_jj(JJ_YELLOW, outline))
        a_bg = Image.alpha_composite(bg.convert('RGBA'), film_bands(int(S * 0.17), int(S * 0.1), film, hole, holes=7))
        return master, small, button, a_bg, fg

    # blue: 처음 아이콘 (청록 → 보라 + 흰 JJ + 오른쪽 아래 흰 동그라미 재생 표시)
    violet = (108, 92, 255)
    bg = gradient((0, 196, 204), violet, glow=38)

    def white_jj(size, dx, dy):
        layer = Image.new('RGBA', (S, S), (0, 0, 0, 0))
        font = ImageFont.truetype(FONT, int(S * size))
        l, t, r, b = ImageDraw.Draw(layer).textbbox((0, 0), 'JJ', font=font)
        x, y = (S - (r - l)) / 2 - l + dx, (S - (b - t)) / 2 - t + dy
        sh = Image.new('RGBA', (S, S), (0, 0, 0, 0))
        ImageDraw.Draw(sh).text((x + S * 0.012, y + S * 0.022), 'JJ', font=font, fill=(20, 10, 60, 120))
        layer = Image.alpha_composite(layer, sh.filter(ImageFilter.GaussianBlur(S * 0.018)))
        ImageDraw.Draw(layer).text((x, y), 'JJ', font=font, fill=WHITE + (255,))
        return layer

    def badge(cx, cy, rad):
        b = Image.new('RGBA', (S, S), (0, 0, 0, 0))
        ImageDraw.Draw(b).ellipse((cx - rad * 1.12, cy - rad * 1.12, cx + rad * 1.12, cy + rad * 1.12),
                                  fill=(40, 20, 110, 90))
        b = b.filter(ImageFilter.GaussianBlur(S * 0.012))
        d = ImageDraw.Draw(b)
        d.ellipse((cx - rad, cy - rad, cx + rad, cy + rad), fill=WHITE + (255,))
        tri = rad * 0.52
        d.polygon([(cx - tri * 0.62, cy - tri), (cx - tri * 0.62, cy + tri), (cx + tri * 0.95, cy)],
                  fill=violet + (255,))
        return b

    master = on(bg, white_jj(0.56, -S * 0.035, -S * 0.02), badge(S * 0.765, S * 0.765, S * 0.135), radius=0.23)
    small = on(bg, white_jj(0.66, 0, 0), radius=0.23)
    fg = Image.alpha_composite(white_jj(0.36, -S * 0.02, -S * 0.01), badge(S * 0.64, S * 0.64, S * 0.085))
    return master, small, small, bg.convert('RGBA'), fg


def save_ico(path, master, small, sizes):
    imgs = [(small if s <= 32 else master).resize((s, s), Image.LANCZOS) for s in sizes]
    imgs[-1].save(path, format='ICO', sizes=[(s, s) for s in sizes], append_images=imgs[:-1])


def main():
    icon_dir = ROOT / 'assets' / 'icon'
    out = icon_dir / 'variants'
    out.mkdir(parents=True, exist_ok=True)
    res = ROOT / 'android' / 'app' / 'src' / 'main' / 'res'
    any_dpi = res / 'mipmap-anydpi-v26'
    any_dpi.mkdir(parents=True, exist_ok=True)
    dpis = {'mdpi': 48, 'hdpi': 72, 'xhdpi': 96, 'xxhdpi': 144, 'xxxhdpi': 192}
    # 예전 판에서 만든 파일 정리
    for name in ('app_icon_256.png', 'app_icon_small_256.png', 'app_button_256.png', 'preview.png'):
        (icon_dir / name).unlink(missing_ok=True)
    for d in res.glob('mipmap-*'):
        for f in d.glob('ic_launcher*'):
            f.unlink()

    all_icons = {}
    for vid in IDS:
        master, small, button, a_bg, a_fg = all_icons[vid] = variant(vid)
        master.resize((256, 256), Image.LANCZOS).save(out / f'{vid}_256.png')
        button.resize((128, 128), Image.LANCZOS).save(out / f'{vid}_button.png')
        save_ico(out / f'{vid}.ico', master, small, [16, 20, 24, 32, 40, 48, 64, 128, 256])
        # Android: 고를 수 있는 아이콘마다 ic_launcher_<id>, 기본 아이콘은 ic_launcher 로도
        for name in [f'_{vid}'] + ([''] if vid == DEFAULT else []):
            for dpi, px in dpis.items():
                d = res / f'mipmap-{dpi}'
                d.mkdir(parents=True, exist_ok=True)
                master.resize((px, px), Image.LANCZOS).save(d / f'ic_launcher{name}.png')
                a = px * 108 // 48  # adaptive 는 108dp
                a_bg.resize((a, a), Image.LANCZOS).save(d / f'ic_launcher{name}_bg.png')
                a_fg.resize((a, a), Image.LANCZOS).save(d / f'ic_launcher{name}_fg.png')
            (any_dpi / f'ic_launcher{name}.xml').write_text(
                '<?xml version="1.0" encoding="utf-8"?>\n'
                '<adaptive-icon xmlns:android="http://schemas.android.com/apk/res/android">\n'
                f'    <background android:drawable="@mipmap/ic_launcher{name}_bg"/>\n'
                f'    <foreground android:drawable="@mipmap/ic_launcher{name}_fg"/>\n'
                f'    <monochrome android:drawable="@mipmap/ic_launcher{name}_fg"/>\n'
                '</adaptive-icon>\n', encoding='utf-8')
        if vid == DEFAULT:
            master.save(icon_dir / 'app_icon_1024.png')
            save_ico(ROOT / 'windows' / 'runner' / 'resources' / 'app_icon.ico', master, small,
                     [16, 20, 24, 32, 40, 48, 64, 128, 256])
            save_ico(ROOT / 'assets' / 'tray_icon.ico', master, small, [16, 20, 24, 32, 48])

    # 한눈에 보기: 줄마다 큰 아이콘 · Android 동그라미 · 앱 안 버튼 / 16px
    prev = Image.new('RGBA', (len(IDS) * 280 + 20, 660), (128, 128, 136, 255))
    circle = Image.new('L', (256, 256), 0)
    ImageDraw.Draw(circle).ellipse((0, 0, 255, 255), fill=255)
    c = int(S * 18 / 108)
    for i, vid in enumerate(IDS):
        master, small, button, a_bg, a_fg = all_icons[vid]
        x = 20 + i * 280
        prev.alpha_composite(master.resize((256, 256), Image.LANCZOS), (x, 20))
        full = Image.alpha_composite(a_bg, a_fg).crop((c, c, S - c, S - c)).resize((256, 256), Image.LANCZOS)
        prev.paste(full, (x, 296), circle)
        prev.alpha_composite(button.resize((52, 52), Image.LANCZOS), (x, 580))
        prev.alpha_composite(small.resize((32, 32), Image.LANCZOS), (x + 80, 590))
        prev.alpha_composite(small.resize((16, 16), Image.LANCZOS), (x + 130, 598))
    (ROOT / 'build').mkdir(exist_ok=True)
    prev.save(ROOT / 'build' / 'icon_preview.png')
    print('icons ok')


if __name__ == '__main__':
    main()
