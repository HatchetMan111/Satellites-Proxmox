#!/usr/bin/env node
/**
 * Backt die Kontinente (world-atlas/land-110m) als kompakte Punktwolke.
 *
 * Ergebnis: src/landmask.json – ein flaches Array [lat, lon, lat, lon, …]
 * mit einem Punkt pro Rasterzelle, die auf Land liegt. Die Datei wird
 * committed, damit der Globe im Container KEIN Netzwerk braucht.
 *
 * Nutzung (einmalig, bei Bedarf):
 *   node scripts/build-landmask.mjs
 */
import { readFileSync, writeFileSync, mkdirSync } from 'node:fs'
import { dirname, resolve } from 'node:path'
import { fileURLToPath } from 'node:url'
import * as topojson from 'topojson-client'

const HERE = dirname(fileURLToPath(import.meta.url))
const ROOT = resolve(HERE, '..')

// Rasterweite in Grad. 1.5° ≈ 8.000 Land-Punkte (kompakt, ~60 kB JSON).
const STEP = Number(process.env.LANDMASK_STEP || 1.5)

const land = JSON.parse(readFileSync(resolve(ROOT, 'node_modules/world-atlas/land-110m.json'), 'utf8'))
const geo = topojson.feature(land, land.objects.land)

// Punkt-in-Polygon über die GeoJSON-Kontinente (Ray-Casting).
function inRing(lon, lat, ring) {
  let inside = false
  for (let i = 0, j = ring.length - 1; i < ring.length; j = i++) {
    const [xi, yi] = ring[i]
    const [xj, yj] = ring[j]
    if ((yi > lat) !== (yj > lat) && lon < ((xj - xi) * (lat - yi)) / (yj - yi) + xi) {
      inside = !inside
    }
  }
  return inside
}

function isLand(lon, lat) {
  const polys = geo.features[0].geometry.type === 'MultiPolygon'
    ? geo.features[0].geometry.coordinates
    : [geo.features[0].geometry.coordinates]
  for (const poly of polys) {
    for (const ring of poly) {
      if (inRing(lon, lat, ring)) return true
    }
  }
  return false
}

const dots = []
for (let lat = -89; lat <= 89; lat += STEP) {
  // In Polnähe schrumpft der Längengrad-Umfang – adaptive Schrittweite,
  // damit die Punkte auf der Kugel gleichmäßig verteilt wirken.
  const lonStep = STEP / Math.max(0.25, Math.cos((lat * Math.PI) / 180))
  for (let lon = -180; lon <= 180; lon += lonStep) {
    if (isLand(lon, lat)) {
      dots.push(Math.round(lat * 100) / 100, Math.round(lon * 100) / 100)
    }
  }
}

mkdirSync(resolve(ROOT, 'src'), { recursive: true })
writeFileSync(resolve(ROOT, 'src/landmask.json'), JSON.stringify(dots))
console.log(`landmask.json: ${dots.length / 2} Punkte (${Math.round(JSON.stringify(dots).length / 1024)} kB)`)
console.log(`Raster: ${STEP}° – feiner mit LANDMASK_STEP=1.0 node scripts/build-landmask.mjs`)