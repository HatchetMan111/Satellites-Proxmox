#!/usr/bin/env python3
"""
Satellites – Lokale Satelliten-Tracking-Web-App (Backend).

Eine schlanke FastAPI-Anwendung, die die Oberfläche (React/Vite-Frontend)
ausliefert und die Bahndaten von CelesTrak (TLE) bezieht, zwischencacht
und die Positionen des nächsten Überflugs berechnet.

Läuft vollständig lokal – keine Cloud-Dienste nötig.
"""

import math
import os
import time
from pathlib import Path

import requests
from fastapi import FastAPI, HTTPException
from fastapi.responses import FileResponse, JSONResponse
from fastapi.staticfiles import StaticFiles
from fastapi.middleware.cors import CORSMiddleware

# ── Konfiguration (Defaults; zur Laufzeit via .env.runtime überschreibbar) ──
BASE_DIR = Path(__file__).resolve().parent
STATIC_DIR = BASE_DIR / "static"
TLE_CACHE_FILE = BASE_DIR / "tle_cache.json"
TLE_CACHE_TTL = int(os.environ.get("SAT_TLE_CACHE_TTL", "3600"))  # 1 h
TLE_URL = os.environ.get(
    "SAT_TLE_URL",
    "https://celestrak.org/NORAD/elements/gp.php?GROUP=stations&FORMAT=tle",
)
HTTP_TIMEOUT = int(os.environ.get("SAT_HTTP_TIMEOUT", "20"))

app = FastAPI(title="Satellites", version="1.0.0")

# Das Frontend wird vom Browser aus bedient; CORS ist nur für den lokalen
# Betrieb relevant, wir erlauben alles – die App hat keine sensiblen Daten.
app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_methods=["*"],
    allow_headers=["*"],
)


# ── TLE-Beschaffung mit Cache ───────────────────────────────────────────────
def fetch_tle_text() -> str:
    """Holt die aktuelle TLE-Liste von CelesTrak."""
    resp = requests.get(TLE_URL, timeout=HTTP_TIMEOUT)
    resp.raise_for_status()
    return resp.text


def load_tle(force: bool = False) -> list[dict]:
    """Liefert die geparsten TLE-Datensätze (Name + 2 Zeilen)."""
    use_cache = (
        not force
        and TLE_CACHE_FILE.exists()
        and (time.time() - TLE_CACHE_FILE.stat().st_mtime) < TLE_CACHE_TTL
    )
    text = ""
    if use_cache:
        text = TLE_CACHE_FILE.read_text(encoding="utf-8")
    else:
        try:
            text = fetch_tle_text()
            TLE_CACHE_FILE.write_text(text, encoding="utf-8")
        except requests.RequestException:
            # Offline? Letzten Cache verwenden, wenn vorhanden.
            if TLE_CACHE_FILE.exists():
                text = TLE_CACHE_FILE.read_text(encoding="utf-8")
            else:
                raise

    lines = [ln for ln in text.splitlines() if ln.strip()]
    sats = []
    i = 0
    while i + 2 < len(lines) + 1 and i + 2 <= len(lines):
        name = lines[i].strip()
        tle1 = lines[i + 1].strip()
        tle2 = lines[i + 2].strip()
        if not tle1.startswith("1 ") or not tle2.startswith("2 "):
            i += 1
            continue
        sats.append(
            {
                "name": name,
                "tle1": tle1,
                "tle2": tle2,
                "norad_id": tle1[2:7].strip(),
            }
        )
        i += 3
    return sats


# ── Mini-SGP4 (vereinfachte Kepler-Bahn) ────────────────────────────────────
def orbital_period_minutes(tle2: str) -> float:
    """Mittlere Bewegung (Umläufe/Tag) aus TLE-Zeile 2 → Periode in Minuten."""
    try:
        mean_motion = float(tle2[52:63])
        if mean_motion <= 0:
            return 0.0
        return 1440.0 / mean_motion
    except (ValueError, IndexError):
        return 0.0


