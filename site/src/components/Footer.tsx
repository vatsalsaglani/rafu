import { Github } from "lucide-react";
import { Link } from "react-router-dom";
import { SeamMark } from "../brand/SeamMark";
import { GITHUB_URL } from "../lib/site";

export function Footer() {
  return (
    <footer className="border-t border-border px-5 py-12 sm:px-8">
      <div className="mx-auto flex max-w-6xl flex-col items-start justify-between gap-8 sm:flex-row sm:items-center">
        <div className="flex items-center gap-3">
          <SeamMark size={26} />
          <div>
            <p className="text-sm font-semibold text-text">Rafu</p>
            <p className="text-xs text-text-3">A mending tool for the agent era.</p>
          </div>
        </div>

        <nav className="flex items-center gap-6 text-sm text-text-2" aria-label="Footer">
          <a href="/#craft" className="transition-colors duration-150 hover:text-text">
            Craft
          </a>
          <a href="/#features" className="transition-colors duration-150 hover:text-text">
            Features
          </a>
          <a href="/#themes" className="transition-colors duration-150 hover:text-text">
            Themes
          </a>
          <Link to="/docs" className="transition-colors duration-150 hover:text-text">
            Docs
          </Link>
          <a
            href={GITHUB_URL}
            target="_blank"
            rel="noopener noreferrer"
            aria-label="Rafu on GitHub"
            className="transition-colors duration-150 hover:text-text"
          >
            <Github size={16} strokeWidth={1.75} />
          </a>
        </nav>

        <p className="text-xs text-text-3">© {new Date().getFullYear()} Rafu. macOS 15+.</p>
      </div>
    </footer>
  );
}
