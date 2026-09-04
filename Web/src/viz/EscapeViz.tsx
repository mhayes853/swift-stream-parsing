import type { EscapeTrace } from "../types";
import { glyph, hex, VerifiedNote } from "./common";

/**
 * `streamSimpleEscapeTable` — the smallest lookup in the parser, and the one whose *sentinel* is
 * the interesting part.
 *
 * A direct 128-byte map from the character after the backslash to the byte it decodes to. Zero
 * means "not a simple escape", and that costs nothing extra because no valid simple escape decodes
 * to NUL — so one table answers both "is this legal" and "what is it".
 */
export function EscapeViz({ trace }: { trace: EscapeTrace }) {
  return (
    <div className="viz">
      <p className="viz-caption" style={{ marginTop: 0 }}>
        One load, indexed by the byte after the backslash. There is no branch ladder over the eight
        legal escapes and no separate validity table.
      </p>

      <table className="escape-table">
        <thead>
          <tr>
            <th>source</th>
            <th>index</th>
            <th>entry</th>
            <th>decodes to</th>
            <th />
          </tr>
        </thead>
        <tbody>
          {trace.entries.map((entry) => (
            <tr key={entry.byte} className={entry.decoded === undefined ? "miss" : ""}>
              <td>
                <code>{entry.source}</code>
              </td>
              <td className="mono">0x{hex(entry.byte)}</td>
              <td className="mono">
                {entry.decoded === undefined ? (
                  <span className="sentinel">00</span>
                ) : (
                  hex(entry.decoded)
                )}
              </td>
              <td className="mono">
                {entry.decoded === undefined ? "—" : glyph(entry.decoded)}
              </td>
              <td className="meaning">{entry.meaning}</td>
            </tr>
          ))}
        </tbody>
      </table>

      <p className="viz-note">
        The table is a <code>StaticString</code>, so the 128 bytes live in read-only storage rather
        than being built into an <code>Array</code> at startup — which matters to the parser's
        one-allocation fast path and to Embedded Swift, where there may be no allocator at all. The
        decoded bytes go straight into the destination; no intermediate string is built, and
        <code> \u</code> is handled before the table is consulted because four more bytes cannot be
        represented by a one-byte result.
      </p>
      <VerifiedNote verified={trace.verified} />
    </div>
  );
}
