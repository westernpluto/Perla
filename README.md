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
  - Bible: a book grid colored by section like JW Library, then a chapter grid, then the chapter. Swipe sideways or use the buttons at the end of a chapter to go to the next or previous one.
  - Other publications: a contents screen with each week's or article's picture and date.
  - Library is grouped like JW Library: Bible, meeting workbooks, Watchtower, magazines, books.
- **Meetings tab.** This week and next week, three rows each: the midweek meeting, its Congregation Bible Study chapter, and the Watchtower study article. Tap one to open it.
- **Answers.** Type your answer straight into the answer box. An imported answers file fills the boxes in advance; anything you type replaces it. The ⋯ button copies, shares or prints a page's questions and answers.
- **Text.** The Aa button sets text size, side margins and the font. The same settings are in Settings.
- **References beside the page.** Tap a verse, footnote or research reference and it opens next to the page, so you keep your place: unfolded in a panel on the right, folded in a half-height sheet you can scroll the page behind. Buttons along the bottom:
  - **Open in Bible** goes to that verse in the Bible.
  - **Open in …** opens the cited publication at the cited page or lesson ("w17 October p. 23" → that page). If it isn't downloaded, Perla asks first.
  - **Read as a page** for a whole lesson or chapter that comes with the workbook, like the Bible study.
  - **Play song** for songs; videos play inside the app.
  - Bible references written in the text ("Isa. 11:1-10") and book references ("lfb lesson 12") are tappable too. Other web links open in an in-app browser. Long-press a paragraph to copy or share it.
- **Language.** The app is in English. Publications use the language you pick in the globe menu.
- **iPhone Duo.** Layout follows the available width, never device or orientation checks, so it fills both displays; standard bars, sheets and menus let the system move controls to the side and away from the fold.

## Answers file

Settings → Import answers file (or the ⋯ menu in the questions list). You can also copy the file's text and tap **Paste answers**; text around the JSON (such as a ```json block) is ignored. The file is JSON:

```json
{
  "answers": [
    { "question": "1. ¿Qué tarea recibió Josué?", "answer": "Josué recibió la tarea de…" }
  ]
}
```

Questions are matched by their text (numbers, accents and punctuation don't matter). Each file is kept separately and only fills a page it clearly belongs to (at least half of the page's or the file's questions match), so questions that repeat every week, like "What spiritual gems…?", don't get another week's answer. An answer you write yourself always takes the place of the imported one.

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
