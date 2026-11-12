"""GeoX API.

What this service is for: the three things the Flutter app cannot do on its own.

  1. Score a Mars or Moon coordinate nobody precomputed  (open target mode)
  2. Receive a suggested Earth site and keep it          (suggest a new site)
  3. Turn a shortlist into a link a teammate can open    (share the shortlist)

Everything else in the app reads a bundled file and needs no server, which is
deliberate: if this service is down, the demo still runs.
"""
from __future__ import annotations

import os
from fastapi import Depends, FastAPI, HTTPException, Query, status
from fastapi.middleware.cors import CORSMiddleware

from . import data, store
from .ratelimit import limit
from .auth import (REVIEWERS, User, current_user, require_reviewer, require_user,
                   VERIFY as JWT_VERIFIED)
from .schemas import (OpenTargetRequest, ShortlistRequest, StatusUpdate,
                      SuggestSiteRequest)
from .scoring import TERRAIN_PRESETS, build_target, rank_sites

app = FastAPI(
    title="GeoX API",
    version="1.0.0",
    description=__doc__,
)

origins = [o for o in os.getenv("CORS_ORIGINS", "*").split(",") if o]
app.add_middleware(
    CORSMiddleware,
    allow_origins=origins or ["*"],
    allow_credentials=False,  # the app sends a bearer token, not cookies
    allow_methods=["*"],
    allow_headers=["*"],
)


@app.on_event("startup")
def _startup() -> None:
    store.init()
    if JWT_VERIFIED and origins in ([], ["*"]):
        print("WARNING: CORS_ORIGINS is not set, so any website may call this API. "
              "Set it to the app's address before deploying.")
    if JWT_VERIFIED and not REVIEWERS:
        print("NOTE: REVIEWER_EMAILS is empty, so nobody can accept or reject suggestions.")


@app.get("/health", tags=["meta"])
def health() -> dict:
    rows, source = data.earth_sites()
    return {
        "status": "ok",
        "earth_sites": len(rows),
        "earth_source": source,
        "precomputed_targets": len(data.targets()),
        "reviewers_configured": len(REVIEWERS),
        "cors_open_to_all": origins in ([], ["*"]),
        "jwt_verification": "enabled" if JWT_VERIFIED else
                            "DISABLED - set SUPABASE_URL (or SUPABASE_JWT_SECRET) before deploying",
    }


@app.get("/terrain-presets", tags=["scoring"])
def terrain_presets() -> dict:
    return {
        "presets": [{"id": k, **v} for k, v in TERRAIN_PRESETS.items()],
        "note": "Nobody has measured slope and roughness at an arbitrary point on "
                "another world, so the caller picks the terrain this point resembles "
                "and the answer is labelled modelled.",
    }


@app.get("/targets", tags=["scoring"])
def list_targets() -> dict:
    return {"targets": [
        {"id": t["id"], "planet": t["planet"], "name": t["name"],
         "lat": t["lat"], "lon": t["lon"], "description": t.get("description")}
        for t in data.targets()]}


@app.post("/score/open-target", tags=["scoring"],
          dependencies=[Depends(limit("score", 60))])
def score_open_target(req: OpenTargetRequest) -> dict:
    """Rank Earth sites against a coordinate the user just chose."""
    try:
        target, notes = build_target(req.planet, req.lat, req.lon, req.terrain,
                                     shadowed=req.shadowed)
    except ValueError as e:
        raise HTTPException(status.HTTP_422_UNPROCESSABLE_ENTITY, str(e)) from e

    rows, source = data.earth_sites()
    ranked, feats = rank_sites(rows, target.as_dict(), top_k=req.top_k)
    return {
        "target": {"planet": req.planet, "lat": req.lat, "lon": req.lon,
                   "terrain": req.terrain, "shadowed": req.shadowed,
                   "features": target.as_dict()},
        "features_used": feats,
        "earth_source": source,
        "ranked": ranked,
        "caveats": notes + [
            "Environmental similarity only. The visual half of the GeoX score needs "
            "a satellite tile of this exact coordinate, which does not exist for a "
            "point chosen on the fly, so it is omitted rather than guessed.",
            "Scores are rescaled across the candidate set, so they rank within this "
            "result and are not an absolute physical measurement.",
        ],
    }


