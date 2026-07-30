# validate.jq — bash has no JSON-Schema validator, so jq is the real gate.
# Rejects wrong VALUES; tolerates missing optional keys (normalize.jq fills them),
# which keeps schemaless providers (cursor) usable.
# Usage: jq -e -f validate.jq findings.json >/dev/null
#
# It gates STRUCTURE and the fields that actually decide what gets posted
# (finding severity, non-empty body). It does NOT gate the advisory verdict
# vocabulary: `suggested_verdict` and `intent_note.verdict` are coerced to the
# canonical set in normalize.jq, so rejecting a synonym here would only burn a
# retry and can fail an otherwise-good review (Grok 4.5 says "matches", not
# "fulfils"). The renderer already falls back gracefully on an unknown verdict.

def bad($m): ("VALIDATE: " + $m) | halt_error(3);

if type != "object" then bad("root is not an object") else . end
| if (.schema_version // 1) != 1 then bad("unsupported schema_version \(.schema_version)") else . end
| if (.summary | type) != "string" then bad("summary is not a string") else . end
| if (.findings | type) != "array" then bad("findings is not an array") else . end
| if (.suggested_verdict != null) and ((.suggested_verdict | type) != "string")
  then bad("suggested_verdict is not a string") else . end
| if (.intent_note != null) and ((.intent_note | type) != "object")
  then bad("intent_note is neither object nor null") else . end
# Collected into an array on purpose: `.findings[] | ... as $_` yields NOTHING
# when findings is empty, so `jq -e` would exit non-zero and reject a perfectly
# valid clean review. An array comprehension always produces exactly one value.
| ( [ .findings[]
    | if (.severity | IN("blocker","convention","risk","nit","question")) | not
        then bad("finding.severity=\(.severity)") else . end
    | if (.body | type) != "string" or ((.body | length) == 0)
        then bad("finding.body is empty") else . end
    | if (.title != null) and ((.title | type) != "string")
        then bad("finding.title is not a string") else . end
    | if (.path != null) and ((.path | type) != "string")
        then bad("finding.path is not a string") else . end
    | if (.line != null) and ((.line | type) != "number")
        then bad("finding.line is not a number") else . end
    | if (.start_line != null) and ((.start_line | type) != "number")
        then bad("finding.start_line is not a number") else . end
  ] ) as $_
| .
