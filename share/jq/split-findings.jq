# split-findings.jq — partition findings into those GitHub will accept as inline
# comments and those it won't.
#   --slurpfile ok addressable.json
#
# Unanchorable findings are DEMOTED into the review body, never dropped: a real
# problem on a line outside the diff is still worth telling the author about.
#
# Note the `. as $f` binding: inside `$set | index(...)` the input becomes $set,
# so the finding's own fields must be captured before that pipe.

($ok[0]) as $set
| def has_anchor($p; $s; $l):
    ($p != null) and ($l != null) and (($set | index("\($p) \($s) \($l)")) != null);

  .findings
  | map(
      . as $f
      | ($f.side // "RIGHT") as $side
      | ($f.start_side // $side) as $sside
      | . + { _ok: (
            has_anchor($f.path; $side; $f.line)
            and (($f.start_line == null) or has_anchor($f.path; $sside; $f.start_line))
        )}
    )
  | { inline:  [ .[] | select(._ok)       | del(._ok) ],
      demoted: [ .[] | select(._ok | not) | del(._ok) ] }
