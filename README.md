# Perla

A study app for iPhone, built for iPhone Duo. It downloads publications from jw.org and shows them natively.

- **Meetings:** the week's midweek and weekend meetings.
- **Library:** books, brochures, workbooks, The Watchtower, videos and the Bible (regular or Study Edition).
- **Answers:** type in the answer boxes, or import an answers file in Settings.
- **Reading:** highlights, references beside the page, search, and adjustable text size and margins.
- **Language:** publications and the app each have their own language setting.

## Answers file

JSON with question and answer pairs, imported in Settings:

```json
{ "answers": [ { "question": "1. …", "answer": "…" } ] }
```

## Build

Push to `main` (official builds) or `testing`. GitHub Actions builds a numbered IPA (`Perla-1.0-buildN.ipa`); install it with a sideloading app such as Feather.

For personal use. Publications come from jw.org; don't redistribute them.
