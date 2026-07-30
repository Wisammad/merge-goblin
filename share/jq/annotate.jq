# annotate.jq — render the PR diff with real line numbers on every line, so the
# model can anchor findings exactly instead of guessing positions.
# Input: the /pulls/{n}/files payload as an array.

def pad($n): ($n | tostring) | (" " * (5 - length)) + .;

[ .[]
  | select(.patch != null)
  | "--- FILE: \(.filename)  (+\(.additions) −\(.deletions)) ---\n" +
    ( .patch | split("\n")
      | reduce .[] as $l ({r:0, l:0, out:[]};
          if ($l | startswith("@@")) then
            ( $l | capture("^@@ -(?<ls>[0-9]+)(,[0-9]+)? \\+(?<rs>[0-9]+)(,[0-9]+)? @@") ) as $h
            | .l = ($h.ls | tonumber) | .r = ($h.rs | tonumber)
            | .out += ["            " + $l]
          elif ($l | startswith("\\")) then .out += ["            " + $l]
          elif ($l | startswith("+")) then
            .out += ["RIGHT \(pad(.r)) \($l)"] | .r += 1
          elif ($l | startswith("-")) then
            .out += ["LEFT  \(pad(.l)) \($l)"] | .l += 1
          else
            .out += ["RIGHT \(pad(.r)) \($l)"] | .r += 1 | .l += 1
          end)
      | .out | join("\n") )
]
| join("\n\n")
