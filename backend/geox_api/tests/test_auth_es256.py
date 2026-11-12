"""Supabase's current projects sign login tokens with an asymmetric key (ES256),
not the old shared secret. These tests prove the server verifies them, and
rejects forgeries, without needing a network: the public-key fetch is replaced
by a local key pair."""
import time
import jwt
import pytest
from cryptography.hazmat.primitives.asymmetric import ec
from fastapi import HTTPException
from fastapi.security import HTTPAuthorizationCredentials

from app import auth


class _FakeJWKS:
    def __init__(self, public_key):
        self._k = public_key

    def get_signing_key_from_jwt(self, _token):
        class K: pass
        k = K(); k.key = self._k
        return k


@pytest.fixture()
def es256(monkeypatch):
    good = ec.generate_private_key(ec.SECP256R1())
    monkeypatch.setattr(auth, "VERIFY", True)
    monkeypatch.setattr(auth, "JWT_SECRET", "")
    monkeypatch.setattr(auth, "_jwks", _FakeJWKS(good.public_key()))
    return good


def _tok(key, **over):
    claims = {"sub": "user-1", "email": "a@b.co", "aud": "authenticated",
              "exp": int(time.time()) + 600}
    claims.update(over)
    return jwt.encode(claims, key, algorithm="ES256", headers={"kid": "k1"})


def _call(token):
    return auth.current_user(HTTPAuthorizationCredentials(scheme="Bearer", credentials=token))


def test_a_genuine_es256_token_is_accepted(es256):
    u = _call(_tok(es256))
    assert u.id == "user-1" and u.verified is True


def test_a_token_signed_with_another_key_is_rejected(es256):
    forged = _tok(ec.generate_private_key(ec.SECP256R1()))
    with pytest.raises(HTTPException) as e:
        _call(forged)
    assert e.value.status_code == 401


def test_an_expired_token_is_rejected(es256):
    with pytest.raises(HTTPException) as e:
        _call(_tok(es256, exp=int(time.time()) - 10))
    assert e.value.status_code == 401


def test_an_hs256_token_is_refused_when_no_shared_secret_is_set(es256):
    t = jwt.encode({"sub": "x", "aud": "authenticated"}, "guess", algorithm="HS256")
    with pytest.raises(HTTPException) as e:
        _call(t)
    assert e.value.status_code == 401