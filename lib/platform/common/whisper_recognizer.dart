import 'dart:ffi' as ffi;
import 'dart:io';
import 'dart:math' as math;

import 'package:ffi/ffi.dart';
import 'package:whisper_ggml/whisper_ggml.dart';

import '../../core/srt.dart';
import '../../services/ai_services.dart';

/// whisper.cpp 음성인식. Windows·Android 공용.
class WhisperRecognizer implements SpeechRecognizer {
  /// 지금 음성인식의 중단 신호 (네이티브가 읽는 int32). 0 이 아니면 멈춘다.
  ffi.Pointer<ffi.Int32>? _abort;

  @override
  void cancel() {
    final a = _abort;
    if (a != null) a.value = 1;
  }

  @override
  Future<List<Cue>> transcribe(
    String wavPath, {
    required String modelPath,
    String language = 'auto',
    AiProgress? onProgress,
  }) async {
    // 실제 코어 수 (하이퍼스레딩 절반) 가 가장 빠름
    final threads = math.max(1, math.min(8, Platform.numberOfProcessors ~/ 2));
    final abort = _abort = calloc<ffi.Int32>();
    try {
      final res = await const Whisper(model: WhisperModel.base).transcribe(
        transcribeRequest: TranscribeRequest(
          audio: wavPath,
          language: language,
          threads: threads,
          suppressNonSpeechTokens: true,
        ),
        modelPath: modelPath,
        onProgress: onProgress == null ? null : (pct) => onProgress(pct / 100),
        abortFlagAddress: abort.address,
      );
      if (abort.value != 0) throw const AiCancelled();
      return [
        for (final s in res.segments ?? const <WhisperTranscribeSegment>[])
          Cue(s.fromTs, s.toTs, s.text),
      ];
    } catch (e) {
      // 취소로 멈춘 것이면 "취소" 로 (네이티브는 "failed to process audio" 오류를 낸다)
      if (abort.value != 0) throw const AiCancelled();
      rethrow;
    } finally {
      _abort = null;
      calloc.free(abort);
    }
  }
}
