import { SeamMark } from "../brand/SeamMark";
import { Button } from "../components/Button";

export function NotFound() {
  return (
    <div className="flex min-h-[70vh] flex-col items-center justify-center px-5 pt-16 text-center">
      <SeamMark size={44} />
      <h1 className="mt-8 text-3xl font-semibold tracking-[-0.02em] text-text">
        This page isn't in the{" "}
        <em className="font-display font-normal italic" style={{ color: "var(--accent)" }}>
          weave.
        </em>
      </h1>
      <p className="mt-3 max-w-sm text-[15px] leading-relaxed text-text-2">
        The link may have moved, or the thread was never sewn. The docs and the landing page are intact.
      </p>
      <div className="mt-8 flex gap-3">
        <Button href="/">Back to Rafu</Button>
        <Button href="/docs" variant="secondary">
          Docs
        </Button>
      </div>
    </div>
  );
}
