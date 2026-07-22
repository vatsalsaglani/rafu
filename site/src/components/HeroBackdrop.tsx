import { motion, useReducedMotion, useScroll, useTransform } from "motion/react";
import { useEffect, useRef } from "react";
import { asset } from "../lib/site";
import { useTheme } from "../lib/theme";

/**
 * The immersive hero layer: a 6s ambient loop of cloth and gold thread —
 * indigo in dark mode, khadi in light. Reduced motion gets the matching
 * poster frame. The layer drifts slower than the page for parallax,
 * pauses when offscreen, and fades into the page background so typography
 * always wins.
 */
export function HeroBackdrop() {
  const { theme } = useTheme();
  const reduce = useReducedMotion();
  const ref = useRef<HTMLDivElement>(null);
  const videoRef = useRef<HTMLVideoElement>(null);
  const { scrollYProgress } = useScroll({ target: ref, offset: ["start start", "end start"] });
  const y = useTransform(scrollYProgress, [0, 1], ["0%", "16%"]);

  const dark = theme === "dark";
  const showVideo = !reduce;

  // Honest resources: the loop only plays while visible.
  useEffect(() => {
    const video = videoRef.current;
    if (!video) return;
    const observer = new IntersectionObserver(
      ([entry]) => {
        if (entry.isIntersecting) {
          video.play().catch(() => {});
        } else {
          video.pause();
        }
      },
      { threshold: 0.05 },
    );
    observer.observe(video);
    return () => observer.disconnect();
  }, [showVideo]);

  return (
    <div ref={ref} aria-hidden="true" className="pointer-events-none absolute inset-0 overflow-hidden">
      <motion.div style={reduce ? undefined : { y }} className="absolute -inset-x-[6%] -inset-y-[10%]">
        {showVideo ? (
          <video
            key={dark ? "indigo" : "khadi"}
            ref={videoRef}
            className="h-full w-full object-cover"
            style={{ opacity: dark ? 0.5 : 0.55 }}
            autoPlay
            muted
            loop
            playsInline
            preload="auto"
            poster={asset(dark ? "/media/hero-poster.webp" : "/media/hero-khadi.webp")}
          >
            <source
              src={asset(dark ? "/media/hero-loop.mp4" : "/media/hero-loop-khadi.mp4")}
              type="video/mp4"
            />
          </video>
        ) : (
          <img
            src={asset(dark ? "/media/hero-poster.webp" : "/media/hero-khadi.webp")}
            alt=""
            className="h-full w-full object-cover"
            style={{ opacity: dark ? 0.45 : 0.55 }}
            loading="eager"
            decoding="async"
          />
        )}
      </motion.div>

      {/* Fade the cloth into the page background — edges first, bottom fully. */}
      <div
        className="absolute inset-0"
        style={{
          background:
            "linear-gradient(to bottom, color-mix(in srgb, var(--bg) 30%, transparent) 0%, color-mix(in srgb, var(--bg) 62%, transparent) 46%, var(--bg) 96%)",
        }}
      />
      <div
        className="absolute inset-0"
        style={{
          background:
            "radial-gradient(90% 70% at 50% 34%, transparent 40%, color-mix(in srgb, var(--bg) 55%, transparent) 100%)",
        }}
      />
    </div>
  );
}
