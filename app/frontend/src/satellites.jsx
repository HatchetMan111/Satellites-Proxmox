import React, { useEffect, useState } from 'react'
import Globe from './globe.jsx'

// Satellites – Übersicht: 3D-Weltkugel mit ISS-Live-Position + Satellitenliste.
// Fragt ausschließlich die lokale FastAPI an (keine externen Dienste im Betrieb).

function Satellites() {
  const [health, setHealth] = useState(null)
  const [satellites, setSatellites] = useState([])
  const [iss, setIss] = useState(null)
  const [selected, setSelected] = useState(null)
  const [pos, setPos] = useState(null)
  const [positions, setPositions] = useState([])   // Positionen für den Globe
  const [error, setError] = useState(null)
  const [loading, setLoading] = useState(true)

  // Health + Satellitenliste beim Start laden
  useEffect(() => {
    fetch('/api/health')
      .then((r) => (r.ok ? r.json() : Promise.reject(new Error(`HTTP ${r.status}`))))
      .then(setHealth)
      .catch((e) => setError(e.message))

    fetch('/api/satellites')
      .then((r) => (r.ok ? r.json() : Promise.reject(new Error(`HTTP ${r.status}`))))
      .then((d) => setSatellites(d.satellites || []))
      .catch((e) => setError(e.message))
      .finally(() => setLoading(false))
  }, [])

  // ISS-Position initial + alle 10 s aktualisieren
  useEffect(() => {
    const loadIss = () =>
      fetch('/api/iss')
        .then((r) => (r.ok ? r.json() : Promise.reject(new Error(`HTTP ${r.status}`))))
        .then((d) => {
          setIss(d)
          setPositions((prev) => [...prev.filter((p) => p.norad_id !== d.norad_id), d])
        })
        .catch(() => setIss(null))
    loadIss()
    const iv = setInterval(loadIss, 10000)
    return () => clearInterval(iv)
  }, [])

  // Position des ausgewählten Satelliten laden
  useEffect(() => {
    if (!selected) {
      setPos(null)
      return undefined
    }
    const load = () =>
      fetch(`/api/satellites/${selected.norad_id}/position`)
        .then((r) => (r.ok ? r.json() : Promise.reject(new Error(`HTTP ${r.status}`))))
        .then((d) => {
          setPos(d)
          setPositions((prev) => [...prev.filter((p) => p.norad_id !== d.norad_id), d])
        })
        .catch((e) => setError(e.message))
    load()
    const iv = setInterval(load, 10000)
    return () => clearInterval(iv)
  }, [selected])

  const refresh = () => {
    setLoading(true)
    setError(null)
    fetch('/api/satellites?force=true')
      .then((r) => (r.ok ? r.json() : Promise.reject(new Error(`HTTP ${r.status}`))))
      .then((d) => setSatellites(d.satellites || []))
      .catch((e) => setError(e.message))
      .finally(() => setLoading(false))
  }

  return (
    <div className="app">
      <header className="app-header">
        <h1>🛰️ Satellites</h1>
        <div className="health">
          {health ? (
            <span className={`badge ${health.status === 'ok' ? 'ok' : 'bad'}`}>
              Backend: {health.status}
            </span>
          ) : (
            <span className="badge bad">Backend: offline</span>
          )}
        </div>
      </header>

      {error && (
        <div className="error" role="alert">
          Fehler: {error}
        </div>
      )}

      <div className="grid">
        <section className="panel globe-panel">
          <div className="panel-head">
            <h2>🌍 Weltkugel</h2>
            <span className="muted">Positionen alle 10 s aktualisiert</span>
          </div>
          <Globe positions={positions} iss={iss} selected={selected} selectedPos={pos} />
          {iss && (
            <div className="iss-card">
              <div className="iss-row">
                <span className="iss-lat">{iss.lat}°</span>
                <span className="iss-lon">{iss.lon}°</span>
              </div>
              <div className="iss-meta">
                Höhe: {iss.alt_km} km · Umlauf: {iss.period_min} min · Inklination:{' '}
                {iss.inclination_deg}°
              </div>
            </div>
          )}
        </section>

        <section className="panel">
          <div className="panel-head">
            <h2>📡 Satelliten ({satellites.length})</h2>
            <button onClick={refresh} disabled={loading}>
              {loading ? 'Lade …' : 'Aktualisieren'}
            </button>
          </div>
          {satellites.length === 0 && !loading ? (
            <p className="muted">Keine Satelliten geladen.</p>
          ) : (
            <table className="sat-table">
              <thead>
                <tr>
                  <th>NORAD</th>
                  <th>Name</th>
                  <th>Periode</th>
                  <th></th>
                </tr>
              </thead>
              <tbody>
                {satellites.map((s) => {
                  const period = s.tle2 ? (1440 / parseFloat(s.tle2.slice(52, 63))).toFixed(1) : null
                  return (
                    <tr
                      key={s.norad_id}
                      className={selected?.norad_id === s.norad_id ? 'selected' : ''}
                    >
                      <td>{s.norad_id}</td>
                      <td className="sat-name" title={s.name}>
                        {s.name}
                      </td>
                      <td>{period ? `${period} min` : '–'}</td>
                      <td>
                        <button onClick={() => setSelected(s)}>Position</button>
                      </td>
                    </tr>
                  )
                })}
              </tbody>
            </table>
          )}
          {selected && pos && (
            <div className="pos-card">
              <h3>📍 {selected.name}</h3>
              <p>
                Breite: {pos.lat}° · Länge: {pos.lon}°
                <br />
                Höhe: {pos.alt_km} km · Umlauf: {pos.period_min} min · Inklination:{' '}
                {pos.inclination_deg}°
              </p>
            </div>
          )}
        </section>
      </div>
    </div>
  )
}

export default Satellites