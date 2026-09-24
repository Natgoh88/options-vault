import { defineConfig } from "vite";
import react from "@vitejs/plugin-react";

export default defineConfig({
  plugins: [react()],
  build: {
    target: "es2022",
    sourcemap: false,
    chunkSizeWarningLimit: 700, // viem is the bulk of the bundle; it is cached separately below
    rollupOptions: {
      output: {
        manualChunks(id: string) {
          if (id.includes("node_modules/viem") || id.includes("node_modules/@noble") || id.includes("node_modules/abitype")) {
            return "viem";
          }
          if (id.includes("node_modules/react")) return "react";
        },
      },
    },
  },
});
