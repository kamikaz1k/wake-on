from __future__ import annotations

import json
from pathlib import Path

import pytest

from lobby_wake.sky_cli import inspect_archive, main


def make_archive(tmp_path: Path) -> Path:
    package = tmp_path / "snapshots/v1/hash/payload/node_modules/@oai/sky"
    package.mkdir(parents=True)
    (package / "index.js").write_text("")
    (package / "package.json").write_text(json.dumps({"version": "1", "main": "index.js"}))
    captures = tmp_path / "captures"
    captures.mkdir()
    (captures / "2026-10-08.json").write_text(json.dumps({
        "snapshot": "snapshots/v1/hash", "sky": {"version": "1"},
        "capturedAt": "2026-10-08", "payloadSha256": "hash",
    }))
    return tmp_path


def test_archive_resolves_entry_without_claiming_integrity(tmp_path: Path) -> None:
    report = inspect_archive(make_archive(tmp_path))
    assert report["sky_version"] == "1"
    assert Path(report["entry_point"]).is_file()
    assert report["integrity_verified"] is False


def test_archive_rejects_snapshot_path_escape(tmp_path: Path) -> None:
    archive = make_archive(tmp_path)
    capture = archive / "captures/2026-10-08.json"
    data = json.loads(capture.read_text())
    data["snapshot"] = "../outside"
    capture.write_text(json.dumps(data))
    with pytest.raises(ValueError, match="escapes"):
        inspect_archive(archive)


def test_missing_archive_is_actionable(tmp_path: Path, capsys: pytest.CaptureFixture) -> None:
    assert main(["doctor", "--archive", str(tmp_path)]) == 1
    assert "No captures" in capsys.readouterr().out
