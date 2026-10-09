"""175: 네이티브 구성 요소 · 받는 AI 모델의 라이선스 원문을 상류에서 그 판 그대로 받아 assets/licenses 에 쓴다.

사용법 (app 폴더에서):  python tool/licenses/fetch_licenses.py
 - git · 인터넷이 필요하다. stable-diffusion.cpp 는 고정 커밋을 하위 모듈까지 받아 실제로 sd-cli 에 들어가는 것의 원문을 모은다.
 - stable-diffusion.cpp (lib/core/ai_catalog.dart 의 sdCppVersion · tool/build_sdcpp_android.sh 의 COMMIT) 나
   onnxruntime · whisper.cpp 판을 올리면 아래 판 번호를 같이 고치고 다시 돌린다. 그다음 flutter test test/licenses_test.dart.
 - 하위 모듈 판 (ggml · libwebp · libwebm) 과 함께 묶인 것 (thirdparty) 이 바뀌면 STABLE_DIFFUSION_CPP_LICENSES 의 목록도 확인한다.
"""
import os
import re
import subprocess
import sys
import tempfile
import urllib.request

# ---- 판 (올릴 때 여기를 고친다) ----
SD_COMMIT = '228c707fde018221de74674f1c2f480a9d2b228e'
SD_VERSION = 'master-948-228c707'
ORT_VERSION = '1.15.1'  # onnxruntime (pub 1.4.1 이 묶은 dll · so)
WHISPER_VERSION = 'v1.9.1'  # packages/whisper_ggml 에 넣어 둔 whisper.cpp
JSON_VERSION = 'v3.11.2'  # sd.cpp thirdparty/json.hpp
ZIP_UNLICENSE_COMMIT = 'e5f376e4ee'  # sd.cpp 의 zip.c 는 Unlicense 시절 판 (지금 kuba--/zip 은 MIT)
ESRGAN_TAG = 'v0.3.0'

APP = os.path.abspath(os.path.join(os.path.dirname(__file__), '..', '..'))
OUT = os.path.join(APP, 'assets', 'licenses')
WH = os.path.join(APP, 'packages', 'whisper_ggml', 'android', 'src', 'whisper', 'whisper.cpp', 'LICENSE')
BAR = '=' * 78


def norm(t):
    return t.replace('\r\n', '\n').strip('\n') + '\n'


def rd(*p):
    with open(os.path.join(*p), encoding='utf-8', errors='replace') as f:
        return norm(f.read())


def get(url):
    req = urllib.request.Request(url, headers={'User-Agent': 'jj_mkvmaker-licenses'})
    with urllib.request.urlopen(req, timeout=60) as r:
        return norm(r.read().decode('utf-8', errors='replace'))


def sec(title, src, text):
    # 빈 줄로 나눈다 (앱 라이선스 화면은 한 줄 바꿈을 한 문단으로 이어 붙인다)
    return f'{BAR}\n\n{title}\n\n출처: {src}\n\n{BAR}\n\n{text}\n'


def wr(name, head, parts):
    path = os.path.join(OUT, name)
    with open(path, 'w', encoding='utf-8', newline='\n') as f:
        f.write(head.replace('\n', '\n\n') + '\n' + '\n'.join(parts))
    print(name, os.path.getsize(path))


def git(*args, cwd=None):
    subprocess.run(['git', *args], cwd=cwd, check=True)


def fetch_sdcpp(work):
    src = os.path.join(work, 'sdcpp')
    git('init', '-q', src)
    git('remote', 'add', 'origin', 'https://github.com/leejet/stable-diffusion.cpp.git', cwd=src)
    git('fetch', '-q', '--depth', '1', 'origin', SD_COMMIT, cwd=src)
    git('checkout', '-q', 'FETCH_HEAD', cwd=src)
    git('submodule', 'update', '-q', '--init', '--depth', '1', cwd=src)
    subs = subprocess.run(['git', 'submodule', 'status'], cwd=src, check=True, capture_output=True, text=True).stdout
    sha = {m.group(2): m.group(1) for m in re.finditer(r'^.?([0-9a-f]{40}) (\S+)', subs, re.M)}
    return src, sha


