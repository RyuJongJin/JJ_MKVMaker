import 'dart:async';
import 'dart:ffi' as ffi;
import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:onnxruntime/onnxruntime.dart';
import 'package:path/path.dart' as p;

import '../../core/nllb_tokenizer.dart';
import '../../services/ai_services.dart';
import 'ort_tensors.dart';

/// NLLB-200 (ONNX, int8) 로컬 번역기. Windows·Android 공용.
///
/// 모델 폴더 구성: tokenizer.json, encoder_model_quantized.onnx, decoder_model_merged_quantized.onnx
/// 추론은 별도 isolate 에서 실행하므로 화면이 멈추지 않는다.
class NllbTranslator implements Translator {
  static const files = [
    'tokenizer.json',
    'encoder_model_quantized.onnx',
    'decoder_model_merged_quantized.onnx',
  ];

  /// 한 번에 번역할 줄 수
  final int batchSize;

  NllbTranslator({this.batchSize = 8});

  Isolate? _isolate;
  SendPort? _toWorker;
  ReceivePort? _fromWorker;
  final _pending = <int, _Job>{};
  int _nextId = 0;

  /// 취소 표시 (두 isolate 가 같은 네이티브 메모리를 봄)
  final ffi.Pointer<ffi.Int32> _cancelFlag = calloc<ffi.Int32>();

  @override
  Future<void> load(String modelDir) async {
    if (_isolate != null) return;
    for (final f in files) {
      if (!File(p.join(modelDir, f)).existsSync()) {
        throw FileSystemException('번역 모델 파일이 없습니다', p.join(modelDir, f));
      }
    }
    final ready = Completer<void>();
    final rp = ReceivePort();
    _fromWorker = rp;
    rp.listen((msg) {
      final m = msg as Map;
      switch (m['type']) {
        case 'port':
          _toWorker = m['port'] as SendPort;
        case 'ready':
          ready.complete();
        case 'fatal':
          if (!ready.isCompleted) ready.completeError(StateError('${m['error']}'));
        case 'progress':
          _pending[m['id']]?.onProgress?.call(m['value'] as double);
        case 'result':
          _pending.remove(m['id'])?.done.complete((m['lines'] as List).cast<String>());
        case 'error':
          final job = _pending.remove(m['id']);
          if (m['cancelled'] == true) {
            job?.done.completeError(const AiCancelled());
          } else {
            job?.done.completeError(StateError('${m['error']}'));
          }
      }
    });
    final threads = math.max(1, Platform.numberOfProcessors ~/ 2);
    _isolate = await Isolate.spawn(
      _workerMain,
      [rp.sendPort, modelDir, threads, _cancelFlag.address, batchSize],
      debugName: 'nllb',
    );
    try {
      await ready.future;
    } catch (_) {
      await dispose();
      rethrow;
    }
  }

  @override
  Future<List<String>> translate(
    List<String> lines, {
    required String source,
    required String target,
    AiProgress? onProgress,
  }) {
    final port = _toWorker;
    if (port == null) throw StateError('번역 모델을 먼저 불러와야 합니다.');
    _cancelFlag.value = 0;
    final id = _nextId++;
    final job = _Job(onProgress);
    _pending[id] = job;
    port.send({'id': id, 'lines': lines, 'src': source, 'tgt': target});
    return job.done.future;
  }

  @override
  void cancel() => _cancelFlag.value = 1;

  @override
  Future<void> dispose() async {
    final port = _toWorker;
    if (port != null) {
      final exited = ReceivePort();
      _isolate?.addOnExitListener(exited.sendPort);
      port.send({'type': 'close'});
      await exited.first.timeout(const Duration(seconds: 10), onTimeout: () => null);
      exited.close();
    }
    _isolate?.kill();
    _isolate = null;
    _toWorker = null;
    _fromWorker?.close();
    _fromWorker = null;
    for (final j in _pending.values) {
      j.done.completeError(const AiCancelled());
    }
    _pending.clear();
  }
}

class _Job {
  final AiProgress? onProgress;
  final done = Completer<List<String>>();
  _Job(this.onProgress);
}

// ───────── 작업 isolate ─────────

