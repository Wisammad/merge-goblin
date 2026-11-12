# prior-findings.jq — the Goblin's findings already posted on a pull request, and which
# of them the people on the PR declined. Ported from upstream Merge Goblin, without its
# marker-author filter: a marker counts whoever posted it.
#
# Input: EVERY review comment on the PR, as one array (all pages merged).
# Named args (read through $ARGS so the file compiles on its own):
#   ns        marker namespace ("goblin"); legacy: the pre-rename one ("bob")
#   resolved  REST ids of the first comment of every RESOLVED review thread
#
# Output: [{…marker fields (id, severity, …), commentId, path, line, title,
#           declined, declinedBy, declinedHow, fixedReplied}]
# fixedReplied: the thread was already told "no longer flagged"; never say it twice.
#
# DECLINED — a heuristic, kept small and readable on purpose:
#   * the thread is resolved, or
#   * the LAST reply in the thread that takes a side says one of the phrases below
#     ("intentional", "won't fix", "by design", "not a bug", "false positive", …), and
#     does not also say something that means the opposite ("not intentional",
#     "not a false positive", "good catch", "will fix", "fixed", "you're right").
#     A question ("is this intentional?") takes no side.
# Replies that carry one of our markers, our own "no longer flagged" note, and replies
# from bots are never read as a decline.

($ARGS.named.ns // "goblin") as $ns
| ($ARGS.named.legacy // "bob") as $legacy
| ($ARGS.named.resolved // []) as $resolved
| def norm: gsub("[‘’ʼ]"; "'") | ascii_downcase;
  def decline_re: "\\b(intentional(ly)?|intended|by design|won'?t fix|wont ?fix|will not fix|(not|isn'?t|wasn'?t) (a bug|an issue)|false positive|deliberate(ly)?|working as intended|expected behaviou?r|won'?t change|wont change|as designed)\\b";
  def accept_re: "\\b(not|isn'?t|wasn'?t|un) ?(intentional|intended|deliberate|by design)|\\b(not|isn'?t) (a )?false positive\\b|\\b(good|nice|great) catch\\b|\\bwill fix\\b|\\bi'?ll fix\\b|\\bfixed\\b|\\bfixing\\b|\\byou'?re right\\b";
  # A question ("is this intentional?") decides nothing.
  def decides: norm | (test(decline_re) or test(accept_re)) and (test("\\?\\s*$") | not);
  def declines: norm | test(decline_re) and (test(accept_re) | not);
  def phrase: norm | (match(decline_re).string);
  def ours: test("<!-- (" + $ns + "|" + $legacy + "):");
  def botlike: (((.user.type // "") | ascii_downcase) == "bot") or ((.user.login // "") | test("\\[bot\\]$"));
. as $all
| [ $all[] | select(.in_reply_to_id != null) ] as $replies
| [ $all[]
    | . as $c
    | select(.body != null)
    | (.body | capture("<!-- (?<ns>" + $ns + "|" + $legacy + "):finding (?<j>\\{.*?\\}) -->") // empty) as $mk
    | (try ($mk.j | fromjson) catch empty) as $pf
    | select(($pf | type) == "object")
    | ( [ $replies[]
          | select(.in_reply_to_id == $c.id)
          | select(botlike | not)
          | select(((.body // "") | ours) | not)
          | select(((.body // "") | test("no longer flagged as of")) | not)
          | select((.body // "") | decides) ] | sort_by(.id) | last
      | if . != null and (.body | declines) then . else null end ) as $d
    | any($replies[]; .in_reply_to_id == $c.id
          and ((.body // "") | test("no longer flagged as of"))) as $fx
    | $pf
      + { fixedReplied: $fx }
      + { commentId: $c.id, path: $c.path, line: ($c.line // $c.original_line),
          title: ((($c.body | capture("\\*\\*(?<t>[^*\\n]{1,200})\\*\\*")) | .t) // "") }
      + ( if $d != null then
            { declined: true, declinedBy: ($d.user.login // ""),
              declinedHow: ("replied “" + ($d.body | phrase) + "”") }
          elif ($resolved | index($c.id)) != null then
            { declined: true, declinedBy: "", declinedHow: "resolved the thread" }
          else { declined: false } end ) ]
