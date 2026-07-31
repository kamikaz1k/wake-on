from __future__ import annotations

import io

from lobby_wake.conversation import (
    ConversationController,
    EndMode,
    EndSource,
)
from lobby_wake.events import EventLogger


def test_delegate_handle_requests_graceful_end() -> None:
    logger = EventLogger(stream=io.StringIO())
    controller = ConversationController(logger)
    controller.begin()

    accepted = controller.handle.end(
        reason="task_complete",
        farewell="All done.",
    )
    request = controller.take_request()

    assert accepted
    assert request is not None
    assert request.source is EndSource.DELEGATE
    assert request.mode is EndMode.GRACEFUL
    assert request.farewell == "All done."
    logger.close()


def test_end_request_is_ignored_without_active_conversation() -> None:
    logger = EventLogger(stream=io.StringIO())
    controller = ConversationController(logger)

    assert not controller.handle.end()
    assert controller.take_request() is None
    logger.close()


def test_immediate_end_supersedes_pending_graceful_end() -> None:
    logger = EventLogger(stream=io.StringIO())
    controller = ConversationController(logger)
    controller.begin()
    controller.handle.end(reason="task_complete")

    accepted = controller.request_end(
        source=EndSource.USER,
        reason="emergency_stop",
        mode=EndMode.IMMEDIATE,
    )
    request = controller.take_request()

    assert accepted
    assert request is not None
    assert request.source is EndSource.USER
    assert request.mode is EndMode.IMMEDIATE
    logger.close()


def test_stale_delegate_handle_cannot_end_new_conversation() -> None:
    logger = EventLogger(stream=io.StringIO())
    controller = ConversationController(logger)
    controller.begin()
    stale_handle = controller.handle
    controller.finish()
    controller.begin()

    assert not stale_handle.end(reason="late_completion")
    assert controller.take_request() is None
    logger.close()
