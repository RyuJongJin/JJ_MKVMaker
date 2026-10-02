import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;

/// ONNX 모델을 메모리가 적은 기기 (Android) 에 맞게 바꾼다. 처음 번역할 때 한 번.
///
/// 1. 큰 가중치를 별도 파일 (외부 데이터) 로 옮긴다. 한 파일짜리 모델을 열면 ONNX Runtime 은 파일 내용과
///    가중치를 잠깐 함께 들고 있어 모델 크기의 2~3배를 쓴다. 외부 데이터는 파일을 메모리 맵으로 바로 쓰므로
///    앱 메모리를 거의 쓰지 않고, Android 도 필요하면 그 메모리를 비울 수 있다.
/// 2. 정수 lm_head: NLLB 디코더의 마지막 단계는 int8 공유 임베딩 (25.6만 단어 × 1024) 을 매번 전치하고
///    float 로 풀어 (1GB) 곱한다. 이것을 다른 층과 같은 동적 양자화 정수 곱
///    (DynamicQuantizeLinear → MatMulInteger → 배율) 으로 바꾸고, 전치한 가중치는 미리 만들어 둔다.
///
/// 측정 (NLLB 디코더, 그래프 최적화 끔): 실행 중 최대 1.8GB · 한 단계 800ms → 570MB (대부분 파일 맵) · 60ms.
/// 바꾼 모델이 원래와 같은 결과를 내는지: tool/check_onnx_external.py
///
/// 파일 전체를 메모리에 올리지 않는다: protobuf 머리만 읽으며 큰 raw_data 는 조각조각 .data 파일로 복사하고,
/// 모델 구조 (수 MB) 만 메모리에서 다시 쓴다.
class OnnxExternal {
  /// 이보다 큰 가중치만 옮긴다
  static const threshold = 1024;

  /// .data 안에서 가중치 시작 위치 정렬 (메모리 맵에 유리)
  static const align = 4096;

  /// 바꾼 모델 경로: encoder_model_quantized.onnx → encoder_model_quantized_jj2.onnx (+ .data).
  /// 바꾸는 방식이 달라지면 숫자를 올린다 (예전 것은 지우고 다시 만든다).
  static String externalPath(String onnx) =>
      p.join(p.dirname(onnx), '${p.basenameWithoutExtension(onnx)}_jj2.onnx');

  /// 예전 방식으로 바꾼 파일 (정수 lm_head 없음 - 디코더가 1GB 넘게 씀)
  static List<String> _legacy(String onnx) {
    final base = p.join(p.dirname(onnx), '${p.basenameWithoutExtension(onnx)}_ext.onnx');
    return [base, '$base.data'];
  }

  /// [onnx] 를 [out] (+ [out].data) 로 바꾼다. 중간에 실패하면 만들던 파일을 지운다.
  static void convert(String onnx, String out) {
    final tmp = '$out.tmp', tmpData = '$out.data.tmp';
    final src = File(onnx).openSync();
    final data = File(tmpData).openSync(mode: FileMode.write);
    try {
      final model = _Rewriter(src, data, p.basename('$out.data')).model();
      File(tmp).writeAsBytesSync(model, flush: true);
    } catch (_) {
      src.closeSync();
      data.closeSync();
      for (final f in [tmp, tmpData]) {
        try {
          File(f).deleteSync();
        } catch (_) {}
      }
      rethrow;
    }
    src.closeSync();
    data.closeSync();
    // .data 를 먼저 옮겨 두고 모델 파일을 마지막에 (모델 파일이 있으면 다 된 것)
    File(tmpData).renameSync('$out.data');
    File(tmp).renameSync(out);
  }

  static bool isReady(String onnx) {
    final ext = externalPath(onnx);
    return File(ext).existsSync() && File('$ext.data').existsSync();
  }

  /// 바꾼 모델이 없으면 만든다. 바꾼 모델 경로를 돌려준다.
  /// [deleteOriginal]: 다 바꾸면 원래 파일을 지운다 (저장 공간 절약)
  static String ensure(String onnx, {bool deleteOriginal = false}) {
    final ext = externalPath(onnx);
    for (final f in _legacy(onnx)) {
      try {
        File(f).deleteSync();
      } catch (_) {}
    }
    if (isReady(onnx)) return ext;
    convert(onnx, ext);
    if (deleteOriginal) {
      try {
        File(onnx).deleteSync();
      } catch (_) {}
    }
    return ext;
  }
}

