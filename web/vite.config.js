import { defineConfig } from "vite";

export default defineConfig({
  base: "/ui/",
  esbuild: { jsx: "automatic" },
  server: { proxy: { "^/(events|event-types)(/|\\?|$)": "http://127.0.0.1:8080" } },
});
