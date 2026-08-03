"""Wake-word detection and conversation orchestration."""

from .agent import (
    AudioInputOwnership,
    ConversationDelegate,
    DelegateCapabilities,
    DelegateHealth,
    DelegatePrepareContext,
    DelegateStartContext,
    DelegateStatus,
)
from .conversation import (
    ConversationController,
    ConversationHandle,
    EndConversationRequest,
    EndMode,
    EndSource,
)
from .process_delegate import ProcessConversationDelegate

__all__ = [
    "AudioInputOwnership",
    "ConversationDelegate",
    "ConversationController",
    "ConversationHandle",
    "DelegateCapabilities",
    "DelegateHealth",
    "DelegatePrepareContext",
    "DelegateStartContext",
    "DelegateStatus",
    "EndConversationRequest",
    "EndMode",
    "EndSource",
    "ProcessConversationDelegate",
]

__version__ = "0.1.0"
