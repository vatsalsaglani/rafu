import { defineConfig } from "vite";
import react from "@vitejs/plugin-react";
import tailwindcss from "@tailwindcss/vite";
import { rafuDocs } from "./plugins/vite-rafu-docs";

// `base` is the public path the site is served under. It ships to GitHub
// Pages at vatsalsaglani.github.io/rafu, so the default sub-path is
// "/rafu/"; the deploy workflow passes SITE_BASE, and a future custom
// domain (e.g. rafu.app) just sets SITE_BASE=/ + a CNAME. BrowserRouter
// reads this back via import.meta.env.BASE_URL, so routing and asset URLs
// stay in sync automatically.
export default defineConfig({
  base: process.env.SITE_BASE || "/rafu/",
  plugins: [rafuDocs(), react(), tailwindcss()],
});
