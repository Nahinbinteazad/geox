"""A small per-visitor request limit for the open endpoints.

Why: once the server is public, anyone could call /shortlists or the scoring
routes in a loop and fill the database or slow the server for everyone. Each
route gets a budget of requests per minute for each visitor (IP address).

Kept in the server's memory, so it restarts from zero when the server restarts
and is per server process. That is enough to stop casual abuse; it is not a
firewall.

Behind a proxy (Render, Railway ...) every request seems to come from the proxy.
Set TRUST_PROXY=1 there so the visitor's address is read from X-Forwarded-For.
"""
from __future__ import annotations

import os
import time
from collections import defaultdict, deque

from fastapi import HTTPException, Request, status

_hits: dict[tuple[str, str], deque] = defaultdict(deque)


def _visitor(request: Request) -> str:
    if os.environ.get("TRUST_PROXY", "").strip() in {"1", "true", "yes"}:
        fwd = request.headers.get("x-forwarded-for", "")
        if fwd:
            return fwd.split(",")[0].strip()
    return request.client.host if request.client else "unknown"


def reset() -> None:
    """Forget all counts (used by the tests)."""
    _hits.clear()


def limit(name: str, max_requests: int, per_seconds: int = 60):
    """Dependency that allows max_requests per visitor in per_seconds."""

    def check(request: Request) -> None:
        if os.environ.get("RATE_LIMIT", "").strip().lower() == "off":
            return
        now = time.monotonic()
        q = _hits[(name, _visitor(request))]
        while q and now - q[0] > per_seconds:
            q.popleft()
        if len(q) >= max_requests:
            wait = max(1, int(per_seconds - (now - q[0])) + 1)
            raise HTTPException(
                status.HTTP_429_TOO_MANY_REQUESTS,
                f"Too many requests. Please wait {wait} seconds and try again.",
                headers={"Retry-After": str(wait)})
        q.append(now)

    return check