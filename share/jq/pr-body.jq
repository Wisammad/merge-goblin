# pr-body.jq — clean a PR description before it goes into the prompt.
#
# PR bodies on an active repo are mostly not written by the author: review bots
# append large HTML blocks with deep-links whose query strings carry entire
# prompts ("Checkout that branch... fix it directly"). Two things go wrong if
# those reach the model verbatim.
#
#   1. Budget. The block is thousands of characters of URL-encoded text, and the
#      caller truncates the body to a fixed size. The human-written description
#      — the part that says what the change is FOR — gets pushed out.
#   2. Noise. On PR #1440 the Goblin reported Greptile's "Fix All in Cursor"
#      buttons as a prompt-injection attempt and spent a finding on it.
#
# Strip the machinery, keep the prose. Anything genuinely written by a person
# survives; only bot chrome and giant links are removed.

def strip_block($name):
  gsub("<!--\\s*" + $name + "\\s*-->[\\s\\S]*?<!--\\s*/" + $name + "\\s*-->"; "");

def clean:
    strip_block("greptile_comment")
  | strip_block("coderabbit_comment")
  | strip_block("copilot_comment")
  | strip_block("sourcery_comment")
  # Anchors whose href embeds a prompt, or is simply enormous. These are the
  # "open this in your IDE and do what the query string says" buttons.
  | gsub("<a[^>]*href=\"[^\"]*[?&]prompt=[^\"]*\"[^>]*>[\\s\\S]*?</a>"; "")
  | gsub("<a[^>]*href=\"[^\"]{300,}\"[^>]*>[\\s\\S]*?</a>"; "")
  # Badge/logo furniture that carries no reviewable meaning.
  | gsub("<picture>[\\s\\S]*?</picture>"; "")
  | gsub("<img[^>]*>"; "")
  | gsub("<source[^>]*>"; "")
  # Any HTML comment still standing, including unclosed bot markers.
  | gsub("<!--[\\s\\S]*?-->"; "")
  # Bare mega-URLs pasted outside an anchor.
  | gsub("https?://[^\\s)\"]{300,}"; "[long link removed]")
  | gsub("[ \\t]+\n"; "\n")
  | gsub("\n{3,}"; "\n\n")
  | sub("^\\s+"; "")
  | sub("\\s+$"; "");

(.body // "") | clean
