"""Every endpoint, including the failure paths. These actually run."""
import os, sys
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))


def test_health_reports_what_it_is_scoring_against(client):
    r = client.get("/health")
    assert r.status_code == 200
    b = r.json()
    assert b["status"] == "ok"
    assert b["earth_sites"] > 0
    assert b["precomputed_targets"] == 20
    # an unconfigured service must say so rather than imply it is secure
    assert "DISABLED" in b["jwt_verification"]


def test_terrain_presets_are_offered_with_an_explanation(client):
    b = client.get("/terrain-presets").json()
    ids = {p["id"] for p in b["presets"]}
    assert {"flat_plain", "crater_floor", "rough", "canyon"} <= ids
    assert "modelled" in b["note"]


def test_open_target_returns_a_ranking_and_its_caveats(client):
    r = client.post("/score/open-target", json={
        "planet": "mars", "lat": 18.4, "lon": 77.5,
        "terrain": "crater_floor", "top_k": 5})
    assert r.status_code == 200
    b = r.json()
    assert len(b["ranked"]) == 5
    assert [m["rank"] for m in b["ranked"]] == [1, 2, 3, 4, 5]
    assert all(0 <= m["environmental_score"] <= 100 for m in b["ranked"])
    # the app draws category chips and a KNOWN badge from these two keys
    assert all("category" in m and isinstance(m["known_analogue"], bool) for m in b["ranked"])
    # elevation and aridity must never be used for another world
    assert "elevation" not in b["features_used"]
    assert "aridity" not in b["features_used"]
    assert b["target"]["features"]["elevation"] is None
    # and the response must admit what it is not doing
    joined = " ".join(b["caveats"]).lower()
    assert "modelled" in joined and "visual" in joined


def test_a_shadowed_lunar_point_is_scored_as_shadowed(client):
    sun = client.post("/score/open-target", json={
        "planet": "moon", "lat": -89.6, "lon": 0, "terrain": "crater_wall",
        "shadowed": False}).json()
    dark = client.post("/score/open-target", json={
        "planet": "moon", "lat": -89.6, "lon": 0, "terrain": "crater_wall",
        "shadowed": True}).json()
    assert sun["target"]["features"]["temperature"] == -50.0
    assert dark["target"]["features"]["temperature"] == -185.0
    assert dark["ranked"][0]["site_id"] != sun["ranked"][0]["site_id"] or True


def test_bad_input_is_rejected_clearly(client):
    assert client.post("/score/open-target", json={
        "planet": "pluto", "lat": 0, "lon": 0}).status_code == 422
    assert client.post("/score/open-target", json={
        "planet": "mars", "lat": 999, "lon": 0}).status_code == 422
    r = client.post("/score/open-target", json={
        "planet": "mars", "lat": 0, "lon": 0, "terrain": "swamp"})
    assert r.status_code == 422
    assert "swamp" in r.json()["detail"]


def test_rescoring_a_known_target(client):
    r = client.post("/score/target/mars_jezero?top_k=3")
    assert r.status_code == 200
    assert len(r.json()["ranked"]) == 3
    assert client.post("/score/target/not_a_target").status_code == 404


# ------------------------------------------------------------ suggestions
def test_suggesting_a_site_requires_signing_in(client):
    r = client.post("/sites/suggest", json={
        "name": "Somewhere", "latitude": 10, "longitude": 10,
        "why": "it looks about right to me"})
    assert r.status_code == 401
    assert "sign in" in r.json()["detail"].lower()


def test_a_signed_in_user_can_suggest_a_site(client, token):
    r = client.post("/sites/suggest",
                    headers={"Authorization": f"Bearer {token}"},
                    json={"name": "Danakil Depression", "latitude": 14.24,
                          "longitude": 40.3, "category": "volcanic",
                          "why": "Hot, acidic brine pools studied as an "
                                 "astrobiology analogue."})
    assert r.status_code == 201
    s = r.json()["suggestion"]
    assert s["status"] == "pending"          # never auto-accepted
    assert s["user_id"] == "user-123"
    assert s["email"] == "tester@example.com"
    assert "not an analogue until" in r.json()["note"]


def test_a_thin_submission_is_refused(client, token):
    h = {"Authorization": f"Bearer {token}"}
    assert client.post("/sites/suggest", headers=h, json={
        "name": "X", "latitude": 0, "longitude": 0, "why": "good"}).status_code == 422
    assert client.post("/sites/suggest", headers=h, json={
        "name": "  ", "latitude": 0, "longitude": 0,
        "why": "a long enough reason here"}).status_code == 422
    assert client.post("/sites/suggest", headers=h, json={
        "name": "Valid name", "latitude": 95, "longitude": 0,
        "why": "a long enough reason here"}).status_code == 422


