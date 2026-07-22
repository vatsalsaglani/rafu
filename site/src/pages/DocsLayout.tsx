import { ArrowLeft, ArrowRight, ListTree } from "lucide-react";
import { useEffect, useRef, useState } from "react";
import { Link, Navigate, useLocation, useParams } from "react-router-dom";
import { DocsSearch } from "../components/DocsSearch";
import { docsBySlug, docsNav, neighbors } from "../lib/docs";

function SidebarNav({ onNavigate }: { onNavigate?: () => void }) {
  const { slug } = useParams();
  return (
    <nav aria-label="Documentation" className="flex flex-col gap-6">
      {docsNav.map((group) => (
        <div key={group.label}>
          <p className="px-3 text-[10.5px] font-semibold tracking-[0.1em] text-text-3 uppercase">{group.label}</p>
          <ul className="mt-1.5 flex flex-col gap-px">
            {group.items.map((item) => {
              const active = item.slug === slug;
              return (
                <li key={item.slug}>
                  <Link
                    to={`/docs/${item.slug}`}
                    onClick={onNavigate}
                    className="flex items-center rounded-lg px-3 py-[7px] text-[13.5px] transition-colors duration-100"
                    style={
                      active
                        ? {
                            background: "var(--selection)",
                            color: "var(--text)",
                            boxShadow: "inset 2px 0 0 0 var(--accent)",
                          }
                        : { color: "var(--text-2)" }
                    }
                  >
                    {item.title}
                    {item.badge ? (
                      <span className="ml-auto rounded-full border border-border px-1.5 py-px text-[9px] tracking-wide text-text-3 uppercase">
                        {item.badge}
                      </span>
                    ) : null}
                  </Link>
                </li>
              );
            })}
          </ul>
        </div>
      ))}
    </nav>
  );
}

function OnThisPage({ toc }: { toc: { depth: number; text: string; id: string }[] }) {
  const [activeId, setActiveId] = useState<string>("");
  const location = useLocation();

  useEffect(() => {
    const headings = toc
      .map((t) => document.getElementById(t.id))
      .filter((el): el is HTMLElement => el !== null);
    if (headings.length === 0) return;

    const observer = new IntersectionObserver(
      (entries) => {
        for (const entry of entries) {
          if (entry.isIntersecting) setActiveId(entry.target.id);
        }
      },
      { rootMargin: "-80px 0px -70% 0px", threshold: 0 },
    );
    headings.forEach((h) => observer.observe(h));
    return () => observer.disconnect();
  }, [toc, location.pathname]);

  if (toc.length === 0) return null;

  return (
    <nav aria-label="On this page" className="flex flex-col gap-1">
      <p className="px-3 text-[10.5px] font-semibold tracking-[0.1em] text-text-3 uppercase">On this page</p>
      {toc.map((t) => (
        <a
          key={t.id}
          href={`#${t.id}`}
          className="block rounded-md px-3 py-1 text-[12.5px] transition-colors duration-100"
          style={{
            color: activeId === t.id ? "var(--accent)" : "var(--text-3)",
            paddingLeft: t.depth === 3 ? "1.75rem" : undefined,
          }}
        >
          {t.text}
        </a>
      ))}
    </nav>
  );
}

