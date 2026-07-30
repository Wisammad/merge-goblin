# counts.jq — the severity summary line, e.g. "🔴 1 blocker · 🟠 2 convention".
#
# NB: the helper is NOT called `label` — that is a reserved keyword in jq
# (`label $out | ... break $out`) and defining it is a syntax error.

def sevicon($k):
  { blocker: "🔴", convention: "🟠", risk: "🟡", question: "🔵", nit: "⚪" }[$k] // "•";

[ .findings[]?.severity ] as $s
| [ "blocker", "convention", "risk", "question", "nit" ]
| map( . as $k
       | ($s | map(select(. == $k)) | length) as $n
       | if $n > 0 then "\(sevicon($k)) \($n) \($k)" else empty end )
| if length == 0 then "no findings" else join(" · ") end