/// 정수 lm_head 로 바꿀 곳: Transpose(W) → DequantizeLinear(·, scale, zp) → MatMul(h, ·) → out
class _LmHead {
  final String weight, transposed, dequantized, scale, zeroPoint, input, output;
  const _LmHead(this.weight, this.transposed, this.dequantized, this.scale, this.zeroPoint, this.input, this.output);

  String get key => [weight, transposed, dequantized, scale, zeroPoint, input, output].join('|');
}

/// 노드 하나 (분석용)
class _Node {
  String op = '';
  final inputs = <String>[], outputs = <String>[];
  var perm = <int>[];
}

class _Rewriter {
  final RandomAccessFile src;
  final RandomAccessFile data;
  final String location;
  final _buf = Uint8List(10);

  /// 정수 lm_head 로 바꿀 곳 (없으면 null)
  _LmHead? _lm;

  /// 주 그래프의 W (전치본을 만들 원본): raw 위치 · 크기 · 형
  int? _wRaw, _wRows, _wCols, _wType;

  _Rewriter(this.src, this.data, this.location);

  /// ModelProto: graph (7) 만 다시 쓰고 나머지는 그대로
  Uint8List model() {
    _analyze();
    final out = BytesBuilder(copy: false);
    _fields(0, src.lengthSync(), (no, wt, keyStart, valStart, valLen, end) {
      if (no == 7 && wt == 2) {
        _bytes(out, 7, _graph(valStart, valLen, main: true));
      } else {
        out.add(_read(keyStart, end - keyStart));
      }
    });
    return out.takeBytes();
  }

  // ───────── 분석: 정수 lm_head 로 바꿀 곳 찾기 ─────────

  void _analyze() {
    final mainInits = <String>{};
    final subgraphs = <List<_Node>>[];
    void graph(int start, int len, bool main) {
      final nodes = <_Node>[];
      _fields(start, len, (no, wt, keyStart, valStart, valLen, end) {
        if (no == 1 && wt == 2) {
          nodes.add(_parseNode(valStart, valLen, (gs, gl) => graph(gs, gl, false)));
        } else if (main && no == 5 && wt == 2) {
          _fields(valStart, valLen, (n, w, ks, vs, vl, e) {
            if (n == 8 && w == 2) mainInits.add(utf8.decode(_read(vs, vl)));
          });
        }
      });
      if (!main) subgraphs.add(nodes);
    }

    _fields(0, src.lengthSync(), (no, wt, keyStart, valStart, valLen, end) {
      if (no == 7 && wt == 2) graph(valStart, valLen, true);
    });

    _LmHead? found;
    for (final nodes in subgraphs) {
      for (final tr in nodes) {
        if (tr.op != 'Transpose' || tr.inputs.length != 1 || !mainInits.contains(tr.inputs[0])) continue;
        if (tr.perm.isNotEmpty && (tr.perm.length != 2 || tr.perm[0] != 1 || tr.perm[1] != 0)) continue;
        final dq = nodes.where((n) => n.op == 'DequantizeLinear' && n.inputs.length == 3 && n.inputs[0] == tr.outputs[0]);
        if (dq.length != 1) continue;
        final mm = nodes.where((n) => n.op == 'MatMul' && n.inputs.length == 2 && n.inputs[1] == dq.first.outputs[0]);
        if (mm.length != 1) continue;
        final lm = _LmHead(tr.inputs[0], tr.outputs[0], dq.first.outputs[0], dq.first.inputs[1], dq.first.inputs[2],
            mm.first.inputs[0], mm.first.outputs[0]);
        // 여러 갈래에 같은 모양으로 있어야 한다 (NLLB merged 디코더: If 의 두 갈래)
        if (found != null && found.key != lm.key) return;
        found = lm;
      }
    }
    _lm = found;
  }

