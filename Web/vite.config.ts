import { defineConfig } from "vite";
import react from "@vitejs/plugin-react";

export default defineConfig({
  plugins: [react()],
  // Relative, so the built site is position independent: it works from a GitHub Pages subpath,
  // from the root of any static host, and from `dist/index.html` opened directly. An absolute
  // base bakes one deployment path into the HTML and 404s everywhere else.
  base: "./",
  // The generated bundles are the public directory: content.json, sources.json, traces.json and
  // asm/*.txt are copied to the site root verbatim rather than bundled into the JS. content.json
  // alone is 1.7 MB, and none of it should sit in a script tag.
  publicDir: "generated",
  build: { outDir: "dist", emptyOutDir: true }
});
