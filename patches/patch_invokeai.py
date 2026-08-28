"""Add version-checked Krea 2 ConvRot INT4 support to InvokeAI 6.14.0."""

from __future__ import annotations

import argparse
from pathlib import Path


CONVROT_HELPERS = '''
def _read_convrot_w4a4_layers(model_path: Path) -> dict[str, dict[str, Any]]:
    """Read Star/ComfyUI ConvRot W4A4 layer metadata from a safetensors checkpoint."""
    from safetensors import safe_open

    with safe_open(model_path, framework="pt", device="cpu") as checkpoint:
        raw_metadata = (checkpoint.metadata() or {}).get("_quantization_metadata")
    if raw_metadata is None:
        return {}

    metadata = json.loads(raw_metadata)
    if metadata.get("format_version") != "1.0" or not isinstance(metadata.get("layers"), dict):
        raise ValueError("Unsupported ConvRot checkpoint quantization metadata.")

    layers: dict[str, dict[str, Any]] = {}
    for layer_name, layer_config in metadata["layers"].items():
        if not isinstance(layer_name, str) or not isinstance(layer_config, dict):
            continue
        if layer_config.get("format") != "convrot_w4a4":
            continue
        for prefix in ("model.diffusion_model.", "diffusion_model."):
            if layer_name.startswith(prefix):
                layer_name = layer_name[len(prefix) :]
                break
        layers[layer_name] = layer_config
    return layers


def _wrap_convrot_w4a4_weights(
    sd: dict[str, Any], layers: dict[str, dict[str, Any]], compute_dtype: "torch.dtype"
) -> dict[str, Any]:
    """Keep packed ConvRot INT4 weights quantized for native comfy-kitchen execution."""
    import torch
    from comfy_kitchen.tensor import QuantizedTensor, TensorCoreConvRotW4A4Layout

    for layer_name, layer_config in layers.items():
        weight_key = f"{layer_name}.weight"
        scale_key = f"{layer_name}.weight_scale"
        if weight_key not in sd or scale_key not in sd:
            raise ValueError(f"ConvRot layer {layer_name!r} is missing its packed weight or scale.")

        qdata = sd[weight_key]
        scale = sd[scale_key]
        if qdata.dtype is not torch.int8 or qdata.ndim != 2:
            raise ValueError(
                f"ConvRot layer {layer_name!r} has invalid packed storage "
                f"(expected a 2-D int8 tensor, got {qdata.dtype} {tuple(qdata.shape)})."
            )

        params = TensorCoreConvRotW4A4Layout.Params(
            scale=scale,
            orig_dtype=compute_dtype,
            orig_shape=(qdata.shape[0], qdata.shape[1] * 2),
            convrot_groupsize=int(layer_config.get("convrot_groupsize", 256)),
            quant_group_size=int(layer_config.get("quant_group_size", 64)),
            linear_dtype=str(layer_config.get("linear_dtype", "int4")),
        )
        sd[weight_key] = QuantizedTensor(qdata, "TensorCoreConvRotW4A4Layout", params)
        del sd[scale_key]
    return sd


'''


OLD_LOAD_BLOCK = '''        sd = load_file(model_path)
        sd = _strip_comfyui_prefix(sd)
        # ComfyUI 'scaled fp8' checkpoints: fold the per-tensor weight_scale into the weights. The
        # compute dtype is resolved first so the dequantized weights land there directly instead of
        # transiently materializing the whole model in float32.
        sd = _dequantize_scaled_fp8(sd, model_dtype)
        # Native/ComfyUI key naming → diffusers Krea2Transformer2DModel keys.
        if _is_native_krea2_format(sd):
            sd = _convert_krea2_native_to_diffusers(sd)

        with accelerate.init_empty_weights():
            model = Krea2Transformer2DModel(**KREA2_TRANSFORMER_CONFIG)

        new_sd_size = sum(ten.nelement() * model_dtype.itemsize for ten in sd.values())
        self._ram_cache.make_room(new_sd_size)
        for k in sd.keys():
            sd[k] = sd[k].to(model_dtype)
'''


