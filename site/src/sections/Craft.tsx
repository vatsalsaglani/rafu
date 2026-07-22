import { SeamMark } from "../brand/SeamMark";
import { MendDiff } from "../components/MendDiff";
import { Parallax } from "../components/Parallax";
import { Reveal } from "../components/Reveal";

/**
 * The name story. The રફૂ glyph appears here — the one place on the site
 * where the script has room to breathe (per the product plan).
 */
export function Craft() {
  return (
    <section id="craft" className="relative px-5 py-24 sm:px-8 sm:py-32">
      <div className="mx-auto max-w-6xl">
        <div className="grid items-center gap-12 lg:grid-cols-[1.15fr_1fr] lg:gap-20">
          <div className="mx-auto max-w-2xl text-center lg:mx-0 lg:text-left">
            <Reveal>
              <p className="font-display text-[clamp(4rem,9vw,6.5rem)] leading-none text-text">રફૂ</p>
            </Reveal>
            <Reveal delay={0.05}>
              <p className="mt-4 font-mono text-sm text-text-3">
                rafu · <span style={{ color: "var(--accent)" }}>(rah-foo)</span> — darning
              </p>
            </Reveal>
            <Reveal delay={0.1}>
              <h2 className="mt-8 text-[clamp(1.7rem,3.4vw,2.4rem)] leading-[1.15] font-semibold tracking-[-0.02em] text-text">
                The repair you{" "}
                <em className="font-display font-normal italic" style={{ color: "var(--accent)" }}>
                  never notice.
                </em>
              </h2>
            </Reveal>
            <Reveal delay={0.15}>
              <p className="mt-5 text-[16px] leading-[1.75] text-text-2">
                Rafu is the everyday Gujarati word for mending a small hole in otherwise good fabric — and the{" "}
                <em className="font-display italic">rafugar</em> is the craftsperson whose repairs are meant to be
                invisible. Your coding agent weaves the cloth: the feature, the refactor, the scaffold. Rafu is what
                you reach for to mend what's left — the <code className="font-mono text-[0.85em]">.env</code> value,
                the Dockerfile line, the manifest the agent almost got right.
              </p>
            </Reveal>
          </div>

          <Reveal delay={0.1}>
            <Parallax amount={22}>
              <figure className="relative">
                <div
                  aria-hidden="true"
                  className="absolute -inset-4 rounded-3xl opacity-25 blur-2xl"
                  style={{ background: "radial-gradient(closest-side, var(--accent), transparent)" }}
                />
                <div className="relative">
                  <MendDiff />
                </div>
                <figcaption className="relative mt-3 text-center text-xs text-text-3">
                  The mend, as it looks in Rafu — the agent wove, you changed one line.
                </figcaption>
              </figure>
            </Parallax>
          </Reveal>
        </div>

        <Reveal delay={0.1} className="mx-auto mt-16 max-w-3xl">
          <div className="grid gap-px overflow-hidden rounded-2xl border border-border bg-border sm:grid-cols-3">
            {[
              {
                title: "The mend",
                body: "One gold thread closes the gap — the small, exact fix after the large weave.",
              },
              {
                title: "Two panels",
                body: "The split editor and the side-by-side diff. Two views of the same cloth.",
              },
              {
                title: "One seam",
                body: "Local and SSH workspaces, joined by a single mental model.",
              },
            ].map((item) => (
              <div key={item.title} className="bg-surface p-6">
                <SeamMark size={20} className="mb-4 opacity-90" />
                <h3 className="text-[15px] font-semibold text-text">{item.title}</h3>
                <p className="mt-1.5 text-sm leading-[1.65] text-text-2">{item.body}</p>
              </div>
            ))}
          </div>
        </Reveal>
      </div>
    </section>
  );
}
