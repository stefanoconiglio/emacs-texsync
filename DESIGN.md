# texsync — design

`texsync-mode` keeps a pdf-tools view of a LaTeX document in step with the source, inside one
Emacs frame: the source on the left, the PDF on the right.

- **Source → PDF, automatic.** Beamer: the slide of the frame around point. Other documents: the
  PDF scrolls so that the line at point sits at the same height in both windows; scrolling the
  source scrolls the PDF.
- **PDF → source, automatic too.** Scrolling or paging the PDF moves the source: Beamer to the
  frame of the slide shown, other documents to the line typeset a third of the way down the PDF
  window, at the same height. Whichever window the last command acted on leads.
- **Ctrl+click** (or double-click) in the PDF jumps to the exact source, through pdf-sync.
- **Compiling.** Saving runs latexmk into `build/`, and nothing else does (a pause in typing
  only if `texsync-compile-idle-delay` is set); the PDF reloads and re-syncs when the run
  succeeds.

Requirements: graphical Emacs (pdf-tools draws images, so not `emacs -nw`), pdf-tools with
`pdf-roll.el` (continuous scrolling), AUCTeX, latexmk.

## Files

- `texsync.el`: the package.
- `AGENTS.md`: working rules for changing this repository (tests, the GUI test's screen use).
- `LICENSE`: GPL-3.0-or-later.
- `try.el`: minimal init to try texsync without the user's config:
  `/usr/bin/emacs -Q -l try.el FILE.tex`.
- `test/texsync-test.el`: batch ERT tests (`make test`), pure functions and real SyncTeX output.
- `test/gui-test.el`: scripted run in a graphical Emacs (`make gui-test`), through the command loop.
- `test/fixtures/`: a Beamer deck (overlays, a verbatim frame, a commented-out frame), a
  two-file article with a BibTeX bibliography, and a lecture with its class in an `\input`
  header, an outline, `\AtBeginSection` slides, a `\subsection` without a slide and a frame in an
  `\input` file (`lectures/`).
- `smoke-test/`: the scripts of the first feasibility test on real documents (RESEARCH_LOG.md,
  2026-10-01 08:07).

## Data flow

```
 source buffer (texsync-mode)                         PDF buffer (pdf-view-mode)
 ───────────────────────────                          ──────────────────────────
 post-command-hook (global) ─► window the command acted on ─► timer 0.15 s
   source window ─► texsync-sync ─► forward search (epdfinfo) ─► place PDF page / vscroll
   PDF window    ─► texsync-sync-source ─► backward + forward search ─► source line, height
 after-change ─► idle delay ─► save      │   (only if texsync-compile-idle-delay is set)
 after-save ─► texsync-compile ─► latexmk -outdir=build ─► sentinel
                                         └── on success: revert PDF, timer 0.1 s, re-sync
 ctrl+click in PDF ─► pdf-sync backward search ─► redirect (.vrb) ─► source, point moved
                                                └─► texsync--after-backward-jump
```

## Algorithms

### Main file

`texsync-master-file`, in order: a string `TeX-master`; a `% !TEX root = FILE` comment in the
first 20 lines (the convention of TeXShop, TeXstudio and VS Code's LaTeX Workshop; spaces around
`=` optional); the buffer itself if it has a `\documentclass` or a `\begin{document}` (a
lecture whose class sits in an `\input` header is a main file); otherwise the only `.tex` file in
the same directory that is a main file in that sense and `\input`s / `\include`s /
`\subfile`s this file. With zero or several candidates (a header shared by many decks) there is
no guess and the user sets `TeX-master`. A guess is stored in a buffer-local `TeX-master`, so
AUCTeX's own commands agree.

The main file is found when `texsync-mode` is turned on and again from a buffer-local
`hack-local-variables-hook` (`texsync--find-master`). The setup turns the mode on from
`LaTeX-mode-hook`, and `run-mode-hooks` runs the mode hooks *before* it applies the file's local
variables and `.dir-locals.el`; a `TeX-master` set there (a `Local Variables` block, or a
`.dir-locals.el` that makes every deck of a folder part of one combined document) would
otherwise be ignored, the main file having been found and cached a moment earlier.

The document class (to tell Beamer) is read from the main file, or else from the files its
preamble `\input`s before `\begin{document}` (one level); if neither names it, a `.nav` file in
`build/` (Beamer writes one) marks a Beamer document.

The PDF is `<dir of main>/build/<main>.pdf`. `texsync-mode` also sets, buffer-locally,
`TeX-output-dir` and AUCTeX's viewer to `texsync-view`, so `C-c C-v` and `C-c C-c View` show the
PDF in the right-hand window at the place of point.

### Beamer: sync by frame, not by line

Beamer reads a frame's body as a macro argument and typesets it at `\end{frame}`, so every SyncTeX
record of a frame carries the line of its `\end{frame}`. A line in the upper part of a frame has
no record and SyncTeX snaps to the nearest recorded line, the previous frame's `\end{frame}`,
one slide early. Measured on a 73-slide deck: line-level forward search was right for 744 of
1374 in-frame lines and for no frame on every line; frame-level search was right for 56 of 56.

So: `texsync-frame-bounds` finds the `\begin{frame}` … `\end{frame}` around point (matches
inside `%` comments are skipped), and the forward search is made for the `\end{frame}` line.

**Section lines.** Outside a frame, a line that starts `\part`, `\section`, `\subsection` or
`\subsubsection` (starred too) shows the slide it makes: decks that put an outline or a title
slide in `\AtBeginSection` get a page whose SyncTeX records carry the `\section` line itself (the
macro is expanded while that line is read). `texsync-beamer-target` forward-searches the line
and keeps the page only if a backward search at that page's centre returns the same line; if
not (a `\subsection` without `\AtBeginSubsection` makes no slide, and forward search then
returns the previous frame's page), it shows the first frame after the line, where the section
starts. Other lines between frames (blank, comments) move nothing. Measured on a 57-slide lecture
with `\AtBeginSection`: its four `\section` lines showed their slides (3, 11, 27, 38), its two
`\subsection` lines the first slides of those subsections (43, 56).

**Overlays.** All overlays of a frame are typeset from that same line, so SyncTeX cannot say
which overlay a source line belongs to. The `.nav` file lists each frame's pages
(`\beamer@framepages{a}{b}`); `texsync-overlay-page` takes the range containing the page SyncTeX
returned and shows its last page (`texsync-beamer-overlay` = `last`, the complete slide) or its
first.

**Ctrl+click.** pdf-view binds the ctrl+press (`C-down-mouse-1`) to extending the text
selection. That command follows the mouse until the release and, if the pointer moved at all
(on a touchpad it nearly always does), discards the release event — the `C-mouse-1` that
pdf-sync binds to its jump. So a real ctrl+click jumped only when the mouse stayed perfectly
still. `texsync-pdf-mode`, a minor mode turned on in the PDF buffers texsync shows, binds the
press (and the second press of a double-click) to `ignore` and the release to
`pdf-sync-backward-search-mouse`. Ctrl+drag no longer extends a text selection there.

pdf-sync's backward search finds the `\end{frame}` line and then its text
heuristic usually moves point to the clicked words. If point is still on `\end{frame}`,
`texsync--after-backward-jump` moves it to the frame's `\begin{frame}`.

**Files LaTeX wrote.** SyncTeX sometimes names a file LaTeX wrote and read back instead of a
source: Beamer's `.vrb` for verbatim (`[fragile]`) frames, `.toc` for an outline, `.bbl` for a
bibliography (`.lof`, `.lot`, `.ind` likewise). `texsync--aux-source` sends such an answer to its
source: in a Beamer document, to the frame typeset on that page (`texsync-frame-at-page`); in
other documents, to the command that reads the file (`\bibliography` / `\printbibliography`,
`\tableofcontents`, `\listoffigures`, `\listoftables`, `\printindex`), searched from
`\begin{document}` on, because a preamble may name the command in a definition (an
`\AtBeginSection` outline did). Ctrl+click goes through the same function
(`texsync--redirect-aux`, a `pdf-sync-backward-redirect-functions` entry), with the clicked page
taken from the click in continuous mode.

`texsync-frame-at-page` is a binary search over the main file's frames: frames are typeset in
source order, so the page of frame *i* grows with *i*; frames made by macros (title or section
pages) are not in the list but do not break the order. Each step is one forward search, so a
65-frame deck needs at most 7 (53 ms on a 57-slide deck, against 10 ms for one backward search).
It is now only the fallback (next section).

### Other documents: line at the same height

For the line at point, `texsync-paper-target` returns `(PAGE . Y)`, `Y` the top of the line's
text as a fraction of the page height.

- **Structural lines** (`texsync-structural-line-regexp`: blank and comment lines, a lone
  `\begin{…}` / `\end{…}` with an optional `\label`, `\input`, `\include`, `\label`, page breaks,
  `\maketitle`, `\bibliography…`) get unreliable records: on a two-column paper, all 15 places
  where the position moved backwards were such lines, mapped to the top of a page. For them, and
  for lines with no record, the nearest other line is used: point's line, then one above, one
  below, two above, …, up to `texsync-search-radius` (8).
- **Boxes** with zero width or more than half a page tall are rejected the same way.

`texsync--show-position` then scrolls the PDF window so that height `Y` of `PAGE` sits at the
fraction `f` of the window height at which point's line sits in the source window:

```
offset = Y · h(PAGE) − f · H
```

with `h(PAGE)` the displayed page height and `H` the window height, in pixels. In roll mode
(continuous scrolling) the window starts on `PAGE` with vscroll `offset`. A negative offset
moves the start to earlier pages, adding each page's height plus `pdf-roll-vertical-margin`
until it is non-negative. Without roll mode the page is shown alone and the offset clamped at 0.

**Two columns.** Reading order runs down the left column and then up to the top of the right
one, so scrolling the source down can move the PDF up: the PDF shows where the text is.

### Which side leads

One global `post-command-hook` function, `texsync--post-command`, decides after every command:

- **The window the command acted on.** For mouse events (the wheel, clicks) that is the window
  under the pointer: Emacs scrolls it without selecting it, so "the selected window" would be
  wrong — that mistake made the PDF snap back to the source after every wheel scroll over it.
  For `scroll-other-window` it is the other window; otherwise the selected window.
- **A source window** (`texsync-mode`) leads: the PDF follows (above).
- **A PDF window** (`texsync-pdf-mode`) leads only if the command changed its page or vscroll
  since the last sync (window parameter `texsync-synced`, set by both directions), and the
  command is not a jump or a pass-through: pdf-sync's jump, `ignore` (the swallowed press),
  `pdf-util-image-map-mouse-event-proxy` (pdf-tools re-sends clicks on text without their
  image-map area), an undefined key, or pointer motion.
- Either way one timer (`texsync--timer`) restarts at 0.15 s (`texsync-sync-delay`): the other
  window moves once motion pauses, and the latest leader wins. SyncTeX queries cost 8–22 ms each
  through epdfinfo, which allows one round per pause, not one per scroll step.
- **Paused documents.** `texsync-follow` (buffer-local, t) gates both directions: a source
  buffer with it nil schedules nothing, and `texsync--source-window` skips it, so its PDF does
  not lead either. `texsync-toggle-follow` sets it in every texsync buffer of the same PDF (all
  files of the document), from a source or from the PDF; switching it back on syncs at once.
  Compiling, `texsync-view` and ctrl+click ignore it; a recompile does not re-place the PDF of a
  paused document. The lighter reads `Sync:off` while paused.
- Programmatic moves run no command, so the follower's move never triggers a sync back.
- A ctrl+click jump cancels any pending sync and suppresses source-led syncs for 0.5 s.
- `texsync--place` remembers the last target and the PDF state after placing it, and skips the
  work only when both are unchanged.

### The PDF leads

`texsync-sync-source` finds the source window showing a texsync buffer of the same PDF.

**Beamer.** `texsync-beamer-source` asks SyncTeX once, at the centre of the slide shown. A line
inside a frame of that file (the main file or an `\input` one; frames are read once per change
of the file on disk) gives the frame's first line; a line outside frames is the line that made
the slide (a `\section` with an `\AtBeginSection` slide) and is used as it is; an answer in a
file LaTeX wrote is sent to the frame on that page (above). Only when that gives nothing is the
binary search used. Measured on a 57-slide lecture: every frame's slide round-trips to its frame,
the four section slides give their `\section` lines, the outline (`.toc`) and the verbatim slide
(`.vrb`) their frames; median 11 ms per slide (it was 53 ms with the binary search alone). The
line is shown near the top of the source window, with point on it; if point is already in that
frame, or on that line, nothing moves.

**Other documents.** The anchor is the point at `texsync-pdf-anchor` (one third) of the PDF
window's height, converted to (page, y) by walking the displayed pages (heights from
`pdf-view-desired-image-size`, which needs no rendering: pdf-roll draws pages lazily and asking
an undrawn page for its image size signals an error). `texsync--source-at` then asks SyncTeX
for the line typeset there and checks the answer both ways, because in margins and between pages
SyncTeX's nearest record can belong to any line (at the top of a page it returned a blank line
of the main file, from the page head):

