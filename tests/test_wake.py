from pathlib import Path

import pytest

from lobby_wake.wake import SherpaWakeWordEngine


def touch_model(directory: Path, component: str, chunk: int, *, int8: bool) -> Path:
    suffix = ".int8.onnx" if int8 else ".onnx"
    path = directory / f"{component}-epoch-1-chunk-{chunk}-left-64{suffix}"
    path.touch()
    return path


def test_find_component_selects_requested_chunk_and_variant(tmp_path: Path) -> None:
    expected = touch_model(tmp_path, "encoder", 8, int8=True)
    touch_model(tmp_path, "encoder", 8, int8=False)
    touch_model(tmp_path, "encoder", 16, int8=True)

    selected = SherpaWakeWordEngine._find_component(tmp_path, "encoder", "int8", 8)

    assert selected == expected


def test_find_component_reports_missing_chunk(tmp_path: Path) -> None:
    touch_model(tmp_path, "encoder", 16, int8=True)

    with pytest.raises(FileNotFoundError, match="chunk-8"):
        SherpaWakeWordEngine._find_component(tmp_path, "encoder", "int8", 8)


def test_int8_variant_uses_fp32_decoder_when_no_quantized_decoder_exists(
    tmp_path: Path,
) -> None:
    expected = touch_model(tmp_path, "decoder", 8, int8=False)

    selected = SherpaWakeWordEngine._find_component(tmp_path, "decoder", "int8", 8)

    assert selected == expected
