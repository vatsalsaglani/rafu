import { Check, ChevronRight, CornerDownLeft, Sparkles, TerminalSquare } from "lucide-react";
import type { ReactNode } from "react";
import { Parallax } from "../components/Parallax";
import { Reveal } from "../components/Reveal";

/* ---------- mini mocks (CSS-built, theme-token colored) ---------- */

function QuickOpenMock() {
  const rows = [
    { name: ".env", path: "raft/", hit: true },
    { name: ".env.local", path: "raft/", hit: false },
    { name: "deploy.env.example", path: "raft/ops/", hit: false },
  ];
  return (
    <div className="overflow-hidden rounded-xl border border-border-strong bg-elevated shadow-[0_20px_60px_-20px_rgba(0,0,0,0.5)]">
      <div className="flex items-center gap-2 border-b border-border px-4 py-3 font-mono text-[13px]">
        <span className="text-text">env</span>
        <span className="h-4 w-px animate-pulse" style={{ background: "var(--accent)" }} />
      </div>
      <div className="p-1.5">
        {rows.map((r, i) => (
          <div
            key={r.name}
            className="flex items-center rounded-lg px-3 py-2 text-[13px]"
            style={i === 0 ? { background: "var(--selection)" } : undefined}
          >
            <span className={i === 0 ? "text-text" : "text-text-2"}>
              <span style={i === 0 ? { color: "var(--accent)" } : undefined}>.env</span>
              {r.name.slice(4)}
            </span>
            <span className="ml-3 text-xs text-text-3">{r.path}</span>
            {i === 0 ? <CornerDownLeft size={12} className="ml-auto text-text-3" /> : null}
          </div>
        ))}
      </div>
      <div className="flex gap-4 border-t border-border px-4 py-2 text-[10.5px] text-text-3">
        <span>↵ open</span>
        <span>⌘↵ open in split</span>
        <span>esc close</span>
      </div>
    </div>
  );
}

function CommitMock() {
  return (
    <div className="overflow-hidden rounded-xl border border-border-strong bg-elevated shadow-[0_20px_60px_-20px_rgba(0,0,0,0.5)]">
      <div className="border-b border-border px-4 py-2.5 text-[10px] font-semibold tracking-[0.08em] text-text-3 uppercase">
        Source control
      </div>
      <div className="px-4 py-3">
        <p className="text-[11px] font-medium text-text-2">Staged — 2 files</p>
        {[
          { b: "M", c: "var(--git-modified)", n: ".env" },
          { b: "M", c: "var(--git-modified)", n: "Dockerfile" },
        ].map((f) => (
          <div key={f.n} className="mt-1.5 flex items-center gap-2 text-[12.5px] text-text-2">
            <span className="font-mono text-[11px]" style={{ color: f.c }}>
              {f.b}
            </span>
            {f.n}
            <Check size={12} className="ml-auto" style={{ color: "var(--git-added)" }} />
          </div>
        ))}
        <button
          type="button"
          className="mt-4 flex w-full items-center justify-center gap-2 rounded-lg border px-3 py-2 text-[12.5px] font-medium"
          style={{ borderColor: "var(--accent)", color: "var(--accent)" }}
        >
          <Sparkles size={13} /> Draft from staged
        </button>
        <p className="mt-2 text-[10.5px] leading-relaxed text-text-3">
          scope: 2 staged files · ~0.4 KB · <span style={{ color: "var(--success)" }}>secrets redacted</span> · preview
          before sending
        </p>
        <div className="mt-3 rounded-lg border border-border bg-surface px-3 py-2 text-[12.5px] text-text">
          Lower log level to debug for local dev
        </div>
        <div className="mt-2 rounded-lg border border-border bg-surface px-3 py-2 text-[12px] leading-relaxed text-text-3">
          The agent set LOG_LEVEL=warn; local development needs debug.
        </div>
        <button
          type="button"
          className="mt-3 w-full rounded-lg px-3 py-2 text-[12.5px] font-medium"
          style={{ background: "var(--accent)", color: "var(--on-accent)" }}
        >
          Commit
        </button>
      </div>
    </div>
  );
}

