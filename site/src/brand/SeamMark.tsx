/**
 * The Rafu mark — two cloth panels laced by one zari-gold zigzag thread.
 * Inline version: panels/stroke follow the active theme, thread is always
 * the accent gold. The squircle app icon lives in /public/favicon.svg.
 */
export function SeamMark({ size = 22, className = "" }: { size?: number; className?: string }) {
  return (
    <svg
      width={size}
      height={size}
      viewBox="0 0 48 48"
      fill="none"
      aria-hidden="true"
      className={className}
    >
      <rect x="4" y="6" width="17" height="36" rx="4" fill="var(--elevated)" stroke="var(--border-strong)" strokeWidth="1.5" />
      <rect x="27" y="6" width="17" height="36" rx="4" fill="var(--elevated)" stroke="var(--border-strong)" strokeWidth="1.5" />
      <polyline
        points="19,11 29,16 19,21 29,26 19,31 29,36 19,39"
        fill="none"
        stroke="var(--accent)"
        strokeWidth="3"
        strokeLinecap="round"
        strokeLinejoin="round"
      />
    </svg>
  );
}
