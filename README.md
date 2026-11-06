# Perla

A native study app for iPhone (built for iPhone Duo). It downloads publications from jw.org, draws every page natively the way JW Library does, and lets you write answers into the publication's own answer boxes, or fill them from an answers file you import.

## What it does

- **Pages that look like JW Library.** Each page is rebuilt from the publication's own structure and design classes, not shown as a web page:
  - Meeting workbook: the colored section headers with their gem, wheat and sheep icons, the gray band behind the first part, song lines with the music icon, part titles in the section color, times, indents, pictures and captions.
  - Watchtower: the colored date band, theme scripture, the "TEMA" box, study questions with their answer boxes, paragraph numbers, centered subheadings and the review box at the end.
  - Bible: serif text, large chapter numbers, blue verse numbers, indented paragraphs, poetry lines, footnote marks and footnotes at the end.
  - The publication's own spacing (margins, padding, rules) is used wherever it sets one.
- **Answers where the publication puts them.**
  - Questions are found from the publication itself: the answer boxes it contains, the numbered study questions, and prompts like "PARA MEDITAR:" or "PREGÚNTESE:".
  - Study questions are tied to their exact paragraphs through the publication's own paragraph links.
- **Native navigation.**
  - Bible: a book grid colored by section like JW Library, then a chapter grid, then the chapter. Swipe sideways or use the buttons at the end of a chapter to go to the next or previous one. The grid button in the reader jumps to any book and chapter.
  - Other publications: a contents screen with each week's or article's picture and date.
  - Tapping a verse, footnote or reference opens it in a sheet, drawn the same way as the page.
- **Meetings tab.** Finds this week's midweek meeting and Watchtower study article, downloads them if needed, and opens them.
- **Answers.**
  - Tap an answer box to write your answer; long-press for copy, edit and "use sentence from the paragraph".
  - The sentence in the paragraph that answers each question is highlighted.
  - Import a Perla answers file (or paste one) and its answers fill the matching boxes (see below).
- **Links that work.**
  - Verses, footnotes and research open in a sheet. Research from another publication has an "Open" button for the whole lesson or chapter.
  - Book references in the text ("lfb lesson 12", "bt chap. 5", "w24.04") are tappable: the publication is downloaded if needed and opened at that lesson or chapter.
  - The Meetings tab shows this week's Congregation Bible Study lesson and opens it directly.
  - Videos and songs play inside the app. Bible links and jw.org document links open in the app; other web links open in an in-app browser.
- **Language.** The app is in English. Publications and answers use the language you pick in the globe menu.
- **iPhone Duo.** Folded: answers in the boxes plus a sheet with all of them. Unfolded: the page and an answers column side by side.

## Answers file

Settings → Import answers file (or the ⋯ menu in the answers list). You can also copy the file's text and tap **Paste answers**; text around the JSON (such as a ```json block) is ignored. The file is JSON:

```json
{
  "answers": [
    { "question": "1. ¿Qué tarea recibió Josué?", "answer": "Josué recibió la tarea de…" }
  ]
}
```

Questions are matched by their text (numbers, accents and punctuation don't matter), so one file can cover a whole week. An answer you write yourself always takes the place of the imported one.

## Build

1. Push to `main` (or upload this folder to the repo root).
2. GitHub Actions builds `Perla-ipa`. If the build fails, the run turns red and a `build-log` file is attached. After a successful build on `main`, earlier runs are deleted so only the newest IPA is listed.
3. Install `Perla.ipa` with Feather.

## Notes

- For personal use. jw.org's terms allow free, non-commercial apps that download its EPUB files; don't redistribute the app or the files.
- Read the paragraphs and put comments in your own words.

## Code map

| Folder | What's there |
| --- | --- |
| `Perla/Library` | jw.org download service, EPUB unpacking, library, Bible book index, contents reader, search index, this-week finder |
| `Perla/Reader` | XHTML → native page tree, design classes and icons, question finder, key sentences, imported answers, links (references, Bible, videos), reader model |
| `Perla/Answers` | Saved answers |
| `Perla/Views` | Tabs, Meetings, Library, publication contents, Bible grids, Search, page renderer, reader screen, answers panel, video player, settings |
