import type { DocMeta, TocEntry } from "./doc-types";

export interface DocPage {
  slug: string;
  meta: DocMeta;
  toc: TocEntry[];
  html: string;
  plainText: string;
}

interface DocModule {
  meta: DocMeta;
  toc: TocEntry[];
  html: string;
  plainText: string;
}

const modules = import.meta.glob<DocModule>("../docs/*.md", { eager: true });

function slugFromPath(path: string): string {
  return path.replace(/^.*\//, "").replace(/\.md$/, "");
}

export const docsBySlug = new Map<string, DocPage>(
  Object.entries(modules).map(([path, mod]) => {
    const slug = slugFromPath(path);
    return [slug, { slug, meta: mod.meta, toc: mod.toc, html: mod.html, plainText: mod.plainText }];
  }),
);

export interface DocNavItem {
  slug: string;
  title: string;
  badge?: string;
}

export interface DocNavGroup {
  label: string;
  items: DocNavItem[];
}

export const docsNav: DocNavGroup[] = [
  {
    label: "Start here",
    items: [
      { slug: "getting-started", title: "Getting started" },
      { slug: "workspaces", title: "Workspaces" },
    ],
  },
  {
    label: "Using Rafu",
    items: [
      { slug: "the-editor", title: "The editor" },
      { slug: "search", title: "Find & replace" },
      { slug: "markdown", title: "Markdown & Mermaid" },
      { slug: "git", title: "Git in Rafu" },
      { slug: "worktrees", title: "Worktrees" },
      { slug: "commit-messages", title: "AI in Rafu" },
    ],
  },
  {
    label: "Reference",
    items: [
      { slug: "themes", title: "Themes" },
      { slug: "cli", title: "The rafu command" },
      { slug: "terminal", title: "The terminal" },
      { slug: "language-intelligence", title: "Language intelligence" },
      { slug: "shortcuts", title: "Keyboard shortcuts" },
    ],
  },
  {
    label: "Trust",
    items: [
      { slug: "privacy-and-security", title: "Privacy & security" },
      { slug: "roadmap", title: "Roadmap" },
    ],
  },
];

export const orderedSlugs: string[] = docsNav.flatMap((g) => g.items.map((i) => i.slug));

export function neighbors(slug: string): { prev?: DocNavItem; next?: DocNavItem } {
  const idx = orderedSlugs.indexOf(slug);
  const find = (s: string | undefined) => {
    if (!s) return undefined;
    for (const g of docsNav) {
      const item = g.items.find((i) => i.slug === s);
      if (item) return item;
    }
    return undefined;
  };
  return {
    prev: idx > 0 ? find(orderedSlugs[idx - 1]) : undefined,
    next: idx >= 0 && idx < orderedSlugs.length - 1 ? find(orderedSlugs[idx + 1]) : undefined,
  };
}
