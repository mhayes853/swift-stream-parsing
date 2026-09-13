/** A class list from the names that apply: `cx("lane", on && "on", dim && "dim")`. */
export function cx(...names: (string | false | null | undefined)[]): string {
  return names.filter(Boolean).join(" ");
}
