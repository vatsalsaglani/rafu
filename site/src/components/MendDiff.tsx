import { GitBranch } from "lucide-react";

/**
 * The mend, as it actually looks in Rafu: a working-tree diff of the .env.
 * The agent wove `warn`; the human mends it to `debug`. A gold gutter bar
 * and the "mended" tag are the single thread closing the gap — the visible
 * proof of "the repair you never notice".
 */

const K = ({ children }: { children: string }) => <span style={{ color: "var(--syn-property)" }}>{children}</span>;
const V = ({ children }: { children: string }) => <span style={{ color: "var(--syn-string)" }}>{children}</span>;
const P = ({ children }: { children: string }) => <span style={{ color: "var(--syn-punctuation)" }}>{children}</span>;

function Row({
  n,
  tone,
  tag,
  children,
}: {
  n: string;
  tone?: "removed" | "added";
  tag?: string;
  children: React.ReactNode;
}) {
  const sign = tone === "removed" ? "−" : tone === "added" ? "+" : " ";
  return (
    <div
      className="flex items-baseline rounded-[3px] pr-3"
      style={
        tone
          ? {
              background: tone === "removed" ? "var(--diff-removed-bg)" : "var(--diff-added-bg)",
              boxShadow: tone === "added" ? "inset 2px 0 0 var(--accent)" : undefined,
            }
          : undefined
      }
    >
      <span className="w-8 shrink-0 pr-2 text-right select-none" style={{ color: "var(--gutter)" }}>
        {n}
      </span>
      <span
        className="w-4 shrink-0 select-none"
        style={{
          color:
            tone === "removed" ? "var(--git-deleted)" : tone === "added" ? "var(--git-added)" : "transparent",
        }}
        aria-hidden="true"
      >
        {sign}
      </span>
      <span className="whitespace-pre">{children}</span>
      {tag ? (
        <span
          className="ml-auto pl-4 font-sans text-[10px] tracking-wide"
          style={{ color: tone === "removed" ? "var(--text-3)" : "var(--accent)" }}
        >
          {tag}
        </span>
      ) : null}
    </div>
  );
}

export function MendDiff() {
  return (
    <div
      className="overflow-hidden rounded-2xl border border-border-strong bg-elevated text-left shadow-[0_24px_80px_-24px_rgba(0,0,0,0.55)]"
      role="img"
      aria-label="A diff in Rafu: the agent set LOG_LEVEL to warn, shown as removed; below it LOG_LEVEL set to debug, shown as added with a gold bar and the word mended"
    >
      {/* Chrome */}
      <div className="flex h-10 items-center gap-2 border-b border-border bg-surface px-4 text-xs">
        <span className="text-text">.env</span>
        <span className="font-mono text-[10.5px]" style={{ color: "var(--git-modified)" }}>
          M
        </span>
        <span className="text-text-3">· working tree</span>
        <span className="ml-auto flex items-center gap-1.5 text-text-3">
          <GitBranch size={12} strokeWidth={1.75} /> main
        </span>
      </div>

      {/* Diff */}
      <div className="flex flex-col gap-[3px] bg-editor-bg py-3 font-mono text-[12.5px] leading-[1.7]">
        <Row n="3">
          <K>REDIS_URL</K>
          <P>=</P>
          <V>redis://localhost:6379</V>
        </Row>
        <Row n="4" tone="removed" tag="the agent's weave">
          <K>LOG_LEVEL</K>
          <P>=</P>
          <V>warn</V>
        </Row>
        <Row n="4" tone="added" tag="mended">
          <K>LOG_LEVEL</K>
          <P>=</P>
          <V>debug</V>
        </Row>
        <Row n="5">
          <K>API_TIMEOUT_MS</K>
          <P>=</P>
          <V>4000</V>
        </Row>
      </div>

      {/* Footer */}
      <div className="flex items-center gap-3 border-t border-border bg-surface px-4 py-2 text-[11px] text-text-3">
        <span className="h-1.5 w-1.5 rounded-full" style={{ background: "var(--accent)" }} aria-hidden="true" />
        one line — the whole mend
        <span className="ml-auto">⌘⇧S stage</span>
      </div>
    </div>
  );
}
