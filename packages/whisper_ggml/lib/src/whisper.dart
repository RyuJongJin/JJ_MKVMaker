import 'dart:convert';
import 'dart:ffi';
import 'dart:isolate';

import 'package:ffi/ffi.dart';
import 'package:flutter/foundation.dart';
import 'package:universal_io/io.dart';
import 'package:whisper_ggml/src/models/whisper_model.dart';
import 'package:whisper_ggml/src/whisper_audio_convert.dart';

import 'models/requests/release_model_request.dart';
import 'models/requests/transcribe_request.dart';
import 'models/requests/transcribe_request_dto.dart';
import 'models/requests/version_request.dart';
import 'models/responses/whisper_transcribe_response.dart';
import 'models/responses/whisper_version_response.dart';
import 'models/whisper_dto.dart';

export 'models/_models.dart';
export 'whisper_audio_convert.dart';

/// Native request type
typedef WReqNative = Pointer<Utf8> Function(Pointer<Utf8> body);

/// Entry point
class Whisper {
  /// [model] is required
  /// [modelDir] is path where downloaded model will be stored.
  /// Default to library directory
  const Whisper({required this.model, this.modelDir});

  /// model used for transcription
  final WhisperModel model;

  /// override of model storage path
  final String? modelDir;

  /// JJ_MKVMaker 패치: 네이티브가 malloc 으로 만든 응답을 네이티브 free 로 해제한다.
  static void freeNativeResponse(DynamicLibrary lib, Pointer<Utf8> res) =>
      lib.lookupFunction<Void Function(Pointer<Utf8>), void Function(Pointer<Utf8>)>(
          'free_response')(res);

  DynamicLibrary _openLib() {
    if (Platform.isAndroid) {
      return DynamicLibrary.open('libwhisper.so');
    } else if (Platform.isWindows) {
      return DynamicLibrary.open('whisper_ggml.dll');
    } else if (Platform.isLinux) {
      return DynamicLibrary.open('libwhisper_ggml.so');
    } else {
      return DynamicLibrary.process();
    }
  }

  Future<Map<String, dynamic>> _request({
    required WhisperRequestDto whisperRequest,
    Map<String, Object?>? extra,
  }) async {
    return Isolate.run(() async {
      final Pointer<Utf8> data =
          (extra == null
                  ? whisperRequest.toRequestString()
                  : json.encode({
                      ...json.decode(whisperRequest.toRequestString()) as Map<String, dynamic>,
                      ...extra,
                    }))
              .toNativeUtf8();
      final DynamicLibrary lib = _openLib();
      final Pointer<Utf8> res =
          lib.lookupFunction<WReqNative, WReqNative>('request').call(data);

      final Map<String, dynamic> result =
          json.decode(res.toDartString()) as Map<String, dynamic>;

      malloc.free(data);
      // JJ_MKVMaker 패치: 네이티브 C 런타임으로 해제 (Windows 힙 손상 방지)
      freeNativeResponse(lib, res);
      return result;
    });
  }

  /// Transcribe audio file to text
  ///
  /// [onProgress] is invoked with whisper.cpp's transcription progress
  /// (0–100, coarse steps) while inference runs.
  Future<WhisperTranscribeResponse> transcribe({
    required TranscribeRequest transcribeRequest,
    required String modelPath,
    void Function(int percent)? onProgress,
    // JJ: address of an int32 flag; set it to non-zero to stop recognition early
    int? abortFlagAddress,
  }) async {
    // A listener callable may be invoked from whisper's worker thread;
    // it delivers to this isolate. Kept open until the request finishes.
    final NativeCallable<Void Function(Int32)>? progressCallable =
        onProgress == null
            ? null
            : NativeCallable<Void Function(Int32)>.listener(onProgress);
    try {
      final WhisperAudioConvert converter = WhisperAudioConvert(
        audioInput: File(transcribeRequest.audio),
        audioOutput: File('${transcribeRequest.audio}.wav'),
      );

      final File? convertedFile = await converter.convert();

      final TranscribeRequest req = transcribeRequest.copyWith(
        audio: convertedFile?.path ?? transcribeRequest.audio,
      );

      final Map<String, dynamic> result = await _request(
        whisperRequest: TranscribeRequestDto.fromTranscribeRequest(
          req,
          modelPath,
          progressCallbackAddress: progressCallable?.nativeFunction.address,
        ),
        extra: abortFlagAddress == null ? null : {'abort_flag': abortFlagAddress},
      );

      if (result['text'] == null) {
        throw Exception(result['message']);
      }
      return WhisperTranscribeResponse.fromJson(result);
    } catch (e) {
      debugPrint(e.toString());
      rethrow;
    } finally {
      progressCallable?.close();
    }
  }

  /// Free the model parked in native memory by a transcription with
  /// `keepModelLoaded: true`. Safe to call when nothing is parked.
  ///
  /// A transcription still in flight keeps its model until it completes;
  /// one that was started with `keepModelLoaded: true` parks the model
  /// again when it finishes.
  Future<void> releaseModel() async {
    final Map<String, dynamic> result = await _request(
      whisperRequest: const ReleaseModelRequest(),
    );
    if (result['@type'] == 'error') {
      throw Exception(result['message']);
    }
  }

  /// Get whisper version
  Future<String?> getVersion() async {
    final Map<String, dynamic> result = await _request(
      whisperRequest: const VersionRequest(),
    );

    final WhisperVersionResponse response = WhisperVersionResponse.fromJson(
      result,
    );
    return response.message;
  }
}
