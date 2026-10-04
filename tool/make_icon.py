"""JJ_MKVMaker 아이콘 만들기 (1024px 원본 → .ico / .png)

눈에 띄게: 빨강 → 주황 그라데이션 바탕에 큰 흰 재생(▶) 버튼, 위아래 필름 구멍 띠.
(JJ 로 시작하는 다른 프로그램과 헷갈리지 않게 글자 대신 재생 버튼이 주인공)

사용법: python tool/make_icon.py
결과:   assets/icon/app_icon_1024.png · app_icon_256.png · app_icon_small_256.png,
        windows/runner/resources/app_icon.ico, assets/tray_icon.ico,
        android/app/src/main/res/mipmap-*/ic_launcher.png (예전 Android),
        mipmap-*/ic_launcher_foreground.png · ic_launcher_background.png + mipmap-anydpi-v26/ic_launcher.xml (Android 8 이상)
"""
from pathlib import Path

from PIL import Image, ImageDraw, ImageFilter, ImageFont

ROOT = Path(__file__).resolve().parent.parent
S = 1024  # 원본 크기

RED = (255, 45, 85)      # 왼쪽 위
ORANGE = (255, 149, 0)   # 오른쪽 아래
FILM = (25, 10, 30)      # 필름 띠
YELLOW = (255, 230, 0)   # JJ 글자 (빨강 · 주황 바탕에서 눈에 띄게)
OUTLINE = (60, 0, 30)    # JJ 테두리
FONT = 'C:/Windows/Fonts/seguibl.ttf'  # Segoe UI Black


def lerp(a, b, t):
    return tuple(round(a[i] + (b[i] - a[i]) * t) for i in range(3))


def rounded_mask(size, radius):
    m = Image.new('L', (size, size), 0)
    ImageDraw.Draw(m).rounded_rectangle((0, 0, size - 1, size - 1), radius=radius, fill=255)
    return m


def gradient(size):
    """대각선 그라데이션 (왼쪽 위 빨강 → 오른쪽 아래 주황) + 왼쪽 위의 은은한 빛"""
    g = Image.new('RGB', (size, size))
    px = g.load()
    for y in range(size):
        for x in range(size):
            px[x, y] = lerp(RED, ORANGE, (x + y) / (2 * (size - 1)))
    glow = Image.new('L', (size, size), 0)
    ImageDraw.Draw(glow).ellipse((-size * 0.4, -size * 0.5, size * 0.8, size * 0.45), fill=45)
    glow = glow.filter(ImageFilter.GaussianBlur(size * 0.15))
    return Image.composite(Image.new('RGB', (size, size), (255, 255, 255)), g, glow)


def play(size, scale=1.0, cx=0.5, cy=0.5):
    """흰 재생 버튼 (모서리가 둥근 굵은 삼각형 + 그림자) 만 있는 투명 그림"""
    layer = Image.new('RGBA', (size, size), (0, 0, 0, 0))
    h = size * 0.46 * scale          # 삼각형 높이 (세로)
    w = h * 0.92                      # 너비
    # 무게 중심이 가운데 오도록 약간 오른쪽으로
    x0 = size * cx - w * 0.40
    y0 = size * cy - h / 2
    pts = [(x0, y0), (x0, y0 + h), (x0 + w, y0 + h / 2)]
    r = size * 0.05 * scale           # 모서리 둥글기 (선 두께로)

    def draw(img, fill, off=(0, 0)):
        d = ImageDraw.Draw(img)
        p = [(x + off[0], y + off[1]) for x, y in pts]
        d.polygon(p, fill=fill)
        d.line(p + [p[0]], fill=fill, width=int(r * 2), joint='curve')
        for x, y in p:
            d.ellipse((x - r, y - r, x + r, y + r), fill=fill)

    shadow = Image.new('RGBA', (size, size), (0, 0, 0, 0))
    draw(shadow, (90, 0, 20, 140), off=(size * 0.012 * scale, size * 0.028 * scale))
    shadow = shadow.filter(ImageFilter.GaussianBlur(size * 0.025 * scale))
    layer = Image.alpha_composite(layer, shadow)
    draw(layer, (255, 255, 255, 255))
    return layer


