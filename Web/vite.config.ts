/// <reference types="vitest/config" />
import { defineConfig } from "vite";
import react from "@vitejs/plugin-react";

export default defineConfig({
  plugins: [react()],
  // Relative, so the build works from any subpath or from dist/index.html.
  base: "./",
  // Served as static files rather than bundled: content.json alone is 1.7 MB.
  publicDir: "generated",
  build: { outDir: "dist", emptyOutDir: true },
  test: {
    environment: "jsdom",
    setupFiles: ["src/test/setup.ts"],
    testTimeout: 15000
  }
});
