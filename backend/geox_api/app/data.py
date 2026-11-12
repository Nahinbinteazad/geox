"""Loads the reference data the API scores against.

Two sources, in order of preference:
  1. earth_candidates.csv from the Kaggle dataset — all 600 sites, the real thing
  2. geox_data.json — the 89 sites that appear in a ranking, which ships with the app

The second is a fallback so the service starts with nothing else installed. The
response always says which one was used, because scoring against 89 sites and
scoring against 600 are not the same claim.
"""
from __future__ import annotations

import csv
import json
import os
from functools import lru_cache
from typing import Any

HERE = os.path.dirname(__file__)
GEOX_JSON = os.getenv("GEOX_DATA", os.path.join(HERE, "geox_data.json"))
EARTH_CSV = os.getenv("EARTH_CSV", os.path.join(HERE, "earth_candidates.csv"))

ENV_FEATURES = [
    "elevation", "slope", "roughness", "temperature",
    "temperature_variation", "aridity", "ndvi", "bare_ground",
]


@lru_cache(maxsize=1)
def geox() -> dict[str, Any]:
    with open(GEOX_JSON) as fh:
        return json.load(fh)


@lru_cache(maxsize=1)
def earth_sites() -> tuple[list[dict], str]:
    """Every Earth site with a complete set of features, plus where it came from."""
    if os.path.exists(EARTH_CSV):
        rows = []
        with open(EARTH_CSV, newline="") as fh:
            for r in csv.DictReader(fh):
                try:
                    feats = {f: float(r[f]) for f in ENV_FEATURES}
                except (KeyError, ValueError):
                    continue  # a site without a full set is dropped, never filled in
                rows.append({
                    "id": r.get("location_id"),
                    "name": r.get("name"),
                    "region": r.get("country"),
                    "category": r.get("category"),
                    "lat": float(r["latitude"]),
                    "lon": float(r["longitude"]),
                    "known_analogue": str(r.get("is_known_analogue", "")).lower() in ("true", "1"),
                    **feats,
                })
        if rows:
            return rows, f"earth_candidates.csv ({len(rows)} sites)"

    rows = []
    for s in geox()["sites"]:
        f = s.get("features") or {}
        if any(f.get(k) is None for k in ENV_FEATURES):
            continue
        rows.append({
            "id": s["id"], "name": s.get("name"), "region": s.get("region"),
            "category": s.get("category"), "lat": s["lat"], "lon": s["lon"],
            "known_analogue": bool(s.get("known_analogue")),
            **{k: float(f[k]) for k in ENV_FEATURES},
        })
    return rows, f"geox_data.json ({len(rows)} sites, the app's bundled subset)"


def targets() -> list[dict]:
    return geox()["targets"]


def target_by_id(tid: str) -> dict | None:
    for t in targets():
        if t["id"] == tid:
            return t
    return None
