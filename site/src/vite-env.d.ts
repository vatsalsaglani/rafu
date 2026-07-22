/// <reference types="vite/client" />

declare module "*.md" {
  import type { DocMeta, TocEntry } from "./lib/doc-types";
  export const meta: DocMeta;
  export const toc: TocEntry[];
  export const html: string;
  export const plainText: string;
  const doc: { meta: DocMeta; toc: TocEntry[]; html: string; plainText: string };
  export default doc;
}

declare module "*?highlight" {
  const html: string;
  export default html;
}
