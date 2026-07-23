"""CLI entry point for the client-owned Godot AI stdio bridge."""

from __future__ import annotations

import argparse
import asyncio
import sys
from collections.abc import Sequence

import httpx

from godot_ai.attach.ensure import AttachStartupError, BackendEnsurer, probe_backend
from godot_ai.attach.lease import LeaseClient
from godot_ai.attach.proxy import (
    DEFAULT_MONITOR_PROBE_TIMEOUT_SECONDS,
    create_attach_proxy,
)
from godot_ai.tools.domains import parse_exclude_list


def _parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(prog="godot-ai attach", description="Godot AI stdio bridge")
    parser.add_argument("--port", type=int, default=8000, help="Shared backend HTTP port")
    parser.add_argument("--ws-port", type=int, default=9500, help="Godot editor WebSocket port")
    parser.add_argument(
        "--exclude-domains",
        default="",
        help="Comma-separated backend tool domains to exclude",
    )
    return parser


async def run_attach(port: int, ws_port: int, exclude_domains: tuple[str, ...]) -> None:
    ensurer = BackendEnsurer(port, ws_port, exclude_domains)
    lease: LeaseClient

    async def ensure_ready():
        status = await ensurer.ensure()
        await lease.sync(status)
        return status

    async def observe_backend():
        # In-flight observation must never acquire the spawn lock or create a
        # backend. A slow/inconclusive probe is handled conservatively by the
        # monitor's consecutive-failure threshold.
        return await probe_backend(port, timeout=DEFAULT_MONITOR_PROBE_TIMEOUT_SECONDS)

    # Lease recovery calls the raw ensure operation. Passing ensure_ready here
    # would recurse back into lease.sync() while the lease lock is held.
    lease = LeaseClient(ensurer.base_url, ensurer.ensure)
    initial_status = await ensurer.ensure()
    await lease.start(initial_status)
    proxy = create_attach_proxy(ensurer.mcp_url, ensure_ready, observe_backend)
    try:
        await proxy.run_async(transport="stdio", show_banner=False)
    finally:
        await lease.close()


def main(argv: Sequence[str] | None = None) -> None:
    parser = _parser()
    args = parser.parse_args(argv)
    try:
        exclude_domains = tuple(sorted(parse_exclude_list(args.exclude_domains)))
    except ValueError as exc:
        parser.error(str(exc))
    try:
        asyncio.run(run_attach(args.port, args.ws_port, exclude_domains))
    except AttachStartupError as exc:
        print(exc.stderr_text(), file=sys.stderr)
        raise SystemExit(exc.exit_code) from exc
    except httpx.HTTPError as exc:
        print(
            f"godot-ai attach [ATTACH_START_FAILED]: failed to establish the backend lease. {exc}",
            file=sys.stderr,
        )
        raise SystemExit(1) from exc
