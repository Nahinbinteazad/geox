"""The matching engine, lifted from the ML notebook so the API scores a new
target exactly the way the precomputed results were scored.

Only the environmental half runs here. The visual half needs DINOv2 and a
satellite tile for the new coordinate, neither of which exists for a point the
user has just invented. The response says so rather than quietly dropping it.
"""
from __future__ import annotations

import math
from dataclasses import dataclass
from typing import Iterable, Sequence

import numpy as np
from sklearn.preprocessing import RobustScaler

# The same eight features the pipeline uses, in the same order.
ENV_FEATURES = [
    "elevation", "slope", "roughness", "temperature",
    "temperature_variation", "aridity", "ndvi", "bare_ground",
]

# Elevation and aridity never apply to another world: heights use a different
# reference surface on each body, and the aridity index is defined from rainfall.
TARGET_UNUSABLE = {"elevation", "aridity"}


@dataclass(frozen=True)
class TargetFeatures:
    """What we know about a point on Mars or the Moon."""
    planet: str
    lat: float
    lon: float
    slope: float
    roughness: float
    temperature: float
    temperature_variation: float
    ndvi: float = 0.0
    bare_ground: float = 1.0

    def as_dict(self) -> dict[str, float | None]:
        return {
            "elevation": None,
            "slope": self.slope,
            "roughness": self.roughness,
            "temperature": self.temperature,
            "temperature_variation": self.temperature_variation,
            "aridity": None,
            "ndvi": self.ndvi,
            "bare_ground": self.bare_ground,
        }


# ---------------------------------------------------------------- the model
# Latitude models from notebook cell 11, printed there and repeated here so the
# two can be compared. Annual means, to match the five-year annual mean of the
# Earth data.
def mean_temperature_c(planet: str, lat: float) -> float:
    c = math.cos(math.radians(lat))
    k = 150 + 70 * c if planet.lower() == "mars" else 143 + 125 * c
    return round(k - 273.15, 1)


def diurnal_range_c(planet: str, lat: float) -> float:
    c = math.cos(math.radians(lat))
    v = 55 * c + 5 if planet.lower() == "mars" else 250 * c
    return round(v, 1)


# A sunlit lunar polar ridge and a shadowed polar floor sit side by side, so
# latitude alone cannot describe them. These are the measured values.
SUNLIT_POLAR = (-50.0, 90.0)
SHADOWED_POLAR = (-185.0, 5.0)

TERRAIN_PRESETS: dict[str, dict] = {
    "flat_plain":   {"label": "Flat plain",        "slope": 1.0,  "roughness": 10.0},
    "crater_floor": {"label": "Crater floor",      "slope": 3.0,  "roughness": 30.0},
    "rough":        {"label": "Rugged highland",   "slope": 10.0, "roughness": 200.0},
    "canyon":       {"label": "Canyon or scarp",   "slope": 20.0, "roughness": 450.0},
    "crater_wall":  {"label": "Crater wall",       "slope": 30.0, "roughness": 400.0},
}


def build_target(planet: str, lat: float, lon: float, terrain: str,
                 shadowed: bool = False) -> tuple[TargetFeatures, list[str]]:
    """Features for a point nobody measured, with a note on every assumption."""
    if terrain not in TERRAIN_PRESETS:
        raise ValueError(f"unknown terrain preset {terrain!r}")
    p = TERRAIN_PRESETS[terrain]
    notes: list[str] = []

    polar = abs(lat) > 80 and planet.lower() == "moon"
    if polar and shadowed:
        temp, swing = SHADOWED_POLAR
        notes.append(
            "Treated as a permanently shadowed polar floor, using the measured "
            "88 K Shackleton floor values rather than the latitude model.")
    elif polar:
        temp, swing = SUNLIT_POLAR
        notes.append(
            "Treated as sunlit polar high ground, using the measured Shackleton "
            "rim value rather than the latitude model.")
    else:
        temp = mean_temperature_c(planet, lat)
        swing = diurnal_range_c(planet, lat)
        notes.append(
            f"Temperature and swing are modelled from latitude "
            f"({planet.title()} annual mean), not measured at this point.")

    notes.append(
        f"Slope and roughness come from the '{p['label']}' preset you chose. "
        "Nobody measured the terrain at this exact coordinate.")
    notes.append(
        "Elevation and aridity are not used: heights use a different reference "
        "surface on each world, and aridity is defined from rainfall.")

    return TargetFeatures(
        planet=planet, lat=lat, lon=lon,
        slope=p["slope"], roughness=p["roughness"],
        temperature=temp, temperature_variation=swing,
    ), notes