  _Node _parseNode(int start, int len, void Function(int, int) subgraph) {
    final n = _Node();
    _fields(start, len, (no, wt, keyStart, valStart, valLen, end) {
      if (wt != 2) return;
      switch (no) {
        case 1:
          n.inputs.add(utf8.decode(_read(valStart, valLen)));
        case 2:
          n.outputs.add(utf8.decode(_read(valStart, valLen)));
        case 4:
          n.op = utf8.decode(_read(valStart, valLen));
        case 5: // AttributeProto
          var name = '';
          final ints = <int>[];
          _fields(valStart, valLen, (an, aw, aks, avs, avl, ae) {
            if (an == 1 && aw == 2) name = utf8.decode(_read(avs, avl));
            if (an == 6 && aw == 2) subgraph(avs, avl); // g
            if (an == 11 && aw == 2) subgraph(avs, avl); // graphs
            if (an == 8 && aw == 0) ints.add(_readVarint(avs).$1);
            if (an == 8 && aw == 2) {
              for (var q = avs; q < avs + avl;) {
                final (v, k) = _readVarint(q);
                ints.add(v);
                q += k;
              }
            }
          });
          if (name == 'perm') n.perm = ints;
      }
    });
    return n;
  }

  // ───────── 다시 쓰기 ─────────

  /// GraphProto: initializer (5) 를 외부 데이터로, 노드 (1) 안의 하위 그래프를 다시 쓰고,
  /// 정수 lm_head 로 바꾸는 갈래에서는 세 노드를 빼고 새 노드를 붙인다
  Uint8List _graph(int start, int len, {required bool main}) {
    final out = BytesBuilder(copy: false);
    final lm = _lm;
    var replaced = false;
    _fields(start, len, (no, wt, keyStart, valStart, valLen, end) {
      if (no == 5 && wt == 2) {
        _bytes(out, 5, _tensor(valStart, valLen, main: main));
      } else if (no == 1 && wt == 2) {
        final n = _parseNode(valStart, valLen, (_, _) {});
        if (lm != null &&
            ((n.op == 'Transpose' && n.outputs.contains(lm.transposed)) ||
                (n.op == 'DequantizeLinear' && n.outputs.contains(lm.dequantized)) ||
                (n.op == 'MatMul' && n.outputs.contains(lm.output) && n.inputs.contains(lm.dequantized)))) {
          replaced = true;
          return; // 뺀다
        }
        _bytes(out, 1, _node(valStart, valLen));
      } else {
        out.add(_read(keyStart, end - keyStart));
      }
    });
    if (replaced && lm != null) {
      // 정수 lm_head: out = Cast(MatMulInteger(DQL(h), Wᵀ)) × (h 배율 × W 배율)
      for (final nb in [
        _newNode('DynamicQuantizeLinear', [lm.input], ['jj_lm_hq', 'jj_lm_hs', 'jj_lm_hz'], 'jj_lm_dq'),
        _newNode('MatMulInteger', ['jj_lm_hq', lm.transposed, 'jj_lm_hz', lm.zeroPoint], ['jj_lm_i32'], 'jj_lm_mmi'),
        _newNode('Cast', ['jj_lm_i32'], ['jj_lm_f'], 'jj_lm_cast', castTo: 1), // FLOAT
        _newNode('Mul', ['jj_lm_hs', lm.scale], ['jj_lm_s'], 'jj_lm_scale'),
        _newNode('Mul', ['jj_lm_f', 'jj_lm_s'], [lm.output], 'jj_lm_out'),
      ]) {
        _bytes(out, 1, nb);
      }
    }
    // 주 그래프 끝에 전치한 가중치 Wᵀ 를 더한다 (W 는 단어 찾기 (Gather) 에 계속 쓰인다)
    if (main && lm != null && _wRaw != null) {
      _bytes(out, 5, _transposedInit(lm.transposed));
    }
    return out.takeBytes();
  }

