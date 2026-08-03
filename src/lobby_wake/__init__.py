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
from .events import WakeEvent, normalize_trigger_id
from .orchestrator import Orchestrator, State, WakeListener, WakeRoute, WakeRouter
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
    "Orchestrator",
    "State",
    "WakeListener",
    "WakeEvent",
    "WakeRoute",
    "WakeRouter",
    "normalize_trigger_id",
]

__version__ = "0.1.0"
