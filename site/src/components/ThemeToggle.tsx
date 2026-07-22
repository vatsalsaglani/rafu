import { Moon, Sun } from "lucide-react";
import { motion } from "motion/react";
import { useTheme } from "../lib/theme";

export function ThemeToggle({ className = "" }: { className?: string }) {
  const { theme, toggle } = useTheme();
  const isDark = theme === "dark";

  return (
    <motion.button
      type="button"
      onClick={toggle}
      whileTap={{ scale: 0.94 }}
      transition={{ type: "spring", bounce: 0, duration: 0.2 }}
      aria-label={isDark ? "Switch to Khadi light theme" : "Switch to Indigo dark theme"}
      title={isDark ? "Khadi (light)" : "Indigo (dark)"}
      className={`inline-flex h-9 w-9 items-center justify-center rounded-lg border border-border bg-surface text-text-2 transition-colors duration-150 hover:text-text ${className}`}
    >
      {isDark ? <Sun size={16} strokeWidth={1.75} /> : <Moon size={16} strokeWidth={1.75} />}
    </motion.button>
  );
}
