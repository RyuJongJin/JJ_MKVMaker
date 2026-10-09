/// 123 · 121: 기기 안 AI (그림 만들기 · 해상도 올리기) 에 받는 파일. 공식 배포처 주소와 SHA-256 을 고정한다.
/// 상업 사용이 막힌 라이선스 (CC-BY-NC 계열) 는 넣지 않는다.
class AiFile {
  final String id;
  final String name;
  final String url;
  final String sha256;
  final int size;

  /// 'model' 그림 모델 · 'lora' · 'taesd' 빠른 디코더 · 'engine' 실행 파일 (zip) · 'upscale' 해상도 올리기 모델 (Real-ESRGAN)
  final String kind;

  /// 라이선스 이름 · 주소 · 받기 전에 보여 줄 조건 (있으면)
  final String license;
  final String licenseUrl;
  final String? terms;
  /// 175: 라이선스 원문 (저작권 줄 · 허가 문구 그대로, assets/licenses) - 받기 화면 [원문] · 라이선스 화면
  final String? licenseAsset;

  /// 'windows' · 'android' (비어 있으면 모두)
  final List<String> platforms;

  /// 'nvidia' 그래픽카드가 있을 때만 받기 목록에 보인다
  final String? needs;

  const AiFile({
    required this.id,
    required this.name,
    required this.url,
    required this.sha256,
    required this.size,
    required this.kind,
    required this.license,
    required this.licenseUrl,
    this.terms,
    this.licenseAsset,
    this.platforms = const [],
    this.needs,
  });

  /// 받아 두는 파일 이름
  String get fileName => Uri.parse(url).pathSegments.last;
}

/// stable-diffusion.cpp 판 (Windows 실행 파일 · Android 빌드가 같은 판)
const sdCppVersion = 'master-948-228c707';
const _sdRel = 'https://github.com/leejet/stable-diffusion.cpp/releases/download/$sdCppVersion';

/// CreativeML OpenRAIL-M 의 사용 제한 (받기 화면 · 라이선스 화면에 보인다, 62)
const openRailTerms = 'Stable Diffusion v1.5 는 CreativeML OpenRAIL-M 라이선스입니다. 상업적 사용을 포함해 쓸 수 있지만, '
    '다음 용도로는 쓸 수 없습니다: 법을 어기는 일, 미성년자를 해치거나 이용하는 일, 남을 해치려는 거짓 정보, '
    '개인 정보로 사람을 해치는 일, 차별 · 괴롭힘, 의료 · 법률 판단을 대신하는 일 등 (라이선스 부속서 A). '
    '만든 그림에 대한 책임은 쓰는 사람에게 있습니다.';

