import React, { useEffect, useRef, useState } from 'react'
import * as THREE from 'three'
import landmask from './landmask.json'

// Globe – rotierende 3D-Weltkugel (three.js) mit Kontinenten als Punktwolke,
// Breiten-/Längengrad-Raster, ISS- und Satelliten-Marker. Die Kontinente
// liegen als gebackene Punktwolke (landmask.json) im Bundle → kein
// Netzwerk-Zugriff, keine Texturen, läuft offline im LXC.

const R = 1                 // Erdradius in Szenen-Einheiten
const ALT_SCALE = 0.045     // 400 km ISS-Höhe ≈ 0.045 R (optisch verschaerft)

// Geozentrische Kugelkoordinaten → three.js-Vektor.
// three.js: Y = oben (Nordpol), X/Z = Äquatorebene.
function latLonToVec3(lat, lon, radius = R) {
  const phi = (lat * Math.PI) / 180
  const theta = (lon * Math.PI) / 180
  const x = radius * Math.cos(phi) * Math.cos(theta)
  const y = radius * Math.sin(phi)
  const z = -radius * Math.cos(phi) * Math.sin(theta)
  return new THREE.Vector3(x, y, z)
}

// Punktwolke aus den Land-Koordinaten bauen (einmalig).
function buildLandDots() {
  const positions = new Float32Array((landmask.length / 2) * 3)
  const v = new THREE.Vector3()
  for (let i = 0, j = 0; i < landmask.length; i += 2, j += 3) {
    v.copy(latLonToVec3(landmask[i], landmask[i + 1], R * 1.002))
    positions[j] = v.x
    positions[j + 1] = v.y
    positions[j + 2] = v.z
  }
  const geo = new THREE.BufferGeometry()
  geo.setAttribute('position', new THREE.BufferAttribute(positions, 3))
  const mat = new THREE.PointsMaterial({
    color: 0x4f8cff,
    size: 0.011,
    sizeAttenuation: true,
    transparent: true,
    opacity: 0.9,
  })
  return new THREE.Points(geo, mat)
}

// Breiten-/Längengrad-Gitter (Kugellinien).
function buildGraticule() {
  const group = new THREE.Group()
  const mat = new THREE.LineBasicMaterial({ color: 0x2a3a63, transparent: true, opacity: 0.55 })
  const seg = 120
  // Breitenkreise
  for (let lat = -60; lat <= 60; lat += 30) {
    const pts = []
    for (let i = 0; i <= seg; i++) {
      pts.push(latLonToVec3(lat, (i / seg) * 360 - 180, R * 1.001))
    }
    group.add(new THREE.Line(new THREE.BufferGeometry().setFromPoints(pts), mat))
  }
  // Längenkreise
  for (let lon = -180; lon < 180; lon += 30) {
    const pts = []
    for (let i = 0; i <= seg; i++) {
      pts.push(latLonToVec3((i / seg) * 180 - 90, lon, R * 1.001))
    }
    group.add(new THREE.Line(new THREE.BufferGeometry().setFromPoints(pts), mat))
  }
  return group
}

// Sternenhintergrund.
function buildStars() {
  const n = 900
  const pos = new Float32Array(n * 3)
  for (let i = 0; i < n; i++) {
    const v = new THREE.Vector3(
      Math.random() * 2 - 1,
      Math.random() * 2 - 1,
      Math.random() * 2 - 1
    ).normalize().multiplyScalar(8 + Math.random() * 6)
    pos[i * 3] = v.x; pos[i * 3 + 1] = v.y; pos[i * 3 + 2] = v.z
  }
  const g = new THREE.BufferGeometry()
  g.setAttribute('position', new THREE.BufferAttribute(pos, 3))
  return new THREE.Points(g, new THREE.PointsMaterial({
    color: 0xffffff, size: 0.05, transparent: true, opacity: 0.7,
  }))
}

// Orbit-Ring für die Inklination des Satelliten.
function buildOrbitRing(inclinationDeg, radius) {
  const pts = []
  const inc = (inclinationDeg * Math.PI) / 180
  for (let i = 0; i <= 180; i++) {
    const a = (i / 180) * Math.PI * 2
    // Kreis in der Bahnebene, um die X-Achse um die Inklination gedreht
    const x = radius * Math.cos(a)
    const z = radius * Math.sin(a)
    pts.push(new THREE.Vector3(x, z * Math.sin(inc), z * Math.cos(inc)))
  }
  const g = new THREE.BufferGeometry().setFromPoints(pts)
  const m = new THREE.LineDashedMaterial({
    color: 0xffd166, dashSize: 0.055, gapSize: 0.025, transparent: true, opacity: 0.95,
  })
  const line = new THREE.Line(g, m)
  line.computeLineDistances()
  return line
}