  /// NodeProto: 속성 (5) 안의 하위 그래프만 다시 쓴다
  Uint8List _node(int start, int len) {
    final out = BytesBuilder(copy: false);
    _fields(start, len, (no, wt, keyStart, valStart, valLen, end) {
      if (no == 5 && wt == 2) {
        _bytes(out, 5, _attribute(valStart, valLen));
      } else {
        out.add(_read(keyStart, end - keyStart));
      }
    });
    return out.takeBytes();
  }

  /// AttributeProto: g (6) · graphs (11)
  Uint8List _attribute(int start, int len) {
    final out = BytesBuilder(copy: false);
    _fields(start, len, (no, wt, keyStart, valStart, valLen, end) {
      if ((no == 6 || no == 11) && wt == 2) {
        _bytes(out, no, _graph(valStart, valLen, main: false));
      } else {
        out.add(_read(keyStart, end - keyStart));
      }
    });
    return out.takeBytes();
  }

  /// TensorProto: 큰 raw_data (9) 를 .data 로 옮기고 external_data (13) · data_location (14) 를 붙인다
  Uint8List _tensor(int start, int len, {required bool main}) {
    final out = BytesBuilder(copy: false);
    int? rawStart, rawLen, type;
    var name = '';
    final dims = <int>[];
    var external = false;
    _fields(start, len, (no, wt, keyStart, valStart, valLen, end) {
      if (no == 14 && wt == 0) external = true; // 이미 외부 데이터
      if (no == 8 && wt == 2) name = utf8.decode(_read(valStart, valLen));
      if (no == 2 && wt == 0) type = _readVarint(valStart).$1;
      if (no == 1 && wt == 0) dims.add(_readVarint(valStart).$1);
      if (no == 1 && wt == 2) {
        for (var q = valStart; q < valStart + valLen;) {
          final (v, k) = _readVarint(q);
          dims.add(v);
          q += k;
        }
      }
      if (no == 9 && wt == 2 && valLen >= OnnxExternal.threshold) {
        rawStart = valStart;
        rawLen = valLen;
      } else {
        out.add(_read(keyStart, end - keyStart));
      }
    });
    if (rawStart == null || external) {
      // 옮길 것이 없으면 원래 그대로
      if (rawStart != null) return _read(start, len);
      return out.takeBytes();
    }
    // 전치본을 만들 W (int8 · uint8 2차원)
    if (main && name == _lm?.weight && dims.length == 2 && (type == 2 || type == 3) && dims[0] * dims[1] == rawLen) {
      _wRaw = rawStart;
      _wRows = dims[0];
      _wCols = dims[1];
      _wType = type;
    }
    final offset = _alignData();
    const chunk = 4 << 20;
    for (var done = 0; done < rawLen!; done += chunk) {
      final n = rawLen! - done < chunk ? rawLen! - done : chunk;
      data.writeFromSync(_read(rawStart! + done, n));
    }
    _externalFields(out, offset, rawLen!);
    return out.takeBytes();
  }

  /// W [rows × cols] 를 전치해 .data 에 쓰고, Wᵀ initializer 를 만든다.
  /// 256 열씩 나눠 (64MB) W 를 여러 번 읽는다 - 큰 메모리를 한 번에 잡지 않도록.
  Uint8List _transposedInit(String name) {
    final rows = _wRows!, cols = _wCols!, raw = _wRaw!;
    final offset = _alignData();
    const block = 256, readRows = 4096;
    for (var c0 = 0; c0 < cols; c0 += block) {
      final bc = cols - c0 < block ? cols - c0 : block;
      final outBuf = Uint8List(bc * rows);
      for (var r0 = 0; r0 < rows; r0 += readRows) {
        final br = rows - r0 < readRows ? rows - r0 : readRows;
        final inBuf = _read(raw + r0 * cols, br * cols);
        for (var r = 0; r < br; r++) {
          final ib = r * cols + c0;
          final ob = r0 + r;
          for (var c = 0; c < bc; c++) {
            outBuf[c * rows + ob] = inBuf[ib + c];
          }
        }
      }
      data.writeFromSync(outBuf);
    }
    final out = BytesBuilder(copy: false);
    _key(out, 1, 0);
    _varint(out, cols);
    _key(out, 1, 0);
    _varint(out, rows);
    _key(out, 2, 0);
    _varint(out, _wType!);
    _str(out, 8, name);
    _externalFields(out, offset, rows * cols);
    return out.takeBytes();
  }

