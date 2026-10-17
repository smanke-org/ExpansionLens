# ExpansionLens feature map

This document lists what ExpansionLens does and how. It describes behavior, not anyone else's code. Snippet text uses the common `%`-macro syntax, so libraries written for other expanders import unchanged.

## Library

- **Groups** hold snippets. Each group has:
  - a name and notes
  - an optional **prefix** that is added before every abbreviation in the group
  - an **Expand After** override (whitespace / non-alphanumeric / any character)
  - an **app scope** (all apps, all except…, only…)
  - an enabled switch
- **Snippets** have:
  - an abbreviation and a label
  - a content type (plain text, formatted text, AppleScript, shell script, JavaScript)
  - a **case mode** (case-sensitive, ignore case, adapt to the case typed)
  - the content itself
  - created, modified and last-used dates, and a use count
- **Conflicts** are flagged when two abbreviations are the same, or one is a prefix of, begins, contains or occurs within another.
- **Sorting** is by label, abbreviation, content, date modified or uses, ascending or descending. Search covers labels, abbreviations and content.
- **Actions:** move or copy snippets between groups, duplicate, new snippet from clipboard, edit last expanded.

## Expansion engine

1. A key-down event tap (needs Accessibility) keeps a rolling buffer of the characters typed.
   - The buffer resets on clicks, arrow keys, Command/Control chords and app switches.
   - Delete removes the last character from the buffer.
   - While Secure Input is on, typing is ignored. The menu shows "Expansion Blocked (App)".
2. **Expand modes:** immediately when typed, at a delimiter keeping it, or at a delimiter abandoning it. The delimiter keys can be edited.
3. **Expand After** controls what may come before the abbreviation: whitespace, any non-alphanumeric character, or any character.
4. **Matching:** the longest matching abbreviation wins. The match respects the snippet's case mode. Adapt-to-case turns `Sig` into "Cheers…" and `SIG` into "CHEERS…".
5. **Replacement:** the app sends Delete presses for the abbreviation (and for the delimiter, if it is abandoned), then inserts the text.
   - Insertion pastes the content (string, RTF or HTML), restores the clipboard after a delay you can set, and positions the cursor with arrow keys (`%|`) or selects text (`%|…%\`).
   - Key macros post real keys.
6. **Other expansion options:** sound on expansion, a per-group app scope, and a global app exception list.
7. **Auto-capitalization (optional):** capitalize new sentences and fix DOuble CApitals, with app exceptions and extra contraction characters.

## Macro language

| Macro | Meaning |
|---|---|
| `%|` | Put the cursor here |
| `%\` | Select from the cursor mark to here |
| `%%` | A literal % |
| `%clipboard` / `%pasteboard` | Plain-text clipboard |
| `%snippet:abbr%` | Nested snippet (cycles are an error) |
| `%key:enter%` `%key:return%` `%key:tab%` `%key:esc%` | Press a key |
| `%<` `%>` `%^` `%v` | Arrow keys |
| `%delay:ms%` | Pause |
| `%Y %y %B %b %m %1m %d %e %A %a %j` | Year, month and day parts |
| `%H %1H %I %1I %M %1M %S %1S %p %z %Z` | Time parts |
| `%date:FORMAT%` | Unicode date pattern |
| `%@+1D` `%@-2M` … (Y M D h m s) | Date math; applies to the date macros that follow |
| `%filltext:name=x:default=y:width=n%` | Single-line field |
| `%fillarea:name=x:default=y:width=n:height=n%` | Multi-line field |
| `%fillpopup:name=x:default=a:b:c%` | Popup menu (`default=` marks the default choice) |
| `%filldatepicker:name=x:format=f%` | Date picker |
| `%fillpart:name=x:default=yes%…%fillpartend%` | Optional section |
| `%fillconditional:…%…%fillbranch:…%…%fillbranchend%…%fillconditionalend%` | Conditional section with branches |
| `%filltop%` | Show the fill-in window at the top of the screen |

Fields with the same name share one value. The fill-in window previews the result live and has Cancel and OK buttons (OK is the Return key).

## Scripts

- **AppleScript** runs through NSAppleScript. **Shell** runs with `/bin/sh -c` and `#!` lines are honored. **JavaScript** runs in JavaScriptCore, and the last expression's value is the result.
- Before a script runs, its `%` macros are expanded, so `%snippet:lib%` pulls in shared code.
- Scripts are off until you allow them. There is a timeout you can set.

## Search & hotkeys

- **Quick Search:** a floating panel opened by a hotkey. Type to filter, press Return to insert into the app you were using.
- **Hotkeys:** enable/disable expansion, open the main window, new snippet, new snippet from clipboard, edit last expanded, quick search.

## Suggestions

- Optionally, the app counts phrases you type (5+ words, typed 3+ times). Counts are only kept in memory and in a hashed digest.
- Suggestions appear in the sidebar's Suggested section, where you can create a snippet from one, ignore it, or never suggest it again.
- "Tutor" option: tells you the abbreviation when you type out a snippet's whole content by hand.

## Import

- **Libraries from other apps on this Mac:** reads local WebKit IndexedDB snippet stores (event-log format), copied read-only first.
- **Files:** CSV (abbreviation, content, label) and property-list snippet group files.

## Sync

- CloudKit private database, zone "ExpansionLens", with every record sealed under a key that is wrapped by your sync passphrase (AES-256-GCM), the same design as the other Lens apps.
- **Records:** Keyring, Settings, Device_<id>, Group_<id>, Snippet_<id>.

## Coexistence with PasteLens

- If PasteLens's abbreviation expansion is on, ExpansionLens posts a notification with a button that asks PasteLens to turn it off.
- PasteLens (1.1.1+) posts the matching notification when ExpansionLens is running.