function RemoteMock() {
  return (
    <div className="overflow-hidden rounded-xl border border-border-strong bg-elevated shadow-[0_20px_60px_-20px_rgba(0,0,0,0.5)]">
      <div className="flex items-center gap-2 border-b border-border px-4 py-3 text-[12.5px]">
        <span className="rounded-md bg-hover px-2 py-1 text-text-2">compose — local</span>
        <ChevronRight size={12} className="text-text-3" />
        <span className="flex items-center gap-1.5 rounded-md bg-hover px-2 py-1 text-text">
          api — prod
          <span className="h-1.5 w-1.5 rounded-full" style={{ background: "#74BFCB" }} title="remote" />
        </span>
      </div>
      <div className="px-4 py-3.5 font-mono text-[12.5px] leading-[1.8]">
        <div className="flex items-center gap-2 text-text-3">
          <TerminalSquare size={13} />
          <span>your shell, your ssh config</span>
        </div>
        <p className="mt-1.5">
          <span style={{ color: "var(--syn-constant)" }}>$</span>{" "}
          <span style={{ color: "var(--syn-function)" }}>rafu</span>{" "}
          <span style={{ color: "var(--syn-keyword)" }}>--ssh</span>{" "}
          <span style={{ color: "var(--syn-string)" }}>prod</span>{" "}
          <span style={{ color: "var(--syn-property)" }}>/srv/api</span>
        </p>
        <p className="mt-1.5 text-text-3">
          # reads ~/.ssh/config · same editor, same Git,
          <br />
          # one mental model — the file just lives elsewhere
        </p>
      </div>
    </div>
  );
}

/* ---------- section ---------- */

interface Dive {
  index: string;
  title: ReactNode;
  body: string;
  points: string[];
  mock: ReactNode;
  badge?: string;
}

const dives: Dive[] = [
  {
    index: "01",
    title: (
      <>
        Made for the <em className="font-display font-normal italic">last mile</em> of agent work
      </>
    ),
    body: "The agent wrote four hundred lines. You need to change four. Rafu opens instantly beside your terminal — each repository in its own real window — and gets out of the way.",
    points: [
      "Quick open and workspace-wide find that feel immediate",
      "An embedded terminal for the one command you still need to run",
      "Tabs, splits, and scroll positions restored exactly where you left them",
    ],
    mock: <QuickOpenMock />,
  },
  {
    index: "02",
    title: (
      <>
        Review, then commit — on <em className="font-display font-normal italic">your</em> terms
      </>
    ),
    body: "Rafu's Git is a review surface, not an autopilot. Stage what you mean, draft a commit message from exactly the diff you choose, edit it, and commit. Repository hooks ask before they run, and their output is shown.",
    points: [
      "Changes, history with a commit graph, branches, side-by-side diffs, hunks, stash, blame",
      "Linked worktrees: open in a new window, compare with your checkout",
      "AI drafting is explicit: visible scope, redacted secrets, previewed payload",
      "No automatic commit, no automatic transmission, no silent anything",
    ],
    mock: <CommitMock />,
  },
  {
    index: "03",
    title: (
      <>
        One window, <em className="font-display font-normal italic">local or remote</em>
      </>
    ),
    body: "SSH workspaces open folders that stay on the remote machine, through the system ssh and your own ~/.ssh/config — aliases, ProxyJump, agents, and security keys included. The UI doesn't fork; only the title bar admits the file is elsewhere.",
    points: [
      "Your OpenSSH config is the authority — nothing reimplemented",
      "A small versioned remote agent; atomic, conflict-checked saves",
      "Unsaved work survives a dropped connection",
    ],
    mock: <RemoteMock />,
    badge: "in a later release",
  },
];

export function DeepDives() {
  return (
    <section className="px-5 py-24 sm:px-8 sm:py-32">
      <div className="mx-auto flex max-w-6xl flex-col gap-28">
        {dives.map((d, i) => (
          <div
            key={d.index}
            className="grid items-center gap-10 lg:grid-cols-2 lg:gap-16"
          >
            <Reveal className={i % 2 === 1 ? "lg:order-2" : ""}>
              <div className="flex items-baseline gap-3">
                <span className="font-mono text-xs text-accent">{d.index}</span>
                {d.badge ? (
                  <span className="rounded-full border border-border px-2 py-0.5 text-[10.5px] tracking-wide text-text-3 uppercase">
                    {d.badge}
                  </span>
                ) : null}
              </div>
              <h3 className="mt-3 text-[clamp(1.6rem,3vw,2.2rem)] leading-[1.12] font-semibold tracking-[-0.02em] text-text">
                {d.title}
              </h3>
              <p className="mt-4 text-[15.5px] leading-[1.75] text-text-2">{d.body}</p>
              <ul className="mt-6 flex flex-col gap-2.5">
                {d.points.map((p) => (
                  <li key={p} className="flex items-start gap-3 text-sm leading-[1.6] text-text-2">
                    <span className="mt-[7px] h-1 w-3 shrink-0 rounded-full" style={{ background: "var(--accent)" }} />
                    {p}
                  </li>
                ))}
              </ul>
            </Reveal>
            <Reveal delay={0.1} className={i % 2 === 1 ? "lg:order-1" : ""}>
              <Parallax amount={16}>
                <div className="relative">
                  <div
                    aria-hidden="true"
                    className="dither absolute -inset-6 rounded-3xl text-border-strong opacity-20 [mask-image:radial-gradient(closest-side,black,transparent)]"
                  />
                  <div className="relative">{d.mock}</div>
                </div>
              </Parallax>
            </Reveal>
          </div>
        ))}
      </div>
    </section>
  );
}