  /// .data 끝을 정렬 위치까지 0 으로 채우고 그 위치를 돌려준다
  int _alignData() {
    var offset = data.lengthSync();
    final pad = (OnnxExternal.align - offset % OnnxExternal.align) % OnnxExternal.align;
    data.setPositionSync(offset);
    if (pad > 0) {
      data.writeFromSync(Uint8List(pad));
      offset += pad;
    }
    return offset;
  }

  void _externalFields(BytesBuilder out, int offset, int length) {
    for (final (k, v) in [('location', location), ('offset', '$offset'), ('length', '$length')]) {
      final entry = BytesBuilder(copy: false);
      _str(entry, 1, k);
      _str(entry, 2, v);
      _bytes(out, 13, entry.takeBytes());
    }
    _key(out, 14, 0);
    _varint(out, 1); // EXTERNAL
  }

  /// 새 NodeProto (기본 도메인). [castTo]: Cast 의 to 속성
  static Uint8List _newNode(String op, List<String> inputs, List<String> outputs, String name, {int? castTo}) {
    final out = BytesBuilder(copy: false);
    for (final i in inputs) {
      _str(out, 1, i);
    }
    for (final o in outputs) {
      _str(out, 2, o);
    }
    _str(out, 3, name);
    _str(out, 4, op);
    if (castTo != null) {
      final a = BytesBuilder(copy: false);
      _str(a, 1, 'to');
      _key(a, 3, 0);
      _varint(a, castTo);
      _key(a, 20, 0);
      _varint(a, 2); // AttributeType.INT
      _bytes(out, 5, a.takeBytes());
    }
    return out.takeBytes();
  }

  /// [start] 부터 [len] 바이트 안의 protobuf 필드를 차례로
  void _fields(int start, int len,
      void Function(int no, int wt, int keyStart, int valStart, int valLen, int end) f) {
    var pos = start;
    final end = start + len;
    while (pos < end) {
      final keyStart = pos;
      final (key, kn) = _readVarint(pos);
      pos += kn;
      final no = key >> 3, wt = key & 7;
      int valStart = pos, valLen;
      switch (wt) {
        case 0:
          final (_, n) = _readVarint(pos);
          valLen = n;
        case 1:
          valLen = 8;
        case 5:
          valLen = 4;
        case 2:
          final (l, n) = _readVarint(pos);
          valStart = pos + n;
          valLen = l;
        default:
          throw FormatException('지원하지 않는 protobuf 형식 (wire type $wt, 위치 $keyStart)');
      }
      final fieldEnd = valStart + valLen;
      if (fieldEnd > end) throw FormatException('모델 파일이 잘렸습니다 (위치 $keyStart)');
      f(no, wt, keyStart, valStart, valLen, fieldEnd);
      pos = fieldEnd;
    }
  }

  (int, int) _readVarint(int pos) {
    src.setPositionSync(pos);
    final n = src.readIntoSync(_buf);
    var v = 0, shift = 0;
    for (var i = 0; i < n; i++) {
      final b = _buf[i];
      v |= (b & 0x7f) << shift;
      if (b < 0x80) return (v, i + 1);
      shift += 7;
    }
    throw FormatException('잘못된 varint (위치 $pos)');
  }

  Uint8List _read(int pos, int len) {
    src.setPositionSync(pos);
    final b = src.readSync(len);
    if (b.length != len) throw FormatException('모델 파일이 잘렸습니다 (위치 $pos)');
    return b;
  }

  static void _key(BytesBuilder out, int no, int wt) => _varint(out, (no << 3) | wt);

  static void _varint(BytesBuilder out, int v) {
    while (v >= 0x80) {
      out.addByte((v & 0x7f) | 0x80);
      v >>= 7;
    }
    out.addByte(v);
  }

  static void _bytes(BytesBuilder out, int no, Uint8List b) {
    _key(out, no, 2);
    _varint(out, b.length);
    out.add(b);
  }

  static void _str(BytesBuilder out, int no, String s) => _bytes(out, no, utf8.encode(s));
}
