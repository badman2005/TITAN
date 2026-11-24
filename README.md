# Project TITAN — Module 1: MariaDB schema + FastAPI backend

Military medical logistics & cold-chain verification. This module delivers the database, rules engine,
SHA-256 audit chain and the three required endpoints. Edge simulator (Module 2) and React PWA (Module 3) plug into it.

**Verified:** 29 pytest tests (SQLite), plus `schema.sql`, `seed.py`, and the API exercised against a real MariaDB 10.11
(including the append-only triggers and least-privilege grants).

## Quick start (one command)
```bash
chmod +x setup.sh run.sh && ./setup.sh     # installs MariaDB if needed, builds DB, venv, .env, seeds, tests, starts API
```
Options: `--sqlite` (no MariaDB), `--reset` (wipe & reseed), `--no-install`, `--skip-tests`, `--no-run`. Later: `./run.sh`.
Env: `TITAN_DB_PASSWORD`, `MYSQL_ROOT_PASSWORD`, `PORT`. The manual steps below do the same thing by hand.

## Layout
```
setup.sh / run.sh   one-shot setup / start the API
schema.sql          MariaDB DDL, append-only triggers, least-privilege grants
seed.py             demo data, written through the real ingest path (genuine hash chains)
app/main.py         FastAPI routes          app/services.py  ingest + verify logic
app/geo.py          Haversine + geofence    app/rules.py     thermal / MKT / tamper / expiry rules
app/audit.py        SHA-256 hash chain      app/anchor.py    mock / IPFS / Polygon anchor providers
app/models.py, schemas.py, config.py, database.py, util.py
tests/              pytest suite            .env.example     all settings
```

## Setup
```bash
# 1. Database  (edit the titan password in schema.sql first!)
mariadb -u root -p < schema.sql

# 2. Python
python -m venv .venv && source .venv/bin/activate
pip install -r requirements.txt
cp .env.example .env && export $(grep -v '^#' .env | sed 's/ #.*//' | xargs)   # or set DATABASE_URL yourself

# 3. Seed + run
python seed.py
uvicorn app.main:app --reload          # docs at http://127.0.0.1:8000/docs

# 4. Tests (self-contained, in-memory SQLite — no DB needed)
pytest -q
```
No MariaDB handy? `DATABASE_URL=sqlite:///./titan.db TITAN_AUTO_CREATE=1 python seed.py` works for local dev
(you lose the triggers/grants, which are MariaDB-side).

## Seed data (crate → scenario)
| Crate (QR) | Scenario | Expected `/verify` |
|---|---|---|
| 1 `TITAN-CRATE-0001` | At ALPHA, dispatch PLANNED → BRAVO (use for live demo) | SAFE |
| 2 `TITAN-CRATE-0002` | IN_TRANSIT ALPHA → CHARLIE, blood + albumin | SAFE |
| 3 `TITAN-CRATE-0003` | IN_STORAGE at BRAVO, one item expires in 9 days | SAFE + `EXPIRING_SOON` warning |
| 4 `TITAN-CRATE-0004` | IN_STORAGE at ALPHA, 9.7 °C excursion → locked out, items quarantined | COMPROMISED |
| 5 `TITAN-CRATE-0005` | Cold chain fine, tetanus vaccine expired | COMPROMISED |

## Try it
```bash
NOW=$(date -u +%Y-%m-%dT%H:%M:%SZ)

# Crate 1 leaves ALPHA's geofence → IN_TRANSIT, dispatch EN_ROUTE (3 audit records)
curl -s localhost:8000/api/telemetry/ingest -H 'content-type: application/json' -d '{
  "qr_code_payload":"TITAN-CRATE-0001","device_id":"EDGE-TITAN-01","sequence":1000,"recorded_at":"'$NOW'",
  "lat":-15.20,"lng":28.30,"temperature_c":4.6,"humidity_pct":37,"battery_pct":90,"ldr_tamper":false}'

# Arrive inside BRAVO's geofence → AT_BATTLEFIELD + BASE_HANDOFF
curl -s localhost:8000/api/telemetry/ingest -H 'content-type: application/json' -d '{
  "crate_id":1,"device_id":"EDGE-TITAN-01","sequence":1001,"recorded_at":"'$(date -u +%Y-%m-%dT%H:%M:%SZ)'",
  "lat":-14.4469,"lng":28.4464,"temperature_c":4.8,"ldr_tamper":false}'

# Thermal excursion (zero tolerance) → lockout
curl -s localhost:8000/api/telemetry/ingest -H 'content-type: application/json' -d '{
  "crate_id":1,"device_id":"EDGE-TITAN-01","sequence":1002,"recorded_at":"'$(date -u +%Y-%m-%dT%H:%M:%SZ)'",
  "lat":-14.4469,"lng":28.4464,"temperature_c":9.3,"ldr_tamper":false}'

# Tamper (LDR light-ingress) on another crate
curl -s localhost:8000/api/telemetry/ingest -H 'content-type: application/json' -d '{
  "crate_id":2,"device_id":"EDGE-TITAN-02","recorded_at":"'$(date -u +%Y-%m-%dT%H:%M:%SZ)'",
  "lat":-15.61,"lng":28.22,"temperature_c":5.0,"ldr_tamper":true}'

curl -s 'localhost:8000/api/inventory?movement_status=IN_TRANSIT'
curl -s 'localhost:8000/api/inventory?base_code=BRAVO&item_type=DRUG&expiry_status=EXPIRING_SOON'
curl -s  localhost:8000/api/crates/1/verify
curl -s  localhost:8000/api/crates/by-qr/TITAN-CRATE-0003/verify      # what the PWA scanner will call
curl -s  localhost:8000/api/crates/3/audit                            # chain + records
curl -s -X POST localhost:8000/api/crates/3/anchor                    # ANCHOR_BACKEND receipt
```
Burst sync of an offline buffer: `POST /api/telemetry/ingest/batch` with `{"readings":[…]}` (replayed in device-time
order, one transaction per reading, safe to retry).

