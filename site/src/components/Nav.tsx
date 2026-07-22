import { Github, Menu, X } from "lucide-react";
import { AnimatePresence, motion } from "motion/react";
import { useState } from "react";
import { Link, useLocation } from "react-router-dom";
import { SeamMark } from "../brand/SeamMark";
import { GITHUB_URL, NAV_SECTIONS } from "../lib/site";
import { DownloadButton } from "./DownloadButton";
import { ThemeToggle } from "./ThemeToggle";

/**
 * Translucent chrome (apple-design §12): content scrolls under a blurred
 * layer; a gradient edge fade instead of a hard divider.
 */
export function Nav() {
  const [open, setOpen] = useState(false);
  const location = useLocation();
  const onDocs = location.pathname.startsWith("/docs");

  return (
    <header className="fixed inset-x-0 top-0 z-50">
      <div
        className="border-b border-transparent backdrop-blur-xl"
        style={{
          background: "color-mix(in srgb, var(--bg) 72%, transparent)",
          maskImage: "linear-gradient(to bottom, black 78%, transparent)",
          WebkitMaskImage: "linear-gradient(to bottom, black 78%, transparent)",
        }}
      >
        <nav className="mx-auto flex h-16 max-w-6xl items-center justify-between px-5 sm:px-8" aria-label="Main">
          <Link to="/" className="flex items-center gap-2.5" aria-label="Rafu home">
            <SeamMark size={24} />
            <span className="text-[17px] font-semibold tracking-[-0.01em] text-text">Rafu</span>
          </Link>

          <div className="hidden items-center gap-1 md:flex">
            {NAV_SECTIONS.map((item) => (
              <a
                key={item.label}
                href={item.href}
                className="rounded-md px-3 py-1.5 text-sm text-text-2 transition-colors duration-150 hover:text-text"
              >
                {item.label}
              </a>
            ))}
            <Link
              to="/docs"
              className={`rounded-md px-3 py-1.5 text-sm transition-colors duration-150 ${
                onDocs ? "text-accent" : "text-text-2 hover:text-text"
              }`}
            >
              Docs
            </Link>
          </div>

          <div className="hidden items-center gap-2.5 md:flex">
            <ThemeToggle />
            <a
              href={GITHUB_URL}
              target="_blank"
              rel="noopener noreferrer"
              aria-label="Rafu on GitHub"
              className="inline-flex h-9 w-9 items-center justify-center rounded-lg border border-border bg-surface text-text-2 transition-colors duration-150 hover:text-text"
            >
              <Github size={16} strokeWidth={1.75} />
            </a>
            <DownloadButton size="sm" />
          </div>

          <button
            type="button"
            className="inline-flex h-9 w-9 items-center justify-center rounded-lg border border-border bg-surface text-text-2 md:hidden"
            onClick={() => setOpen((v) => !v)}
            aria-expanded={open}
            aria-label={open ? "Close menu" : "Open menu"}
          >
            {open ? <X size={16} /> : <Menu size={16} />}
          </button>
        </nav>
      </div>

      <AnimatePresence>
        {open ? (
          <motion.div
            initial={{ opacity: 0, y: -8 }}
            animate={{ opacity: 1, y: 0 }}
            exit={{ opacity: 0, y: -8 }}
            transition={{ type: "spring", bounce: 0, duration: 0.3 }}
            className="mx-4 mt-2 rounded-xl border border-border bg-elevated p-2 shadow-lg md:hidden"
          >
            {NAV_SECTIONS.map((item) => (
              <a
                key={item.label}
                href={item.href}
                onClick={() => setOpen(false)}
                className="block rounded-lg px-3 py-2.5 text-sm text-text-2 hover:bg-hover hover:text-text"
              >
                {item.label}
              </a>
            ))}
            <Link
              to="/docs"
              onClick={() => setOpen(false)}
              className="block rounded-lg px-3 py-2.5 text-sm text-text-2 hover:bg-hover hover:text-text"
            >
              Docs
            </Link>
            <div className="mt-1 flex items-center gap-2 border-t border-border px-3 py-2.5">
              <ThemeToggle />
              <a
                href={GITHUB_URL}
                target="_blank"
                rel="noopener noreferrer"
                className="inline-flex h-9 w-9 items-center justify-center rounded-lg border border-border bg-surface text-text-2"
                aria-label="Rafu on GitHub"
              >
                <Github size={16} strokeWidth={1.75} />
              </a>
              <DownloadButton size="sm" />
            </div>
          </motion.div>
        ) : null}
      </AnimatePresence>
    </header>
  );
}
