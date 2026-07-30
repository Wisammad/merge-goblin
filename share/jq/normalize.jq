# normalize.jq — fill defaults, assign stable ids, dedupe, sort by severity, cap.
#   --argjson max <n>   maximum findings to keep
#
# The finding id deliberately EXCLUDES the line number: sha256(path + title) so a
# finding that merely shifts lines on a rebase is still recognised as one we
# already posted.

def sevrank:
  { "blocker": 0, "convention": 1, "risk": 2, "question": 3, "nit": 4 }[.] // 9;

# The two verdict fields are ADVISORY (a header hint and a secondary "does it do
# what the ticket asked" note), and different models phrase them differently:
# Grok 4.5 says "matches" where the contract says "fulfils". Coerce to the
# canonical vocabulary here rather than letting validate.jq hard-fail the whole
# review over one synonym — a rejected review costs a second model call and can
# fail outright. Negatives are tested before positives so "not fulfilled" reads
# as diverges, not fulfils.
def canon_intent:
  (. // "unknown" | ascii_downcase) as $v
  | if   ($v | test("no.?ticket|none|n/?a"))                 then "no_ticket"
    elif ($v | test("diverg|deviat|mismatch|unmet|\\bnot\\b|\\bno\\b|does ?not|fail")) then "diverges"
    elif ($v | test("partial|incomplete|mostly"))            then "partial"
    elif ($v | test("fulfil|match|satisf|\\byes\\b|\\bmet\\b|complete|deliver")) then "fulfils"
    else "unknown" end;
def canon_suggested:
  (. // "comment" | ascii_downcase) as $s
  | if   ($s | test("approv"))               then "approve"
    elif ($s | test("request|change|block")) then "request_changes"
    else "comment" end;

{
  schema_version: 1,
  summary: (.summary // ""),
  suggested_verdict: (.suggested_verdict | canon_suggested),
  intent_note: (
    if (.intent_note | type) == "object" then
      { issue:   (.intent_note.issue // ""),
        verdict: (.intent_note.verdict | canon_intent),
        body:    (.intent_note.body // "") }
    else null end
  ),
  findings: (
    [ .findings[]?
      | select((.body // "") != "")
      | {
          path:       (.path // null),
          line:       (if (.line | type) == "number" and .line > 0 then (.line | floor) else null end),
          start_line: (if (.start_line | type) == "number" and .start_line > 0 then (.start_line | floor) else null end),
          side:       (if (.side // "RIGHT") == "LEFT" then "LEFT" else "RIGHT" end),
          start_side: (if (.start_side // null) == "LEFT" then "LEFT" else null end),
          severity:   (.severity // "risk"),
          title:      ((.title // (.body | split("\n")[0])) | .[0:120]),
          body:       (.body | ltrimstr("\n") | rtrimstr("\n")),
          suggestion: (if (.suggestion // "") == "" then null else .suggestion end)
        }
      # a range whose start is after its end is nonsense — drop the range, keep the finding
      | if (.start_line != null and .line != null and .start_line >= .line)
        then .start_line = null | .start_side = null else . end
      | if (.start_line != null and .start_side == null) then .start_side = .side else . end
      # idRaw is hashed into the short, stable `id` by findings.sh (jq has no
      # hash function; base64-truncation would only reflect the prefix).
      | . + { idRaw: ((.path // "repo") + "\n" + (.title | ascii_downcase)) }
    ]
    | unique_by(.idRaw)
    | sort_by([ (.severity | sevrank), (.path // ""), (.line // 0) ])
    | .[0:$max]
  )
}
