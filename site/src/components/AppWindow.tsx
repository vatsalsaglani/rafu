import { FileCode2, Folder, GitBranch, PanelLeft, Search } from "lucide-react";
import { motion } from "motion/react";

/**
 * A CSS-built mock of the Rafu window — durable against UI iteration and
 * sharp at any density. It tells the founding story: a terminal agent wove
 * the repo; the human is mending one line of the .env (gold find-highlight),
 * with the Git sidebar showing what the agent touched.
 */

const files = [
  { name: ".env", badge: "M", badgeColor: "var(--git-modified)", active: true },
  { name: "compose.yaml", badge: "??", badgeColor: "var(--info)", active: false },
  { name: "Dockerfile", badge: "M", badgeColor: "var(--git-modified)", active: false },
  { name: "README.md", badge: null, badgeColor: null, active: false },
];

function EnvLine({ n, children, mended = false }: { n: number; children: React.ReactNode; mended?: boolean }) {
  return (
    <div
      className="flex items-baseline rounded-[3px] pr-3"
      style={mended ? { background: "color-mix(in srgb, var(--accent) 18%, transparent)" } : undefined}
    >
      <span
        className="w-9 shrink-0 pr-3 text-right select-none"
        style={{ color: mended ? "var(--gutter-active)" : "var(--gutter)" }}
      >
        {n}
      </span>
      <span className="whitespace-pre">{children}</span>
      {mended ? (
        <span className="ml-auto pl-4 font-sans text-[10px] tracking-wide" style={{ color: "var(--accent)" }}>
          mended
        </span>
      ) : null}
    </div>
  );
}

const K = ({ children }: { children: string }) => <span style={{ color: "var(--syn-property)" }}>{children}</span>;
const V = ({ children }: { children: string }) => <span style={{ color: "var(--syn-string)" }}>{children}</span>;
const P = ({ children }: { children: string }) => <span style={{ color: "var(--syn-punctuation)" }}>{children}</span>;
const C = ({ children }: { children: string }) => (
  <span className="italic" style={{ color: "var(--syn-comment)" }}>
    {children}
  </span>
);
const N = ({ children }: { children: string }) => <span style={{ color: "var(--syn-number)" }}>{children}</span>;

export function AppWindow() {
  return (
    <motion.div
      initial={{ opacity: 0, y: 24, scale: 0.985 }}
      animate={{ opacity: 1, y: 0, scale: 1 }}
      transition={{ type: "spring", bounce: 0, duration: 0.7, delay: 0.15 }}
      className="overflow-hidden rounded-2xl border border-border-strong bg-elevated text-left shadow-[0_24px_80px_-24px_rgba(0,0,0,0.55)]"
      role="img"
      aria-label="The Rafu window: a .env file open in the editor, one line highlighted as mended, with the Git sidebar showing files changed by a coding agent"
    >
      {/* Window chrome */}
      <div className="flex h-10 items-center gap-3 border-b border-border bg-surface px-4">
        <div className="flex gap-1.5" aria-hidden="true">
          <span className="h-2.5 w-2.5 rounded-full bg-border-strong" />
          <span className="h-2.5 w-2.5 rounded-full bg-border-strong" />
          <span className="h-2.5 w-2.5 rounded-full bg-border-strong" />
        </div>
        <span className="text-xs text-text-2">
          compose <span className="text-text-3">— ~/work/raft</span>
        </span>
        <div className="ml-auto flex items-center gap-3 text-text-3">
          <PanelLeft size={14} strokeWidth={1.75} />
          <Search size={14} strokeWidth={1.75} />
          <span className="flex items-center gap-1 rounded-md bg-hover px-2 py-0.5 text-[11px]" style={{ color: "var(--text-2)" }}>
            <GitBranch size={11} strokeWidth={1.75} />
            main <span style={{ color: "var(--git-modified)" }}>2M</span> <span style={{ color: "var(--info)" }}>1??</span>
          </span>
        </div>
      </div>

      <div className="flex">
        {/* Sidebar */}
        <div className="hidden w-44 shrink-0 flex-col gap-px border-r border-border bg-surface py-2 sm:flex">
          <span className="px-3 pt-1 pb-1.5 text-[10px] font-semibold tracking-[0.08em] text-text-3 uppercase">Files</span>
          {files.map((f) => (
            <div
              key={f.name}
              className="mx-1.5 flex items-center gap-1.5 rounded-md px-2 py-[5px] text-[12px]"
              style={f.active ? { background: "var(--selection)", color: "var(--text)" } : { color: "var(--text-2)" }}
            >
              <FileCode2 size={12} strokeWidth={1.75} className="shrink-0 opacity-60" />
              <span className="truncate">{f.name}</span>
              {f.badge ? (
                <span className="ml-auto font-mono text-[10px]" style={{ color: f.badgeColor ?? undefined }}>
                  {f.badge}
                </span>
              ) : null}
            </div>
          ))}
          <div className="mx-1.5 flex items-center gap-1.5 rounded-md px-2 py-[5px] text-[12px] text-text-2">
            <Folder size={12} strokeWidth={1.75} className="shrink-0 opacity-60" />
            Sources
          </div>
          <div className="mx-1.5 flex items-center gap-1.5 rounded-md px-2 py-[5px] text-[12px] text-text-2">
            <Folder size={12} strokeWidth={1.75} className="shrink-0 opacity-60" />
            Tests
          </div>
        </div>

        {/* Editor */}
        <div className="min-w-0 flex-1 bg-editor-bg">
          {/* Tabs */}
          <div className="flex border-b border-border bg-surface text-[12px]">
            <span className="flex items-center gap-2 border-r border-border bg-editor-bg px-3.5 py-2 text-text">
              .env
              <span className="h-1.5 w-1.5 rounded-full" style={{ background: "var(--accent)" }} aria-label="unsaved" />
            </span>
            <span className="border-r border-border px-3.5 py-2 text-text-3">compose.yaml</span>
          </div>

          {/* Buffer */}
          <div className="flex flex-col gap-[3px] py-3 font-mono text-[12.5px] leading-[1.7]">
            <EnvLine n={1}>
              <C># Local overrides — the agent wove, you mend</C>
            </EnvLine>
            <EnvLine n={2}>
              <K>DATABASE_URL</K>
              <P>=</P>
              <V>postgres://localhost:5432/raft_dev</V>
            </EnvLine>
            <EnvLine n={3}>
              <K>REDIS_URL</K>
              <P>=</P>
              <V>redis://localhost:6379</V>
            </EnvLine>
            <EnvLine n={4} mended>
              <K>LOG_LEVEL</K>
              <P>=</P>
              <V>debug</V>
              <C>            # was "warn" — the agent's guess</C>
            </EnvLine>
            <EnvLine n={5}>
              <K>API_TIMEOUT_MS</K>
              <P>=</P>
              <N>4000</N>
            </EnvLine>
            <EnvLine n={6}>
              <K>ENABLE_TELEMETRY</K>
              <P>=</P>
              <N>false</N>
            </EnvLine>
          </div>

          {/* Status bar */}
          <div className="flex items-center gap-4 border-t border-border bg-surface px-4 py-1.5 text-[11px] text-text-3">
            <span className="flex items-center gap-1">
              <GitBranch size={10} /> main
            </span>
            <span>4:13</span>
            <span className="ml-auto">2 spaces</span>
            <span>LF</span>
            <span>UTF-8</span>
          </div>
        </div>
      </div>
    </motion.div>
  );
}
