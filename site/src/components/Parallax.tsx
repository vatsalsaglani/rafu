import { motion, useReducedMotion, useScroll, useTransform } from "motion/react";
import { useRef, type ReactNode } from "react";

/**
 * Gentle scroll parallax: the child drifts `amount` pixels against scroll
 * across the element's transit through the viewport. Reduced motion → still.
 */
export function Parallax({
  children,
  amount = 18,
  className = "",
}: {
  children: ReactNode;
  /** Peak drift in pixels; keep small (12–28) per apple-design restraint. */
  amount?: number;
  className?: string;
}) {
  const ref = useRef<HTMLDivElement>(null);
  const reduce = useReducedMotion();
  const { scrollYProgress } = useScroll({ target: ref, offset: ["start end", "end start"] });
  const y = useTransform(scrollYProgress, [0, 1], [amount, -amount]);

  return (
    <motion.div ref={ref} style={reduce ? undefined : { y }} className={className}>
      {children}
    </motion.div>
  );
}
