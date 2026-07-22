import { Reveal } from "../components/Reveal";

const noGoals = [
  "Extension marketplace",
  "Embedded coding agent",
  "AI chat or inline generation",
  "Debugger",
  "Collaboration suite",
  "Per-document WebViews",
  "Automatic network calls",
  "A kitchen sink",
];

/** The non-goals are a feature. This section says so, plainly. */
export function NonGoals() {
  return (
    <section className="px-5 py-24 sm:px-8 sm:py-32">
      <Reveal className="mx-auto max-w-4xl">
        <div className="relative overflow-hidden rounded-3xl border border-border bg-surface px-7 py-12 sm:px-12 sm:py-16">
          <div
            aria-hidden="true"
            className="dither absolute inset-0 text-border-strong opacity-[0.12] [mask-image:linear-gradient(120deg,black,transparent_65%)]"
          />
          <div className="relative">
            <h2 className="text-[clamp(1.9rem,4vw,2.9rem)] leading-[1.08] font-semibold tracking-[-0.025em] text-text">
              Deliberately{" "}
              <em className="font-display font-normal italic" style={{ color: "var(--accent)" }}>
                not
              </em>{" "}
              an IDE.
            </h2>
            <p className="mt-4 max-w-xl text-[15.5px] leading-[1.75] text-text-2">
              Rafu ships with a written list of things it will never do. That's not a limitation — it's how the tool
              stays fast, small, and yours.
            </p>
            <ul className="mt-9 grid gap-x-10 gap-y-3 sm:grid-cols-2">
              {noGoals.map((item) => (
                <li key={item} className="flex items-center gap-3 text-[15px] text-text-2">
                  <span className="h-px w-4 shrink-0" style={{ background: "var(--accent)" }} aria-hidden="true" />
                  {item}
                </li>
              ))}
            </ul>
            <p className="mt-10 border-t border-border pt-6 text-sm leading-[1.7] text-text-3">
              Every feature must support opening, editing, reviewing, or committing a repository.{" "}
              <span className="text-text-2">If it doesn't, it isn't in Rafu.</span>
            </p>
          </div>
        </div>
      </Reveal>
    </section>
  );
}
