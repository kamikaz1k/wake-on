from __future__ import annotations

import sys

source = sys.stdin.read()
namespace = {"__name__": "__macos_harness_fixture__"}
exec(compile(source, "<macos-harness-fixture>", "exec"), namespace, namespace)