# ------------------------------------------------------------- the matching
def usable_features(target: dict[str, float | None]) -> list[str]:
    return [f for f in ENV_FEATURES
            if f not in TARGET_UNUSABLE and target.get(f) is not None]


def environmental_scores(earth_rows: Sequence[dict], target: dict[str, float | None]):
    """Weighted mean absolute difference in a shared scaled space, as 0..100.

    One scaler is fitted on Earth and the target TOGETHER. Fitting them apart
    would put the two worlds on different scales and destroy the comparison.
    """
    feats = usable_features(target)
    if not feats:
        raise ValueError("the target has no usable features")
    weights = np.full(len(feats), 1.0 / len(feats))

    E = np.array([[float(r[f]) for f in feats] for r in earth_rows], dtype=float)
    T = np.array([[float(target[f]) for f in feats]], dtype=float)

    scaler = RobustScaler().fit(np.vstack([E, T]))
    Es, Ts = scaler.transform(E), scaler.transform(T)[0]

    dist = (np.abs(Es - Ts[None, :]) * weights[None, :]).sum(axis=1)
    scores = 100.0 / (1.0 + dist)
    per_feature = {
        f: (100.0 / (1.0 + np.abs(Es[:, i] - Ts[i]))) for i, f in enumerate(feats)
    }
    return scores, per_feature, feats


def rescale(x: np.ndarray) -> np.ndarray:
    """Stretch across the candidate set, the way the notebook does before fusing."""
    lo, hi = float(np.nanmin(x)), float(np.nanmax(x))
    if not math.isfinite(lo) or hi - lo < 1e-9:
        return np.full_like(x, 50.0)
    return (x - lo) / (hi - lo) * 100.0


FINGERPRINT_GROUPS = {
    "terrain": ["slope", "roughness"],
    "thermal": ["temperature", "temperature_variation"],
    "aridity": ["aridity"],
    "vegetation": ["ndvi"],
    "bare_ground": ["bare_ground"],
}

MISSION_LENS = {
    "rover": ["slope", "roughness"],
    "geology": ["bare_ground", "roughness"],
    "astrobiology": ["aridity", "ndvi", "temperature"],
    "eva": ["temperature", "temperature_variation", "slope"],
    "isru": ["bare_ground", "aridity", "temperature"],
}

FEATURE_WORDS = {
    "slope": "slope",
    "roughness": "surface roughness",
    "temperature": "surface temperature",
    "temperature_variation": "day to night swing",
    "aridity": "dryness",
    "ndvi": "lack of vegetation",
    "bare_ground": "exposed bare ground",
}


def _group(per_feature, groups, idx):
    out = {}
    for name, feats in groups.items():
        vals = [per_feature[f][idx] for f in feats if f in per_feature]
        out[name] = round(float(np.mean(vals)), 1) if vals else None
    return out


def rank_sites(earth_rows: Sequence[dict], target: dict[str, float | None],
               top_k: int = 25) -> tuple[list[dict], list[str]]:
    """Rank every Earth site against one target and explain each result."""
    raw, per_feature, feats = environmental_scores(earth_rows, target)
    shown = rescale(raw)
    order = np.argsort(-raw)

    results = []
    for rank, idx in enumerate(order[:top_k], start=1):
        row = earth_rows[idx]
        strong = [FEATURE_WORDS.get(f, f) for f in feats if per_feature[f][idx] >= 75]
        weak = [FEATURE_WORDS.get(f, f) for f in feats if per_feature[f][idx] <= 40]
        results.append({
            "site_id": row["id"],
            "name": row.get("name"),
            "region": row.get("region"),
            "category": row.get("category"),
            "known_analogue": bool(row.get("known_analogue")),
            "lat": row.get("lat"),
            "lon": row.get("lon"),
            "rank": rank,
            "environmental_score": round(float(shown[idx]), 2),
            "raw_similarity": round(float(raw[idx]), 3),
            "fingerprint": _group(per_feature, FINGERPRINT_GROUPS, idx),
            "mission_relevance": _group(per_feature, MISSION_LENS, idx),
            "strong_matches": strong,
            "weak_matches": weak,
        })
    return results, feats