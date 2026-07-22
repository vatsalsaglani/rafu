import { Reveal } from "../components/Reveal";

const stats = [
  { value: "< 150 MB", label: "idle-memory budget for a local workspace" },
  { value: "1 frame", label: "p95 target for typing-path work" },
  { value: "0", label: "persistent Git processes held open" },
  { value: "0", label: "network calls without an explicit action" },
];

export function Numbers() {
  return (
    <section className="px-5 py-20 sm:px-8 sm:py-24">
      <div className="mx-auto max-w-6xl">
        <div className="grid gap-px overflow-hidden rounded-2xl border border-border bg-border sm:grid-cols-2 lg:grid-cols-4">
          {stats.map((s, i) => (
            <Reveal key={s.label} delay={0.05 * i} className="bg-surface">
              <div className="p-7">
                <p className="font-mono text-[clamp(1.5rem,2.6vw,2rem)] font-medium tracking-[-0.02em] text-text">
                  {s.value}
                </p>
                <p className="mt-2 text-[13px] leading-[1.6] text-text-2">{s.label}</p>
              </div>
            </Reveal>
          ))}
        </div>
        <Reveal delay={0.15}>
          <p className="mt-5 text-center text-xs text-text-3">
            Budgets from the engineering plan, not marketing promises — measured in Release builds, not assumed.
          </p>
        </Reveal>
      </div>
    </section>
  );
}