void _workerMain(List<Object?> args) {
  final main = args[0] as SendPort;
  final modelDir = args[1] as String;
  final threads = args[2] as int;
  final cancel = ffi.Pointer<ffi.Int32>.fromAddress(args[3] as int);
  final batch = args[4] as int;

  final inbox = ReceivePort();
  main.send({'type': 'port', 'port': inbox.sendPort});

  _NllbEngine engine;
  try {
    engine = _NllbEngine.load(modelDir, threads);
  } catch (e) {
    main.send({'type': 'fatal', 'error': '$e'});
    inbox.close();
    return;
  }
  main.send({'type': 'ready'});

  inbox.listen((msg) {
    final m = msg as Map;
    if (m['type'] == 'close') {
      engine.release();
      inbox.close();
      Isolate.exit();
    }
    final id = m['id'] as int;
    final lines = (m['lines'] as List).cast<String>();
    try {
      final out = <String>[];
      for (var i = 0; i < lines.length; i += batch) {
        if (cancel.value != 0) {
          main.send({'type': 'error', 'id': id, 'cancelled': true});
          return;
        }
        final chunk = lines.sublist(i, math.min(i + batch, lines.length));
        out.addAll(engine.translateBatch(chunk, m['src'] as String, m['tgt'] as String));
        main.send({'type': 'progress', 'id': id, 'value': out.length / lines.length});
      }
      main.send({'type': 'result', 'id': id, 'lines': out});
    } catch (e) {
      main.send({'type': 'error', 'id': id, 'error': '$e'});
    }
  });
}

class _NllbEngine {
  static const _layers = 12, _heads = 16, _headDim = 64;

  final NllbTokenizer tok;
  final OrtSession encoder;
  final OrtSession decoder;
  final OrtRunOptions runOptions = OrtRunOptions();
  late final Map<String, int> _outIndex = {
    for (var i = 0; i < decoder.outputNames.length; i++) decoder.outputNames[i]: i,
  };

  _NllbEngine(this.tok, this.encoder, this.decoder);

  factory _NllbEngine.load(String dir, int threads) {
    OrtEnv.instance.init();
    final tok = NllbTokenizer.fromJson(
        File(p.join(dir, 'tokenizer.json')).readAsStringSync());
    return _NllbEngine(
      tok,
      openSession(p.join(dir, 'encoder_model_quantized.onnx'), threads: threads),
      openSession(p.join(dir, 'decoder_model_merged_quantized.onnx'), threads: threads),
    );
  }

  void release() {
    runOptions.release();
    encoder.release();
    decoder.release();
    OrtEnv.instance.release();
  }

