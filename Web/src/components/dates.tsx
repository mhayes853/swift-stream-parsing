import { commitURL, stamp, wasRewritten } from "../lib/dates";
import type { DocHistory } from "../types";

/** One line of provenance: when the section was written, and whether it was rewritten afterwards. */
export function Recorded({ history }: { history?: DocHistory }) {
  if (!history) return null;
  return (
    <span className="dated">
      <time dateTime={history.recorded} title={`${history.recordedSubject} (${history.recordedCommit})`}>
        {stamp(history.recorded)}
      </time>
      {wasRewritten(history) && (
        <>
          <span className="dated-sep">·</span>
          <span
            className="dated-revised"
            title={`Last rewritten by: ${history.revisedSubject} (${history.revisedCommit})`}
          >
            revised {history.revisions - 1}× through {stamp(history.revised, false)}
          </span>
        </>
      )}
    </span>
  );
}

/** The same, with the commits as links. Used where there is room for them. */
export function RecordedDetail({ history }: { history?: DocHistory }) {
  if (!history) return null;
  return (
    <span className="dated">
      Recorded <time dateTime={history.recorded}>{stamp(history.recorded)}</time> in{" "}
      <CommitLink sha={history.recordedCommit} subject={history.recordedSubject} />
      {wasRewritten(history) ? (
        <>
          {", rewritten "}
          {history.revisions - 1}× since, last on{" "}
          <time dateTime={history.revised}>{stamp(history.revised)}</time> in{" "}
          <CommitLink sha={history.revisedCommit} subject={history.revisedSubject} />
        </>
      ) : (
        ", and not rewritten since"
      )}
      .
    </span>
  );
}

function CommitLink({ sha, subject }: { sha: string; subject: string }) {
  return (
    <a href={commitURL(sha)} target="_blank" rel="noreferrer" title={subject}>
      <code>{sha.slice(0, 7)}</code>
    </a>
  );
}
