import { motion } from "motion/react";
import { AppWindow } from "../components/AppWindow";
import { Button } from "../components/Button";
import { DownloadButton } from "../components/DownloadButton";
import { HeroBackdrop } from "../components/HeroBackdrop";
import { Parallax } from "../components/Parallax";
import { GITHUB_URL } from "../lib/site";

const spring = { type: "spring" as const, bounce: 0, duration: 0.6 };

export function Hero() {
  return (
    <section className="relative overflow-hidden px-5 pt-36 pb-16 sm:px-8 sm:pt-44">
      <HeroBackdrop />
      {/* Low gold glow above the cloth */}
      <div aria-hidden="true" className="pointer-events-none absolute inset-0">
        <div
          className="absolute top-[430px] left-1/2 h-[420px] w-[820px] -translate-x-1/2 rounded-full opacity-[0.10]"
          style={{ background: "radial-gradient(closest-side, var(--accent), transparent)" }}
        />
      </div>

      <div className="relative mx-auto max-w-6xl">
        <div className="mx-auto max-w-3xl text-center">
          <motion.p
            initial={{ opacity: 0, y: 10 }}
            animate={{ opacity: 1, y: 0 }}
            transition={{ ...spring, delay: 0 }}
            className="mx-auto inline-flex items-center gap-2 rounded-full border border-border bg-surface px-3.5 py-1.5 text-xs text-text-2"
          >
            <span className="h-1.5 w-1.5 rounded-full" style={{ background: "var(--accent)" }} />
            રફૂ · a native macOS repository companion
          </motion.p>

          <motion.h1
            initial={{ opacity: 0, y: 14 }}
            animate={{ opacity: 1, y: 0 }}
            transition={{ ...spring, delay: 0.06 }}
            className="mt-7 text-[clamp(2.9rem,7.5vw,5.4rem)] leading-[1.02] font-semibold tracking-[-0.035em] text-text"
          >
            The agent weaves.
            <br />
            <span className="font-display font-normal italic" style={{ color: "var(--accent)" }}>
              You mend.
            </span>
          </motion.h1>

          <motion.p
            initial={{ opacity: 0, y: 14 }}
            animate={{ opacity: 1, y: 0 }}
            transition={{ ...spring, delay: 0.12 }}
            className="mx-auto mt-6 max-w-xl text-[17px] leading-[1.65] text-text-2"
          >
            Rafu — <span className="text-text">રફૂ</span>, <em className="font-display">darning</em> — is a small,
            native editor for the focused fixes that remain after a terminal coding agent has done the larger weave.
            Open the repository. Fix the <code className="font-mono text-[0.85em] text-text">.env</code>. Review the
            diff. Commit.
          </motion.p>

          <motion.div
            initial={{ opacity: 0, y: 14 }}
            animate={{ opacity: 1, y: 0 }}
            transition={{ ...spring, delay: 0.18 }}
            className="mt-9 flex flex-wrap items-center justify-center gap-3"
          >
            <DownloadButton />
            <Button href="/docs" variant="secondary">
              Read the docs
            </Button>
            <Button href={GITHUB_URL} variant="ghost" external>
              GitHub →
            </Button>
          </motion.div>

          <motion.p
            initial={{ opacity: 0 }}
            animate={{ opacity: 1 }}
            transition={{ duration: 0.5, delay: 0.3 }}
            className="mt-6 text-xs tracking-wide text-text-3"
          >
            Free · Native · No account · macOS 15+
          </motion.p>
        </div>

        <div className="relative mx-auto mt-16 max-w-4xl">
          <Parallax amount={14}>
            <AppWindow />
          </Parallax>
        </div>
      </div>
    </section>
  );
}
