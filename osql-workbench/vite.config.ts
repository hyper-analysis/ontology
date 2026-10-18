import { defineConfig } from "vite";
import react from "@vitejs/plugin-react";
export default defineConfig({ base: "./", worker: { format: "es" }, plugins: [react()], build: { outDir: "dist" } });
