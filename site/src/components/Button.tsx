import { motion } from "motion/react";
import type { ReactNode } from "react";
import { Link } from "react-router-dom";

type Variant = "primary" | "secondary" | "ghost";

const styles: Record<Variant, string> = {
  primary:
    "bg-accent text-on-accent border border-transparent hover:bg-accent-hover font-medium shadow-[0_1px_0_0_rgba(0,0,0,0.15)]",
  secondary:
    "bg-surface text-text border border-border-strong hover:border-accent hover:text-accent font-medium",
  ghost: "bg-transparent text-text-2 border border-transparent hover:text-text font-medium",
};

/** Instant pointer-down feedback (apple-design §1), critically damped. */
export function Button({
  children,
  href,
  variant = "primary",
  className = "",
  external = false,
  badge,
  onClick,
}: {
  children: ReactNode;
  href?: string;
  variant?: Variant;
  className?: string;
  external?: boolean;
  badge?: string;
  onClick?: () => void;
}) {
  const inner = (
    <>
      <span>{children}</span>
      {badge ? (
        <span className="rounded-full border border-current px-1.5 py-px text-[10px] font-medium tracking-wide uppercase opacity-70">
          {badge}
        </span>
      ) : null}
    </>
  );

  const cls = `inline-flex items-center gap-2 rounded-full px-5 py-2.5 text-sm transition-colors duration-150 ${styles[variant]} ${className}`;

  const motionProps = {
    whileTap: { scale: 0.97 },
    transition: { type: "spring" as const, bounce: 0, duration: 0.25 },
    className: cls,
  };

  if (href && external) {
    return (
      <motion.a href={href} target="_blank" rel="noopener noreferrer" {...motionProps}>
        {inner}
      </motion.a>
    );
  }
  if (href) {
    return (
      <motion.div whileTap={{ scale: 0.97 }} transition={{ type: "spring", bounce: 0, duration: 0.25 }}>
        <Link to={href} className={cls}>
          {inner}
        </Link>
      </motion.div>
    );
  }
  return (
    <motion.button type="button" onClick={onClick} {...motionProps}>
      {inner}
    </motion.button>
  );
}