export function DocsLayout() {
  const { slug } = useParams();
  const location = useLocation();
  const [mobileNavOpen, setMobileNavOpen] = useState(false);
  const articleRef = useRef<HTMLDivElement>(null);

  const doc = slug ? docsBySlug.get(slug) : undefined;

  useEffect(() => {
    if (!doc) return;
    document.title = `${doc.meta.title} — Rafu docs`;
    if (location.hash) {
      requestAnimationFrame(() => {
        document.getElementById(location.hash.slice(1))?.scrollIntoView({ block: "start" });
      });
    } else {
      window.scrollTo({ top: 0, behavior: "instant" as ScrollBehavior });
    }
  }, [doc, location.hash]);

  // Copy buttons inside rendered markdown (event delegation).
  useEffect(() => {
    const el = articleRef.current;
    if (!el) return;
    const onClick = (e: MouseEvent) => {
      const btn = (e.target as HTMLElement).closest<HTMLButtonElement>("button[data-copy]");
      if (!btn) return;
      const pre = btn.closest(".codeblock")?.querySelector("pre");
      if (!pre) return;
      navigator.clipboard.writeText(pre.textContent ?? "").then(() => {
        btn.textContent = "Copied";
        setTimeout(() => {
          btn.textContent = "Copy";
        }, 1400);
      });
    };
    el.addEventListener("click", onClick);
    return () => el.removeEventListener("click", onClick);
  }, [doc]);

  if (!doc) return <Navigate to="/docs/getting-started" replace />;

  const { prev, next } = neighbors(doc.slug);

  return (
    <div className="mx-auto max-w-6xl px-5 pt-24 pb-20 sm:px-8">
      {/* Mobile docs nav */}
      <div className="mb-8 lg:hidden">
        <DocsSearch />
        <button
          type="button"
          onClick={() => setMobileNavOpen((v) => !v)}
          className="mt-3 flex w-full items-center gap-2 rounded-lg border border-border bg-surface px-3 py-2 text-sm text-text-2"
          aria-expanded={mobileNavOpen}
        >
          <ListTree size={14} />
          {doc.meta.title}
          <span className="ml-auto text-text-3">{mobileNavOpen ? "−" : "+"}</span>
        </button>
        {mobileNavOpen ? (
          <div className="mt-2 rounded-xl border border-border bg-elevated p-3">
            <SidebarNav onNavigate={() => setMobileNavOpen(false)} />
          </div>
        ) : null}
      </div>

      <div className="grid gap-10 lg:grid-cols-[220px_minmax(0,1fr)] xl:grid-cols-[220px_minmax(0,1fr)_190px]">
        {/* Left sidebar */}
        <aside className="hidden lg:block">
          <div className="sticky top-24 flex max-h-[calc(100vh-7rem)] flex-col gap-6 overflow-y-auto pb-8">
            <DocsSearch />
            <SidebarNav />
          </div>
        </aside>

        {/* Content */}
        <article ref={articleRef} className="min-w-0">
          {doc.meta.badge ? (
            <span className="mb-4 inline-block rounded-full border border-border px-2.5 py-1 text-[10.5px] tracking-wide text-text-3 uppercase">
              {doc.meta.badge}
            </span>
          ) : null}
          <div className="docs-content" dangerouslySetInnerHTML={{ __html: doc.html }} />

          <div className="mt-16 grid gap-3 border-t border-border pt-8 sm:grid-cols-2">
            {prev ? (
              <Link
                to={`/docs/${prev.slug}`}
                className="group flex items-center gap-3 rounded-xl border border-border bg-surface px-4 py-3.5 transition-colors duration-150 hover:border-border-strong"
              >
                <ArrowLeft size={15} className="text-text-3 transition-colors group-hover:text-accent" />
                <span>
                  <span className="block text-[11px] text-text-3">Previous</span>
                  <span className="block text-sm font-medium text-text">{prev.title}</span>
                </span>
              </Link>
            ) : (
              <span />
            )}
            {next ? (
              <Link
                to={`/docs/${next.slug}`}
                className="group flex items-center justify-end gap-3 rounded-xl border border-border bg-surface px-4 py-3.5 text-right transition-colors duration-150 hover:border-border-strong"
              >
                <span>
                  <span className="block text-[11px] text-text-3">Next</span>
                  <span className="block text-sm font-medium text-text">{next.title}</span>
                </span>
                <ArrowRight size={15} className="text-text-3 transition-colors group-hover:text-accent" />
              </Link>
            ) : null}
          </div>
        </article>

        {/* Right TOC */}
        <aside className="hidden xl:block">
          <div className="sticky top-24 max-h-[calc(100vh-7rem)] overflow-y-auto pb-8">
            <OnThisPage toc={doc.toc} />
          </div>
        </aside>
      </div>
    </div>
  );
}
