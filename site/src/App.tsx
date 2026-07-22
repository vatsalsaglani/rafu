import { lazy, Suspense, useEffect } from "react";
import { Navigate, Outlet, Route, Routes, useLocation } from "react-router-dom";
import { Footer } from "./components/Footer";
import { Nav } from "./components/Nav";
import { Landing } from "./pages/Landing";
import { NotFound } from "./pages/NotFound";

const DocsLayout = lazy(() =>
  import("./pages/DocsLayout").then((m) => ({ default: m.DocsLayout })),
);

function ScrollManager() {
  const location = useLocation();
  useEffect(() => {
    if (location.pathname.startsWith("/docs")) return; // docs manages its own scrolling
    if (location.hash) {
      requestAnimationFrame(() => {
        document.getElementById(location.hash.slice(1))?.scrollIntoView({ block: "start" });
      });
    } else {
      window.scrollTo({ top: 0, behavior: "instant" as ScrollBehavior });
    }
  }, [location.pathname, location.hash]);
  return null;
}

function SiteShell() {
  return (
    <div className="flex min-h-screen flex-col">
      <Nav />
      <main className="flex-1">
        <Outlet />
      </main>
      <Footer />
    </div>
  );
}

export default function App() {
  return (
    <>
      <ScrollManager />
      <Routes>
        <Route element={<SiteShell />}>
          <Route index element={<Landing />} />
          <Route path="docs" element={<Navigate to="/docs/getting-started" replace />} />
          <Route
            path="docs/:slug"
            element={
              <Suspense fallback={<div className="mx-auto max-w-6xl px-5 pt-32 pb-20 text-sm text-text-3">Loading…</div>}>
                <DocsLayout />
              </Suspense>
            }
          />
          <Route path="*" element={<NotFound />} />
        </Route>
      </Routes>
    </>
  );
}
