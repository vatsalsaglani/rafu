import type { ThemeRegistration } from "shiki";

/**
 * Shiki/TextMate themes converted from Rafu's bundled themes:
 *   Resources/Themes/indigo.json  (dark)
 *   Resources/Themes/khadi.json   (light)
 *
 * The app's semantic syntax tokens are mapped onto the TextMate scopes that
 * Shiki's bundled grammars emit, so code on this site renders with Rafu's
 * real syntax colors in both appearances.
 */

interface RafuSyntaxTokens {
  comment: string;
  docComment: string;
  string: string;
  escape: string;
  number: string;
  constant: string;
  keyword: string;
  operator: string;
  punctuation: string;
  function: string;
  type: string;
  variable: string;
  parameter: string;
  property: string;
  tag: string;
  attribute: string;
  namespace: string;
  markupHeading: string;
  markupLink: string;
  markupCode: string;
  markupCodeBg: string;
  markupQuote: string;
  markupList: string;
  foreground: string;
  background: string;
  added: string;
  deleted: string;
}

const indigo: RafuSyntaxTokens = {
  comment: "#5F6980",
  docComment: "#6E7890",
  string: "#9FC98F",
  escape: "#74BFCB",
  number: "#E0B36A",
  constant: "#E3A857",
  keyword: "#9D8CE8",
  operator: "#98A6C4",
  punctuation: "#6E7A94",
  function: "#74BFCB",
  type: "#82A7F0",
  variable: "#E7EAF2",
  parameter: "#C9D2E6",
  property: "#B8C2DC",
  tag: "#E08D8D",
  attribute: "#D2B958",
  namespace: "#A9B4CE",
  markupHeading: "#E3A857",
  markupLink: "#74BFCB",
  markupCode: "#9FC98F",
  markupCodeBg: "#1B212D",
  markupQuote: "#9AA3B8",
  markupList: "#98A6C4",
  foreground: "#E7EAF2",
  background: "#151A24",
  added: "#7CC08A",
  deleted: "#E06C75",
};

const khadi: RafuSyntaxTokens = {
  comment: "#8C8776",
  docComment: "#7E7B6C",
  string: "#4E7D45",
  escape: "#1E7A87",
  number: "#9A5F12",
  constant: "#A2701F",
  keyword: "#6C4FC4",
  operator: "#55617A",
  punctuation: "#7A8294",
  function: "#1E7A87",
  type: "#3557B7",
  variable: "#2B2F3A",
  parameter: "#4A5568",
  property: "#52608F",
  tag: "#AD3B3B",
  attribute: "#8F6A10",
  namespace: "#5C6474",
  markupHeading: "#8A5D14",
  markupLink: "#1E7A87",
  markupCode: "#4E7D45",
  markupCodeBg: "#F1EDE3",
  markupQuote: "#5D6474",
  markupList: "#55617A",
  foreground: "#2B2F3A",
  background: "#FAF7F0",
  added: "#2E7D46",
  deleted: "#B3362E",
};

function buildTheme(name: string, type: "dark" | "light", t: RafuSyntaxTokens): ThemeRegistration {
  return {
    name,
    type,
    colors: {
      "editor.background": t.background,
      "editor.foreground": t.foreground,
    },
    settings: [
      { scope: ["comment", "punctuation.definition.comment", "string.comment"], settings: { foreground: t.comment, fontStyle: "italic" } },
      { scope: ["comment.documentation", "comment.block.documentation"], settings: { foreground: t.docComment, fontStyle: "italic" } },
      { scope: ["string", "string.quoted", "string.template", "punctuation.definition.string"], settings: { foreground: t.string } },
      { scope: ["constant.character.escape", "string.interpolated", "punctuation.definition.template-expression"], settings: { foreground: t.escape } },
      { scope: ["constant.numeric", "keyword.other.unit"], settings: { foreground: t.number } },
      { scope: ["constant.language", "support.constant", "variable.other.constant", "constant.other"], settings: { foreground: t.constant } },
      { scope: ["keyword", "storage.type", "storage.modifier", "keyword.control", "keyword.operator.new", "punctuation.definition.keyword"], settings: { foreground: t.keyword } },
      { scope: ["keyword.operator", "keyword.operator.expression"], settings: { foreground: t.operator } },
      { scope: ["punctuation", "punctuation.separator", "punctuation.terminator", "punctuation.accessor"], settings: { foreground: t.punctuation } },
      { scope: ["entity.name.function", "support.function", "meta.function-call", "variable.function", "entity.name.command"], settings: { foreground: t.function } },
      { scope: ["entity.name.type", "support.type", "storage.type.cs", "entity.name.class", "entity.name.struct", "entity.name.enum", "entity.other.inherited-class", "markup.raw"], settings: { foreground: t.type } },
      { scope: ["variable", "variable.other", "variable.other.readwrite", "meta.definition.variable"], settings: { foreground: t.variable } },
      { scope: ["variable.parameter", "meta.parameters", "entity.name.variable.parameter"], settings: { foreground: t.parameter } },
      { scope: ["variable.other.property", "variable.other.object.property", "support.variable.property", "meta.object-literal.key", "entity.name.tag.yaml", "support.type.property-name", "variable.other.member"], settings: { foreground: t.property } },
      { scope: ["entity.name.tag", "punctuation.definition.tag"], settings: { foreground: t.tag } },
      { scope: ["entity.other.attribute-name", "entity.name.function.decorator", "meta.attribute"], settings: { foreground: t.attribute } },
      { scope: ["entity.name.namespace", "entity.name.module", "support.namespace", "entity.name.package"], settings: { foreground: t.namespace } },
      { scope: ["markup.heading", "entity.name.section", "markup.heading.setext"], settings: { foreground: t.markupHeading, fontStyle: "bold" } },
      { scope: ["markup.underline.link", "string.other.link", "meta.link"], settings: { foreground: t.markupLink, fontStyle: "underline" } },
      { scope: ["markup.raw.inline", "markup.inline.raw", "markup.fenced_code", "markup.raw.block"], settings: { foreground: t.markupCode } },
      { scope: ["markup.quote"], settings: { foreground: t.markupQuote, fontStyle: "italic" } },
      { scope: ["markup.list", "beginning.punctuation.definition.list"], settings: { foreground: t.markupList } },
      { scope: ["markup.bold"], settings: { fontStyle: "bold" } },
      { scope: ["markup.italic"], settings: { fontStyle: "italic" } },
      { scope: ["markup.strikethrough"], settings: { fontStyle: "strikethrough" } },
      { scope: ["markup.inserted", "markup.inserted.diff"], settings: { foreground: t.added } },
      { scope: ["markup.deleted", "markup.deleted.diff"], settings: { foreground: t.deleted } },
      { scope: ["markup.changed"], settings: { foreground: t.attribute } },
      { scope: ["invalid", "invalid.illegal"], settings: { foreground: t.deleted } },
    ],
  };
}

export const rafuIndigoTheme = buildTheme("rafu-indigo", "dark", indigo);
export const rafuKhadiTheme = buildTheme("rafu-khadi", "light", khadi);
