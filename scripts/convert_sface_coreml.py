"""Convert OpenCV Zoo's SFace face-embedding model (ONNX) to a Core ML package.

Source model (Apache-2.0):
  https://github.com/opencv/opencv_zoo/tree/main/models/face_recognition_sface
  file face_recognition_sface_2021dec.onnx, sha256 below.

The graph is a plain MobileFaceNet: Conv/BatchNorm/PRelu blocks, then
BatchNorm, Flatten, Gemm and a final BatchNorm. It is small enough to rebuild
op by op with coremltools' MIL builder, so no PyTorch or ONNX runtime is needed.
BatchNorms that follow a Conv or the Gemm are folded into their weights.

Input  "data": float32 [1, 3, 112, 112], RGB, raw 0...255 (the 5-point aligned crop).
Output "embedding": float32 [1, 128], not normalised; callers L2-normalise and
compare with cosine similarity, as OpenCV's FaceRecognizerSF does.

Usage (any OS; prediction checks need macOS):
  python -I scripts/convert_sface_coreml.py SOURCE.onnx OUT.mlpackage [--check]
Requires: coremltools>=8, onnx, numpy; --check also needs onnxruntime.
"""
import argparse
import hashlib
import sys

import numpy as np
import onnx
from onnx import numpy_helper

SOURCE_SHA256 = '0ba9fbfa01b5270c96627c4ef784da859931e02f04419c829e83484087c34e79'


def load_graph(path):
    digest = hashlib.sha256(open(path, 'rb').read()).hexdigest()
    if digest != SOURCE_SHA256:
        sys.exit(f'unexpected source model sha256 {digest}')
    model = onnx.load(path)
    graph = model.graph
    weights = {t.name: numpy_helper.to_array(t).astype(np.float32) for t in graph.initializer}
    nodes = [(n.op_type, list(n.input), list(n.output),
              {a.name: onnx.helper.get_attribute_value(a) for a in n.attribute}) for n in graph.node]
    return nodes, weights


def plan(nodes, weights):
    """Turn the ONNX node list into folded steps, shared by the MIL builder and the numpy check."""
    steps = []
    i = 0
    while i < len(nodes):
        op, inputs, outputs, attrs = nodes[i]
        nxt = nodes[i + 1] if i + 1 < len(nodes) else None
        if op == 'Sub':
            steps.append(('sub', float(weights[inputs[1]][0])))
        elif op == 'Mul':
            steps.append(('mul', float(weights[inputs[1]][0])))
        elif op in ('Conv', 'Gemm'):
            w = weights[inputs[1]]
            b = weights[inputs[2]] if len(inputs) > 2 else np.zeros(w.shape[0], np.float32)
            if op == 'Gemm':
                assert attrs.get('transB') == 1 and attrs.get('transA', 0) == 0
                assert attrs.get('alpha', 1.0) == 1.0 and attrs.get('beta', 1.0) == 1.0
            if nxt and nxt[0] == 'BatchNormalization' and nxt[1][0] == outputs[0]:
                gamma, beta, mean, var = (weights[n] for n in nxt[1][1:5])
                scale = gamma / np.sqrt(var + nxt[3]['epsilon'])
                w = w * scale.reshape((-1,) + (1,) * (w.ndim - 1))
                b = (b - mean) * scale + beta
                i += 1
            if op == 'Conv':
                assert attrs['dilations'] == [1, 1]
                pads = attrs['pads']
                assert pads[0] == pads[2] and pads[1] == pads[3]
                steps.append(('conv', w, b, attrs['strides'], [pads[0], pads[2], pads[1], pads[3]], attrs['group']))
            else:
                steps.append(('linear', w, b))
        elif op == 'BatchNormalization':
            gamma, beta, mean, var = (weights[n] for n in inputs[1:5])
            scale = gamma / np.sqrt(var + attrs['epsilon'])
            steps.append(('affine', scale, beta - mean * scale))
        elif op == 'PRelu':
            steps.append(('prelu', weights[inputs[1]].reshape(-1)))
        elif op == 'Dropout':
            pass  # identity at inference
        elif op == 'Flatten':
            steps.append(('flatten',))
        else:
            sys.exit(f'unsupported op {op}')
        i += 1
    return steps


def build_program(steps):
    from coremltools.converters.mil import Builder as mb
    from coremltools.converters.mil.mil import types

    @mb.program(input_specs=[mb.TensorSpec(shape=(1, 3, 112, 112), dtype=types.fp32)])
    def prog(data):
        x = data
        for step in steps:
            kind = step[0]
            if kind == 'sub':
                x = mb.sub(x=x, y=np.float32(step[1]))
            elif kind == 'mul':
                x = mb.mul(x=x, y=np.float32(step[1]))
            elif kind == 'conv':
                _, w, b, strides, pad, groups = step
                x = mb.conv(x=x, weight=w, bias=b, strides=strides, pad_type='custom', pad=pad, groups=groups)
            elif kind == 'prelu':
                x = mb.prelu(x=x, alpha=step[1])
            elif kind == 'affine':
                rank = len(x.shape)
                shape = (1, -1) + (1,) * (rank - 2)
                x = mb.add(x=mb.mul(x=x, y=step[1].reshape(shape)), y=step[2].reshape(shape))
            elif kind == 'flatten':
                x = mb.reshape(x=x, shape=[1, -1])
            elif kind == 'linear':
                x = mb.linear(x=x, weight=step[1], bias=step[2])
        return mb.identity(x=x, name='embedding')

    return prog


