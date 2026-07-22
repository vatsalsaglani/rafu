import { Check, Copy, X } from "lucide-react";
import { AnimatePresence, motion } from "motion/react";
import { useEffect, useState } from "react";
import { GITHUB_RELEASES_URL, LATEST_RELEASE } from "../lib/site";

const XATTR = "xattr -dr com.apple.quarantine /Applications/Rafu.app";

/**
 * Shown as the releases page opens in a new tab: the four steps from zip to
 * first launch, including the quarantine removal pre-release builds need.
 */
export function InstallDialog({ open, onClose }: { open: boolean; onClose: () => void }) {
  const [copied, setCopied] = useState(false);

  useEffect(() => {
    if (!open) return;
    const onKey = (e: KeyboardEvent) => e.key === "Escape" && onClose();
    document.addEventListener("keydown", onKey);
    document.documentElement.style.overflow = "hidden";
    return () => {
      document.removeEventListener("keydown", onKey);
      document.documentElement.style.overflow = "";
    };
  }, [open, onClose]);

  const copy = async () => {
    try {
      await navigator.clipboard.writeText(XATTR);
      setCopied(true);
      setTimeout(() => setCopied(false), 1600);
    } catch {
      /* clipboard denied — the command is selectable */
    }
  };

  return (
    <AnimatePresence>
      {open ? (
        <motion.div
          initial={{ opacity: 0 }}
          animate={{ opacity: 1 }}
          exit={{ opacity: 0 }}
          transition={{ duration: 0.18 }}
          className="fixed inset-0 z-[60] flex items-end justify-center bg-black/45 p-4 backdrop-blur-sm sm:items-center"
          onClick={onClose}
        >
          <motion.div
            role="dialog"
            aria-modal="true"
            aria-labelledby="install-title"
            initial={{ opacity: 0, y: 16, scale: 0.98 }}
            animate={{ opacity: 1, y: 0, scale: 1 }}
            exit={{ opacity: 0, y: 10, scale: 0.98 }}
            transition={{ type: "spring", bounce: 0, duration: 0.35 }}
            className="w-full max-w-md rounded-2xl border border-border-strong bg-elevated p-6 shadow-2xl"
            onClick={(e) => e.stopPropagation()}
          >
            <div className="flex items-start justify-between gap-4">
              <div>
                <h2 id="install-title" className="text-lg font-semibold tracking-[-0.01em] text-text">
                  Install Rafu
                </h2>
                <p className="mt-1 text-[13px] leading-relaxed text-text-3">
                  The releases page just opened in a new tab.
                </p>
              </div>
              <button
                type="button"
                onClick={onClose}
                autoFocus
                aria-label="Close"
                className="inline-flex h-8 w-8 shrink-0 items-center justify-center rounded-lg border border-border bg-surface text-text-2 transition-colors hover:text-text"
              >
                <X size={14} />
              </button>
            </div>

            <ol className="mt-5 flex flex-col gap-4 text-[13.5px] leading-[1.6] text-text-2">
              <li className="flex gap-3">
                <StepN n={1} />
                <span>
                  Download <code className="font-mono text-[0.85em] text-text">{LATEST_RELEASE.asset}</code> from the{" "}
                  <a
                    href={GITHUB_RELEASES_URL}
                    target="_blank"
                    rel="noopener noreferrer"
                    className="font-medium text-accent underline decoration-accent/40 underline-offset-2 hover:decoration-accent"
                  >
                    latest release
                  </a>{" "}
                  <span className="text-text-3">({LATEST_RELEASE.version})</span>.
                </span>
              </li>
              <li className="flex gap-3">
                <StepN n={2} />
                <span>
                  Unzip and move <code className="font-mono text-[0.85em] text-text">Rafu.app</code> to{" "}
                  <code className="font-mono text-[0.85em] text-text">/Applications</code>.
                </span>
              </li>
              <li className="flex gap-3">
                <StepN n={3} />
                <div className="min-w-0 flex-1">
                  <span>Beta builds aren't notarized yet, so clear the quarantine flag once:</span>
                  <div className="mt-2 flex items-center gap-2 rounded-lg border border-border bg-editor-bg px-3 py-2">
                    <code className="min-w-0 flex-1 overflow-x-auto font-mono text-[12px] whitespace-nowrap text-text">
                      {XATTR}
                    </code>
                    <button
                      type="button"
                      onClick={copy}
                      aria-label="Copy command"
                      className="shrink-0 text-text-3 transition-colors hover:text-text"
                    >
                      {copied ? <Check size={14} style={{ color: "var(--git-added)" }} /> : <Copy size={14} />}
                    </button>
                  </div>
                </div>
              </li>
              <li className="flex gap-3">
                <StepN n={4} />
                <span>Open Rafu from Applications — and mend.</span>
              </li>
            </ol>

            <p className="mt-5 border-t border-border pt-4 text-[11.5px] leading-relaxed text-text-3">
              Run the command only on the app you just downloaded. Signed, notarized builds arrive with the first
              stable release.
            </p>
          </motion.div>
        </motion.div>
      ) : null}
    </AnimatePresence>
  );
}

function StepN({ n }: { n: number }) {
  return (
    <span
      aria-hidden="true"
      className="mt-px flex h-5 w-5 shrink-0 items-center justify-center rounded-full font-mono text-[11px]"
      style={{ background: "color-mix(in srgb, var(--accent) 16%, transparent)", color: "var(--accent)" }}
    >
      {n}
    </span>
  );
}