## Endpoints
| Method & path | Purpose |
|---|---|
| `POST /api/telemetry/ingest` | Validate → rules + geofence → update crate/dispatch → append chained audit records |
| `POST /api/telemetry/ingest/batch` | Offline-buffer burst sync (≤1000 readings) |
| `GET /api/inventory` | Filters: `movement_status`, `item_type`, `base_code`, `expiry_status` (+`limit`/`offset`). `transit{vehicle, driver, dispatched_at, lat/lng}` for IN_TRANSIT, `storage{base…}` otherwise, plus expiry/integrity per item |
| `GET /api/crates/{id}/verify` | `SAFE TO ADMINISTER` or `COMPROMISED — DO NOT USE` with `reasons`, `warnings`, per-check status, per-item verdicts |
| `GET /api/crates/by-qr/{payload}/verify` | Same, keyed by scanned QR payload |
| `GET /api/crates/{id}/audit`, `POST /api/crates/{id}/anchor` | Inspect chain / anchor its head |

`base_code` matches crates *at* that base, plus `IN_TRANSIT` crates inbound to or outbound from it.

## Design decisions worth knowing
- **State machine.** With a dispatch: inside destination radius → `AT_BATTLEFIELD` (dispatch `ARRIVED`, `BASE_HANDOFF` logged);
  else inside origin radius → `AT_BASE`; else `IN_TRANSIT`. First departure sets `dispatched_at` and `EN_ROUTE`.
  `IN_STORAGE` / `DISPENSED` are set by storage/dispensing workflows (not in this module) and are never overridden by telemetry.
- **Zero tolerance + sticky lockout.** Any reading outside 2–8 °C, MKT out of range, or `ldr_tamper` locks the crate, quarantines
  its available items and writes a `LOCKOUT` event. Later good readings never clear it (clearing needs a future, audited release workflow).
  MKT is computed server-side (24 h window, ΔH = 83.144 kJ/mol) and accepted from the device; under zero tolerance a server MKT
  breach can only follow a raw excursion, so the device-reported MKT is what adds coverage.
- **Offline buffering.** Readings carry the device clock (`recorded_at`) and an optional per-device `sequence`.
  Duplicates are ignored; late readings still trigger lockout but never move the crate backwards; timestamps >5 min in the future are rejected.
- **Verification re-derives everything** from raw telemetry and the chain rather than trusting cached flags. A crate with no
  telemetry or no audit trail is *not* safe. Any expired/quarantined item makes the whole crate verdict COMPROMISED (conservative);
  per-item results show which item. Each `/verify` call is itself appended to the chain (`VERIFICATION`).
- **Hash chain.** One chain per crate (parallel ingest, cheap verification): `current_hash = SHA256(previous_hash + canonical_event_json)`,
  genesis = 64 zeros, exact hashed JSON stored in `event_json`. `audit.verify_chain()` detects edits, reordering and mid-chain deletion.
  Tail truncation or a fully re-computed chain can only be caught by an **external anchor** — hence `anchor_receipts`.
- **Immutability is layered:** triggers block UPDATE/DELETE for everyone (including root); the app user has no UPDATE/DELETE/DROP on
  `audit_trail`, `telemetry_readings`, `anchor_receipts`; ingest also checks the chain head and sets `HASH_MISMATCH` lockout if it fails.

## Anchoring (`ANCHOR_BACKEND`)
| Backend | Needs | Status |
|---|---|---|
| `mock` (default) | nothing | Tested. Deterministic fake CID/tx, flagged `is_mock=true`. |
| `ipfs` | `IPFS_API_URL` (+ `IPFS_API_AUTH` for hosted nodes) | Implemented, **not tested live** |
| `polygon` | `pip install web3`, `POLYGON_RPC_URL`, `POLYGON_CHAIN_ID` (137 / 80002 Amoy), funded `POLYGON_PRIVATE_KEY`; optional IPFS vars to embed a CID | Implemented, **not tested live** — try Amoy testnet first |

Polygon anchoring writes `"TITAN1" ‖ head_hash [‖ CID]` as calldata of a 0-value self-transaction. Keep the private key in a secret manager.
Add another provider by subclassing `AnchorProvider` and registering it in `get_provider()`.

## Known limits / next steps
- No auth yet (add device API keys for ingest and operator auth for verify/anchor before any real deployment).
- Single temperature band for all items; per-`item_type` bands (e.g. frozen vaccines) are a small change in `rules.py`.
- Dispatch creation, storage-in, dispensing and lockout-release endpoints are not in scope for Module 1.
- Timestamps are UTC and returned without a `Z` suffix in JSON.
- `verify_chain` loads a crate's full chain into memory — fine for prototype volumes; stream/checkpoint for very long chains.
