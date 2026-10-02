# 외부 데이터로 바꾼 NLLB 모델 (lib/platform/common/onnx_external.dart) 이 원래 모델과 같은 결과를 내는지 확인.
#
# 사용: flutter test test/onnx_external_test.dart 를 JJ_ONNX_EXT_OUT=<폴더> 로 실행해 바꾼 모델을 만든 뒤
#       python tool/check_onnx_external.py <원래 모델 폴더> <바꾼 모델 폴더>
# 필요: pip install onnxruntime numpy
import sys
import numpy as np
import onnxruntime as ort

src, dst = sys.argv[1], sys.argv[2]


def session(path, low):
    o = ort.SessionOptions()
    if low:  # Android 와 같은 설정
        o.graph_optimization_level = ort.GraphOptimizationLevel.ORT_DISABLE_ALL
        o.enable_cpu_mem_arena = False
        o.enable_mem_pattern = False
        o.add_session_config_entry('session.disable_prepacking', '1')
    return ort.InferenceSession(path, o, providers=['CPUExecutionProvider'])


ids = np.array([[256047, 9906, 1159, 5, 2], [256047, 59002, 2, 1, 1]], dtype=np.int64)
mask = np.array([[1, 1, 1, 1, 1], [1, 1, 1, 0, 0]], dtype=np.int64)

a = session(f'{src}/encoder_model_quantized.onnx', False).run(None, {'input_ids': ids, 'attention_mask': mask})[0]
b = session(f'{dst}/encoder_model_quantized_jj2.onnx', True).run(None, {'input_ids': ids, 'attention_mask': mask})[0]
print('encoder max diff', float(np.abs(a - b).max()))
assert np.allclose(a, b, atol=1e-3)

feeds = {'encoder_attention_mask': mask, 'input_ids': np.array([[2], [2]], dtype=np.int64),
         'encoder_hidden_states': a, 'use_cache_branch': np.array([False])}
for l in range(12):
    for kind in ('decoder', 'encoder'):
        for kv in ('key', 'value'):
            feeds[f'past_key_values.{l}.{kind}.{kv}'] = np.zeros((2, 16, 0, 64), dtype=np.float32)
x = session(f'{src}/decoder_model_merged_quantized.onnx', False).run(['logits'], feeds)[0]
y = session(f'{dst}/decoder_model_merged_quantized_jj2.onnx', True).run(['logits'], feeds)[0]
print('decoder max diff', float(np.abs(x - y).max()), 'same argmax', bool((x.argmax(-1) == y.argmax(-1)).all()))
assert (x.argmax(-1) == y.argmax(-1)).all()
print('OK')
