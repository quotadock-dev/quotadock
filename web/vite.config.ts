import { defineConfig } from 'vite';
export default defineConfig({
  root: 'web', publicDir: 'public',
  build: { outDir: '../web-dist', emptyOutDir: true,
    rollupOptions: { output: { entryFileNames: 'app.js', assetFileNames: 'style.[ext]', chunkFileNames: 'chunk-[hash].js' } } }
});
