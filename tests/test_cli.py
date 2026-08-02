from lobby_wake.cli import build_parser


def test_parser_uses_low_latency_wake_defaults() -> None:
    args = build_parser().parse_args([])

    assert args.model_chunk == 8
    assert args.max_active_paths == 16
    assert args.trailing_blanks == 0
    assert args.score == 2.0
    assert args.threshold == 0.1
    assert args.realtime_vad == "server_vad"
    assert args.vad_silence_ms == 300
    assert args.full_duplex is True


def test_parser_accepts_zero_trailing_blanks() -> None:
    args = build_parser().parse_args(["--trailing-blanks", "0"])

    assert args.trailing_blanks == 0


def test_parser_can_disable_full_duplex_fallback() -> None:
    args = build_parser().parse_args(["--no-full-duplex"])

    assert args.full_duplex is False