NEW_LOAD_BLOCK = '''        convrot_layers = _read_convrot_w4a4_layers(model_path)
        sd = load_file(model_path)
        sd = _strip_comfyui_prefix(sd)
        # Reserve room before scaled-fp8 expansion. Doing this after dequantization
        # leaves the previous model resident during the checkpoint's largest allocation.
        new_sd_size = sum(ten.nelement() * model_dtype.itemsize for ten in sd.values())
        source_sd_size = sum(ten.nelement() * ten.element_size() for ten in sd.values())
        if convrot_layers:
            # ConvRot weights remain packed and share their loaded qdata with the
            # model, so do not reserve for a fictitious bf16 expansion.
            self._ram_cache.make_room(source_sd_size)
            sd = _wrap_convrot_w4a4_weights(sd, convrot_layers, model_dtype)
        else:
            self._ram_cache.make_room(new_sd_size + source_sd_size)
        # ComfyUI 'scaled fp8' checkpoints: fold the per-tensor weight_scale into the weights. The
        # compute dtype is resolved first so the dequantized weights land there directly instead of
        # transiently materializing the whole model in float32.
        sd = _dequantize_scaled_fp8(sd, model_dtype)
        # Native/ComfyUI key naming → diffusers Krea2Transformer2DModel keys.
        if _is_native_krea2_format(sd):
            sd = _convert_krea2_native_to_diffusers(sd)

        with accelerate.init_empty_weights():
            model = Krea2Transformer2DModel(**KREA2_TRANSFORMER_CONFIG)

        for k in sd.keys():
            sd[k] = sd[k].to(model_dtype)
'''


CALC_OLD = '''    if callable(sdnq_storage_nbytes):
        return sdnq_storage_nbytes()
    return t.nelement() * t.element_size()
'''


CALC_NEW = '''    if callable(sdnq_storage_nbytes):
        return sdnq_storage_nbytes()
    # QuantizedTensor exposes its logical shape to PyTorch; nbytes is the real packed storage.
    if type(t) is not torch.Tensor and type(t) is not torch.nn.Parameter:
        packed_nbytes = getattr(t, "nbytes", None)
        if isinstance(packed_nbytes, int):
            return packed_nbytes
    return t.nelement() * t.element_size()
'''


def replace_once(path: Path, old: str, new: str, marker: str) -> None:
    text = path.read_text(encoding="utf-8")
    if marker in text:
        print(f"Already patched: {path}")
        return
    count = text.count(old)
    if count != 1:
        raise RuntimeError(f"Expected one patch target in {path}, found {count}")
    path.write_text(text.replace(old, new), encoding="utf-8")
    print(f"Patched: {path}")


def patch_krea2(path: Path) -> None:
    text = path.read_text(encoding="utf-8")
    if "def _read_convrot_w4a4_layers" in text:
        print(f"Already patched: {path}")
        return

    replacements = (
        (
            "from pathlib import Path\n",
            "import json\nfrom pathlib import Path\n",
            "json import",
        ),
        (
            "    out = dict(sd)\n",
            "    # Avoid retaining a second reference to the full fp8 checkpoint during expansion.\n"
            "    out = sd\n",
            "scaled-fp8 in-place conversion",
        ),
        (
            "def _convert_krea2_native_to_diffusers",
            CONVROT_HELPERS + "def _convert_krea2_native_to_diffusers",
            "ConvRot helpers",
        ),
        (OLD_LOAD_BLOCK, NEW_LOAD_BLOCK, "ConvRot load path"),
    )
    for old, new, label in replacements:
        count = text.count(old)
        if count != 1:
            raise RuntimeError(f"Expected one {label} patch target in {path}, found {count}")
        text = text.replace(old, new)
    path.write_text(text, encoding="utf-8")
    print(f"Patched: {path}")


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--site-packages", type=Path, required=True)
    args = parser.parse_args()

    invokeai_root = args.site_packages / "invokeai"
    krea2 = invokeai_root / "backend" / "model_manager" / "load" / "model_loaders" / "krea2.py"
    calc = invokeai_root / "backend" / "util" / "calc_tensor_size.py"

    patch_krea2(krea2)
    replace_once(calc, CALC_OLD, CALC_NEW, 'packed_nbytes = getattr(t, "nbytes", None)')


if __name__ == "__main__":
    main()
