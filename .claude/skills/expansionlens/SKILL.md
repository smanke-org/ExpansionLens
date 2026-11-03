---
name: expansionlens
description: Drive ExpansionLens, the text expander on this Mac, from the shell with the `expansionlens` command: list, search, add, change and delete snippets (abbreviations that expand into text) and their groups, see what a snippet expands to, import and export snippets, and turn expansion on or off. Use when the user asks about their snippets or abbreviations, wants one added, changed or found, or names ExpansionLens.
---

# ExpansionLens

`expansionlens` runs commands in the ExpansionLens app. Changes show in its library window at once.
If the app is closed, the command opens it in the background. If `expansionlens` isn't on PATH, use
`/Applications/ExpansionLens.app/Contents/MacOS/ExpansionLens` the same way.

## Rules

- Always add `--json` and read the JSON. Exit 0 is ok; otherwise read `error.code` and
  `error.message`, and do what the message says.
- Name a snippet by its abbreviation as typed (`";addr"`, group prefix included) or by its id from
  `expansionlens snippets list`. Groups go by name or id. Quote abbreviations: `;` ends a shell command.
- `snippets delete` and `groups delete` only report what they would delete. Show the user that
  report and ask before you run it again with `--yes`: it can't be undone and removes it on every
  synced Mac. A group goes with all its snippets.
- `snippets expand` returns the text only; nothing is typed. Script snippets never run from here.
- Content uses % placeholders (`%Y`, `%clipboard`, `%filltext:name=Name%`); write `%%` for a percent sign.
  Formatted text snippets are edited in the window (`expansionlens open --snippet <id>`).
- Paths may be relative in the shell; over MCP they must be absolute.
- To try something without real data, run a Debug build with `APP_STORE=/tmp/expansionlens-test` in front.

## Main commands

| Command | Does |
| --- | --- |
| `expansionlens status --json` | Version, expansion on and running, counts, sync, PasteLens overlap |
| `expansionlens snippets list [--search T] [--group G] [--conflicts] [--limit N] --json` | Find snippets |
| `expansionlens snippets show <snippet> --json` / `snippets expand <snippet> [--fields '{"Name":"Alex"}'] --json` | Full content / what it expands to |
| `expansionlens snippets add --abbreviation A --content T [--label L] [--group G] --json` | Add one |
| `expansionlens snippets update <snippet> [--abbreviation A] [--content T] [--label L] [--group G] --json` | Change one |
| `expansionlens groups list --json` / `groups update <group> --enabled false --json` | Groups, and turning one off |

Everything else: `expansionlens help`, and `expansionlens help <command>` for its options.