def jj(size, cx, top, bottom):
    """왼쪽에 J 를 위 · 아래로 하나씩 (노란 굵은 글자 + 진한 테두리 + 그림자)"""
    layer = Image.new('RGBA', (size, size), (0, 0, 0, 0))
    h = (bottom - top) / 2
    font = ImageFont.truetype(FONT, int(h * 1.18))
    stroke = max(2, int(h * 0.09))
    shadow = Image.new('RGBA', (size, size), (0, 0, 0, 0))
    for i in range(2):
        d = ImageDraw.Draw(layer)
        l, t, r, b = d.textbbox((0, 0), 'J', font=font, stroke_width=stroke)
        x = cx - (l + r) / 2
        y = top + h * i + (h - (b - t)) / 2 - t
        ImageDraw.Draw(shadow).text((x + h * 0.04, y + h * 0.07), 'J', font=font, fill=(60, 0, 20, 150),
                                    stroke_width=stroke, stroke_fill=(60, 0, 20, 150))
        d.text((x, y), 'J', font=font, fill=YELLOW + (255,), stroke_width=stroke, stroke_fill=OUTLINE + (255,))
    shadow = shadow.filter(ImageFilter.GaussianBlur(h * 0.05))
    return Image.alpha_composite(shadow, layer)


def film_bands(size, top, band, holes=6):
    """위아래 필름 띠 (어두운 띠 + 흰 구멍)"""
    layer = Image.new('RGBA', (size, size), (0, 0, 0, 0))
    d = ImageDraw.Draw(layer)
    for y0 in (top, size - top - band):
        d.rectangle((0, y0, size, y0 + band), fill=FILM + (235,))
        hw, hh = size / (holes * 2.2), band * 0.46
        gap = size / holes
        for i in range(holes):
            cx = gap * (i + 0.5)
            cy = y0 + band / 2
            d.rounded_rectangle((cx - hw / 2, cy - hh / 2, cx + hw / 2, cy + hh / 2), radius=hh * 0.3,
                                fill=(255, 255, 255, 230))
    return layer


def make_master(small=False):
    """앱 아이콘 (둥근 사각형). small=True: 16~32px 용 (필름 띠 없이 재생 버튼을 크게)"""
    icon = Image.new('RGBA', (S, S), (0, 0, 0, 0))
    icon.paste(gradient(S), (0, 0), rounded_mask(S, int(S * 0.22)))
    if small:
        return Image.alpha_composite(icon, play(S, scale=1.25))
    bands = film_bands(S, top=int(S * 0.055), band=int(S * 0.13))
    icon = Image.alpha_composite(icon, Image.composite(bands, Image.new('RGBA', (S, S)), rounded_mask(S, int(S * 0.22))))
    # 왼쪽: J · J (위 · 아래), 재생 버튼은 오른쪽으로
    icon = Image.alpha_composite(icon, jj(S, cx=S * 0.19, top=S * 0.23, bottom=S * 0.77))
    return Image.alpha_composite(icon, play(S, scale=0.92, cx=0.6))


def make_adaptive():
    """Android 8 이상 (adaptive icon): 108dp 바탕 (그라데이션 + 필름 띠) · 앞 (재생 버튼, 안전 영역 66dp 안)"""
    bg = gradient(S).convert('RGBA')
    bg = Image.alpha_composite(bg, film_bands(S, top=int(S * 0.17), band=int(S * 0.1), holes=7))
    # 안전 영역 (가운데 66/108) 안에: 왼쪽 J · J, 오른쪽 재생 버튼
    fg = Image.alpha_composite(jj(S, cx=S * 0.335, top=S * 0.31, bottom=S * 0.69), play(S, scale=0.55, cx=0.57))
    return bg, fg