  /// 여러 줄을 한 번에 번역 (탐욕적 디코딩 + KV 캐시)
  List<String> translateBatch(List<String> lines, String src, String tgt) {
    final result = List<String>.filled(lines.length, '');
    // 빈 줄은 건너뜀
    final idx = [for (var i = 0; i < lines.length; i++) if (lines[i].trim().isNotEmpty) i];
    if (idx.isEmpty) return result;

    final encoded = [for (final i in idx) tok.encode(lines[i], src)];
    final b = encoded.length;
    final encLen = encoded.map((e) => e.length).reduce(math.max);
    final ids = <int>[], mask = <int>[];
    for (final e in encoded) {
      ids.addAll(e);
      mask.addAll(List.filled(e.length, 1));
      ids.addAll(List.filled(encLen - e.length, NllbTokenizer.padId));
      mask.addAll(List.filled(encLen - e.length, 0));
    }

    final inIds = int64Tensor(ids, [b, encLen]);
    final inMask = int64Tensor(mask, [b, encLen]);
    final encOut = encoder.run(runOptions, {'input_ids': inIds, 'attention_mask': inMask});
    inIds.release();
    final hidden = encOut[0]!;

    final tgtId = tok.langId(tgt);
    final maxNew = math.min(256, encLen * 2 + 10);
    final generated = List.generate(b, (_) => <int>[]);
    final finished = List<bool>.filled(b, false);
    var last = List<int>.filled(b, NllbTokenizer.eosId); // 디코더 시작 토큰 </s>

    final emptyKv = Float32List(0);
    List<OrtValue> pastDec = [
      for (var i = 0; i < _layers * 2; i++) floatTensor(emptyKv, [b, _heads, 0, _headDim]),
    ];
    List<OrtValue> pastEnc = [
      for (var i = 0; i < _layers * 2; i++) floatTensor(emptyKv, [b, _heads, 0, _headDim]),
    ];
    var firstStep = true;

    try {
      for (var step = 0; step < maxNew; step++) {
        final inputs = <String, OrtValue>{
          'encoder_attention_mask': inMask,
          'input_ids': int64Tensor(last, [b, 1]),
          'encoder_hidden_states': hidden,
          'use_cache_branch': boolTensor(!firstStep),
        };
        for (var l = 0; l < _layers; l++) {
          inputs['past_key_values.$l.decoder.key'] = pastDec[l * 2];
          inputs['past_key_values.$l.decoder.value'] = pastDec[l * 2 + 1];
          inputs['past_key_values.$l.encoder.key'] = pastEnc[l * 2];
          inputs['past_key_values.$l.encoder.value'] = pastEnc[l * 2 + 1];
        }
        final out = decoder.run(runOptions, inputs);
        inputs['input_ids']!.release();
        inputs['use_cache_branch']!.release();

        // 다음 토큰 고르기
        final logits = floatView(out[_outIndex['logits']!]!);
        final vocab = logits.length ~/ b;
        final next = List<int>.filled(b, NllbTokenizer.padId);
        for (var r = 0; r < b; r++) {
          if (finished[r]) continue;
          if (step == 0) {
            next[r] = tgtId; // 대상 언어 코드 강제
            continue;
          }
          var best = NllbTokenizer.eosId;
          var bestScore = double.negativeInfinity;
          final base = r * vocab;
          for (var t = 0; t < vocab; t++) {
            if (t == NllbTokenizer.unkId || t == NllbTokenizer.padId || t >= 256001) continue;
            final s = logits[base + t];
            if (s > bestScore) {
              bestScore = s;
              best = t;
            }
          }
          next[r] = best;
          if (best == NllbTokenizer.eosId || _looping(generated[r], best)) {
            finished[r] = true;
          } else {
            generated[r].add(best);
          }
        }

        // 캐시 교체: 디코더 캐시는 매번, 인코더 캐시는 첫 단계 결과를 계속 사용
        for (final v in pastDec) {
          v.release();
        }
        pastDec = [
          for (var l = 0; l < _layers; l++) ...[
            out[_outIndex['present.$l.decoder.key']!]!,
            out[_outIndex['present.$l.decoder.value']!]!,
          ],
        ];
        final keepEnc = firstStep;
        if (keepEnc) {
          for (final v in pastEnc) {
            v.release();
          }
          pastEnc = [
            for (var l = 0; l < _layers; l++) ...[
              out[_outIndex['present.$l.encoder.key']!]!,
              out[_outIndex['present.$l.encoder.value']!]!,
            ],
          ];
        }
        for (var i = 0; i < out.length; i++) {
          final v = out[i];
          if (v == null || pastDec.contains(v) || pastEnc.contains(v)) continue;
          v.release();
        }
        firstStep = false;
        last = next;
        if (finished.every((f) => f)) break;
      }
    } finally {
      for (final v in [...pastDec, ...pastEnc]) {
        v.release();
      }
      hidden.release();
      inMask.release();
    }

    for (var k = 0; k < idx.length; k++) {
      result[idx[k]] = tok.decode(generated[k]);
    }
    return result;
  }

  /// 같은 구절이 반복되기 시작하면 멈춤 (길이 1~6 의 꼬리가 3번 연속)
  static bool _looping(List<int> gen, int next) {
    final seq = [...gen, next];
    for (var n = 1; n <= 6; n++) {
      if (seq.length < n * 3) break;
      var same = true;
      for (var i = 0; i < n && same; i++) {
        final a = seq[seq.length - 1 - i];
        if (a != seq[seq.length - 1 - i - n] || a != seq[seq.length - 1 - i - 2 * n]) same = false;
      }
      if (same) return true;
    }
    return false;
  }
}
