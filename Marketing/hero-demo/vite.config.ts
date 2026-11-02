import { defineConfig } from 'vite'
import react from '@vitejs/plugin-react'

export default defineConfig({
  base: './',
  plugins: [react()],
  build: {
    target: 'es2022',
    rollupOptions: {
      output: {
        // Preserve vendor stylesheet provenance for Stageshow's ownership
        // checks. Authored scene CSS remains in the ordinary assets bundle.
        manualChunks(id) { if (id.includes('/hero-demo/kit/')) return 'stageshow' },
        assetFileNames(asset) {
          return asset.name === 'stageshow.css'
            ? 'kit/[name]-[hash][extname]' : 'assets/[name]-[hash][extname]'
        },
      },
    },
  },
})
