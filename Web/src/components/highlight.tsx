import { useMemo, type CSSProperties } from "react";
import { tokenize, type Language } from "../lib/highlight";

export function Code({
  children,
  language,
  style
}: {
  children: string;
  language: Language;
  style?: CSSProperties;
}) {
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
