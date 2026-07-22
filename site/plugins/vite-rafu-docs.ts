import { readFile } from "node:fs/promises";
import { dirname, extname, resolve } from "node:path";
import matter from "gray-matter";
import { Marked, type Tokens } from "marked";
import { createHighlighter, type Highlighter } from "shiki";
import type { Plugin } from "vite";
import { rafuIndigoTheme, rafuKhadiTheme } from "./shiki-rafu-themes";

/**
 * Rafu docs pipeline.
 *
 * 1. `*.md` imports become JS modules `{ meta, toc, html, plainText }`:
 *    frontmatter parsed, GFM markdown rendered, fenced code highlighted at
 *    build/dev time with Shiki using Rafu's own Indigo/Khadi themes, and a
 *    heading TOC extracted. No markdown or highlighting cost in the client.
 *
 * 2. `<file>?highlight` imports return a highlighted HTML string for that
 *    file's contents (used for landing-page code samples).
 */

const HIGHLIGHT_PREFIX = "\0rafu-highlight:";
const HIGHLIGHT_QUERY = "?highlight";

const LANGS = [
  "swift",
  "typescript",
  "tsx",
  "javascript",
  "json",
  "jsonc",
  "yaml",
  "bash",
  "shellscript",
  "dockerfile",
  "toml",
  "markdown",
  "python",
  "diff",
  "xml",
  "ini",
  "text",
];

let highlighterPromise: Promise<Highlighter> | null = null;

function getHighlighter(): Promise<Highlighter> {
  highlighterPromise ??= createHighlighter({
    themes: [rafuIndigoTheme, rafuKhadiTheme],
    langs: LANGS,
  });
  return highlighterPromise;
}

function highlightCode(highlighter: Highlighter, code: string, lang: string): string {
  const language = highlighter.getLoadedLanguages().includes(lang) ? lang : "text";
  return highlighter.codeToHtml(code.replace(/\n$/, ""), {
    lang: language,
    themes: { dark: "rafu-indigo", light: "rafu-khadi" },
    defaultColor: false,
  });
}

function slugify(text: string, seen: Map<string, number>): string {
  const base = text
    .toLowerCase()
    .trim()
    .replace(/<[^>]+>/g, "")
    .replace(/[`*_~]/g, "")
    .replace(/[^\p{L}\p{N}\s-]/gu, "")
    .replace(/\s+/g, "-");
  const count = seen.get(base) ?? 0;
  seen.set(base, count + 1);
  return count === 0 ? base : `${base}-${count}`;
}

function escapeAttr(value: string): string {
  return value.replace(/&/g, "&amp;").replace(/"/g, "&quot;");
}

function stripHtml(html: string): string {
  return html
    .replace(/<script[\s\S]*?<\/script>/g, " ")
    .replace(/<style[\s\S]*?<\/style>/g, " ")
    .replace(/<[^>]+>/g, " ")
    .replace(/&amp;/g, "&")
    .replace(/&lt;/g, "<")
    .replace(/&gt;/g, ">")
    .replace(/&quot;/g, '"')
    .replace(/&#39;/g, "'")
    .replace(/\s+/g, " ")
    .trim();
}

interface TocEntry {
  depth: number;
  text: string;
  id: string;
}

export function rafuDocs(): Plugin {
  return {
    name: "rafu-docs",
    enforce: "pre",

    resolveId(source, importer) {
      if (!source.endsWith(HIGHLIGHT_QUERY)) return null;
      const target = source.slice(0, -HIGHLIGHT_QUERY.length);
      const file = target.startsWith(".") && importer ? resolve(dirname(importer), target) : target;
      return HIGHLIGHT_PREFIX + file;
    },

    async load(id) {
      if (!id.startsWith(HIGHLIGHT_PREFIX)) return null;
      const file = id.slice(HIGHLIGHT_PREFIX.length);
      const code = await readFile(file, "utf8");
      const lang = extname(file).slice(1).replace(/^\./, "") || "text";
      const highlighter = await getHighlighter();
      const html = highlightCode(highlighter, code, lang);
      return `export default ${JSON.stringify(html)};`;
    },

    async transform(code, id) {
      if (!id.endsWith(".md")) return null;

      const { data, content } = matter(code);
      const highlighter = await getHighlighter();
      const toc: TocEntry[] = [];
      const seenSlugs = new Map<string, number>();

      const md = new Marked({ gfm: true, breaks: false });
      md.use({
        renderer: {
          code({ text, lang }: Tokens.Code): string {
            const language = (lang ?? "").trim().split(/\s+/)[0] ?? "";
            const label = language || "text";
            const highlighted = highlightCode(highlighter, text, label);
            return `<div class="codeblock" data-lang="${escapeAttr(label)}"><div class="codeblock-header"><span class="codeblock-lang">${escapeAttr(label)}</span><button class="codeblock-copy" type="button" data-copy>Copy</button></div>${highlighted}</div>`;
          },
          heading(this: unknown, token: Tokens.Heading): string {
            const parser = (this as { parser: { parseInline(tokens: unknown[]): string } }).parser;
            const inner = parser.parseInline(token.tokens as unknown[]);
            const plain = stripHtml(inner);
            const slug = slugify(plain, seenSlugs);
            if (token.depth >= 2 && token.depth <= 3) {
              toc.push({ depth: token.depth, text: plain, id: slug });
            }
            return `<h${token.depth} id="${slug}"><a class="heading-anchor" href="#${slug}" aria-hidden="true" tabindex="-1">#</a>${inner}</h${token.depth}>`;
          },
          link({ href, tokens }: Tokens.Link): string {
            const text = (this as { parser: { parseInline(tokens: unknown[]): string } }).parser.parseInline(
              tokens as unknown[],
            );
            const external = /^https?:\/\//.test(href);
            const attrs = external ? ' target="_blank" rel="noopener noreferrer"' : "";
            return `<a href="${escapeAttr(href)}"${attrs}>${text}</a>`;
          },
        },
      });

      const html = md.parse(content, { async: false }) as string;
      const meta = {
        title: typeof data.title === "string" ? data.title : "Untitled",
        description: typeof data.description === "string" ? data.description : "",
        badge: typeof data.badge === "string" ? data.badge : null,
      };
      const plainText = stripHtml(html);

      return [
        `export const meta = ${JSON.stringify(meta)};`,
        `export const toc = ${JSON.stringify(toc)};`,
        `export const html = ${JSON.stringify(html)};`,
        `export const plainText = ${JSON.stringify(plainText)};`,
        `export default { meta, toc, html, plainText };`,
      ].join("\n");
    },
  };
}
