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
    // three.js ist gross (~450 kB) und ändert sich selten – eigener Chunk,
    // damit der Browser ihn beim App-Update nicht neu laden muss.
    rollupOptions: {
      output: {
        manualChunks: {
          three: ['three'],
        },
      },
    },
    chunkSizeWarningLimit: 700,
  },
  server: {
    proxy: {
      '/api': 'http://127.0.0.1:8020',
    },
  },
})