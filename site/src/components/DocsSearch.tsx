import Fuse from "fuse.js";
import { Search } from "lucide-react";
import { AnimatePresence, motion } from "motion/react";
import { useEffect, useMemo, useRef, useState } from "react";
import { useNavigate } from "react-router-dom";
import { docsBySlug, docsNav } from "../lib/docs";

interface SearchDoc {
  slug: string;
  title: string;
  text: string;
}

function titleFor(slug: string): string {
  for (const g of docsNav) {
    const item = g.items.find((i) => i.slug === slug);
    if (item) return item.title;
  }
  return slug;
}

/** ⌘K palette over a build-time content index. Springs, no lockout. */
export function DocsSearch() {
  const [open, setOpen] = useState(false);
  const [query, setQuery] = useState("");
  const [active, setActive] = useState(0);
  const inputRef = useRef<HTMLInputElement>(null);
  const navigate = useNavigate();

  const index = useMemo<SearchDoc[]>(
    () =>
      [...docsBySlug.values()].map((d) => ({
        slug: d.slug,
        title: titleFor(d.slug),
        text: d.plainText.slice(0, 4000),
      })),
    [],
  );
  const fuse = useMemo(() => new Fuse(index, { keys: ["title", "text"], threshold: 0.35, ignoreLocation: true }), [index]);

  const results = query.trim() ? fuse.search(query.trim()).slice(0, 8) : [];

  useEffect(() => {
    const onKey = (e: KeyboardEvent) => {
      if ((e.metaKey || e.ctrlKey) && e.key.toLowerCase() === "k") {
        e.preventDefault();
        setOpen((v) => !v);
      }
      if (e.key === "Escape") setOpen(false);
    };
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  }, []);

  useEffect(() => {
    if (open) {
      setQuery("");
      setActive(0);
      requestAnimationFrame(() => inputRef.current?.focus());
    }
  }, [open]);

  useEffect(() => setActive(0), [query]);

  const go = (slug: string) => {
    setOpen(false);
    navigate(`/docs/${slug}`);
  };

  return (
    <>
      <button
        type="button"
        onClick={() => setOpen(true)}
        className="flex w-full items-center gap-2 rounded-lg border border-border bg-surface px-3 py-2 text-sm text-text-3 transition-colors duration-150 hover:border-border-strong hover:text-text-2"
      >
        <Search size={14} strokeWidth={1.75} />
        <span>Search docs</span>
        <kbd className="ml-auto rounded border border-border bg-elevated px-1.5 py-px font-mono text-[10px] text-text-3">
          ⌘K
        </kbd>
      </button>

      <AnimatePresence>
        {open ? (
          <motion.div
            className="fixed inset-0 z-[60] flex items-start justify-center px-4 pt-[18vh]"
            initial={{ opacity: 0 }}
            animate={{ opacity: 1 }}
            exit={{ opacity: 0 }}
            transition={{ duration: 0.15 }}
          >
            <div className="absolute inset-0 bg-black/45 backdrop-blur-[2px]" onClick={() => setOpen(false)} />
            <motion.div
              initial={{ opacity: 0, y: -10, scale: 0.985 }}
              animate={{ opacity: 1, y: 0, scale: 1 }}
              exit={{ opacity: 0, y: -6, scale: 0.99 }}
              transition={{ type: "spring", bounce: 0, duration: 0.3 }}
              className="relative w-full max-w-lg overflow-hidden rounded-xl border border-border-strong bg-elevated shadow-2xl"
              role="dialog"
              aria-modal="true"
              aria-label="Search documentation"
            >
              <div className="flex items-center gap-2.5 border-b border-border px-4 py-3">
                <Search size={15} className="text-text-3" />
                <input
                  ref={inputRef}
                  value={query}
                  onChange={(e) => setQuery(e.target.value)}
                  onKeyDown={(e) => {
                    if (e.key === "ArrowDown") {
                      e.preventDefault();
                      setActive((a) => Math.min(a + 1, results.length - 1));
                    } else if (e.key === "ArrowUp") {
                      e.preventDefault();
                      setActive((a) => Math.max(a - 1, 0));
                    } else if (e.key === "Enter" && results[active]) {
                      go(results[active].item.slug);
                    }
                  }}
                  placeholder="Search the docs…"
                  className="w-full bg-transparent text-sm text-text outline-none placeholder:text-text-3"
                />
                <kbd className="rounded border border-border bg-surface px-1.5 py-px font-mono text-[10px] text-text-3">
                  esc
                </kbd>
              </div>
              <div className="max-h-80 overflow-y-auto p-1.5">
                {query.trim() === "" ? (
                  <p className="px-3 py-6 text-center text-xs text-text-3">
                    Type to search across every page — install, themes, Git, SSH, shortcuts.
                  </p>
                ) : results.length === 0 ? (
                  <p className="px-3 py-6 text-center text-xs text-text-3">No matches for “{query}”.</p>
                ) : (
                  results.map((r, i) => (
                    <button
                      key={r.item.slug}
                      type="button"
                      onMouseEnter={() => setActive(i)}
                      onClick={() => go(r.item.slug)}
                      className="flex w-full flex-col gap-0.5 rounded-lg px-3 py-2.5 text-left"
                      style={i === active ? { background: "var(--selection)" } : undefined}
                    >
                      <span className="text-sm font-medium" style={{ color: i === active ? "var(--text)" : "var(--text-2)" }}>
                        {r.item.title}
                      </span>
                      <span className="line-clamp-1 text-xs text-text-3">
                        {r.item.text.slice(0, 110)}…
                      </span>
                    </button>
                  ))
                )}
              </div>
            </motion.div>
          </motion.div>
        ) : null}
      </AnimatePresence>
    </>
  );
}
