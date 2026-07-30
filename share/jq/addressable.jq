# addressable.jq — every (path, side, line) a review comment can legally anchor to.
# Input: the /pulls/{n}/files payload as an array.
#
# GitHub rejects the ENTIRE grouped review if one comment points at a line that
# isn't in the diff, so this set is what stands between us and losing a review.
#   RIGHT = added (+) and context lines, numbered in the NEW file
#   LEFT  = removed (-) and context lines, numbered in the OLD file

[ .[]
  | select(.patch != null)
  | .filename as $p
  | ( .patch | split("\n")
      | reduce .[] as $l ({r:0, l:0, out:[]};
          if ($l | startswith("@@")) then
            ( $l | capture("^@@ -(?<ls>[0-9]+)(,[0-9]+)? \\+(?<rs>[0-9]+)(,[0-9]+)? @@") ) as $h
            | .l = ($h.ls | tonumber) | .r = ($h.rs | tonumber)
          elif ($l | startswith("\\")) then .
          elif ($l | startswith("+")) then .out += [{p:$p, s:"RIGHT", n:.r}] | .r += 1
          elif ($l | startswith("-")) then .out += [{p:$p, s:"LEFT",  n:.l}] | .l += 1
          else .out += [{p:$p, s:"RIGHT", n:.r}, {p:$p, s:"LEFT", n:.l}] | .r += 1 | .l += 1
          end)
      | .out )
]
| flatten
| map("\(.p) \(.s) \(.n)")
| unique
