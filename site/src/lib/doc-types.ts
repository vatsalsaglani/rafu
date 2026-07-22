export interface DocMeta {
  title: string;
  description: string;
  badge: string | null;
}

export interface TocEntry {
  depth: number;
  text: string;
  id: string;
}