def numpy_forward(steps, x):
    """Reference implementation of the folded plan, checked against ONNX's own evaluator."""
    for step in steps:
        kind = step[0]
        if kind == 'sub':
            x = x - step[1]
        elif kind == 'mul':
            x = x * step[1]
        elif kind == 'conv':
            _, w, b, strides, pad, groups = step
            x = np.pad(x, ((0, 0), (0, 0), (pad[0], pad[1]), (pad[2], pad[3])))
            n, c, h, wd = x.shape
            o, cg, kh, kw = w.shape
            sh, sw = strides
            oh, ow = (h - kh) // sh + 1, (wd - kw) // sw + 1
            out = np.zeros((n, o, oh, ow), np.float32)
            og = o // groups
            for g in range(groups):
                xs = x[:, g * cg:(g + 1) * cg]
                cols = np.stack([xs[:, :, i:i + sh * oh:sh, j:j + sw * ow:sw]
                                 for i in range(kh) for j in range(kw)], axis=2)  # n,cg,k,oh,ow
                wg = w[g * og:(g + 1) * og].reshape(og, cg, kh * kw)
                out[:, g * og:(g + 1) * og] = np.einsum('nckhw,ock->nohw', cols, wg)
            x = out + b.reshape(1, -1, 1, 1)
        elif kind == 'prelu':
            a = step[1].reshape(1, -1, 1, 1)
            x = np.where(x >= 0, x, x * a)
        elif kind == 'affine':
            shape = (1, -1) + (1,) * (x.ndim - 2)
            x = x * step[1].reshape(shape) + step[2].reshape(shape)
        elif kind == 'flatten':
            x = x.reshape(1, -1)
        elif kind == 'linear':
            x = x @ step[1].T + step[2]
    return x


def quantize_step(step):
    """Simulate coremltools' per-channel linear_symmetric int8 weight quantization."""
    if step[0] not in ('conv', 'linear'):
        return step
    w = step[1]
    scale = np.abs(w).reshape(w.shape[0], -1).max(axis=1) / 127
    scale = np.where(scale == 0, 1, scale).reshape((-1,) + (1,) * (w.ndim - 1))
    return (step[0], (np.round(w / scale).clip(-127, 127) * scale).astype(np.float32)) + step[2:]


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('source')
    parser.add_argument('output')
    parser.add_argument('--check', action='store_true',
                        help='compare the folded plan, fp32 and simulated int8, with onnxruntime')
    args = parser.parse_args()

    import coremltools as ct
    import coremltools.optimize.coreml as cto

    nodes, weights = load_graph(args.source)
    steps = plan(nodes, weights)

    if args.check:
        # onnx.reference mis-evaluates this graph's BatchNorms (its weights are
        # also listed as graph inputs), so onnxruntime is the reference.
        import onnxruntime
        session = onnxruntime.InferenceSession(args.source, providers=['CPUExecutionProvider'])
        quantized = [quantize_step(step) for step in steps]
        for seed in range(3):
            sample = np.random.default_rng(seed).uniform(0, 255, (1, 3, 112, 112)).astype(np.float32)
            expected = session.run(None, {'data': sample})[0]
            for label, plan_steps, floor in (('fp32', steps, 0.99999), ('int8', quantized, 0.99)):
                actual = numpy_forward(plan_steps, sample)
                cos = float((expected * actual).sum() / np.linalg.norm(expected) / np.linalg.norm(actual))
                print(f'{label} plan vs onnxruntime (seed {seed}): cosine {cos:.6f}')
                if cos < floor:
                    sys.exit(f'{label} plan does not match the ONNX model')

    mlmodel = ct.convert(
        build_program(steps),
        convert_to='mlprogram',
        minimum_deployment_target=ct.target.macOS14,
        compute_precision=ct.precision.FLOAT32,
    )
    config = cto.OptimizationConfig(global_config=cto.OpLinearQuantizerConfig(mode='linear_symmetric', dtype='int8'))
    mlmodel = cto.linear_quantize_weights(mlmodel, config=config)
    mlmodel.author = 'OpenCV Zoo SFace (Apache-2.0), converted for Moments'
    mlmodel.license = 'Apache-2.0'
    mlmodel.short_description = ('Face embedding. Input: 5-point aligned 112x112 RGB crop, 0...255. '
                                 'Output: 128-d embedding; L2-normalise and compare by cosine.')
    mlmodel.input_description['data'] = 'float32 [1,3,112,112] RGB 0...255'
    mlmodel.output_description['embedding'] = 'float32 [1,128]'
    mlmodel.save(args.output)
    print(f'saved {args.output}')


if __name__ == '__main__':
    main()
