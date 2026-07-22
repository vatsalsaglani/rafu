import { Reveal } from "../components/Reveal";
import mendSwift from "../brand/samples/mend.swift?highlight";

/**
 * The same Swift sample rendered twice, each panel forcing its own
 * [data-theme], so Indigo and Khadi sit side by side regardless of the
 * site theme. Code is Shiki-highlighted at build time with themes
 * converted from the app's own theme JSON.
 */
function ThemePanel({ theme, name, note }: { theme: "dark" | "light"; name: string; note: string }) {
  return (
    <div
      data-theme={theme}
      className="overflow-hidden rounded-2xl border border-border bg-surface shadow-[0_20px_60px_-24px_rgba(0,0,0,0.45)]"
    >
      <div className="flex items-baseline justify-between border-b border-border px-5 py-3">
        <span className="text-sm font-semibold text-text">{name}</span>
        <span className="text-xs text-text-3">{note}</span>
      </div>
      <div
        className="theme-sample text-[12.5px] leading-[1.75] [&_pre]:m-0 [&_pre]:overflow-x-auto [&_pre]:p-5 [&_pre]:font-mono"
        dangerouslySetInnerHTML={{ __html: mendSwift }}
      />
    </div>
  );
}

export function Themes() {
  return (
    <section id="themes" className="px-5 py-24 sm:px-8 sm:py-32">
      <div className="mx-auto max-w-6xl">
        <div className="mx-auto max-w-2xl text-center">
          <Reveal>
            <p className="text-xs font-semibold tracking-[0.12em] text-accent uppercase">Indigo &amp; Khadi</p>
          </Reveal>
          <Reveal delay={0.05}>
            <h2 className="mt-4 text-[clamp(1.9rem,4vw,2.9rem)] leading-[1.08] font-semibold tracking-[-0.025em] text-text">
              Two palettes,{" "}
              <em className="font-display font-normal italic" style={{ color: "var(--accent)" }}>
                one identity.
              </em>
            </h2>
          </Reveal>
          <Reveal delay={0.1}>
            <p className="mt-5 text-[16px] leading-[1.75] text-text-2">
              Indigo-dyed cloth at night; undyed khadi in daylight; one zari-gold thread through both. Themes are
              data-only JSON — hot-reloaded on save — so your own palette is an afternoon, not a plugin.
            </p>
          </Reveal>
        </div>

        <Reveal delay={0.1} className="mt-14 grid gap-5 lg:grid-cols-2">
          <ThemePanel theme="dark" name="Indigo" note="dark — indigo-dyed cloth, thread gold" />
          <ThemePanel theme="light" name="Khadi" note="light — undyed cotton, indigo ink" />
        </Reveal>

        <Reveal delay={0.15}>
          <p className="mt-6 text-center text-xs text-text-3">
            Highlighted with Rafu's own syntax themes. This page honors the same two palettes — try the toggle above.
          </p>
        </Reveal>
      </div>
    </section>
  );
}