export default function Globe({ positions = [], iss = null, selected = null, selectedPos = null }) {
  const mountRef = useRef(null)
  const stateRef = useRef({})
  const [webglError, setWebglError] = useState(null)

  // Szene einmalig aufbauen
  useEffect(() => {
    try {
      buildScene()
    } catch (e) {
      console.error('[globe] useEffect-Fehler:', e && e.message)
      setWebglError('Globe: ' + (e && e.message))
    }

    function buildScene() {
    const mount = mountRef.current
    if (!mount) return undefined

    // WICHTIG: three.js erzeugt einen eigenen Canvas – er muss explizit
    // ins DOM gehängt werden, sonst bleibt .globe-canvas leer.
    const renderer = new THREE.WebGLRenderer({ antialias: true, alpha: true })
    renderer.setPixelRatio(Math.min(window.devicePixelRatio, 2))
    renderer.setSize(mount.clientWidth, mount.clientHeight)
    mount.appendChild(renderer.domElement)

    const scene = new THREE.Scene()
    const camera = new THREE.PerspectiveCamera(45, mount.clientWidth / mount.clientHeight, 0.1, 100)
    camera.position.set(0, 0.6, 3.2)
    camera.lookAt(0, 0, 0)

    // Erd-Gruppe: Kugel + Land-Punkte + Gitter drehen gemeinsam
    const earth = new THREE.Group()
    const globeMesh = new THREE.Mesh(
      new THREE.SphereGeometry(R, 48, 48),
      new THREE.MeshPhongMaterial({
        color: 0x0b1b3a, emissive: 0x050d20, specular: 0x1b3a6b, shininess: 18,
      })
    )
    earth.add(globeMesh)
    earth.add(buildLandDots())
    earth.add(buildGraticule())
    scene.add(earth)
    scene.add(buildStars())

    // Atmosphären-Glow (BackSide-Kugel, additiv)
    const glow = new THREE.Mesh(
      new THREE.SphereGeometry(R * 1.12, 48, 48),
      new THREE.MeshBasicMaterial({
        color: 0x2f6fd0, transparent: true, opacity: 0.16, side: THREE.BackSide,
      })
    )
    scene.add(glow)

    // Licht: Sonne + Ambiente
    scene.add(new THREE.AmbientLight(0x8899bb, 0.9))
    const sun = new THREE.DirectionalLight(0xffffff, 1.15)
    sun.position.set(5, 3, 5)
    scene.add(sun)

    // ISS-Marker (grün, pulsierend) + Selected-Marker (gelb)
    const issMarker = new THREE.Mesh(
      new THREE.SphereGeometry(0.022, 16, 16),
      new THREE.MeshBasicMaterial({ color: 0x34d399 })
    )
    const issRing = new THREE.Mesh(
      new THREE.RingGeometry(0.04, 0.052, 32),
      new THREE.MeshBasicMaterial({ color: 0x34d399, transparent: true, opacity: 0.55, side: THREE.DoubleSide })
    )
    issMarker.add(issRing)
    scene.add(issMarker)

    // Ausgewählter Satellit: gut sichtbare Kugel + pulsierender Ring + Orbit
    const selMarker = new THREE.Mesh(
      new THREE.SphereGeometry(0.03, 20, 20),
      new THREE.MeshBasicMaterial({ color: 0xffd166 })
    )
    const selRing = new THREE.Mesh(
      new THREE.RingGeometry(0.055, 0.07, 32),
      new THREE.MeshBasicMaterial({ color: 0xffd166, transparent: true, opacity: 0.6, side: THREE.DoubleSide })
    )
    selMarker.add(selRing)
    selMarker.visible = false
    scene.add(selMarker)

    // Marker für alle Satelliten der Liste (klein, blau) – nur wenn vorhanden
    const satGroup = new THREE.Group()
    scene.add(satGroup)

    stateRef.current = {
      renderer, scene, camera, earth, issMarker, issRing, selMarker, satGroup, orbit: null, mount,
    }

    // Resize
    const onResize = () => {
      const w = mount.clientWidth; const h = mount.clientHeight
      if (!w || !h) return
      renderer.setSize(w, h)
      camera.aspect = w / h
      camera.updateProjectionMatrix()
    }
    window.addEventListener('resize', onResize)

    // Render-Loop
    let raf
    const clock = new THREE.Clock()
    const animate = () => {
      raf = requestAnimationFrame(animate)
      const t = clock.getElapsedTime()
      // Erd-Gruppe dreht sich langsam (Marker liegen in Szenen-Koordinaten
      // und bleiben dadurch an ihrer realen Position stehen)
      const st = stateRef.current
      if (st.earth) st.earth.rotation.y = t * 0.045
      // Puls-Ring der ISS skaliert
      if (st.issRing) {
        const s = 1 + 0.35 * Math.sin(t * 3)
        st.issRing.scale.set(s, s, s)
      }
      renderer.render(scene, camera)
    }
    animate()

    return () => {
      cancelAnimationFrame(raf)
      window.removeEventListener('resize', onResize)
      renderer.dispose()
      if (renderer.domElement.parentNode === mount) {
        mount.removeChild(renderer.domElement)
      }
      // WICHTIG (React StrictMode): stateRef leeren, damit der Marker-Effekt
      // nicht auf die zerstoerte Szene der ersten Instanz zeigt.
      stateRef.current = {}
    }
    }
  }, [])

  // Satelliten-Positionen in die Szene spiegeln (bei Props-Änderung)
  useEffect(() => {
    const st = stateRef.current
    if (!st.scene || !st.issMarker) return

    // ISS-Marker (grün, pulsierend)
    if (iss && typeof iss.lat === 'number') {
      st.issMarker.visible = true
      st.issMarker.position.copy(latLonToVec3(iss.lat, iss.lon, R + ALT_SCALE))
    } else {
      st.issMarker.visible = false
    }

    // Ausgewählter Satellit (gelb) + Orbit-Ring.
    // WICHTIG: nicht blind zurücksetzen, wenn nur selectedPos (noch) fehlt –
    // selected und selectedPos treffen nicht im selben Render ein (Position
    // wird erst nach dem Fetch gesetzt). Zurücksetzen nur, wenn gar nichts
    // ausgewählt ist.
    if (selected && selectedPos && typeof selectedPos.lat === 'number') {
      st.selMarker.visible = true
      st.selMarker.position.copy(latLonToVec3(selectedPos.lat, selectedPos.lon, R + ALT_SCALE))
      // Orbit-Ring nur neu bauen, wenn Inklination/ID wechselte
      const key = `${selected.norad_id}:${selectedPos.inclination_deg}`
      if (st.orbitKey !== key) {
        if (st.orbit) { st.scene.remove(st.orbit); st.orbit.geometry.dispose() }
        st.orbit = buildOrbitRing(selectedPos.inclination_deg || 51.6, R + ALT_SCALE)
        st.scene.add(st.orbit)
        st.orbitKey = key
      }
    } else if (!selected) {
      if (st.selMarker) st.selMarker.visible = false
      if (st.orbit) { st.scene.remove(st.orbit); st.orbit = null; st.orbitKey = null }
    }

    // Alle Satelliten als kleine Punkte (max. 120, sonst zu unruhig)
    while (st.satGroup.children.length) {
      const c = st.satGroup.children.pop()
      c.geometry?.dispose?.()
      c.material?.dispose?.()
    }
    for (const p of positions.slice(0, 120)) {
      if (typeof p.lat !== 'number') continue
      const m = new THREE.Mesh(
        new THREE.SphereGeometry(0.009, 8, 8),
        new THREE.MeshBasicMaterial({ color: 0x4f8cff, transparent: true, opacity: 0.75 })
      )
      m.position.copy(latLonToVec3(p.lat, p.lon, R + 0.02))
      st.satGroup.add(m)
    }
  }, [selected, selectedPos, iss, positions])

  return (
    <div className="globe-wrap">
      <div ref={mountRef} className="globe-canvas" />
      {webglError && (
        <div className="globe-fallback">
          {webglError} – die Positionsdaten stehen weiterhin in der Liste rechts.
        </div>
      )}
      <div className="globe-legend">
        <span><i className="dot iss" /> ISS</span>
        <span><i className="dot sel" /> Auswahl</span>
        <span><i className="dot sat" /> Satelliten</span>
      </div>
    </div>
  )
}