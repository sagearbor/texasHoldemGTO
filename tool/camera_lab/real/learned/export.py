"""Export the trained glyph CNN to ONNX (+ optional CoreML) and time CPU inference.
  python export.py <model.pt> <out_dir> [calib.npz]
"""
import os
import sys
import time

import numpy as np
import torch

from common import IN, make_model


def main():
    pt, out = sys.argv[1], sys.argv[2]
    os.makedirs(out, exist_ok=True)
    ck = torch.load(pt, map_location='cpu')
    m = make_model(ck['width'])
    m.load_state_dict(ck['state'])
    m.eval()
    x = torch.zeros(1, 1, IN, IN)
    onnx_path = os.path.join(out, 'glyph_cnn.onnx')
    torch.onnx.export(m, x, onnx_path, input_names=['x'], output_names=['logits'],
                      dynamic_axes={'x': {0: 'n'}, 'logits': {0: 'n'}}, opset_version=17, dynamo=False)
    print('onnx', onnx_path, os.path.getsize(onnx_path), 'bytes')
    import onnxruntime as ort
    try:
        from onnxruntime.quantization import CalibrationDataReader, QuantFormat, QuantType, quantize_static
        calib = np.load(sys.argv[3])['X'][:2000] if len(sys.argv) > 3 else np.random.randint(0, 255, (256, IN, IN))

        class R(CalibrationDataReader):
            def __init__(self):
                self.it = iter([{'x': calib[i:i + 64, None].astype(np.float32) / 255} for i in range(0, len(calib), 64)])

            def get_next(self):
                return next(self.it, None)
        q_path = os.path.join(out, 'glyph_cnn.int8.onnx')
        quantize_static(onnx_path, q_path, R(), quant_format=QuantFormat.QDQ,
                        activation_type=QuantType.QUInt8, weight_type=QuantType.QInt8)
        print('onnx int8', q_path, os.path.getsize(q_path), 'bytes')
    except Exception as e:  # noqa
        q_path = None
        print('int8 quant failed:', e)
    so = ort.SessionOptions()
    so.intra_op_num_threads = 1
    for p in [onnx_path, q_path]:
        if not p:
            continue
        s = ort.InferenceSession(p, so, providers=['CPUExecutionProvider'])
        xb = np.random.rand(1, 1, IN, IN).astype(np.float32)
        for _ in range(50):
            s.run(None, {'x': xb})
        t = time.perf_counter()
        for _ in range(2000):
            s.run(None, {'x': xb})
        one = (time.perf_counter() - t) / 2000
        xb = np.random.rand(64, 1, IN, IN).astype(np.float32)
        t = time.perf_counter()
        for _ in range(100):
            s.run(None, {'x': xb})
        b = (time.perf_counter() - t) / 100 / 64
        ref = m(torch.from_numpy(xb)).detach().numpy()
        diff = np.abs(s.run(None, {'x': xb})[0] - ref).max()
        print(f'{os.path.basename(p)}: 1 thread, batch1 {one * 1e3:.3f} ms/crop, batch64 {b * 1e3:.3f} ms/crop, '
              f'max |logit diff| vs torch {diff:.4f}')
    try:
        import coremltools as ct
        tr = torch.jit.trace(m, x)
        ml = ct.convert(tr, inputs=[ct.TensorType(name='x', shape=x.shape)], convert_to='mlprogram')
        cp = os.path.join(out, 'glyph_cnn.mlpackage')
        ml.save(cp)
        sz = sum(os.path.getsize(os.path.join(d, f)) for d, _, fs in os.walk(cp) for f in fs)
        print('coreml', cp, sz, 'bytes')
    except Exception as e:  # noqa
        print('coreml skipped:', type(e).__name__, str(e)[:200])


if __name__ == '__main__':
    main()
