# ExpansionLens

**A free text expander for the Mac.** Type a short abbreviation such as `;sig` anywhere, and ExpansionLens replaces it with the text you saved: an address, a signature, a reply you write every day. Snippets can ask for details as they expand, insert today's date, run scripts, and sync to your other Macs, end-to-end encrypted.

There's no subscription, no account and no snippet limit.

## Download

### ⬇️ [Download ExpansionLens.dmg](https://github.com/smanke-org/ExpansionLens/releases/latest/download/ExpansionLens.dmg)

1. Open the DMG.
2. Drag **ExpansionLens** to **Applications**.
3. Open ExpansionLens. When asked, allow **Accessibility** so it can notice abbreviations and put snippets in their place.

Requires macOS 26 or later.

## What it does

- **Abbreviations everywhere**: type an abbreviation in any app and it expands. You choose whether to expand immediately or at a delimiter (Space, Return, punctuation), whether to keep that delimiter, and what may come before an abbreviation.
- **Groups**: organize snippets in groups, each with an optional prefix (`;` + `sig` means you type `;sig`), its own Expand After rule, and the apps it works in (all, all except…, or only…).
- **Case**: per snippet or as a default: case-sensitive, ignore case, or adapt to case (`Sig` capitalizes the first letter, `SIG` the whole snippet).
- **Fill-ins**: a snippet can ask for text, a longer note, a choice from a menu or a date as it expands, with a live preview. Optional sections can be included or left out, and conditional sections pick one of several versions. Fields with the same name share a value.
- **Dates and times**: any date or time part, Unicode date patterns, and date math (`%@+1D` for tomorrow).
- **Cursor, keys and pauses**: put the cursor anywhere in the expanded text or select part of it, press Tab, Return or arrow keys, and pause between steps.
- **Nested snippets**: include one snippet in another with `%snippet:abbr%`.
- **Scripts**: AppleScript, shell and JavaScript snippets insert what the script returns. Macros expand inside scripts first, so shared script libraries work. Scripts are off until you turn them on.
- **Formatted text**: snippets can keep fonts, colors and styles.
- **Quick Search (⌃⌥Space)**: find any snippet by abbreviation, label or content and insert it without remembering the abbreviation.
- **Suggestions**: optionally, ExpansionLens notices sentences you type again and again and offers them as snippets. It keeps only counts until a sentence comes up three times. It can also tell you the abbreviation when you type out a snippet by hand.
- **Auto-capitalization**: optionally capitalizes the first word of a sentence and fixes DOuble CApitals.
- **Conflicts**: abbreviations that clash or hide each other are listed so you can fix them.
- **Import**: brings in snippet libraries from other snippet apps on this Mac, CSV files (abbreviation, content, label) and snippet group property lists. Export saves a JSON backup.
- **PasteLens**: if PasteLens's own abbreviation expansion is on, ExpansionLens offers to turn it off so nothing expands twice.

## Snippet macros

| Macro | What it inserts |
|---|---|
| `%clipboard` | The clipboard's text |
| `%|` and `%\` | Where the cursor goes, and the end of a selection |
| `%Y %y %B %b %m %1m %d %e %A %a %j` | Date parts |
| `%H %1H %I %1I %M %S %p %Z` | Time parts |
| `%date:yyyy-MM-dd%` | A Unicode date pattern |
| `%@+1D` `%@-2m` | Date math for the date parts after it (Y m D h M s) |
| `%filltext:name=Name:default=Sam%` | A single-line field |
| `%fillarea:name=Notes%` | A multi-line field |
| `%fillpopup:name=Tone:Warm:default=Brief:Formal%` | A popup menu |
| `%filldatepicker:name=Due:format=MMMM d%` | A date picker |
| `%fillpart:name=P.S.:default=no%…%fillpartend%` | An optional section |
| `%fillconditional:name=Language:default=0%%fillbranch:name=English%…%fillbranchend%…%fillconditionalend%` | A conditional section |
| `%snippet:abbr%` | Another snippet |
| `%key:tab%` `%key:return%` `%<` `%>` `%^` `%v` | Keys |
| `%delay:500%` | A pause, in milliseconds |
| `%+` `%-` `%!` | Keep the delimiter, remove it, or expand immediately (for this snippet) |
| `%%` | A percent sign |

The **Insert Macro** menu in the editor builds any of these for you.

## Sync and encryption

Turn on sync in **Settings › Sync** and choose a passphrase. Enter the same passphrase on your other Macs.

- Snippets, groups and settings sync through CloudKit, one small record per change.
- Every record is sealed with AES-256-GCM on your Mac before it leaves. The key is wrapped with a key derived from your passphrase (PBKDF2-SHA256, 600,000 rounds), so Apple only sees record names, dates and ciphertext.
- The newest change wins on every Mac, and deletions travel too, so a Mac that was offline can't bring something back.
- What you type, suggestions, and whether expansion is on stay on each Mac.

## Privacy

ExpansionLens watches keys only to spot abbreviations, keeping the last few hundred characters in memory. It never saves or sends what you type, and it sees nothing while a password field has Secure Input on. Snippets go in by pasting; they're marked so clipboard managers skip them, and your clipboard is put back afterward. There's no analytics. The only network requests are iCloud sync (when on) and the update check.

## Updates

ExpansionLens checks GitHub for new versions (once a day unless you change it) and, as you choose in **Settings › General**, installs them automatically when your Mac is idle, asks first, or doesn't check. Every download must be signed by the same developer and notarized by Apple before it's installed.

## URL scheme

`expansionlens://quicksearch`, `expansionlens://new`, `expansionlens://newfromclipboard`, `expansionlens://editlast`, `expansionlens://toggle`, `expansionlens://on`, `expansionlens://off`, `expansionlens://settings`.

## Building

Requires Xcode 26 and [XcodeGen](https://github.com/yonaskolb/XcodeGen).

```bash
xcodegen generate
swift test                 # the ExpansionLensKit tests
./build_app.sh             # Developer ID build in .build/app
```

`./release.sh X.Y.Z` builds, notarizes, makes the disk image and publishes the GitHub release.