@app.post("/score/target/{target_id}", tags=["scoring"],
          dependencies=[Depends(limit("score", 60))])
def rescore_known_target(target_id: str, top_k: int = Query(25, ge=1, le=100)) -> dict:
    """Re-rank a precomputed target through the same live code path.

    Useful as a check: the result should agree with the shipped file.
    """
    t = data.target_by_id(target_id)
    if t is None:
        raise HTTPException(status.HTTP_404_NOT_FOUND, f"no target {target_id!r}")
    rows, source = data.earth_sites()
    ranked, feats = rank_sites(rows, t["features"], top_k=top_k)
    return {"target_id": target_id, "features_used": feats,
            "earth_source": source, "ranked": ranked}


# ------------------------------------------------------------- suggestions
@app.post("/sites/suggest", status_code=status.HTTP_201_CREATED, tags=["community"],
          dependencies=[Depends(limit("suggest", 10))])
def suggest_site(req: SuggestSiteRequest,
                 user: User = Depends(require_user)) -> dict:
    """Submit a candidate Earth site. Signing in is required, so a submission
    can be traced to an account and spam has a cost."""
    row = store.add_suggestion(
        name=req.name, latitude=req.latitude, longitude=req.longitude,
        why=req.why, category=req.category, user_id=user.id, email=user.email)
    return {"suggestion": row,
            "note": "Stored as pending. A suggestion is not an analogue until "
                    "someone reviews it."}


@app.get("/sites/suggested", tags=["community"])
def suggested(status_filter: str | None = Query(None, alias="status"),
              limit: int = Query(50, ge=1, le=200)) -> dict:
    # The list is public, so it must not expose who submitted what.
    rows = store.list_suggestions(status_filter, limit)
    return {"suggestions": [{k: v for k, v in r.items()
                             if k not in ("email", "user_id")} for r in rows]}


@app.patch("/sites/suggested/{sid}", tags=["community"])
def review(sid: int, body: StatusUpdate,
           user: User = Depends(require_reviewer)) -> dict:
    row = store.set_status(sid, body.status)
    if row is None:
        raise HTTPException(status.HTTP_404_NOT_FOUND, "no such suggestion")
    return {"suggestion": row}


# -------------------------------------------------------------- shortlists
@app.post("/shortlists", status_code=status.HTTP_201_CREATED, tags=["community"],
          dependencies=[Depends(limit("shortlist-create", 20))])
def create_shortlist(req: ShortlistRequest,
                     user: User | None = Depends(current_user)) -> dict:
    """Turn a shortlist into a short code a teammate can open. Works signed out,
    because sharing a list of public sites needs no account."""
    known = {r["id"] for r in data.earth_sites()[0]}
    unknown = [s for s in req.site_ids if s not in known]
    saved = store.save_shortlist(req.site_ids, req.target_id,
                                 user.id if user else None)
    return {**saved,
            "unknown_site_ids": unknown,
            "note": "Unknown ids are kept rather than dropped, so a list made "
                    "against a newer dataset still opens." if unknown else None}


@app.get("/shortlists/{code}", tags=["community"],
         dependencies=[Depends(limit("shortlist-read", 120))])
def read_shortlist(code: str) -> dict:
    row = store.get_shortlist(code)
    if row is None:
        raise HTTPException(status.HTTP_404_NOT_FOUND, "no shortlist with that code")
    rows = {r["id"]: r for r in data.earth_sites()[0]}
    return {
        "code": row["code"],
        "target_id": row["target_id"],
        "created_at": row["created_at"],
        # every key is always present, including "missing". A client should never
        # have to infer a field's meaning from its absence.
        "sites": [
            {"id": sid,
             "name": rows[sid]["name"] if sid in rows else None,
             "lat": rows[sid]["lat"] if sid in rows else None,
             "lon": rows[sid]["lon"] if sid in rows else None,
             "missing": sid not in rows}
            for sid in row["site_ids"]
        ],
    }