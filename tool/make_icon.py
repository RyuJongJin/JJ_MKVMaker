"""JJ_MKVMaker 아이콘 만들기 (1024px 원본 → .ico / .png)

사용법: python tool/make_icon.py
결과:   assets/icon/app_icon_1024.png, windows/runner/resources/app_icon.ico,
        assets/tray_icon.ico, android/app/src/main/res/mipmap-*/ic_launcher.png
"""
from pathlib import Path

from PIL import Image, ImageDraw, ImageFilter, ImageFont

ROOT = Path(__file__).resolve().parent.parent
S = 1024  # 원본 크기
FONT = 'C:/Windows/Fonts/seguibl.ttf'  # Segoe UI Black

TEAL = (0, 196, 204)
VIOLET = (108, 92, 255)


def lerp(a, b, t):
    return tuple(round(a[i] + (b[i] - a[i]) * t) for i in range(3))


def rounded_mask(size, radius):
    m = Image.new('L', (size, size), 0)
    ImageDraw.Draw(m).rounded_rectangle((0, 0, size - 1, size - 1), radius=radius, fill=255)
    return m


def make_master(small=False):
    """small=True: 16~32px 용 단순 버전 (재생 표시 없이 JJ 를 크게)"""
    # 대각선 그라데이션 (왼쪽 위 청록 → 오른쪽 아래 보라)
    grad = Image.new('RGB', (S, S))
    px = grad.load()
    for y in range(S):
        for x in range(S):
            px[x, y] = lerp(TEAL, VIOLET, (x + y) / (2 * (S - 1)))

    # 왼쪽 위에 아주 은은한 빛 (경계가 보이지 않게 크게 흐림)
    glow = Image.new('L', (S, S), 0)
    ImageDraw.Draw(glow).ellipse((-S * 0.5, -S * 0.6, S * 0.9, S * 0.5), fill=38)
    glow = glow.filter(ImageFilter.GaussianBlur(S * 0.16))
    grad = Image.composite(Image.new('RGB', (S, S), (255, 255, 255)), grad, glow)

    icon = Image.new('RGBA', (S, S), (0, 0, 0, 0))
    icon.paste(grad, (0, 0), rounded_mask(S, int(S * 0.23)))

    # "JJ" (그림자 + 흰 글자)
    font = ImageFont.truetype(FONT, int(S * (0.66 if small else 0.56)))
    text = 'JJ'
    d = ImageDraw.Draw(icon)
    l, t, r, b = d.textbbox((0, 0), text, font=font)
    x = (S - (r - l)) / 2 - l - (0 if small else S * 0.035)
    y = (S - (b - t)) / 2 - t - (0 if small else S * 0.02)

    shadow = Image.new('RGBA', (S, S), (0, 0, 0, 0))
    ImageDraw.Draw(shadow).text((x + S * 0.012, y + S * 0.022), text, font=font, fill=(20, 10, 60, 120))
    shadow = shadow.filter(ImageFilter.GaussianBlur(S * 0.018))
    icon = Image.alpha_composite(icon, shadow)
    ImageDraw.Draw(icon).text((x, y), text, font=font, fill=(255, 255, 255, 255))
    if small:
        return icon

    # 오른쪽 아래 재생(▶) 표시: 흰 원 + 보라 삼각형
    cx, cy, rad = S * 0.765, S * 0.765, S * 0.135
    badge = Image.new('RGBA', (S, S), (0, 0, 0, 0))
    bd = ImageDraw.Draw(badge)
    bd.ellipse((cx - rad * 1.12, cy - rad * 1.12, cx + rad * 1.12, cy + rad * 1.12), fill=(40, 20, 110, 90))
    badge = badge.filter(ImageFilter.GaussianBlur(S * 0.012))
    bd = ImageDraw.Draw(badge)
    bd.ellipse((cx - rad, cy - rad, cx + rad, cy + rad), fill=(255, 255, 255, 255))
    tri = rad * 0.52
    bd.polygon([(cx - tri * 0.62, cy - tri), (cx - tri * 0.62, cy + tri), (cx + tri * 0.95, cy)], fill=VIOLET + (255,))
    return Image.alpha_composite(icon, badge)


def main():
    master = make_master()
    out = ROOT / 'assets' / 'icon'
    out.mkdir(parents=True, exist_ok=True)
    master.save(out / 'app_icon_1024.png')
    master.resize((256, 256), Image.LANCZOS).save(out / 'app_icon_256.png')

    # 작은 크기 (16~32px) 는 단순 버전, 큰 크기는 재생 표시 포함 버전
    simple = make_master(small=True)
    simple.resize((256, 256), Image.LANCZOS).save(out / 'app_icon_small_256.png')

    def ico(path, sizes):
        imgs = [(simple if s <= 32 else master).resize((s, s), Image.LANCZOS) for s in sizes]
        imgs[-1].save(path, format='ICO', sizes=[(s, s) for s in sizes], append_images=imgs[:-1])

    ico(ROOT / 'windows' / 'runner' / 'resources' / 'app_icon.ico', [16, 20, 24, 32, 40, 48, 64, 128, 256])
    ico(ROOT / 'assets' / 'tray_icon.ico', [16, 20, 24, 32, 48])

    # Android 앱 아이콘 (이식 대비)
    for name, px in {'mdpi': 48, 'hdpi': 72, 'xhdpi': 96, 'xxhdpi': 144, 'xxxhdpi': 192}.items():
        d = ROOT / 'android' / 'app' / 'src' / 'main' / 'res' / f'mipmap-{name}'
        if d.exists():
            master.resize((px, px), Image.LANCZOS).save(d / 'ic_launcher.png')
    print('아이콘 생성 완료:', out / 'app_icon_1024.png')


if __name__ == '__main__':
    main()
