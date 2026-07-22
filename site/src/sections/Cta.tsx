import { Button } from "../components/Button";
import { DownloadButton } from "../components/DownloadButton";
import { Reveal } from "../components/Reveal";
import { SeamStitch } from "../components/SeamStitch";
import { GITHUB_URL } from "../lib/site";
import { useTheme } from "../lib/theme";

export function Cta() {
  const { theme } = useTheme();
  return (
    <section className="relative overflow-hidden px-5 pt-24 pb-28 sm:px-8 sm:pt-32">
      {/* The cloth returns, quiet, behind the final ask */}
      <div aria-hidden="true" className="pointer-events-none absolute inset-0">
        <img
          src={theme === "dark" ? "/media/hero-indigo.webp" : "/media/hero-khadi.webp"}
          alt=""
          loading="lazy"
          decoding="async"
          className="absolute inset-0 h-full w-full object-cover"
          style={{
            opacity: theme === "dark" ? 0.16 : 0.2,
            maskImage: "radial-gradient(75% 90% at 50% 60%, black, transparent)",
            WebkitMaskImage: "radial-gradient(75% 90% at 50% 60%, black, transparent)",
          }}
        />
        <div
          className="absolute inset-x-0 bottom-0 h-[420px] opacity-[0.12]"
          style={{ background: "radial-gradient(60% 100% at 50% 100%, var(--accent), transparent)" }}
        />
      </div>
      <div className="relative mx-auto max-w-3xl text-center">
        <Reveal>
          <h2 className="text-[clamp(2.2rem,5vw,3.6rem)] leading-[1.05] font-semibold tracking-[-0.03em] text-text">
            Ready when{" "}
            <em className="font-display font-normal italic" style={{ color: "var(--accent)" }}>
              you
            </em>{" "}
            are.
          </h2>
        </Reveal>
        <Reveal delay={0.08}>
          <p className="mx-auto mt-5 max-w-lg text-[16px] leading-[1.75] text-text-2">
            The beta is live. The docs are already honest about what Rafu does, what it costs, and what it will
            never do.
          </p>
        </Reveal>
        <Reveal delay={0.14}>
          <div className="mt-9 flex flex-wrap items-center justify-center gap-3">
            <DownloadButton />
            <Button href="/docs" variant="secondary">
              Read the docs
            </Button>
            <Button href={GITHUB_URL} variant="ghost" external>
              GitHub →
            </Button>
          </div>
        </Reveal>
        <Reveal delay={0.2} className="mt-16">
          <SeamStitch />
        </Reveal>
      </div>
    </section>
  );
}
