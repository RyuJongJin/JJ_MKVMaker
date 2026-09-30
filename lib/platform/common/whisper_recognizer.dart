import 'dart:io';
import 'dart:math' as math;

import 'package:whisper_ggml/whisper_ggml.dart';

import '../../core/srt.dart';
import '../../services/ai_services.dart';

/// whisper.cpp 음성인식. Windows·Android 공용.
class WhisperRecognizer implements SpeechRecognizer {
  @override
  Future<List<Cue>> transcribe(
    String wavPath, {
    required String modelPath,
    String language = 'auto',
    AiProgress? onProgress,
  }) async {
    // 실제 코어 수 (하이퍼스레딩 절반) 가 가장 빠름
    final threads = math.max(1, math.min(8, Platform.numberOfProcessors ~/ 2));
    final res = await const Whisper(model: WhisperModel.base).transcribe(
      transcribeRequest: TranscribeRequest(
        audio: wavPath,
        language: language,
        threads: threads,
        suppressNonSpeechTokens: true,
      ),
      modelPath: modelPath,
      onProgress: onProgress == null ? null : (pct) => onProgress(pct / 100),
    );
    return [
      for (final s in res.segments ?? const <WhisperTranscribeSegment>[])
        Cue(s.fromTs, s.toTs, s.text),
    ];
  }
}