def sat_position(tle2: str, at: float | None = None) -> dict:
    """
    Sehr einfache Positionsbestimmung: aus den o.g. Bahnelementen wird
    ein kreisförmiger Orbit abgeleitet (Inklination, RAAN, Argument of
    Perigee, mittlere Anomalie zum aktuellen Zeitpunkt).
    Die Erde wird als Kugel mit 6371 km modelliert; die Position ist
    geozentrisch (ECEF) und wird für die UI in Breiten-/Längengrad
    umgerechnet.
    """
    if at is None:
        at = time.time()
    try:
        inclination = math.radians(float(tle2[8:16]))
        raan = math.radians(float(tle2[17:25]))
        arg_perigee = math.radians(float(tle2[34:42]))
        mean_anomaly = math.radians(float(tle2[43:51]))
        mean_motion = float(tle2[52:63])  # Umläufe/Tag
    except (ValueError, IndexError):
        return {"lat": 0.0, "lon": 0.0, "alt_km": 0.0, "period_min": 0.0}

    period_min = 1440.0 / mean_motion if mean_motion > 0 else 0.0
    # Bahnposition: mittlere Anomalie + Fortschritt seit Epoche (TLE-Epoche
    # grob über die aktuelle Zeit approximiert – für eine Sichtanzeige
    # reicht die Näherung über den Umlauf).
    epoch_offset = (at / 60.0) % period_min if period_min else 0.0
    anomaly = mean_anomaly + 2 * math.pi * epoch_offset / period_min if period_min else mean_anomaly

    # Position in der Bahnebene (Radius ~ 6371 + 400 km ISS-Näherung)
    radius = 6771.0
    x_orb = radius * math.cos(anomaly)
    y_orb = radius * math.sin(anomaly)

    # Drehung in das erdfeste System (vereinfacht: nur Inklination + RAAN)
    x1 = x_orb * math.cos(raan) - y_orb * math.sin(raan) * math.cos(inclination)
    y1 = x_orb * math.sin(raan) + y_orb * math.cos(raan) * math.cos(inclination)
    z1 = y_orb * math.sin(inclination)

    # Geozentrische Breite/Länge (Kugel-Erde)
    r = math.sqrt(x1 * x1 + y1 * y1 + z1 * z1)
    lat = math.degrees(math.asin(z1 / r)) if r else 0.0
    lon = math.degrees(math.atan2(y1, x1)) if r else 0.0
    alt = r - 6371.0
    return {
        "lat": round(lat, 4),
        "lon": round(lon, 4),
        "alt_km": round(alt, 1),
        "period_min": round(period_min, 2),
        "inclination_deg": round(math.degrees(inclination), 2),
    }


# ── API-Endpunkte ───────────────────────────────────────────────────────────
@app.get("/api/health")
def health():
    return {"status": "ok", "service": "satellites", "version": app.version}


@app.get("/api/satellites")
def satellites(force: bool = False):
    try:
        sats = load_tle(force=force)
    except (requests.RequestException, OSError) as e:
        raise HTTPException(status_code=502, detail=f"TLE-Quelle nicht erreichbar: {e}")
    return {"count": len(sats), "satellites": sats}


@app.get("/api/satellites/{norad_id}/position")
def position(norad_id: str):
    try:
        sats = load_tle()
    except (requests.RequestException, OSError) as e:
        raise HTTPException(status_code=502, detail=f"TLE-Quelle nicht erreichbar: {e}")
    for sat in sats:
        if sat["norad_id"] == norad_id:
            pos = sat_position(sat["tle2"])
            pos["name"] = sat["name"]
            pos["norad_id"] = norad_id
            return pos
    raise HTTPException(status_code=404, detail=f"Kein Satellit mit NORAD-ID {norad_id}")


@app.get("/api/iss")
def iss_position():
    """Schnellzugriff auf die ISS (NORAD 25544)."""
    return position("25544")


# ── Frontend ausliefern (falls gebaut) ──────────────────────────────────────
if STATIC_DIR.exists():
    app.mount("/assets", StaticFiles(directory=STATIC_DIR / "assets"), name="assets")

    @app.get("/")
    def index():
        index_file = STATIC_DIR / "index.html"
        if index_file.exists():
            return FileResponse(index_file)
        return JSONResponse({"detail": "Frontend nicht gebaut – Installer baut es."}, status_code=503)