def main():
    with tempfile.TemporaryDirectory() as work:
        sd, sub = fetch_sdcpp(work)
        ggml, webp, webm = sub['ggml'], sub['thirdparty/libwebp'][:7], sub['thirdparty/libwebm'][:7]
        tp = os.path.join(sd, 'thirdparty')
        stb_all = rd(tp, 'stb_image.h')
        i = stb_all.index('This software is available under 2 licenses')
        stb = stb_all[i:stb_all.index('\n*/', i)].rstrip('-\n') + '\n'
        miniz_all = rd(tp, 'miniz.h')
        i = miniz_all.index('Copyright 2013-2014 RAD Game Tools')
        miniz = re.sub(r'(?m)^ \* ?', '', miniz_all[i:miniz_all.index('THE SOFTWARE.\n', i) + len('THE SOFTWARE.\n')])
        onig_ver = re.search(r'PACKAGE_VERSION (\S+)\)', rd(tp, 'CMakeLists.txt')).group(1)

        wr('STABLE_DIFFUSION_CPP_LICENSES.txt',
           'stable-diffusion.cpp (sd-cli) 와 그 안에 함께 묶인 구성 요소의 라이선스 원문\n'
           'Android 앱에 들어간 sd-cli (tool/build_sdcpp_android.sh 로 빌드) 와 Windows 에서 받는 실행 파일 (같은 판) 에 해당\n'
           f'판: stable-diffusion.cpp {SD_VERSION} (커밋 {SD_COMMIT}), ggml {ggml[:7]}\n', [
            sec('stable-diffusion.cpp - MIT License', f'https://github.com/leejet/stable-diffusion.cpp/blob/{SD_COMMIT}/LICENSE', rd(sd, 'LICENSE')),
            sec('ggml - MIT License', f'https://github.com/ggml-org/ggml/blob/{ggml}/LICENSE', rd(sd, 'ggml', 'LICENSE')),
            sec('libwebp - BSD 3-Clause License', f'stable-diffusion.cpp/thirdparty/libwebp/COPYING ({webp})', rd(tp, 'libwebp', 'COPYING')),
            sec('libwebp - Additional IP Rights Grant (Patents)', f'stable-diffusion.cpp/thirdparty/libwebp/PATENTS ({webp})', rd(tp, 'libwebp', 'PATENTS')),
            sec('libwebm - BSD 3-Clause License', f'stable-diffusion.cpp/thirdparty/libwebm/LICENSE.TXT ({webm})', rd(tp, 'libwebm', 'LICENSE.TXT')),
            sec('libwebm - Additional IP Rights Grant (Patents)', f'stable-diffusion.cpp/thirdparty/libwebm/PATENTS.TXT ({webm})', rd(tp, 'libwebm', 'PATENTS.TXT')),
            sec(f'Oniguruma {onig_ver} - BSD 2-Clause License', 'stable-diffusion.cpp/thirdparty/oniguruma/COPYING', rd(tp, 'oniguruma', 'COPYING')),
            sec('utf8proc - MIT License (+ Unicode data license)', 'stable-diffusion.cpp/thirdparty/utf8proc/LICENSE.md', rd(tp, 'utf8proc', 'LICENSE.md')),
            sec('Darts-clone - BSD 2-Clause License', 'stable-diffusion.cpp/thirdparty/LICENSE.darts_clone.txt', rd(tp, 'LICENSE.darts_clone.txt')),
            sec(f'JSON for Modern C++ {JSON_VERSION[1:]} (nlohmann/json) - MIT License', f'https://github.com/nlohmann/json/blob/{JSON_VERSION}/LICENSE.MIT',
                get(f'https://raw.githubusercontent.com/nlohmann/json/{JSON_VERSION}/LICENSE.MIT')),
            sec('miniz 2.2.0 - MIT License', 'stable-diffusion.cpp/thirdparty/miniz.h', miniz),
            sec('zip (kuba--/zip) - The Unlicense', f'https://github.com/kuba--/zip/blob/{ZIP_UNLICENSE_COMMIT}/UNLICENSE',
                get(f'https://raw.githubusercontent.com/kuba--/zip/{ZIP_UNLICENSE_COMMIT}/UNLICENSE')),
            sec('stb_image · stb_image_write · stb_image_resize (Sean Barrett) - MIT License 또는 Public Domain', 'stable-diffusion.cpp/thirdparty/stb_image.h', stb),
        ])

    wr('WHISPER_CPP_LICENSE.txt',
       f'whisper.cpp {WHISPER_VERSION} (ggml 포함) - 자막 받아쓰기 (whisper_ggml 안에 함께 빌드, Windows · Android)\n', [
        sec('whisper.cpp / ggml - MIT License', f'https://github.com/ggml-org/whisper.cpp/blob/{WHISPER_VERSION}/LICENSE', rd(WH)),
    ])

    ort = f'https://raw.githubusercontent.com/microsoft/onnxruntime/v{ORT_VERSION}'
    wr('ONNXRUNTIME_LICENSES.txt',
       f'ONNX Runtime {ORT_VERSION} (Microsoft) - onnxruntime.dll (Windows) · libonnxruntime.so (Android)\n', [
        sec('ONNX Runtime - MIT License', f'https://github.com/microsoft/onnxruntime/blob/v{ORT_VERSION}/LICENSE', get(f'{ort}/LICENSE')),
        sec('ONNX Runtime - Third Party Notices', f'https://github.com/microsoft/onnxruntime/blob/v{ORT_VERSION}/ThirdPartyNotices.txt',
            get(f'{ort}/ThirdPartyNotices.txt')),
    ])

    # Hugging Face 의 stable-diffusion-v1-5 사본 저장소에는 LICENSE 파일이 없어 원래 저장소 (CompVis) 의 원문
    wr('CREATIVEML_OPENRAIL_M.txt',
       'Stable Diffusion v1.5 모델 (실행 중에 받음) - CreativeML Open RAIL-M (용도 제한 Attachment A 포함)\n', [
        sec('CreativeML Open RAIL-M', 'https://github.com/CompVis/stable-diffusion/blob/main/LICENSE (Hugging Face 모델 카드의 license: creativeml-openrail-m)',
            get('https://raw.githubusercontent.com/CompVis/stable-diffusion/main/LICENSE')),
    ])

    wr('CREATIVEML_OPENRAIL_PP_M.txt',
       'LCM-LoRA (SD1.5) 모델 (실행 중에 받음) - 모델 카드의 license: openrail++\n'
       'latent-consistency/lcm-lora-sdv1-5 저장소에는 따로 라이선스 파일이 없어, CreativeML Open RAIL++-M 원문을 싣는다.\n', [
        sec('CreativeML Open RAIL++-M', 'https://huggingface.co/stabilityai/stable-diffusion-xl-base-1.0/blob/main/LICENSE.md',
            get('https://huggingface.co/stabilityai/stable-diffusion-xl-base-1.0/resolve/main/LICENSE.md')),
    ])

    wr('TAESD_LICENSE.txt', 'TAESD (빠른 디코더) 모델 (실행 중에 받음)\n', [
        sec('TAESD - MIT License', 'https://github.com/madebyollin/taesd/blob/main/LICENSE',
            get('https://raw.githubusercontent.com/madebyollin/taesd/main/LICENSE')),
    ])

    wr('WHISPER_MODEL_LICENSE.txt', 'Whisper 모델 (ggml-base.bin 등, 처음 쓸 때 받음 - 자막 받아쓰기)\n', [
        sec('OpenAI Whisper - MIT License', 'https://github.com/openai/whisper/blob/main/LICENSE',
            get('https://raw.githubusercontent.com/openai/whisper/main/LICENSE')),
    ])

    wr('REAL_ESRGAN_LICENSE.txt', 'Real-ESRGAN x4plus · x4plus anime 6B 모델 (실행 중에 받음, 해상도 올리기)\n', [
        sec('Real-ESRGAN - BSD 3-Clause License', f'https://github.com/xinntao/Real-ESRGAN/blob/{ESRGAN_TAG}/LICENSE',
            get(f'https://raw.githubusercontent.com/xinntao/Real-ESRGAN/{ESRGAN_TAG}/LICENSE')),
    ])

    wr('NLLB_CC_BY_NC_4.0.txt',
       'NLLB-200 distilled 600M 번역 모델 (처음 쓸 때 받음 - AI 자막 번역 · 화면 언어 더하기)\n'
       '※ 비상업적 이용만 허용됩니다 (CC BY-NC 4.0). 판매 · 유료 서비스에는 쓸 수 없습니다.\n'
       '모델: Meta AI, NLLB-200 (https://huggingface.co/facebook/nllb-200-distilled-600M, license: cc-by-nc-4.0)\n'
       'ONNX 변환본: https://huggingface.co/Xenova/nllb-200-distilled-600M\n', [
        sec('Creative Commons Attribution-NonCommercial 4.0 International (CC BY-NC 4.0)',
            'https://creativecommons.org/licenses/by-nc/4.0/legalcode.txt',
            get('https://creativecommons.org/licenses/by-nc/4.0/legalcode.txt')),
    ])


if __name__ == '__main__':
    sys.exit(main())
