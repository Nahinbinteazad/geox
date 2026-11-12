"""Verifies the Supabase access token the Flutter app already holds.

Two modes, and the service says which one it is in on /health:

  * SUPABASE_URL set         -> tokens signed with Supabase's asymmetric keys
                                (ES256 / RS256, the default for new projects) are
                                verified against the project's public JWKS.
  * SUPABASE_JWT_SECRET set  -> tokens signed with the legacy HS256 shared
                                secret are verified.
  * neither set              -> the token is read but NOT verified, and every
                                protected route is open. Development only, and
                                the service announces it loudly at startup.

Reviewers (people who may accept or reject suggested sites) are listed by email
in REVIEWER_EMAILS, comma separated. With verification on, nobody else can review.
In development mode (nothing verified) every signed-in caller may, as before.

Never guess. A route that needs a user and cannot verify one must say so.
"""
from __future__ import annotations

import os
from dataclasses import dataclass

import jwt
from fastapi import Depends, HTTPException, status
from fastapi.security import HTTPAuthorizationCredentials, HTTPBearer

JWT_SECRET = os.getenv("SUPABASE_JWT_SECRET", "")
SUPABASE_URL = os.getenv("SUPABASE_URL", "").rstrip("/")
JWKS_URL = f"{SUPABASE_URL}/auth/v1/.well-known/jwks.json" if SUPABASE_URL else ""
VERIFY = bool(JWT_SECRET or JWKS_URL)

# Fetches the public keys lazily on the first token and caches them.
_jwks = jwt.PyJWKClient(JWKS_URL, cache_keys=True) if JWKS_URL else None

REVIEWERS = {e.strip().lower() for e in os.getenv("REVIEWER_EMAILS", "").split(",")
             if e.strip()}

bearer = HTTPBearer(auto_error=False)


@dataclass(frozen=True)
class User:
    id: str
    email: str | None
    verified: bool


def current_user(cred: HTTPAuthorizationCredentials | None = Depends(bearer)) -> User | None:
    """The signed-in user, or None. Never raises for an anonymous caller."""
    if cred is None or not cred.credentials:
        return None
    token = cred.credentials
    try:
        if VERIFY:
            alg = jwt.get_unverified_header(token).get("alg")
            if alg in ("ES256", "RS256") and _jwks is not None:
                key = _jwks.get_signing_key_from_jwt(token).key
                payload = jwt.decode(token, key, algorithms=[alg],
                                     audience="authenticated")
            elif alg == "HS256" and JWT_SECRET:
                payload = jwt.decode(token, JWT_SECRET, algorithms=["HS256"],
                                     audience="authenticated")
            else:
                raise HTTPException(status.HTTP_401_UNAUTHORIZED,
                                    detail=f"token algorithm {alg} is not accepted")
        else:
            payload = jwt.decode(token, options={"verify_signature": False})
    except jwt.PyJWTError as e:
        raise HTTPException(status.HTTP_401_UNAUTHORIZED,
                            detail=f"invalid token: {e}") from e
    sub = payload.get("sub")
    if not sub:
        raise HTTPException(status.HTTP_401_UNAUTHORIZED, detail="token has no subject")
    return User(id=sub, email=payload.get("email"), verified=VERIFY)


def require_user(user: User | None = Depends(current_user)) -> User:
    if user is None:
        raise HTTPException(status.HTTP_401_UNAUTHORIZED,
                            detail="sign in to use this endpoint")
    return user


def is_reviewer(user: User) -> bool:
    if not VERIFY:  # development mode: nothing is verified, so nothing is restricted
        return True
    return bool(user.email) and user.email.lower() in REVIEWERS


def require_reviewer(user: User = Depends(require_user)) -> User:
    if not is_reviewer(user):
        raise HTTPException(status.HTTP_403_FORBIDDEN,
                            detail="only a reviewer may accept or reject suggestions")
    return user