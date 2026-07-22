import { Braces, GitCompareArrows, GitFork, Layers, Lock, Palette, Sparkles, Terminal } from "lucide-react";
import type { ReactNode } from "react";
import { Reveal } from "../components/Reveal";

const features: { icon: ReactNode; title: string; body: string }[] = [
  {
    icon: <Layers size={18} strokeWidth={1.75} />,
    title: "Truly native",
    body: "TextKit 2 editing, real windows, real menus, system appearance. No Electron, no WebView canvas — typing that never waits on anything.",
  },
  {
    icon: <GitCompareArrows size={18} strokeWidth={1.75} />,
    title: "Git, at a glance",
    body: "Changes, history with a real commit graph, branches, worktrees, side-by-side diffs, hunk staging, stash, and opt-in inline blame. See exactly what the agent did before you commit it.",
  },
  {
    icon: <GitFork size={18} strokeWidth={1.75} />,
    title: "Worktrees, natively",
    body: "List, add, and remove linked worktrees from Source Control. Open one in its own window or diff it against your checkout — the agent in one tree, you in another.",
  },
  {
    icon: <Lock size={18} strokeWidth={1.75} />,
    title: "Explicit AI, on your terms",
    body: "Commit messages drafted from the diff scope you choose; .gitignore and .dockerignore suggestions with per-pattern reasons. Payloads previewed, secrets redacted — nothing is sent or written automatically.",
  },
  {
    icon: <Braces size={18} strokeWidth={1.75} />,
    title: "Tree-sitter, then your LSP",
    body: "Real incremental highlighting for 11 languages, colored by the active theme. Opt-in language servers — ours or yours — add definition, references, hover, and symbols. No marketplace, nothing always-on.",
  },
  {
    icon: <Sparkles size={18} strokeWidth={1.75} />,
    title: "Markdown, rendered natively",
    body: "GitHub-Flavored Markdown with native Mermaid diagrams — edit, split, or preview per document. No per-document WebView.",
  },
  {
    icon: <Palette size={18} strokeWidth={1.75} />,
    title: "Themes as data",
    body: "Plain JSON theme files, hot-reloaded on save. Indigo and Khadi are bundled; writing your own is an afternoon, not a plugin.",
  },
  {
    icon: <Terminal size={18} strokeWidth={1.75} />,
    title: "Small on purpose",
    body: "Idle memory budgeted below 150 MB. Syntax parsing for open buffers only. Zero persistent Git processes. No silent network calls.",
  },
];

export function Features() {
  return (
    <section id="features" className="px-5 py-24 sm:px-8 sm:py-32">
      <div className="mx-auto max-w-6xl">
        <div className="max-w-2xl">
          <Reveal>
            <p className="text-xs font-semibold tracking-[0.12em] text-accent uppercase">What it does</p>
          </Reveal>
          <Reveal delay={0.05}>
            <h2 className="mt-4 text-[clamp(1.9rem,4vw,2.9rem)] leading-[1.08] font-semibold tracking-[-0.025em] text-text">
              Everything the mend needs.{" "}
              <em className="font-display font-normal italic text-text-2">Nothing it doesn't.</em>
            </h2>
          </Reveal>
        </div>

        <div className="mt-14 grid gap-4 sm:grid-cols-2 lg:grid-cols-3">
          {features.map((f, i) => (
            <Reveal key={f.title} delay={0.05 * (i % 3)}>
              <div className="group h-full rounded-2xl border border-border bg-surface p-6 transition-colors duration-200 hover:border-border-strong">
                <div
                  className="inline-flex h-9 w-9 items-center justify-center rounded-lg border border-border bg-elevated transition-colors duration-200 group-hover:border-accent group-hover:text-accent"
                  style={{ color: "var(--text-2)" }}
                >
                  {f.icon}
                </div>
                <h3 className="mt-5 text-[16px] font-semibold tracking-[-0.01em] text-text">{f.title}</h3>
                <p className="mt-2 text-sm leading-[1.7] text-text-2">{f.body}</p>
              </div>
            </Reveal>
          ))}
        </div>
      </div>
    </section>
  );
}
