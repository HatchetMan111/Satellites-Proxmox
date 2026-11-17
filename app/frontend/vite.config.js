import { defineConfig } from 'vite'
import react from '@vitejs/plugin-react'

// Der Dev-Server proxied /api auf das FastAPI-Backend (Port 8020).
// Der Produktions-Build landet in ../backend/static/ und wird vom
// FastAPI-Server direkt ausgeliefert (kein Node im Container nötig).
export default defineConfig({
  plugins: [react()],
  build: {
    outDir: '../backend/static',
    emptyOutDir: true,
  },
  server: {
    proxy: {
      '/api': 'http://127.0.0.1:8020',
    },
  },
})