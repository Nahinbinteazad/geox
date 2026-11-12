# GeoX

**Which places on Earth best resemble the places we want to explore on Mars and the Moon?**

GeoX ranks Earth sites by how closely their measured conditions match a Mars or Moon target site, so that scientists and mission planners can choose where to rehearse a mission, test a rover, or study a process on Earth first. Built for the NASA Space Apps Challenge 2026.

> GeoX reports similarity in selected measured features. It is not a claim of physical equivalence.

## What you can do in the app

* **Choose a target**: 20 Mars and Moon sites (Jezero, Gale, Shackleton, Cabeus, Taurus-Littrow and others), each with its real NASA Trek picture and stored values.
* **See ranked Earth analogues** for a target, with environmental similarity, visual similarity and an overall score.
* **Compare side by side**: the Earth tile and the target tile with a draggable divider, plus the measured values for each (slope, roughness, temperature, day-night swing, vegetation, bare ground).
* **Set priorities** (rover mobility, geology, astrobiology, EVA, ISRU) and re-rank the results. Your choice is saved on the device.
* **Score any point you choose** on Mars or the Moon (including shadowed polar points) through the server.
* **Shortlist sites** and share them with a short code.
* **Suggest a new analogue site** (sign-in required). Suggestions are reviewed before being confirmed.
* **Trends and Reverse mode**, based on the real data.

Everything except custom-point scoring, suggestions and shortlist sharing works offline from a data file bundled in the app.

## How the scoring works

* Earth candidate sites (600) are described by measured features: slope, roughness, surface temperature, day-night temperature swing, vegetation (NDVI) and bare ground. Elevation and aridity are used for Earth only. They are left out of the comparison because heights use a different reference surface on each world and aridity is defined from rainfall.
* Features are scaled with a robust scaler, then each Earth site is compared with the target. Similarity is rescaled across the candidate set, so scores rank sites **within one target**. They are not an absolute physical measurement.
* Where a target has a usable satellite tile, a visual similarity from a frozen DINOv2 model is fused with the environmental score (75% environment, 25% visual). Earth tiles are blurred to each target's own resolution first. Permanently shadowed targets have no texture, so they are scored on the environment alone.

### What the validation shows, and its limits

* A benchmark of 11 known analogue sites against 10 controls separates the two groups significantly for **all 19 in-scope targets**. One target (Planum Boreum, an ice target) is out of scope, because the benchmark only covers dry rocky sites.
* On this benchmark the environmental channel alone separates known sites from controls more cleanly than the fused score. The fusion weight was fixed in advance and not tuned to look better.
* Many results are generated grid sites, and some sites rank first for several targets.
* In the trend analysis only 3 of 20 targets show a significant trend, all slightly falling (under 1 point over 24 years).

## Data sources

NASA Solar System Treks (Mars and Moon imagery), MODIS, Copernicus DEM, ESA WorldCover, Global Aridity Index and Sentinel-2. The visual encoder is DINOv2 (`dinov2\_vits14`).

## Repository layout

```
backend/geox\_api/     FastAPI server (scoring, suggestions, shortlists, sign-in checks)
frontend/terra\_twin/  Flutter app (runs in Chrome or on a phone browser)
```

## Run it locally

You need Python 3.12 or newer and Flutter.

**Backend** (Windows PowerShell):

```
cd backend\\geox\_api
python -m venv .venv
.\\.venv\\Scripts\\Activate.ps1
pip install -r requirements.txt
python -m uvicorn app.main:app --reload
```

The server runs at http://localhost:8000 (API docs at `/docs`, status at `/health`). Optional settings (see `.env.example`):

* `SUPABASE\_URL`: your Supabase project address. With it set, sign-in tokens are verified.
* `REVIEWER\_EMAILS`: comma-separated emails allowed to review suggestions.
* `CORS\_ORIGINS`: the app's address, when deploying.

**App:**

```
cd frontend\\terra\_twin
flutter pub get
flutter run -d chrome --web-port=5000 --dart-define=GEOX\_API\_URL=http://localhost:8000
```

The Supabase project address and publishable key are set in `frontend/terra\_twin/lib/config.dart`.

**Tests:**

```
cd backend\\geox\_api
python -m pytest tests -q
```

Run the tests with `SUPABASE\_URL` unset.

## API

`GET /health`, `GET /targets`, `GET /terrain-presets`, `POST /score/open-target`, `POST /score/target/{id}`, `POST /sites/suggest`, `GET /sites/suggested`, `PATCH /sites/suggested/{id}` (reviewers only), `POST /shortlists`, `GET /shortlists/{code}`. Open endpoints are rate limited.

## 

