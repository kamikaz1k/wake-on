from __future__ import annotations

from dataclasses import dataclass
from enum import StrEnum


class ConversationMediaPolicy(StrEnum):
    """Backend-neutral policy for conversation-time capture and playback."""

    RAW_FULL_DUPLEX = "raw-full-duplex"
    RAW_HALF_DUPLEX = "raw-half-duplex"
    NATIVE_AEC = "native-aec"


@dataclass(frozen=True, slots=True)
class ResolvedMediaPolicy:
    policy: ConversationMediaPolicy
    adapter: str
    full_duplex: bool
    aec_on_demand: bool


def resolve_media_policy(
    policy: ConversationMediaPolicy | str | None = None,
    *,
    legacy_adapter: str | None = None,
    legacy_full_duplex: bool | None = None,
) -> ResolvedMediaPolicy:
    """Resolve the public policy to the current concrete media implementation.

    The legacy arguments keep existing command lines working while callers move
    to the single explicit policy boundary.
    """

    if policy is not None and (legacy_adapter is not None or legacy_full_duplex is not None):
        raise ValueError("--media-policy cannot be combined with legacy media options")

    if policy is None and (legacy_adapter is not None or legacy_full_duplex is not None):
        adapter = legacy_adapter or "raw"
        full_duplex = True if legacy_full_duplex is None else legacy_full_duplex
        if adapter == "native-macos":
            if not full_duplex:
                raise ValueError("native macOS AEC requires full-duplex conversation audio")
            policy = ConversationMediaPolicy.NATIVE_AEC
        else:
            policy = (
                ConversationMediaPolicy.RAW_FULL_DUPLEX
                if full_duplex
                else ConversationMediaPolicy.RAW_HALF_DUPLEX
            )

    selected = ConversationMediaPolicy(
        policy or ConversationMediaPolicy.RAW_FULL_DUPLEX
    )
    if selected is ConversationMediaPolicy.NATIVE_AEC:
        return ResolvedMediaPolicy(selected, "native-macos", True, True)
    if selected is ConversationMediaPolicy.RAW_HALF_DUPLEX:
        return ResolvedMediaPolicy(selected, "raw", False, False)
    return ResolvedMediaPolicy(selected, "raw", True, False)
