import { defineConfig } from 'vite'
import react from '@vitejs/plugin-react'

// https://vite.dev/config/
export default defineConfig({
  plugins: [react()],
  server: {
    // In production, CloudFront proxies /api/* to the ALB so the frontend
    // can use relative paths. Mirrored here for local dev against a
    // locally-running backend (see backend/.env.example's DEV_BYPASS_AUTH —
    // the real ALB-gated auth flow itself can't be tested locally, see
    // the ALB-native-auth plan for why).
    proxy: {
      '/api': 'http://localhost:8080',
    },
  },
})
