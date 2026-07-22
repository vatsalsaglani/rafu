import { motion, useReducedMotion } from "motion/react";

/**
 * The gold running-stitch seam, drawn once when it scrolls into view.
 * A horizontal chevron zigzag echoing the app icon's thread.
 */
function zigzag(width: number, step: number, high: number, low: number): string {
  const points: string[] = [`M0,${low}`];
  let x = 0;
  let up = true;
  while (x < width) {
    x += step;
    points.push(`L${x},${up ? high : low}`);
    up = !up;
  }
  return points.join(" ");
}

export function SeamStitch({ className = "" }: { className?: string }) {
  const reduce = useReducedMotion();
  const width = 1320;
  const d = zigzag(width, 22, 4, 20);

  return (
    <svg
      viewBox={`0 0 ${width} 24`}
      preserveAspectRatio="none"
      aria-hidden="true"
      className={className}
      style={{ width: "100%", height: 14, display: "block" }}
    >
      <motion.path
        d={d}
        fill="none"
        stroke="var(--accent)"
        strokeWidth="2.5"
        strokeLinecap="round"
        strokeLinejoin="round"
        initial={reduce ? false : { pathLength: 0, opacity: 0 }}
        whileInView={{ pathLength: 1, opacity: 0.55 }}
        viewport={{ once: true, margin: "-40px" }}
        transition={
          reduce
            ? { duration: 0 }
            : { pathLength: { type: "spring", bounce: 0, duration: 1.4 }, opacity: { duration: 0.2 } }
        }
      />
    </svg>
  );
}
