import { defineConfig } from 'vite';
import react from '@vitejs/plugin-react';

// SPA-витрина отдаётся infra-nginx на auth.su10.ru/. В dev — localhost:5173.
export default defineConfig({
  plugins: [react()],
  server: { port: 5173 },
  build: { outDir: 'dist', sourcemap: false },
});
