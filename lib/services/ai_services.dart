import '../core/srt.dart';

/// 진행률 (0.0 ~ 1.0)
typedef AiProgress = void Function(double progress);

class AiCancelled implements Exception {
  const AiCancelled();
  @override
  String toString() => '사용자가 취소했습니다.';
}

/// 음성인식 경계. 구현: platform/common/whisper_recognizer.dart (Windows·Android 공용)
abstract class SpeechRecognizer {
  /// 16kHz 모노 WAV → 자막 줄. [language] 는 Whisper 코드 (ko, en, ja …) 또는 'auto'.
  Future<List<Cue>> transcribe(
    String wavPath, {
    required String modelPath,
    String language = 'auto',
    AiProgress? onProgress,
  });
}

/// 번역 경계. 구현: platform/common/nllb_translator.dart (Windows·Android 공용)
abstract class Translator {
  /// 모델 불러오기 (처음 한 번, 수 초 걸림)
  Future<void> load(String modelDir);

  /// 여러 줄 번역. 언어는 NLLB 코드 (kor_Hang, eng_Latn …).
  Future<List<String>> translate(
    List<String> lines, {
    required String source,
    required String target,
    AiProgress? onProgress,
  });

  void cancel();

  Future<void> dispose();
}
