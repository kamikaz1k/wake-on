from lobby_wake.cli import build_parser


def test_parser_uses_sherpa_default_trailing_blanks() -> None:
    args = build_parser().parse_args([])

    assert args.trailing_blanks == 1


def test_parser_accepts_zero_trailing_blanks() -> None:
    args = build_parser().parse_args(["--trailing-blanks", "0"])

    assert args.trailing_blanks == 0
