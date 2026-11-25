import { defineConfig } from 'vite';
import { resolve } from 'node:path';
export default defineConfig({
  base: process.env.BASE_PATH || './',
  build: { rollupOptions: { input: { index: resolve(__dirname, 'index.html'), seminar: resolve(__dirname, 'seminar.html') } } }
});