def main():
    master = make_master()
    out = ROOT / 'assets' / 'icon'
    out.mkdir(parents=True, exist_ok=True)
    master.save(out / 'app_icon_1024.png')
    master.resize((256, 256), Image.LANCZOS).save(out / 'app_icon_256.png')

    # 앱 안 왼쪽 위 홈 버튼 (26px 정도): 바탕 + 큰 노란 JJ 만 (작아도 또렷하게)
    button = Image.new('RGBA', (S, S), (0, 0, 0, 0))
    button.paste(gradient(S), (0, 0), rounded_mask(S, int(S * 0.22)))
    font = ImageFont.truetype(FONT, int(S * 0.62))
    d = ImageDraw.Draw(button)
    stroke = int(S * 0.035)
    l, t, r, b = d.textbbox((0, 0), 'JJ', font=font, stroke_width=stroke)
    d.text(((S - (r - l)) / 2 - l, (S - (b - t)) / 2 - t), 'JJ', font=font, fill=YELLOW + (255,),
           stroke_width=stroke, stroke_fill=OUTLINE + (255,))
    button.resize((256, 256), Image.LANCZOS).save(out / 'app_button_256.png')

    # 작은 크기 (16~32px) 는 단순 버전, 큰 크기는 필름 띠 포함 버전
    simple = make_master(small=True)
    simple.resize((256, 256), Image.LANCZOS).save(out / 'app_icon_small_256.png')

    def ico(path, sizes):
        imgs = [(simple if s <= 32 else master).resize((s, s), Image.LANCZOS) for s in sizes]
        imgs[-1].save(path, format='ICO', sizes=[(s, s) for s in sizes], append_images=imgs[:-1])

    ico(ROOT / 'windows' / 'runner' / 'resources' / 'app_icon.ico', [16, 20, 24, 32, 40, 48, 64, 128, 256])
    ico(ROOT / 'assets' / 'tray_icon.ico', [16, 20, 24, 32, 48])

    # Android: 예전 기기용 아이콘 + Android 8 이상 adaptive icon (기기마다 다른 모양 틀에 꽉 차게)
    res = ROOT / 'android' / 'app' / 'src' / 'main' / 'res'
    bg, fg = make_adaptive()
    for name, px in {'mdpi': 48, 'hdpi': 72, 'xhdpi': 96, 'xxhdpi': 144, 'xxxhdpi': 192}.items():
        d = res / f'mipmap-{name}'
        d.mkdir(parents=True, exist_ok=True)
        master.resize((px, px), Image.LANCZOS).save(d / 'ic_launcher.png')
        a = px * 108 // 48  # adaptive 는 108dp
        bg.resize((a, a), Image.LANCZOS).save(d / 'ic_launcher_background.png')
        fg.resize((a, a), Image.LANCZOS).save(d / 'ic_launcher_foreground.png')
    any_dpi = res / 'mipmap-anydpi-v26'
    any_dpi.mkdir(parents=True, exist_ok=True)
    (any_dpi / 'ic_launcher.xml').write_text(
        '<?xml version="1.0" encoding="utf-8"?>\n'
        '<adaptive-icon xmlns:android="http://schemas.android.com/apk/res/android">\n'
        '    <background android:drawable="@mipmap/ic_launcher_background"/>\n'
        '    <foreground android:drawable="@mipmap/ic_launcher_foreground"/>\n'
        '    <monochrome android:drawable="@mipmap/ic_launcher_foreground"/>\n'
        '</adaptive-icon>\n', encoding='utf-8')

    # 미리보기 (원형 마스크 · 둥근 사각형 마스크)
    prev = Image.new('RGBA', (S * 3 + 80, S + 40), (40, 40, 48, 255))
    prev.alpha_composite(master, (20, 20))
    full = Image.alpha_composite(bg, fg)
    crop = int(S * 18 / 108)
    view = full.crop((crop, crop, S - crop, S - crop)).resize((S, S), Image.LANCZOS)
    circle = Image.new('L', (S, S), 0)
    ImageDraw.Draw(circle).ellipse((0, 0, S, S), fill=255)
    prev.paste(view, (S + 40, 20), circle)
    prev.paste(view, (S * 2 + 60, 20), rounded_mask(S, int(S * 0.3)))
    prev.resize((prev.width // 4, prev.height // 4), Image.LANCZOS).save(out / 'preview.png')
    print('아이콘 생성 완료:', out / 'app_icon_1024.png')


if __name__ == '__main__':
    main()
