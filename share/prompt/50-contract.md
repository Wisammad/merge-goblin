## Output contract

Return **one JSON object and nothing else** — no prose before or after, no markdown
fence around it.

```
{
  "schema_version": 1,
  "summary": "2-5 sentences on what the PR does and your overall read.",
  "suggested_verdict": "approve" | "comment" | "request_changes",
  "findings": [
    {
      "path": "relative/path/from/repo/root.ts",
      "line": 42,
      "start_line": 40,
      "side": "RIGHT",
      "severity": "blocker" | "convention" | "risk" | "nit" | "question",
      "title": "short imperative summary",
      "body": "what is wrong and what to do instead. markdown.",
      "suggestion": "optional replacement code for exactly those lines"
    }
  ],
  "intent_note": {
    "issue": "TICKET-123",
    "verdict": "fulfils" | "partial" | "diverges" | "unknown" | "no_ticket",
    "body": "what the issue asked / what the PR does / gaps"
  }
}
```

**Line anchoring — this matters.** `path` and `line` must point at a line that appears
in the diff below:

- `side: "RIGHT"` (default) → a line that is **added (`+`) or unchanged context**.
  `line` is its line number in the **new** file.
- `side: "LEFT"` → a line that is **removed (`-`)**. `line` is its number in the **old** file.
- For a multi-line finding set `start_line` (first line) and `line` (last line).
- The diff below is annotated with real line numbers — use them exactly.
- A finding whose line is not in the diff is still valuable: include it with the correct
  `path` and omit `line`. It will be reported in the summary instead of inline.

**Severity**

| value | use for |
|---|---|
| `blocker` | a bug/regression, or something the repo's rules say to block on |
| `convention` | violates a required repo standard listed above |
| `risk` | plausible problem you could not fully verify |
| `nit` | minor; only if it breaks a required standard |
| `question` | genuinely needs the author to answer |

**`suggestion`** must be the exact replacement text for the commented line range —
omit it unless it applies cleanly on its own.

**`intent_note`** answers "does this PR do what its ticket asked?" Use the ticket
context provided above if present; if there is no linked ticket, set
`verdict: "no_ticket"` and leave `body` empty.
