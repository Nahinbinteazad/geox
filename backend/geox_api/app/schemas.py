"""Request and response shapes. Pydantic validates before anything reaches the
scoring code, so a bad coordinate is a 422 with a clear message rather than a
confusing result."""
from __future__ import annotations

from typing import Literal
from pydantic import BaseModel, Field, field_validator


class OpenTargetRequest(BaseModel):
    planet: Literal["mars", "moon"]
    lat: float = Field(..., ge=-90, le=90, description="degrees, -90 to 90")
    lon: float = Field(..., ge=-180, le=180, description="degrees, -180 to 180")
    terrain: str = Field("crater_floor", description="see GET /terrain-presets")
    shadowed: bool = Field(
        False, description="lunar polar point that never receives sunlight")
    top_k: int = Field(25, ge=1, le=100)


class SuggestSiteRequest(BaseModel):
    name: str = Field(..., min_length=2, max_length=120)
    latitude: float = Field(..., ge=-90, le=90)
    longitude: float = Field(..., ge=-180, le=180)
    why: str = Field(..., min_length=10, max_length=2000,
                     description="why this place is worth considering")
    category: str | None = Field(None, max_length=40)

    @field_validator("name", "why")
    @classmethod
    def not_blank(cls, v: str) -> str:
        if not v.strip():
            raise ValueError("cannot be blank")
        return v.strip()


class ShortlistRequest(BaseModel):
    site_ids: list[str] = Field(..., min_length=1, max_length=200)
    target_id: str | None = None

    @field_validator("site_ids")
    @classmethod
    def clean(cls, v: list[str]) -> list[str]:
        out = [s.strip() for s in v if s.strip()]
        if not out:
            raise ValueError("no site ids given")
        return out


class StatusUpdate(BaseModel):
    status: Literal["pending", "accepted", "rejected"]