- heights around the anchor are tried nearest first (±0.02 … ±0.15 of the page);
- a backward result is rejected if its line is structural;
- it is accepted if a forward search of that line starts on the same page at or above the
  height tried;
- only if no height gives such a line, a line whose text starts on the page before is taken —
  a sentence or a whole paragraph on one source line that wraps across the page break — and
  failing that the first structural line met (the title's `\maketitle`);
- an answer in a file LaTeX wrote (the bibliography's `.bbl`) is accepted at once as the line of
  the command that reads it, at the height tried;
- each (file, line) answer is checked once per call (SyncTeX often gives the same answer at
  several heights);
- every SyncTeX answer, both directions, is remembered until the PDF changes on disk
  (`texsync--memoized`, keyed on the modification times of the PDF and of its SyncTeX file).

Measured on a 17-page paper at 45 points, cache cleared each time: median 25 ms, 90th percentile
50 ms (139 ms before), 1.5 backward searches per call (2.7), one point with no answer (six; five
were on the bibliography pages, where every height gave a `.bbl` line and was rejected). A point
already asked costs about 3 ms.

The line is then shown in the source window at the height where its text *starts* in the PDF
window (`texsync--pdf-px`), so both start at the same height, and point is put on it. A buffer of
another `\input` file replaces the source window's buffer. Backward searches use x = 0.25 of
the page width: on a two-column page the source follows the left column (known limitation).

### Compiling

`texsync-compile` runs `latexmk -pdf -synctex=1 -interaction=nonstopmode -file-line-error
-outdir=build <main>` asynchronously in the main file's directory, output in buffer
`*texsync <main>*`. One run per main file at a time; a request during a run queues one more.
On exit 0 the PDF buffer is reverted (epdfinfo reopens the document and its SyncTeX data) and,
after a 0.1 s timer that lets redisplay rebuild pdf-roll's page overlays, the selected source
window is synced again. On failure the old view stays and a message names the log buffer.
With a prefix argument (`force`) latexmk gets `-g` and rebuilds even when it holds the PDF up to
date.

**PDFs without SyncTeX data.** A PDF built by something else — a plain `pdflatex` run, a
Makefile, an agent following a one-off compile command — has no `.synctex.gz`, and then every
lookup fails quietly: texsync looked switched off. Before any lookup, in both directions,
`texsync--ensure-synctex` checks for `<main>.synctex.gz` (or `.synctex`) beside the PDF. When it
is missing it says so in the echo area and rebuilds once per PDF version (`texsync--synctex-asked`
holds the PDF's modification time), forced, since latexmk's own records may call the PDF up to
date. The PDF is still shown meanwhile. Seen on a lecture deck whose 00:10 build had no SyncTeX
file and none of latexmk's (`.fls`, `.fdb_latexmk`).

**AUCTeX's own runs.** `C-c C-c` saves the buffer and then starts AUCTeX's command; the save
would also start texsync's latexmk, and two TeX runs would write the same `build/` files. So
compile-on-save waits 0.3 s and then, while AUCTeX has a live process for the same main file
(`TeX-process`), re-checks every second; texsync's run starts after AUCTeX's ends.

Idle compiling, off by default (`texsync-compile-idle-delay` nil, since 2026-10-06: it saved
and rebuilt at every pause in typing, far more often than wanted). When it is a number, an edit
(re)starts an idle timer of that many seconds; when it fires on a modified buffer it saves the
buffer, and saving compiles (`texsync-compile-on-save`). By default only an explicit save
compiles.

### pdf-tools workarounds

- PDFs are visited with `large-file-warning-threshold` nil (a 17 MB deck asked for confirmation),
  and put in `pdf-view-mode` if pdf-tools is not installed as the `.pdf` handler.
- The PDF buffer ignores `global-auto-revert-mode`: reverting while latexmk rewrites the file
  breaks; texsync reverts after a successful run.
- In roll mode, `pdf-misc-size-indication-minor-mode` measures the selected window (the source
  window here) and signals an error on every redisplay; texsync turns it off in that buffer.

## Known limitations

- **Page-break artifact.** The first line of a paragraph that starts right after a page break
  also has records at the foot of the previous page (glue from the page break), and epdfinfo
  returns only the first record. The PDF then shows the foot of the previous page for that one
  line. Seen once in the 60 checked sentence lines of the fixture. A fix needs all records of a
  line (the `synctex` command line tool, or parsing `.synctex.gz`).
- Two-column papers: when the PDF leads, the source follows the left column only (the anchor
  is at x = 0.25); ctrl+click reaches the right column.
- Near the start or end of a file the source window cannot scroll far enough to put a line at
  the PDF's height, nor the PDF above page 1; alignment is then off by that much.
- Frames written as `\frame{…}` or `\againframe` are not recognised.
- The main-file guess looks only in the file's own directory.
- A compile that fails may leave a partly written PDF on disk; the displayed pages stay, pages
  not yet rendered may fail until the next successful run.

## Tests

- `make test`: 14 ERT tests, headless (about 8 s; they compile the fixtures with latexmk).
  - Pure functions: frame bounds for every line of the fixture deck (a commented-out frame
    included); structural lines; candidate order; overlay choice; main-file guess (unique,
    ambiguous, explicit `TeX-master`); a `TeX-master` from `.dir-locals.el` and from a file's
    `Local Variables`, with texsync turned on from `LaTeX-mode-hook`, wins over the deck being a
    main file itself (and without them the deck is its own); a lecture whose class is in an `\input` header and that
    names itself with `% !TEX root` (its `\input` part's `% !TEX root=` points back).
  - Deck fixture: every line of every frame → its slide, `last` and `first` overlays; page →
    frame by binary search and by one lookup per page, the verbatim frame included.
  - Lecture fixture, both ways: frame lines, `\section` lines (→ their `\AtBeginSection`
    slides), a `\subsection` without a slide (→ the next frame's), lines between frames (→
    nothing), a frame in `part.tex`; each page → its frame's first line or its `\section` line.
  - Article fixture: every sentence line → the page and height (±0.02) of a text search for
    that sentence, in reading order, with page-break artifacts counted (≤ one per page break);
    on the references page PDF → source gives the `\bibliography` line with at most two
    backward searches, and a repeated call asks SyncTeX nothing.
  - Pausing: `texsync-toggle-follow` from one file of the article pauses both files (lighter
    `Sync:off`), a command then schedules no sync, toggling again resumes, `-1` pauses.
  - Missing SyncTeX data: with the article's `.synctex.gz` deleted a lookup gives nil, one forced
    rebuild (`-g`) starts and a second request does not queue another; afterwards the file is
    back and the same lookup answers (the nil was not kept).
- `make gui-test`: 32 checks in a graphical `emacs -Q`, fullscreen, keys and mouse events sent
  through `execute-kbd-macro` so that the command loop, `post-command-hook` and timers run as
  for a user. **It takes over the screen for about a minute: run it when the machine is free.**
  Deck: View, six cursor moves, ctrl+click (called directly) on a normal and on a verbatim slide,
  next slide in the PDF moves the source to its frame and the PDF stays, `C-c C-c View`,
  `C-c C-c LaTeX` (AUCTeX's run, then texsync's, never both at once), no errors logged.
  Article: main file found from `sec.tex`, continuous mode, the sentence at point at the same
  height in both windows (< 25 px) after cursor motion and after `C-v` twice; six wheel steps
  over the PDF with the source selected: the PDF stays where it was scrolled, the focus stays
  in the source, point's line is typeset within 0.2 page of the anchor (checked with SyncTeX)
  and starts at the same height in both windows; a ctrl+click made of real mouse events, held
  still and with a 2 px wobble, lands on the clicked sentence's line, while without
  `texsync-pdf-mode` the wobbly one is lost; an edit is saved, compiled and reloaded by the idle
  timer and alignment holds after it; no errors logged. The harness waits with `redisplay` and
  `accept-process-output` (`sit-for` returns early while a window-manager event is pending),
  runs events that pdf-tools re-queues, and allows for a PDF that cannot scroll above page 1, a
  source window at its first line and `C-v` reaching the end of the buffer.
