"""Wake-word detection and conversation orchestration."""

from .conversation import (
    ConversationController,
    ConversationHandle,
    EndConversationRequest,
    EndMode,
    EndSource,
)

__all__ = [
    "ConversationController",
    "ConversationHandle",
    "EndConversationRequest",
    "EndMode",
    "EndSource",
]

__version__ = "0.1.0"
