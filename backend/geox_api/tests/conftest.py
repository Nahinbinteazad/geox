import os, sys, tempfile
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
# a throwaway database per test session, so tests never touch a real one
os.environ["GEOX_DB"] = os.path.join(tempfile.mkdtemp(), "test.sqlite3")

import pytest
from fastapi.testclient import TestClient
from app.main import app
from app import store, ratelimit


@pytest.fixture(scope="session")
def client():
    store.init()
    with TestClient(app) as c:
        yield c


@pytest.fixture()
def token():
    """An unsigned token. Accepted only because SUPABASE_JWT_SECRET is unset,
    which is exactly the development mode /health warns about."""
    import jwt
    return jwt.encode({"sub": "user-123", "email": "tester@example.com"},
                      "unused", algorithm="HS256")


@pytest.fixture(autouse=True)
def _fresh_rate_limits():
    """Every test starts with an empty request count."""
    ratelimit.reset()
    yield
    ratelimit.reset()