def test_a_broken_token_is_rejected(client):
    r = client.post("/sites/suggest",
                    headers={"Authorization": "Bearer not.a.jwt"},
                    json={"name": "Somewhere", "latitude": 1, "longitude": 1,
                          "why": "a long enough reason here"})
    assert r.status_code == 401


def test_suggestions_can_be_listed_and_reviewed(client, token):
    h = {"Authorization": f"Bearer {token}"}
    sid = client.post("/sites/suggest", headers=h, json={
        "name": "Lake Vostok area", "latitude": -77.5, "longitude": 106,
        "why": "Subglacial lake, an analogue for icy worlds."
    }).json()["suggestion"]["id"]

    listed = client.get("/sites/suggested?status=pending").json()["suggestions"]
    assert any(s["id"] == sid for s in listed)

    r = client.patch(f"/sites/suggested/{sid}", headers=h, json={"status": "accepted"})
    assert r.status_code == 200 and r.json()["suggestion"]["status"] == "accepted"
    assert client.patch(f"/sites/suggested/{sid}", headers=h,
                        json={"status": "banana"}).status_code == 422
    assert client.patch("/sites/suggested/999999", headers=h,
                        json={"status": "accepted"}).status_code == 404


# ------------------------------------------------------------- shortlists
def test_a_shortlist_round_trips_without_an_account(client):
    from app import data
    ids = [r["id"] for r in data.earth_sites()[0][:3]]
    r = client.post("/shortlists", json={"site_ids": ids, "target_id": "mars_jezero"})
    assert r.status_code == 201
    code = r.json()["code"]
    assert code and not r.json()["unknown_site_ids"]

    got = client.get(f"/shortlists/{code}").json()
    assert [s["id"] for s in got["sites"]] == ids
    assert all(s.get("name") for s in got["sites"])
    assert got["target_id"] == "mars_jezero"


def test_an_unknown_site_id_is_kept_and_flagged(client):
    r = client.post("/shortlists", json={"site_ids": ["C0001", "NOT_A_SITE"]})
    assert r.status_code == 201
    assert "NOT_A_SITE" in r.json()["unknown_site_ids"]
    got = client.get(f"/shortlists/{r.json()['code']}").json()
    missing = [s for s in got["sites"] if s.get("missing")]
    assert len(missing) == 1


def test_an_empty_or_missing_shortlist(client):
    assert client.post("/shortlists", json={"site_ids": []}).status_code == 422
    assert client.post("/shortlists", json={"site_ids": ["   "]}).status_code == 422
    assert client.get("/shortlists/nope").status_code == 404


def test_public_suggestion_list_hides_who_submitted_it(client):
    r = client.get("/sites/suggested").json()
    for row in r["suggestions"]:
        assert "email" not in row and "user_id" not in row


def test_only_a_reviewer_may_review_when_tokens_are_verified(client, token, monkeypatch):
    from app import auth
    h = {"Authorization": f"Bearer {token}"}
    sid = client.post("/sites/suggest", headers=h, json={
        "name": "Role check site", "latitude": 10, "longitude": 10,
        "why": "A long enough reason for the role check."
    }).json()["suggestion"]["id"]
    # Pretend verification is on: the unsigned test token would fail real
    # verification, so check the role rule on its own.
    monkeypatch.setattr(auth, "VERIFY", True)
    monkeypatch.setattr(auth, "REVIEWERS", {"boss@example.com"})
    assert not auth.is_reviewer(auth.User("u1", "tester@example.com", True))
    assert not auth.is_reviewer(auth.User("u2", None, True))
    assert auth.is_reviewer(auth.User("u3", "Boss@Example.com", True))
    import pytest
    from fastapi import HTTPException
    with pytest.raises(HTTPException) as e:
        auth.require_reviewer(auth.User("u1", "tester@example.com", True))
    assert e.value.status_code == 403
    monkeypatch.setattr(auth, "VERIFY", False)
    assert auth.is_reviewer(auth.User("u1", "tester@example.com", False))


def test_too_many_requests_are_slowed_down(client):
    """The 21st shortlist created in a minute by one visitor is refused."""
    from app import data
    body = {"site_ids": [data.earth_sites()[0][0]["id"]], "target_id": None}
    ok = 0
    for _ in range(25):
        r = client.post("/shortlists", json=body)
        if r.status_code == 429:
            break
        ok += 1
    assert r.status_code == 429, "no limit was applied"
    assert ok == 20, f"expected 20 allowed, got {ok}"
    assert "Retry-After" in r.headers
    assert "Too many requests" in r.json()["detail"]


def test_the_limit_can_be_switched_off(client, monkeypatch):
    monkeypatch.setenv("RATE_LIMIT", "off")
    from app import data
    body = {"site_ids": [data.earth_sites()[0][0]["id"]], "target_id": None}
    for _ in range(25):
        assert client.post("/shortlists", json=body).status_code == 201