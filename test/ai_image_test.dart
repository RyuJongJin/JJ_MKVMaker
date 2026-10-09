import 'dart:convert';
import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:jj_mkvmaker/app/ai_local.dart';
import 'package:jj_mkvmaker/app/settings.dart';
import 'package:jj_mkvmaker/core/ai_catalog.dart';
import 'package:jj_mkvmaker/core/sd_cli.dart';
import 'package:jj_mkvmaker/services/image_ai.dart';
import 'package:jj_mkvmaker/services/secret_store.dart';
import 'package:path/path.dart' as p;

/// 1×1 PNG
final _png = base64Decode('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==');

void main() {
  group('123: sd-cli 인수 · 진행 읽기', () {
    const m = SdModelPaths(model: 'm.safetensors', loraDir: 'lora', loraName: 'lcm-lora-sdv1-5', taesd: 'taesd.safetensors');

    test('글 → 그림: LCM-LoRA · f16 · TAESD · 장치 · 여러 장', () {
      final a = sdCliArgs(const ImageGenRequest(prompt: 'a cat', negative: 'blurry', seed: 7, count: 2), m,
          out: 'o_%d.png', backend: 'vulkan0', threads: 8);
      expect(a.join(' '), contains('-m m.safetensors --type f16 --lora-model-dir lora --taesd taesd.safetensors'));
      expect(a[a.indexOf('-p') + 1], 'a cat<lora:lcm-lora-sdv1-5:1>');
      expect(a[a.indexOf('-n') + 1], 'blurry');
      for (final pair in [
        ['--sampling-method', 'lcm'],
        ['--seed', '7'],
        ['-b', '2'],
        ['--backend', 'vulkan0'],
        ['-t', '8'],
        ['-o', 'o_%d.png'],
        ['--cfg-scale', '1.0'],
      ]) {
        expect(a[a.indexOf(pair[0]) + 1], pair[1], reason: pair[0]);
      }
      expect(a, isNot(contains('-i')));
    });

    test('그림 → 그림 · LoRA 없이 · 빼고 싶은 것 없으면 -n 없음', () {
      final a = sdCliArgs(const ImageGenRequest(prompt: 'x', initImage: 'in.png', strength: 0.4), const SdModelPaths(model: 'm'),
          out: 'o.png');
      expect(a[a.indexOf('-i') + 1], 'in.png');
      expect(a[a.indexOf('--strength') + 1], '0.4');
      expect(a[a.indexOf('-p') + 1], 'x');
      expect(a, isNot(contains('-n')));
      expect(a, isNot(contains('--sampling-method')));
    });

    test('해상도 올리기 인수 (121)', () {
      expect(sdUpscaleArgs(model: 'esr.pth', input: 'a.png', out: 'b.png', repeats: 2).join(' '),
          '-M upscale --upscale-model esr.pth -i a.png --upscale-repeats 2 -o b.png');
    });

    test('진행: 읽기 · 그리기 (단계당 초) · 디코드 · 끝', () {
      final load = parseSdProgress('  |#######################                           | 90/196 - 628.27MB/s\x1b[K')!;
      expect((load.phase, load.step, load.steps), ('load', 90, 196));
      expect(load.overall, closeTo(0.1 * 90 / 196, 1e-9));
      final s = parseSdProgress('  |=========================>                        | 2/4 - 25.11s/it')!;
      expect((s.phase, s.step, s.steps, s.secondsPerStep), ('sample', 2, 4, 25.11));
      expect(s.overall, closeTo(0.5, 1e-9));
      expect(parseSdProgress('|===>  | 1/4 - 2.00it/s')!.secondsPerStep, 0.5);
      expect(parseSdProgress('[I] decode_first_stage completed, taking 2.56s')!.phase, 'decode');
      expect(parseSdProgress('[I] generate_image completed in 49.03s')!.overall, 1);
      expect(parseSdProgress('[I] loading model from x'), isNull);
      // 150: GB/s 로 읽는 줄도 진행 (원문이 오류 글에 섞이지 않게)
      expect(parseSdProgress('|#####  | 431/686 - 1.86GB/s')!.phase, 'load');
    });

    test('장치 목록 읽기', () {
      expect(parseSdDevices('ggml_vulkan: 1 = ...\nVulkan0\tNVIDIA GeForce MX150\nVulkan1\tIntel UHD\nCPU\tIntel i7\n'), [
        ('vulkan0', 'NVIDIA GeForce MX150'),
        ('vulkan1', 'Intel UHD'),
        ('cpu', 'Intel i7'),
      ]);
    });

    test('다시 만들 수 있게 남기는 json (시드 · 모델 · 프롬프트)', () {
      const r = ImageGenRequest(prompt: '고양이', negative: 'x', width: 768, height: 512, steps: 6, seed: -1, initImage: 'a.png', strength: 0.3);
      final back = ImageGenRequest.fromJson(jsonDecode(r.encode(engine: '이 기기', actualSeed: 42)) as Map<String, Object?>);
      expect((back.prompt, back.negative, back.width, back.height, back.steps, back.seed, back.initImage, back.strength),
          ('고양이', 'x', 768, 512, 6, 42, 'a.png', 0.3));
      expect(resolveSeed(5), 5);
      expect(resolveSeed(-1), inInclusiveRange(0, (1 << 31) - 1));
    });
  });

  group('123: 받는 파일 목록', () {
    test('공식 배포처 · SHA-256 고정 · 비상업 라이선스 없음 · CUDA 는 NVIDIA 때만', () {
      for (final f in aiCatalog) {
        expect(f.url, startsWith('https://'), reason: f.id);
        expect(RegExp(r'^[0-9a-f]{64}$').hasMatch(f.sha256), isTrue, reason: f.id);
        expect(f.size, greaterThan(0), reason: f.id);
        expect(f.license.toUpperCase(), isNot(contains('NC')), reason: f.id);
        expect(f.licenseUrl, startsWith('https://'));
      }
      expect(aiFile('sd15').terms, contains('OpenRAIL-M'));
      expect(aiFile('engine-cuda').needs, 'nvidia');
      expect(aiFile('engine-cudart').needs, 'nvidia');
      expect(aiFile('engine-vulkan').needs, isNull);
      expect(aiLicenseTexts().map((e) => e.$1), contains('stable-diffusion.cpp'));
      expect(aiLicenseTexts().firstWhere((e) => e.$1 == 'Stable Diffusion v1.5').$2, contains('부속서 A'));
    });
  });

  group('123: 받기 (SHA-256 확인 · 풀기)', () {
    late Directory tmp;
    late HttpServer server;
    final files = <String, List<int>>{};
    setUp(() async {
      tmp = Directory.systemTemp.createTempSync('jj_ai_store_');
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((req) async {
        final b = files[req.uri.path];
        if (b == null) {
          req.response.statusCode = 404;
        } else {
          req.response.add(b);
        }
        await req.response.close();
      });
    });
    tearDown(() async {
      await server.close(force: true);
      tmp.deleteSync(recursive: true);
    });

    AiFile file(String id, String path, List<int> body, {String kind = 'model', String? sha}) {
      files[path] = body;
      return AiFile(
          id: id,
          name: id,
          url: 'http://127.0.0.1:${server.port}$path',
          sha256: sha ?? sha256.convert(body).toString(),
          size: body.length,
          kind: kind,
          license: 'MIT',
          licenseUrl: 'https://x');
    }

    test('맞는 파일은 받아 둠 · SHA-256 이 다르면 지우고 알림 · 지우기', () async {
      final store = AiStore(tmp.path);
      final good = file('m1', '/m1.safetensors', List.filled(5000, 7));
      await store.installFile(good);
      expect(store.isFileInstalled(good), isTrue);
      expect(store.isVerified(good), isTrue, reason: '받을 때 SHA-256 을 맞춰 봄 - "확인됨"');
      expect(File(store.pathOf(good)).lengthSync(), 5000);
      final bad = file('m2', '/m2.safetensors', [1, 2, 3], sha: '0' * 64);
      await expectLater(store.installFile(bad), throwsA(isA<ImageAiException>()));
      expect(store.isFileInstalled(bad), isFalse);
      expect(tmp.listSync(recursive: true).whereType<File>().where((f) => f.path.contains('.part')), isEmpty);
    });

    test('149: 끊기면 받은 곳부터 이어 받고 (Range), 서버가 이어 주지 않으면 처음부터 · 진행 글', () async {
      final store = AiStore(tmp.path);
      final body = List<int>.generate(300000, (i) => i * 7 % 251);
      final f = file('big', '/big', body);
      // 첫 요청은 120000 바이트만 보내고 연결을 끊는다, 그다음은 Range 로 나머지
      final port = server.port;
      await server.close(force: true);
      final ranges = <String?>[];
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, port);
      server.listen((req) async {
        final range = req.headers.value(HttpHeaders.rangeHeader);
        ranges.add(range);
        if (range == null) {
          final sock = await req.response.detachSocket(writeHeaders: false);
          sock.add(utf8.encode('HTTP/1.1 200 OK\r\nContent-Length: ${body.length}\r\n\r\n'));
          sock.add(body.sublist(0, 120000));
          await sock.flush();
          sock.destroy();
          return;
        }
        final from = int.parse(RegExp(r'bytes=(\d+)-').firstMatch(range)!.group(1)!);
        req.response
          ..statusCode = 206
          ..headers.set(HttpHeaders.contentRangeHeader, 'bytes $from-${body.length - 1}/${body.length}')
          ..add(body.sublist(from));
        await req.response.close();
      });
      final texts = <String>[];
      void listen() {
        final t = store.progressText('big');
        if (t != null && t.isNotEmpty) texts.add(t);
      }
      store.addListener(listen);
      await store.installFile(f, retryWait: const Duration(milliseconds: 10));
      store.removeListener(listen);
      expect(store.isFileInstalled(f), isTrue);
      expect(File(store.pathOf(f)).readAsBytesSync(), body);
      expect(ranges.first, isNull);
      expect(ranges.last, 'bytes=120000-', reason: '받은 곳부터');
      expect(texts.any((t) => t.contains('%') && t.contains(' / ')), isTrue);
    });

    test('149: 여러 번 끊기면 쉬운 말 (주소 없음) 로 알리고 조각은 남겨 [이어 받기] 로 이어 받음', () async {
      final store = AiStore(tmp.path);
      final body = List<int>.generate(50000, (i) => i % 256);
      final f = file('drop', '/drop', body);
      var calls = 0;
      final port = server.port;
      await server.close(force: true);
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, port);
      var allow = false;
      server.listen((req) async {
        calls++;
        final range = req.headers.value(HttpHeaders.rangeHeader);
        final from = range == null ? 0 : int.parse(RegExp(r'bytes=(\d+)-').firstMatch(range)!.group(1)!);
        if (!allow) {
          final sock = await req.response.detachSocket(writeHeaders: false);
          final n = (from + 5000).clamp(0, body.length);
          sock.add(utf8.encode('HTTP/1.1 ${range == null ? '200 OK' : '206 Partial Content'}\r\nContent-Length: ${body.length - from}\r\n\r\n'));
          sock.add(body.sublist(from, n));
          await sock.flush();
          sock.destroy();
          return;
        }
        req.response
          ..statusCode = range == null ? 200 : 206
          ..add(body.sublist(from));
        await req.response.close();
      });
      await expectLater(store.installFile(f, retries: 2, retryWait: const Duration(milliseconds: 10)),
          throwsA(isA<ImageAiException>().having((e) => e.message, 'message', allOf(contains('이어 받기'), isNot(contains('http'))))));
      expect(calls, 3);
      expect(store.failures['drop'], contains('연결이 끊겼습니다'));
      expect(store.neededSpace(f), lessThan(body.length), reason: '받은 조각을 남김');
      allow = true;
      await store.installFile(f, retryWait: const Duration(milliseconds: 10));
      expect(File(store.pathOf(f)).readAsBytesSync(), body);
      expect(store.failures, isEmpty);
    });

    test('149 · 관리자: 206 인데 범위 시작이 다르거나, 맞지 않는 416 이면 조각을 버리고 처음부터', () async {
      expect(contentRangeStart('bytes 120000-299999/300000'), 120000);
      expect(contentRangeStart(null), isNull);
      final store = AiStore(tmp.path);
      final body = List<int>.generate(40000, (i) => i * 3 % 256);
      final port = server.port;
      await server.close(force: true);
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, port);
      final log = <String>[];
      var mode = 'wrong206';
      server.listen((req) async {
        final range = req.headers.value(HttpHeaders.rangeHeader);
        log.add('$mode ${range ?? '-'}');
        if (range != null && mode == 'wrong206') {
          // 엉뚱한 범위 (처음부터) 를 206 으로
          req.response
            ..statusCode = 206
            ..headers.set(HttpHeaders.contentRangeHeader, 'bytes 0-${body.length - 1}/${body.length}')
            ..add(body);
        } else if (range != null && mode == '416') {
          req.response.statusCode = 416;
        } else {
          req.response.add(body);
        }
        await req.response.close();
      });
      for (final m in ['wrong206', '416']) {
        mode = m;
        final f = file('r$m', '/r$m', body);
        // 받다 만 조각 (엉뚱한 내용) 을 미리 둔다
        File('${store.pathOf(f)}.part')
          ..createSync(recursive: true)
          ..writeAsBytesSync(List.filled(1000, 9));
        await store.installFile(f, retryWait: const Duration(milliseconds: 10));
        expect(File(store.pathOf(f)).readAsBytesSync(), body, reason: m);
      }
      expect(log, containsAllInOrder(['wrong206 bytes=1000-', 'wrong206 -', '416 bytes=1000-', '416 -']));
    });

    test('149: 한꺼번에 받기 - 기다리는 것은 "차례 기다림"', () async {
      final store = AiStore(tmp.path);
      final a = file('qa', '/qa', List.filled(1000, 1)), b2 = file('qb', '/qb', List.filled(1000, 2));
      final seen = <String>{};
      void listen() {
        if (store.progress.containsKey('qa') && store.queued.contains('qb')) seen.add(store.progressText('qb')!);
      }
      store.addListener(listen);
      await store.installAll([a, b2]);
      store.removeListener(listen);
      expect(seen, contains('차례 기다림'));
      expect(store.isFileInstalled(a) && store.isFileInstalled(b2), isTrue);
      expect(store.queued, isEmpty);
    });

    test('실행 파일 zip 은 풀어 둔다', () async {
      final store = AiStore(tmp.path);
      final arc = Archive()..addFile(ArchiveFile.bytes('sd-cli.exe', utf8.encode('fake')));
      final zip = ZipEncoder().encode(arc);
      final eng = file('engine-x', '/e.zip', zip, kind: 'engine');
      await store.installFile(eng);
      expect(File(p.join(store.pathOf(eng), 'sd-cli.exe')).existsSync(), isTrue);
    });
  });

  group('123: 사용자가 추가한 서버 · 서비스', () {
    late HttpServer server;
    final seen = <String>[];
    Map<String, Object?>? lastBody;
    setUp(() async {
      seen.clear();
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      var polls = 0;
      server.listen((req) async {
        seen.add('${req.method} ${req.uri.path} ${req.headers.value('authorization') ?? ''}');
        final text = await utf8.decoder.bind(req).join();
        if (text.isNotEmpty && req.headers.contentType?.mimeType == 'application/json') lastBody = jsonDecode(text) as Map<String, Object?>;
        final res = req.response..headers.contentType = ContentType.json;
        switch (req.uri.path) {
          case '/sdapi/v1/txt2img' || '/sdapi/v1/img2img':
            res.write(jsonEncode({'images': [base64Encode(_png), base64Encode(_png)]}));
          case '/v1/images/generations':
            res.write(jsonEncode({'data': [{'b64_json': base64Encode(_png)}]}));
          case '/prompt':
            res.write(jsonEncode({'prompt_id': 'p1'}));
          case '/history/p1':
            polls++;
            res.write(polls < 2
                ? '{}'
                : jsonEncode({'p1': {'outputs': {'9': {'images': [{'filename': 'a.png', 'subfolder': '', 'type': 'output'}]}}}}));
          case '/view':
            res.headers.contentType = ContentType('image', 'png');
            res.add(_png);
          default:
            res.statusCode = 404;
        }
        await res.close();
      });
    });
    tearDown(() => server.close(force: true));

    Future<List<GeneratedImage>> run(AiService s, ImageGenRequest r) async {
      final dir = Directory.systemTemp.createTempSync('jj_ai_remote_');
      addTearDown(() => dir.deleteSync(recursive: true));
      final made = await RemoteImageEngine(s).generate(r, outDir: dir.path, baseName: 'ai');
      for (final g in made) {
        expect(File(g.path).readAsBytesSync(), _png);
      }
      return made;
    }

    test('Automatic1111: 글 → 그림 · 시드 · 아이디:비밀번호는 Basic', () async {
      final s = AiService(id: 'a', name: 'GPU PC', url: 'http://127.0.0.1:${server.port}/', kind: 'a1111', apiKey: 'u:p');
      final made = await run(s, const ImageGenRequest(prompt: 'cat', seed: 10, count: 2));
      expect(made.map((g) => g.seed), [10, 11]);
      expect(seen.single, startsWith('POST /sdapi/v1/txt2img Basic '));
      expect(lastBody!['seed'], 10);
      expect(lastBody!['batch_size'], 2);
      expect(RemoteImageEngine(s).leavesDevice, isTrue);
    });

    test('OpenAI 형식: Bearer 키 · 크기', () async {
      final s = AiService(id: 'o', name: 'svc', url: 'http://127.0.0.1:${server.port}', kind: 'openai', model: 'm', apiKey: 'sk-test');
      await run(s, const ImageGenRequest(prompt: 'cat', width: 512, height: 768));
      expect(seen.single, 'POST /v1/images/generations Bearer sk-test');
      expect(lastBody!['size'], '512x768');
      expect(lastBody!['model'], 'm');
    });

    test('ComfyUI: 작업 흐름을 보내고 끝날 때까지 기다려 결과를 받는다', () async {
      final s = AiService(id: 'c', name: 'comfy', url: 'http://127.0.0.1:${server.port}', kind: 'comfy', model: 'sd15.safetensors');
      final made = await run(s, const ImageGenRequest(prompt: 'cat', seed: 3));
      expect(made, hasLength(1));
      final flow = lastBody!['prompt'] as Map;
      expect((flow['4'] as Map)['inputs'], {'ckpt_name': 'sd15.safetensors'});
      expect(((flow['3'] as Map)['inputs'] as Map)['seed'], 3);
      expect(seen.where((x) => x.startsWith('GET /history')).length, greaterThanOrEqualTo(2));
    });

    test('설정 파일에는 API 키를 쓰지 않고 안전 저장소에 (124)', () async {
      final dir = Directory.systemTemp.createTempSync('jj_ai_key_');
      addTearDown(() => dir.deleteSync(recursive: true));
      final secrets = MemorySecretStore();
      final st = SettingsStore(p.join(dir.path, 'settings.json'), secrets);
      final s = await st.load();
      s.aiServices = [const AiService(id: 'x', name: 'n', url: 'http://h', kind: 'a1111', apiKey: 'sk-secret')];
      await st.save(s);
      expect(File(p.join(dir.path, 'settings.json')).readAsStringSync(), isNot(contains('sk-secret')));
      expect(secrets.values['ai.key.x'], 'sk-secret');
      final again = await SettingsStore(p.join(dir.path, 'settings.json'), secrets).load();
      expect(again.aiServices.single.apiKey, 'sk-secret');
      s.aiServices = [];
      await st.save(s);
      expect(secrets.values.containsKey('ai.key.x'), isFalse, reason: '지운 서비스의 키는 저장소에서도 지움');
    });
  });

  group('123: 기기 안 엔진 (가짜 sd-cli 로)', () {
    test('진행을 알리고, 여러 장을 시드와 함께 돌려주고, 옆에 json 을 남긴다', () async {
      if (!Platform.isWindows) return markTestSkipped('Windows 전용 (가짜 sd-cli 가 .cmd)');
      final dir = Directory.systemTemp.createTempSync('jj_ai_local_');
      addTearDown(() => dir.deleteSync(recursive: true));
      // 156-2: 정한 크기 (512×512) 여야 엔진이 그린 것으로 본다
      final png = File(p.join(dir.path, 'src.png'))..writeAsBytesSync(img.encodePng(img.Image(width: 512, height: 512)));
      // 받은 인수의 -o (예: ...\ai_X_%d.png) 에 0 · 1 번을 만든다
      final fake = File(p.join(dir.path, 'fake-sd.cmd'))
        ..writeAsStringSync('@echo off\r\n'
            'echo   ^|=====^>     ^| 1/2 - 3.00s/it\r\n'
            'echo   ^|==========^| 2/2 - 3.00s/it\r\n'
            'echo [I] decode_first_stage completed\r\n'
            ':loop\r\nif "%~1"=="" goto done\r\nif "%~1"=="-o" (set OUT=%~2)\r\nshift\r\ngoto loop\r\n:done\r\n'
            'setlocal enabledelayedexpansion\r\nset A=!OUT:%%d=0!\r\nset B=!OUT:%%d=1!\r\n'
            'copy /y "${png.path}" "%A%" >nul\r\ncopy /y "${png.path}" "%B%" >nul\r\n'
            'echo [I] generate_image completed\r\n');
      final engine = LocalSdEngine(device: SdDevice(fake.path, 'cpu', 'CPU'), models: const SdModelPaths(model: 'm'));
      final steps = <String>[];
      final out = p.join(dir.path, 'out');
      final made = await AiJobs.instance.run(engine, const ImageGenRequest(prompt: 'cat', seed: 100, count: 2), outDir: out);
      expect(made.map((g) => g.seed), [100, 101]);
      for (final g in made) {
        expect(File(g.path).existsSync(), isTrue);
        final j = jsonDecode(File('${p.withoutExtension(g.path)}.json').readAsStringSync()) as Map;
        expect(j['prompt'], 'cat');
        expect(j['model'], 'sd15-lcm');
      }
      expect(made.first.seed, (jsonDecode(File('${p.withoutExtension(made.first.path)}.json').readAsStringSync()) as Map)['seed']);
      expect(AiJobs.instance.busy, isFalse);
      expect(steps, isEmpty);
    });

    test('156-2: 정한 크기가 아닌 그림 (바탕 그림을 그대로 돌려줌 등) 은 실패 · 남기지 않음', () async {
      if (!Platform.isWindows) return markTestSkipped('Windows 전용 (가짜 sd-cli 가 .cmd)');
      final dir = Directory.systemTemp.createTempSync('jj_ai_local_');
      addTearDown(() => dir.deleteSync(recursive: true));
      final png = File(p.join(dir.path, 'src.png'))..writeAsBytesSync(_png); // 1×1
      final fake = File(p.join(dir.path, 'fake-sd.cmd'))
        ..writeAsStringSync('@echo off\r\n'
            ':loop\r\nif "%~1"=="" goto done\r\nif "%~1"=="-o" (set OUT=%~2)\r\nshift\r\ngoto loop\r\n:done\r\n'
            'setlocal enabledelayedexpansion\r\nset A=!OUT:%%d=0!\r\n'
            'copy /y "${png.path}" "%A%" >nul\r\n');
      final engine = LocalSdEngine(device: SdDevice(fake.path, 'cpu', 'CPU'), models: const SdModelPaths(model: 'm'));
      final out = p.join(dir.path, 'out');
      await expectLater(AiJobs.instance.run(engine, const ImageGenRequest(prompt: 'cat'), outDir: out),
          throwsA(isA<ImageAiException>()));
      expect(Directory(out).listSync().whereType<File>().where((f) => f.path.endsWith('.png')), isEmpty);
    });

    test('150 · 151: 취소하면 "취소했습니다" (실패 아님) · 그리는 동안 쓰는 파일 표시', () async {
      if (!Platform.isWindows) return markTestSkipped('Windows 전용');
      final dir = Directory.systemTemp.createTempSync('jj_ai_cancel_');
      addTearDown(() => dir.deleteSync(recursive: true));
      final fake = File(p.join(dir.path, 'slow.cmd'))
        ..writeAsStringSync('@echo off\r\necho   ^|=====^>     ^| 431/686 - 1.86GB/s\r\nping -n 8 127.0.0.1 >nul\r\n');
      final engine = LocalSdEngine(device: SdDevice(fake.path, 'cpu', 'CPU'), models: const SdModelPaths(model: 'm'));
      final run = AiJobs.instance.run(engine, const ImageGenRequest(prompt: 'x'), outDir: dir.path);
      await Future<void>.delayed(const Duration(milliseconds: 600));
      expect(AiJobs.instance.inUse, contains('sd15'));
      AiJobs.instance.cancel();
      await expectLater(run, throwsA(isA<ImageAiException>()
          .having((e) => e.cancelled, 'cancelled', isTrue)
          .having((e) => e.message, 'message', '취소했습니다')));
      expect(AiJobs.instance.inUse, isEmpty);
      expect(AiJobs.instance.busy, isFalse);
    });

    test('엔진이 실패하면 마지막 출력으로 알린다', () async {
      if (!Platform.isWindows) return markTestSkipped('Windows 전용');
      final dir = Directory.systemTemp.createTempSync('jj_ai_fail_');
      addTearDown(() => dir.deleteSync(recursive: true));
      final fake = File(p.join(dir.path, 'bad.cmd'))..writeAsStringSync('@echo off\r\necho [E] out of memory\r\nexit /b 3\r\n');
      final engine = LocalSdEngine(device: SdDevice(fake.path, 'cpu', 'CPU'), models: const SdModelPaths(model: 'm'));
      await expectLater(engine.generate(const ImageGenRequest(prompt: 'x'), outDir: dir.path, baseName: 'a'),
          throwsA(isA<ImageAiException>()
              .having((e) => e.message, 'message', isNot(contains('out of memory')))
              .having((e) => e.detail, 'detail', contains('out of memory'))));
    });
  });

  test('123: AI 설정 처음 값 · 저장 · 예전 설정에 AI 그림 화면을 한 번 넣음', () {
    final s = AppSettings();
    expect((s.aiEngine, s.aiDevice, s.aiTaesd, s.aiWidth, s.aiHeight, s.aiSteps, s.aiCfg, s.aiCount),
        ('local', 'auto', true, 512, 512, 4, 1.0, 1));
    expect(s.components, contains('aiimage'));
    final b = AppSettings.fromJson((AppSettings()
          ..aiWidth = 768
          ..aiSteps = 8
          ..aiTaesd = false)
        .toJson());
    expect((b.aiWidth, b.aiSteps, b.aiTaesd), (768, 8, false));
    final old = AppSettings.fromJson({'components': ['mkv', 'browser']});
    expect(old.components, contains('aiimage'));
    expect(old.migrated, contains('aiImage'));
    final off = AppSettings.fromJson((AppSettings()..components = ['mkv']).toJson());
    expect(off.components, isNot(contains('aiimage')), reason: '사용자가 끈 것은 그대로');
  });
}
