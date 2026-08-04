from lobby_wake.cli import build_parser
from lobby_wake.media_policy import ConversationMediaPolicy, resolve_media_policy


def test_parser_uses_low_latency_wake_defaults() -> None:
    args = build_parser().parse_args([])

    assert args.model_chunk == 8
    assert args.max_active_paths == 16
    assert args.trailing_blanks == 0
    assert args.score == 2.0
    assert args.threshold == 0.1
    assert args.realtime_vad == "server_vad"
    assert args.vad_silence_ms == 300
    assert args.media_policy is None
    assert args.full_duplex is None
    assert args.conversation_media is None
    assert resolve_media_policy(args.media_policy).policy is (
        ConversationMediaPolicy.RAW_FULL_DUPLEX
    )


def test_parser_accepts_zero_trailing_blanks() -> None:
    args = build_parser().parse_args(["--trailing-blanks", "0"])

    assert args.trailing_blanks == 0


def test_parser_can_disable_full_duplex_fallback() -> None:
    args = build_parser().parse_args(["--no-full-duplex"])

    assert args.full_duplex is False


def test_parser_accepts_native_macos_conversation_media() -> None:
    args = build_parser().parse_args(["--conversation-media", "native-macos"])

    assert args.conversation_media == "native-macos"


def test_parser_accepts_explicit_media_policies() -> None:
    args = build_parser().parse_args(["--media-policy", "native-aec"])

    resolved = resolve_media_policy(args.media_policy)
    assert resolved.policy is ConversationMediaPolicy.NATIVE_AEC
    assert resolved.aec_on_demand is True
    assert resolved.full_duplex is True


def test_legacy_half_duplex_maps_to_explicit_policy() -> None:
    args = build_parser().parse_args(["--no-full-duplex"])

    resolved = resolve_media_policy(legacy_full_duplex=args.full_duplex)
    assert resolved.policy is ConversationMediaPolicy.RAW_HALF_DUPLEX


def test_parser_preserves_external_delegate_command_arguments() -> None:
    args = build_parser().parse_args(
        [
            "--agent",
            "process",
            "--delegate-audio-input",
            "delegate",
            "--delegate-command",
            "python",
            "worker.py",
            "--backend-option",
            "value",
        ]
    )

    assert args.delegate_audio_input == "delegate"
    assert args.delegate_command == [
        "python",
        "worker.py",
        "--backend-option",
        "value",
    ]
