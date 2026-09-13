import { useMemo, type CSSProperties } from "react";
import { tokenize, type Language } from "../lib/highlight";

/**
 * A highlighted block. The tokenizers are in `lib/highlight.ts`; a `text` block draws as one plain
 * run with no classes.
 */
export function Code({
  children,
  language,
  style
}: {
  children: string;
  language: Language;
  style?: CSSProperties;
}) {
  // Memoised on the text: an assembly listing is six hundred lines and the panel re-renders on
  // every tab change.
  const tokens = useMemo(() => tokenize(children, language), [children, language]);
  return (
    <pre style={style}>
      <code className={`hl hl-${language}`}>
        {tokens.map((token, i) =>
          token.cls === "plain" ? (
            token.text
          ) : (
            <span key={i} className={`t-${token.cls}`}>
              {token.text}
            </span>
          )
        )}
      </code>
    </pre>
  );
}
