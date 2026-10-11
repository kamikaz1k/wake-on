"""Standalone Sky diagnostics and tasks, independent of microphone/Realtime setup."""
from __future__ import annotations

import argparse
import json
import math
import subprocess
import time
from dataclasses import asdict
from pathlib import Path

from .events import EventLogger
from .sky_task import DEFAULT_CODEX_COMMAND, CodexSkyTaskRunner, parse_codex_command

DEFAULT_ARCHIVE = Path.home() / "workspace/sky-lib-archive"
DEFAULT_NODE = Path("/Applications/ChatGPT.app/Contents/Resources/cua_node/bin/node")


def inspect_archive(archive: Path) -> dict:
    """Resolve the latest capture without executing code or changing the archive."""
    captures = sorted((archive / "captures").glob("*.json"))
    if not captures:
        raise ValueError(f"No captures found in {archive}")
    capture = json.loads(captures[-1].read_text())
    snapshot = (archive / capture["snapshot"]).resolve()
    if not snapshot.is_relative_to((archive / "snapshots").resolve()):
        raise ValueError("Capture snapshot escapes archive/snapshots")
    package = snapshot / "payload/node_modules/@oai/sky"
    metadata = json.loads((package / "package.json").read_text())
    entry = (package / metadata["main"]).resolve()
    if not entry.is_relative_to(package) or not entry.is_file():
        raise ValueError("Sky package entry point is missing or outside the package")
    if metadata["version"] != capture["sky"]["version"]:
        raise ValueError("Capture and package versions disagree")
    return {
        "capture": str(captures[-1]),
        "captured_at": capture["capturedAt"],
        "sky_version": metadata["version"],
        "entry_point": str(entry),
        "payload_sha256": capture["payloadSha256"],
        "integrity_verified": False,
    }


def probe_archive(entry: str, node: str) -> dict:
    # No injected nativePipe, forged host identity, or policy overrides.
    script = '''
try {
  const {sky} = await import(process.argv[1]);
  await sky.list_apps();
  console.log(JSON.stringify({status: "available"}));
} catch (error) {
  console.log(JSON.stringify({status: "unavailable", reason: error.message}));
  process.exitCode = 1;
}
'''
    try:
        result = subprocess.run(
            [node, "--input-type=module", "-e", script, Path(entry).as_uri()],
            capture_output=True, text=True, timeout=15, check=False,
        )
        for line in reversed(result.stdout.splitlines()):
            try:
                value = json.loads(line)
            except json.JSONDecodeError:
                continue
            if isinstance(value, dict) and value.get("status") in {"available", "unavailable"}:
                return value
        return {"status": "unavailable", "reason": f"Node exited {result.returncode}"}
    except (OSError, subprocess.TimeoutExpired) as error:
        return {"status": "unavailable", "reason": str(error)}


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="command", required=True)
    doctor = sub.add_parser("doctor", help="Inspect archive and probe direct read-only SDK access")
    doctor.add_argument("--archive", type=Path, default=DEFAULT_ARCHIVE)
    doctor.add_argument("--node", default=str(DEFAULT_NODE))
    run = sub.add_parser("run", help="Run a bounded task using Sky in an authenticated Codex host")
    run.add_argument("task")
    run.add_argument("--app", required=True)
    run.add_argument("--codex-command", default=DEFAULT_CODEX_COMMAND)
    run.add_argument("--model", default="gpt-5.6-luna")
    run.add_argument("--timeout", type=float, default=180)
    run.add_argument("--log", type=Path)
    args = parser.parse_args(argv)
    if args.command == "doctor":
        try:
            report = inspect_archive(args.archive)
            report["direct_sdk"] = probe_archive(report["entry_point"], args.node)
        except (OSError, ValueError, KeyError) as error:
            print(json.dumps({"status": "error", "reason": str(error)}))
            return 1
        print(json.dumps(report, indent=2))
        return 0 if report["direct_sdk"]["status"] == "available" else 1
    if not math.isfinite(args.timeout) or args.timeout <= 0:
        parser.error("--timeout must be finite and positive")
    logger = EventLogger(output=args.log)
    runner = CodexSkyTaskRunner(
        logger, allowed_applications=frozenset({args.app}),
        command=parse_codex_command(args.codex_command), model=args.model,
        timeout_seconds=args.timeout,
    )
    try:
        runner.prepare()
        runner.start(args.task, args.app)
        while True:
            for event in runner.poll_events():
                if event.terminal:
                    print(json.dumps(asdict(event)))
                    return 0 if event.status == "completed" else 1
            time.sleep(0.05)
    except KeyboardInterrupt:
        return 130
    except (OSError, RuntimeError, ValueError) as error:
        print(json.dumps({"status": "failed", "reason": str(error)}))
        return 1
    finally:
        runner.close()
        logger.close()


if __name__ == "__main__":
    raise SystemExit(main())