const aiCatalog = <AiFile>[
  AiFile(
    id: 'sd15',
    name: 'Stable Diffusion v1.5',
    url: 'https://huggingface.co/stable-diffusion-v1-5/stable-diffusion-v1-5/resolve/main/v1-5-pruned-emaonly.safetensors',
    sha256: '6ce0161689b3853acaa03779ec93eafe75a02f4ced659bee03f50797806fa2fa',
    size: 4265146304,
    kind: 'model',
    license: 'CreativeML OpenRAIL-M',
    licenseUrl: 'https://github.com/CompVis/stable-diffusion/blob/main/LICENSE',
    licenseAsset: 'assets/licenses/CREATIVEML_OPENRAIL_M.txt',
    terms: openRailTerms,
  ),
  AiFile(
    id: 'lcm-lora-sd15',
    name: 'LCM-LoRA (SD1.5, 4단계로 빠르게)',
    url: 'https://huggingface.co/latent-consistency/lcm-lora-sdv1-5/resolve/main/pytorch_lora_weights.safetensors',
    sha256: '8f90d840e075ff588a58e22c6586e2ae9a6f7922996ee6649a7f01072333afe4',
    size: 134621556,
    kind: 'lora',
    license: 'OpenRAIL++',
    licenseUrl: 'https://huggingface.co/latent-consistency/lcm-lora-sdv1-5',
    licenseAsset: 'assets/licenses/CREATIVEML_OPENRAIL_PP_M.txt',
  ),
  AiFile(
    id: 'taesd',
    name: 'TAESD (빠른 디코더)',
    url: 'https://huggingface.co/madebyollin/taesd/resolve/main/diffusion_pytorch_model.safetensors',
    sha256: 'db169d69145ec4ff064e49d99c95fa05d3eb04ee453de35824a6d0f325513549',
    size: 9793292,
    kind: 'taesd',
    license: 'MIT',
    licenseUrl: 'https://huggingface.co/madebyollin/taesd',
    licenseAsset: 'assets/licenses/TAESD_LICENSE.txt',
  ),
  // 121: 해상도 올리기 (Real-ESRGAN, BSD-3 - 상업 사용 가능). stable-diffusion.cpp 가 읽는 RRDBNet 형식만
  AiFile(
    id: 'esrgan-anime6b',
    name: 'Real-ESRGAN x4plus anime 6B (만화 · 그림, 가볍고 빠름)',
    url: 'https://github.com/xinntao/Real-ESRGAN/releases/download/v0.2.2.4/RealESRGAN_x4plus_anime_6B.pth',
    sha256: 'f872d837d3c90ed2e05227bed711af5671a6fd1c9f7d7e91c911a61f155e99da',
    size: 17938799,
    kind: 'upscale',
    license: 'BSD-3-Clause',
    licenseUrl: 'https://github.com/xinntao/Real-ESRGAN/blob/master/LICENSE',
    licenseAsset: 'assets/licenses/REAL_ESRGAN_LICENSE.txt',
  ),
  AiFile(
    id: 'esrgan-x4plus',
    name: 'Real-ESRGAN x4plus (사진)',
    url: 'https://github.com/xinntao/Real-ESRGAN/releases/download/v0.1.0/RealESRGAN_x4plus.pth',
    sha256: '4fa0d38905f75ac06eb49a7951b426670021be3018265fd191d2125df9d682f1',
    size: 67040989,
    kind: 'upscale',
    license: 'BSD-3-Clause',
    licenseUrl: 'https://github.com/xinntao/Real-ESRGAN/blob/master/LICENSE',
    licenseAsset: 'assets/licenses/REAL_ESRGAN_LICENSE.txt',
  ),
  AiFile(
    id: 'engine-vulkan',
    name: 'stable-diffusion.cpp (Windows · CPU · Vulkan)',
    url: '$_sdRel/sd-master-228c707-bin-win-vulkan-x64.zip',
    sha256: '6de279c833a47ca5ede5fe16415dcf8a2a718ca3ececfbe024fc2f86c7728e89',
    size: 30098372,
    kind: 'engine',
    license: 'MIT',
    licenseUrl: 'https://github.com/leejet/stable-diffusion.cpp/blob/master/LICENSE',
    licenseAsset: 'assets/licenses/STABLE_DIFFUSION_CPP_LICENSES.txt',
    platforms: ['windows'],
  ),
  AiFile(
    id: 'engine-cuda',
    name: 'stable-diffusion.cpp (Windows · NVIDIA CUDA 12)',
    url: '$_sdRel/sd-master-228c707-bin-win-cuda12-x64.zip',
    sha256: '14e7a91053809b2c22a6259d5264d3696447828d2afaaa5a4280dbf41f472ba6',
    size: 337979057,
    kind: 'engine',
    license: 'MIT',
    licenseUrl: 'https://github.com/leejet/stable-diffusion.cpp/blob/master/LICENSE',
    licenseAsset: 'assets/licenses/STABLE_DIFFUSION_CPP_LICENSES.txt',
    platforms: ['windows'],
    needs: 'nvidia',
  ),
  AiFile(
    id: 'engine-cudart',
    name: 'NVIDIA CUDA 12 런타임 (CUDA 판과 함께)',
    url: '$_sdRel/cudart-sd-bin-win-cu12-x64.zip',
    sha256: 'fe20366827d357c00797eebb58244dddab7fd9a348d70090c3871004c320f38d',
    size: 563452046,
    kind: 'engine',
    license: 'NVIDIA CUDA Toolkit EULA (재배포 허용 파일)',
    licenseUrl: 'https://docs.nvidia.com/cuda/eula/index.html',
    platforms: ['windows'],
    needs: 'nvidia',
  ),
];

AiFile aiFile(String id) => aiCatalog.firstWhere((f) => f.id == id);

/// 그림 만들기 "SD1.5 + LCM" 에 꼭 필요한 파일 (TAESD 는 고를 수 있음)
const sd15LcmFiles = ['sd15', 'lcm-lora-sd15'];

/// stable-diffusion.cpp (sd-cli) 와 그 안에 함께 묶인 구성 요소 (ggml · libwebp · libwebm · Oniguruma 등) 의 원문
const sdCppLicenseAsset = 'assets/licenses/STABLE_DIFFUSION_CPP_LICENSES.txt';

/// 앱 안 라이선스 화면 (showLicensePage) 에 넣을 AI 구성 요소 (패키지 이름, 요약, 원문 asset)
List<(String, String, String?)> aiLicenseTexts() => [
      (
        'stable-diffusion.cpp',
        'MIT License - https://github.com/leejet/stable-diffusion.cpp ($sdCppVersion)\n\n'
            '함께 묶인 구성 요소: ggml (MIT) · libwebp · libwebm (BSD-3) · Oniguruma · Darts-clone (BSD-2) · utf8proc · '
            'nlohmann/json · miniz · stb (MIT) · zip (Unlicense)',
        sdCppLicenseAsset,
      ),
      for (final f in aiCatalog)
        if (f.kind != 'engine' || f.licenseAsset == null)
          (f.name, '${f.license} - ${f.licenseUrl}${f.terms == null ? '' : '\n\n${f.terms}'}', f.licenseAsset),
    ];

/// 121: 해상도 올리기 모델 (설정 'auto' · 'photo' · 'anime'). 자동은 폰이면 가볍고 빠른 만화용, PC 면 사진용 (x4plus)
String upscaleModelFor(String setting, {required bool phone}) => switch (setting) {
      'photo' => 'esrgan-x4plus',
      'anime' => 'esrgan-anime6b',
      _ => phone ? 'esrgan-anime6b' : 'esrgan-x4plus',
    };
