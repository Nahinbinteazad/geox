# GeoX API

The three things the Flutter app cannot do on its own.

| Endpoint | Unblocks | Why the app can't |
|---|---|---|
| `POST /score/open-target` | **Open target mode** | ranking a new coordinate needs the scoring engine, not a lookup |
| `POST /sites/suggest` | **Suggest a new site** | a submission has to go somewhere |
| `POST /shortlists` → `GET /shortlists/{code}` | **Share the shortlist** | a link needs a server to resolve it |

Everything else in GeoX reads a bundled file and needs no server. **That is deliberate.
If this service is down, the demo still runs.** Build on that property rather than
against it.

---

## Run it

```bash
pip install -r requirements.txt
uvicorn app.main:app --reload --port 8000
```

Open <http://localhost:8000/docs> for the interactive API docs, generated from the code.

```bash
pytest -q          # 41 tests
```

### Two settings that matter

**`SUPABASE_JWT_SECRET`** — without it, tokens are read but **not verified**, and every
protected route is effectively open. `GET /health` reports this in plain words. Set it
before anyone but you can reach the service:

```
Supabase dashboard -> Project settings -> API -> JWT Secret
```

**`EARTH_CSV`** — point it at `earth_candidates.csv` to score against all **600** Earth
sites. The file is written by the data-preparation notebook and sits in the Kaggle
dataset at `terraform-data/earth_candidates.csv`. Copy it to `app/earth_candidates.csv`
and no environment variable is needed. Without it the service falls back to the **89**
sites bundled in `geox_data.json`, and every response says which was used. `GET /health`
reports the count, so after copying it should say 600, not 89.

This matters more than it looks. `RobustScaler` centres on the median and scales by the
IQR, so a smaller candidate set moves every scaled value and reorders near-ties.
`tests/test_scoring.py` measures that effect rather than hand-waving it: halving the fit
set drops rank agreement to about 0.93 on average, and as low as 0.71.

---

## The scoring, and what it does not claim

`app/scoring.py` is lifted from the ML notebook so a new coordinate is scored the way
the precomputed results were.

**Only the environmental half runs here.** The visual half needs DINOv2 and a satellite
tile of that exact coordinate, and no such tile exists for a point a user invented thirty
seconds ago. The response omits it and says so, rather than returning a number that looks
like the app's fusion score but is not.

For a point nobody measured, the service builds features like this:

- **Temperature and day-night swing** from the latitude model printed in notebook cell 11
- **Lunar polar points** override that model: a sunlit ridge and a permanently shadowed
  floor sit side by side, so latitude alone cannot describe them. Both use measured values
- **Slope and roughness** from a terrain preset the caller chooses, because nobody has
  measured the terrain at an arbitrary coordinate on another world
- **Elevation and aridity** are never used. Heights use a different reference surface on
  each world, and aridity is defined from rainfall

Every one of those appears in the `caveats` array of the response. The app should show
them, not hide them.

---

## Wiring it into the Flutter app

The app is offline-first, so the service is an enhancement and must never be a dependency.

```dart
// Keep a timeout, and fall back to the bundled data on any failure.
final res = await http
    .post(Uri.parse('$apiBase/score/open-target'),
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode({'planet': 'mars', 'lat': lat, 'lon': lon,
                            'terrain': 'crater_floor'}))
    .timeout(const Duration(seconds: 8));
```

For the protected routes, pass the token the app already holds:

```dart
headers: {'Authorization': 'Bearer ${AuthService.instance.accessToken}'}
```

That is the same Supabase session the app signs in with, so no second login.

---

## Postgres and row level security

`sql/schema.sql` is the Supabase version. **Read the policies, not just the tables.**
Without row level security, every row in a Supabase project is readable by anyone holding
the anon key.

What the policies enforce:

- A **pending** suggestion is visible only to whoever submitted it. Accepted ones are
  public. An unreviewed submission is never published by accident
- A user may only insert **as themselves**, and only with `status = 'pending'`. Nothing
  can be self-accepted
- Moderation runs with the service role, which bypasses RLS. **Never put the service key
  in the app**
- A shortlist is readable by anyone with the code, because it is a list of public sites.
  The random code is the only thing protecting it, so nothing private belongs in one

SQLite is the default so the service runs with nothing installed. Use Postgres the moment
more than one person touches it.

---

## Test results

All 41 run and pass. Not claimed, run:

```
41 passed
```

What they cover:

- The latitude model reproduces the notebook's own printed checks
- Live scoring is compared against the shipped rankings for all 20 targets, with the
  agreement threshold depending on whether the full 600-site file is present
- The scaler sensitivity above is measured, so any disagreement has a demonstrated cause
- A site identical to the target scores exactly 100
- Shadowed lunar points use measured values, not the model
- Every protected route rejects an anonymous caller and a malformed token
- A thin or out-of-range submission is refused with 422
- A submission is always stored `pending`, never auto-accepted
- Shortlists round-trip, and an unknown site id is kept and flagged rather than dropped

One real bug was found and fixed by these tests: the insert read its row back on a
second connection before the first had committed, so SQLite returned nothing.

## Not done

- **No rate limiting.** Add it before this is public; `slowapi` is the usual choice
- **Moderation has no admin check.** Any signed-in user can change a suggestion's status.
  Add a role claim or move review behind the service role
- **Postgres schema is not exercised by the tests**, which run on SQLite. The SQL has not
  been executed against a real Postgres
