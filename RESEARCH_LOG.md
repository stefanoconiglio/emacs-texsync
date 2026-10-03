# Research log

## 2026-10-01 08:07 CEST — Smoke test: SyncTeX through pdf-tools in graphical Emacs

**Question.** Can Emacs + pdf-tools give continuous source↔PDF sync: Beamer frame ↔ slide, and paper
scroll ↔ scroll? Do the SyncTeX answers that pdf-tools returns land in the right places?

**Setting.** Emacs 31.1 (pgtk, Wayland/Hyprland), pdf-tools 20260102 (epdfinfo on poppler 26.08),
TeX Live latexmk `-pdf -synctex=1 -outdir=build`. Two of the user's documents, copied to a scratch
folder (sources unchanged):
- a 73-slide Beamer lecture deck (1781 lines, one page per frame, no overlays, two `[fragile]` frames);
- a 7-page two-column paper split over six `\input` files.

**What was done.** Scripts in `smoke-test/`:
- `dump.el` (batch Emacs): forward search on every source line, backward search on a 9-point
  vertical grid per page, all through `pdf-info-synctex-forward-search` / `-backward-search`.
- `check_deck.py`: ground truth independent of SyncTeX — a frame's page is the page whose
  `pdftotext` contains the frame title (unique for 56 of 65 source frames).
- `check_paper.py`: puts lines in reading order (following `\input`) and counts where the PDF
  position moves backwards; column-aware rerun inline.
- `gui-init.el`, `smoke-sync.el`: graphical Emacs (`emacs -Q`, unit `latexsync-smoke`), source left,
  PDF right, frame-level forward sync; continuous mode (`pdf-view-roll-minor-mode`) on the paper.

**Results.**
- Build time: deck 9.5 s (full latexmk run), paper 1.5 s.
- Query cost: deck ≈ 22 ms per SyncTeX query (55 s for ~2400 queries), paper ≈ 8 ms.
- Deck, line-level forward search: 744 / 1374 in-frame lines land on the right slide; 0 / 56 frames
  are right on every line. Cause: Beamer collects the frame body and typesets it at `\end{frame}`, so
  every record of a frame sits on its `\end{frame}` line. Lines in the upper part of a frame have no
  record and snap to the nearest recorded line, the previous frame's `\end{frame}` → one slide early.
- Deck, frame-level forward search (query the enclosing frame's `\end{frame}` line): 56 / 56 right,
  including both fragile frames. Confirmed in the GUI: cursor lines 40, 60, 150, 1380, 1420 →
  slides 4, 5, 7, 57, 58, read back from `pdf-view-current-page`.
- Deck, backward search: 491 / 504 grid points return exactly the frame's `\end{frame}` line; the
  other 13 (the fragile frames) return lines of the `.vrb` temporary file.
- Paper, forward search: 522 / 528 lines get a position. Column-aware, the PDF position moves
  backwards 15 times; each is a single structural line (`\end{eqnarray}`, `\end{equation*}`,
  `\input`, `\end{subequations}`) mapped to the top of a page — isolated outliers.
- Paper, continuous mode: scrolling to (page 4, y 0.618) for a line that starts a block of
  equations put those equations at the top of the PDF pane; pages 4 and 5 visible together.

**Problems seen.**
- Opening the 17 MB deck PDF triggers Emacs's large-file prompt (`large-file-warning-threshold`,
  10 MB). The package must not prompt for PDFs.
- `Wrong type argument: window-live-p, #<window 3>` in the echo area after I deleted and re-split
  the windows to swap the PDF pane (window 3 was one I deleted). Source not identified: no backtrace
  taken; pdf-view and pdf-roll both keep per-window state.
- Rendering looks slightly soft on the HiDPI screen; check `pdf-view-use-scaling`.

**Conclusions.**
- Beamer: sync by frame, not by line. Parse frames from the source; forward = enclosing frame's
  `\end{frame}` line; backward = page → frame through a page→frame table built after each compile
  (covers fragile frames, whose backward search points into `.vrb`).
- Papers: line-level forward search is usable for scroll sync once structural lines are skipped or
  outliers filtered (e.g. median over the lines in view). Two-column layouts make "next" positions
  jump to the top of the right column; that is correct, not a glitch.
- Queries are cheap enough for one per scroll pause (debounced), not one per scroll event; a table
  built once per compile avoids per-scroll queries entirely.

**Gaps in the deck check.** The 56 / 56 excludes 9 source frames whose title was missing or
matched 0 or several pages (repeated-title continuation slides among them), and the 8 pages made by
macros (title page, section pages); backward sync from those pages is untested.

**Open.** Beamer overlays (this deck has none). Every overlay of a frame is typeset from the same
`\end{frame}` line, so SyncTeX cannot tell which overlay a cursor line belongs to. First or last
overlay is easy (`.nav` has `\beamer@framepages{a}{b}` per frame); "the overlay the cursor is in"
needs counting `\pause` / `<n->` in the source, a heuristic. Test on a deck with overlays; the
choice is the user's. Continuous vs click-only PDF → source for papers: still the user's call.
Running graphical Emacs instead of `emacs -nw`: the user agreed to try it.

## 2026-10-01 08:14 CEST — Decision: PDF → source only on click

**Decision (user).** For papers, scrolling the PDF does not move the source; the source jumps only
when the user clicks in the PDF. Source → PDF stays automatic (the PDF follows the cursor and
scrolling in the source).

## 2026-10-01 08:31 CEST — Decision refined: automatic source → PDF scroll, ctrl+click back

**Decision (user).** The must-have is the automatic scroll from source to PDF. PDF → source by
ctrl+click is fine (pdf-sync already binds `C-mouse-1` and
`double-mouse-1`), replacing the plain click I had proposed after the 08:14 entry.

**Seen.** In the `emacs -Q` test window, `C-c C-c View` from `lp.tex` opened GNOME's Document
Viewer on a missing `lp.pdf`: no config (no `TeX-output-dir`, no viewer), and `lp.tex` has no
master, so AUCTeX took it as its own master.

## 2026-10-01 09:04 CEST — texsync 0.1: automatic source → PDF sync in Emacs

**Question.** Does a minor mode on pdf-tools give automatic source → PDF scrolling (Beamer: the
frame's slide; papers: same height in both windows), ctrl+click back, and compiling on the fly?

**What was done.** `texsync.el` (DESIGN.md has the algorithms), batch tests (`make test`, 8 ERT
tests on fixtures in `test/fixtures/`) and a scripted graphical run (`make gui-test`, 21 checks,
keys through `execute-kbd-macro` so the command loop and timers run). Checked by hand in the
`latexsync-smoke` window (unit `latexsync-smoke`, `emacs -Q`) on the 73-slide deck and the
two-column paper (scratch copies). A 74-page problem-sheet deck switched from `[handout]` to plain beamer
confirmed that all overlays of a frame come from its `\end{frame}` line (8 overlays, pages 5–12,
one source line).

**Results.**
- `make test`: 8 / 8. `make gui-test`: 21 / 21; the sentence at point and its PDF text are within
  0.4 px of the same height after cursor motion, two `C-v`s, and an edit → idle save → compile
  → reload.
- Real deck, cursor moved by keyboard macro to lines 40, 150, 1380, 1420, 60 → slides 4, 7, 57,
  58, 5 (all right, 57 and 58 are verbatim frames), no errors logged.
- Real paper (from an `\input` file, main file guessed): View resolves to texsync (no
  external viewer). Inserting 13 lines and pausing saved and compiled in 2 s; a sentence
  moved from line 46 / (p4, y 0.863) to line 59 / (p4, y 0.337),
  and a text search in the new PDF finds it at (p4, y 0.323, right column): SyncTeX data reload.
- Ctrl+click on verbatim slides 57 and 58 of the real deck now maps to their frames (lines 1359,
  1402) through the `.vrb` redirect, in under a second.

**Mistakes and their correction.**
- `texsync--window-state` read the PDF window's page in the source buffer → `listp, t` after
  every placement (the page had already moved, so it looked right). Fixed: read it in the PDF
  buffer.
- pdf-tools bug: in roll mode its mode-line size indicator measures the selected window and
  errors on every redisplay when the source window is selected. texsync turns it off there.
- After a revert, roll mode rebuilds its page overlays at the next redisplay; syncing at once
  signalled `overlayp, nil` in the process sentinel. Fixed: re-sync on a 0.1 s timer, redisplay
  first if the overlays are missing.
- In a bare Emacs `.pdf` opened in doc-view; texsync now switches it to pdf-view-mode.
- Two GUI-test failures were test bugs (search words cut before the sentence number; moving
  point without a command, so no sync was triggered), not texsync bugs.
- My first attempt to read a backtrace sent `(top-level)` through emacsclient, which aborted the
  reply and hung the client; `pkill -f` on that pattern then killed my own shell. Read the
  `*Backtrace*` buffer instead.

**Known limitation found.** Page-break artifact: the first line of a paragraph starting right
after a page break maps to the foot of the previous page (epdfinfo returns only the first of the
line's records; the first is page-break glue). Once in 60 fixture sentences. Fix would need all
records (synctex CLI or own `.synctex.gz` parser).

**Decision (Claude, user to confirm).** Default overlay `last` (the complete slide); `first` is
an option. Key bindings: none of its own (`C-c` + letter is reserved for users); View is
AUCTeX's `C-c C-v`.

**Open.** The user's own acceptance test (mouse wheel, ctrl+click, real decks). Integration into
the user's init.el (not done: their config; proposed only in graphical frames, zathura kept for
`-nw`). `git init` of this folder: asked, unanswered.

## 2026-10-01 09:33 CEST — Ctrl+click did nothing; `C-c C-c` and double compiles

**Report (user).** Only source → PDF worked: in the `texsync-try` window, ctrl+click in the
PDF did not jump to the source.

**Cause.** pdf-view binds `C-down-mouse-1` to `pdf-view-mouse-extend-region`. Its drag tracker
(`pdf-util-track-mouse-dragging`) drops the click event from `unread-command-events` as soon as
one mouse-movement event was seen, so the `C-mouse-1` release that pdf-sync binds never runs
when the pointer moves during the click (a touchpad). My earlier GUI test called
`pdf-sync-backward-search` directly and never went through the mouse bindings, so it could not
see this.

**Fix.** `texsync-pdf-mode` in texsync's PDF buffers: `C-down-mouse-1` and
`double-down-mouse-1` → `ignore`, `C-mouse-1` and `double-mouse-1` → pdf-sync's jump. Loaded into
the user's open `texsync-try` window.

**Evidence.** GUI test with real mouse events (`execute-kbd-macro` of press / movement / release):
without the mode a ctrl+click with a 2 px wobble stays in the PDF; with it, held still and with
the wobble, point lands on the clicked sentence's line ("Paragraph 4 sentence 2").

**Also checked.**
- `C-c C-c View` (which had opened an external viewer on a missing PDF) now reaches
  `texsync-view`.
- `C-c C-c LaTeX` saved the buffer, which also triggered texsync's latexmk, while AUCTeX started
  its own run into the same `build/`. Fix: compile-on-save waits 0.3 s and defers while
  `TeX-process` of the main file is alive. GUI check: AUCTeX ran, texsync ran after, never both.
- `make gui-test` 26 / 26 on two consecutive runs; `make test` 8 / 8.

**Mistakes.**
- `pkill -f` with a pattern contained in my own command line killed my shell — the second time
  today. Use `pgrep -af '^/usr/bin/emacs …'` and kill by PID.
- `backtrace-to-string` is not loaded in `emacs -Q` (needs `(require 'backtrace)`); the test's
  error handler failed and the test never exited.
- Test helper called `pdf-view-image-size` from the source buffer (same class as the
  `texsync--window-state` bug).
- Window sizes vary with Hyprland tiling (a 466 px tile when another Emacs was open): checks now
  allow a PDF pinned at page 1 and `C-v` reaching the end of the buffer.

## 2026-10-01 11:35 CEST — Bidirectional sync: the PDF can lead

**Report and decision (user).** Scrolling the PDF snapped it back to the source's position;
the user asked for sync in both directions, keeping ctrl+click. This replaces the 08:14 decision
(PDF → source only on click): scrolling the PDF now moves the source.

**Cause of the snap-back.** A wheel scroll over the PDF runs `mwheel-scroll` with the source
window still selected, so the source buffer's `post-command-hook` scheduled a source-led sync,
and `texsync--place` re-placed the PDF because its state had changed.

**What was done.** One global `post-command-hook` picks the leader: the window the command acted
on (under the pointer for mouse events). PDF leads only when its page/vscroll changed since the
last sync and the command is not a jump/pass-through (pdf-sync jump, `ignore`, pdf-tools'
image-map proxy, undefined key, pointer motion). PDF → source: Beamer → frame of the slide;
papers → anchor at 1/3 of the PDF window → `texsync--source-at` (backward search, structural
lines rejected, forward search must start on the page at or above the height tried; fallback to
a line starting on the page before) → line shown at the height where its text starts. Page
heights from `pdf-view-desired-image-size`. `window-scroll-functions` dropped.

**Results.** `make gui-test` 32 / 32 on the last three consecutive runs (earlier runs of the new
code had test-harness failures, below); `make test` 8 / 8. Wheel over the PDF: PDF stays, focus
stays in the source, point's line starts within 10 px of its PDF text.

**Found on the way (real bugs).**
- Clicks on text arrive with the image-map area `pdf-view-text-region` and go through pdf-tools'
  proxy command; that proxy command would have scheduled a PDF-led sync that overrides the
  ctrl+click jump 0.15 s later. Fixed (proxy in the pass-through list; the jump cancels pending
  syncs).
- `texsync--point-fraction` returned nil when point's long wrapped line began above the window
  start, so nothing synced. Fixed (measure from the first visible part of the line).
- Asking pdf-roll for the image size of an undrawn page signals "Invalid image specification".
  Fixed (sizes from `pdf-view-desired-image-size`).
- In a margin at the top of a page, backward search returned a blank line of `main.tex` (page
  head records); validation now rejects such answers.

**Mistakes.**
- Test harness: `sit-for` returns early while a window-manager event is pending (the user
  closing a window), so redisplay was skipped and point measured as invisible; events that
  pdf-tools re-queues are not run inside a keyboard macro; a first-cut check expected each line
  to start on the page where it is seen (wrong for a sentence wrapping across a page break).
- A Python edit script stopped at an assertion and I ran one test round on unchanged code.
- Negative result, unexplained: in one run "pause after an edit saves and recompiles" failed
  (no recompile within 30 s). It did not recur in the eight later runs; its cause was not
  established (the pointer-motion fix came in the same round, but that is not shown to be it).
- I ran the GUI test (a window, the last ones fullscreen) about a dozen times while the user was
  working at the same machine. `make gui-test` takes over the screen: run it only when the machine
  is free (AGENTS.md).

**Open.** The user's own test of PDF → source scrolling (their `texsync-try` window had closed
before the new code; not reopened). Two-column: the source follows the left column when the PDF
leads. `git init` and `init.el` integration still unanswered.

## 2026-10-01 12:12 CEST — Accepted; published as texsync

**Result (user).** Tried both directions on a 17-page single-column paper (copy) and a deck:
accepted; the project is finished for now.

**Decisions (user).** Publish texsync on GitHub, public. The Omarchy theme follower is not part
of it: `omarchy-follow.el` moved to a separate local repository with the user's Emacs settings
(not published; that decision is open). `try.el` turns it on only when it is on the load path.

**Decisions (Claude).** Folder renamed from ~/repos/latexeditor to ~/repos/texsync (a link keeps
the old path). License GPL-3.0-or-later, as Emacs, AUCTeX and pdf-tools. Personal details
(document names, quotes from the user's text and remarks) removed from this log before
publishing; measurements and mistakes kept. AGENTS.md added with the working rules.

**State.** `make test` 8 / 8; `make gui-test` 32 / 32 on its last three runs (not rerun after
the split: it takes over the screen). Known limitations: DESIGN.md.

## 2026-10-01 14:32 CEST — "Cannot tell the main file" on a lecture with its class in a header

**Report (user, screenshot).** On a lecture deck, texsync said "cannot tell the main file; set
TeX-master". The deck's first line is `% !TEX root = <itself>.tex`, its second
`\input{header}`; the `\documentclass[handout,…]{beamer}` is in `header.tex`, and
`\begin{document}` is in the lecture. All lectures of that course are built this way.

**Fix.** Main file: the `% !TEX root` comment, then a `\begin{document}` as well as a
`\documentclass` makes a file its own main file. Class: also from the files the preamble
`\input`s; a `.nav` file in `build/` as the last sign of Beamer.

**Results.** `make test` 10 / 10 (2 new, with a fixture in that shape). On the real deck,
read-only with its existing build: main file found, class beamer; the frames titled in the
source map to slides 4, 5, 6, and pdftotext shows those titles on exactly those slides.

## 2026-10-01 21:16 CEST — Section slides, and the PDF leading more slowly than the source

**Reports (user).** (1) Two-way scrolling works, but following the PDF feels slower than
following the source. (2) In a Beamer lecture with `\AtBeginSection` slides, a section slide never
brings the source to its `\section` line.

**Measured (scratch copies of a 57-slide lecture and a 17-page paper, batch Emacs).**
- Source leads: one forward search, about 13 ms on the paper.
- PDF leads, deck: `texsync-frame-at-page` (binary search, ~7 forward searches) 53 ms per slide,
  against 10 ms for one backward search. A backward search at the centre of each of the 57 pages
  returned the frame's `\end{frame}` line for every frame slide, exactly the `\section` line
  for the 4 section slides (the `\AtBeginSection` macro is expanded while that line is read), the
  `.toc` file for the outline slide and the `.vrb` file for the one verbatim slide. The binary
  search over source frames cannot find a section slide: it belongs to no frame.
- PDF leads, paper: `texsync--source-at` over 45 points: median 27 ms, 90th percentile 139 ms,
  max 212 ms, 2.7 backward searches per call, 6 points with no answer. The slow and failed ones:
  the bibliography pages (every height answered with a `.bbl` line, rejected: 11 tries) and
  points where the same rejected line came back at every height.

**Mistake.** My first paper timing showed no answer at all 40 points: the scratch copy had been
deleted when the session restarted, so every lookup failed on a missing PDF. Recreated it before
measuring again.

**What was done.** `texsync-beamer-source` (one backward search at the slide's centre; frame of
the answering file, or the line itself outside frames; binary search as fallback); section lines
lead too (`texsync-beamer-target`: the line's own slide if SyncTeX confirms it, else the next
frame's); `texsync--aux-source` maps answers in files LaTeX wrote (Beamer: the frame on the page;
others: `\bibliography`, `\tableofcontents`, … searched from `\begin{document}`); ctrl+click uses
it (`texsync--redirect-aux`, clicked page from the event); `texsync--source-at` checks each
answer once, accepts helper-file answers at once and falls back to a structural line; every
SyncTeX answer is memoized until the PDF changes.

**Results.** Deck: all 57 slides correct (frames round-trip, section slides → `\section` lines,
outline and verbatim slides → their frames); median 11 ms, max 47 ms per slide, no cache. Source
→ PDF: the 4 `\section` lines → slides 3, 11, 27, 38; the 2 `\subsection` lines (no slide of
their own) → 43, 56, their first slides; blank lines between frames → nothing. Paper: median
25 ms, 90th percentile 50 ms, 1.5 backward searches per call, 1 point without an answer (before
the structural fallback; the title block, `\maketitle`); bibliography pages → `\bibliography{BIB}`;
a repeated point about 3 ms. `make test` 11 / 11 (2 new tests, fixtures extended).

**Mistake on the way.** The first `.toc` mapping searched the whole file for `\tableofcontents`
and found the one inside the preamble's `\AtBeginSection` definition: the outline slide went to
that macro's frame. In Beamer, helper-file answers now go through the page; elsewhere the search
starts at `\begin{document}`.

**Not checked.** `make gui-test` (it takes over the screen; not run without asking). Whether the
PDF-led sync now *feels* as fast as the source-led one is the user's call: both still wait
0.15 s after the last motion (`texsync-sync-delay`), and pdf-tools' own scrolling and rendering
of pages is unchanged.

## 2026-10-01 21:34 CEST — The fix was not loaded; a switch to pause the following

**Report (user).** Section slides still did not sync.

**Cause.** The user edits in the Emacs daemon (frames from "Emacs (Client)"), which had loaded
texsync before the 21:16 change: `texsync-beamer-source` was not defined in it. Not a code
problem. Reloaded `texsync.el` into the daemon through `emacsclient` (functions only; nothing
on screen moved; the old `texsync--redirect-vrb` hook entry removed). Checked there, on the open
lecture: its 4 `\section` lines → slides 3, 11, 27, 38, its 2 `\subsection` lines → 43, 56,
and slides 3, 11, 27, 38 → the `\section` lines 89, 259, 642, 896.

**Request (user).** What kind of mode is this, and how to switch it off: sometimes the PDF should
not track the text, nor the text the PDF.

**Answer and change.** Minor modes (`texsync-mode` in the source, `texsync-pdf-mode` in the
PDF); turning `texsync-mode` off already stopped both directions, but also compiling and the
View redirect. Added `texsync-toggle-follow`: pauses both directions for every file of the
document, from a source or the PDF, and keeps compiling, View and ctrl+click; the lighter shows
`Sync:off`. `texsync-mode` now has an (empty) keymap so a key can be bound to it. `make test`
12 / 12 (1 new). Decision (Claude): no default key (`C-c` + letter is the user's).

**Note for next time.** After changing texsync, the running daemon must reload it
(`emacsclient --eval '(load "~/repos/texsync/texsync.el" nil t)'`) or be restarted; a new
GUI Emacs is not enough when the user works in daemon frames.

## 2026-10-03 12:09 CEST — "texsync mode is off now?": a PDF without SyncTeX data

**Report (user).** texsync looked switched off on a lecture deck.

**Found (read-only, in the user's Emacs daemon).** `texsync-mode` on, following on, the right
PDF shown with `texsync-pdf-mode`, mode line "Sync". But every SyncTeX lookup failed: epdfinfo
"Unable to create synctex scanner". The deck's `build/` had the PDF from 00:10 and no
`.synctex.gz`, nor latexmk's `.fls` / `.fdb_latexmk`: built by a plain pdflatex run without
`-synctex=1` (no Makefile in that folder). A likely source: the one-off compile command in the
user's CLAUDE.md has no `-synctex=1`, so PDFs built by agents following it cannot be synced. The
memo also kept the failed (nil) answers for that PDF version.

**Mistake.** My first check read the missing `.synctex.gz`'s modification time as 12:05
(`file-attributes` of a missing file is nil, which `format-time-string` prints as "now"), and
I briefly took it for a broken rebuild.

**Done.** Rebuilt the deck with `texsync-compile` in the daemon (6 s): `.synctex.gz` written
(115 KB), point's line 26 → slide 4. Code: `texsync--ensure-synctex` (rebuild once per PDF
version, forced, with a message), `texsync-compile` FORCE (`-g`), memo keyed on the SyncTeX
file too. `make test` 13 / 13. LOG.md started (change log, as the user's CLAUDE.md asks).

**Open.** Whether the user's CLAUDE.md compile command should carry `-synctex=1` (asked).

## 2026-10-03 21:33 CEST — Renamed emacs-texsync

**Decision (user).** The repository is called `emacs-texsync`, public on the user's GitHub; the
local folder follows (`~/repos/emacs-texsync`). The Omarchy theme follower stays in the private
`omarchy-customizations`.

**Done.** `gh repo rename emacs-texsync` (GitHub redirects the old URL; the local `origin`
follows). README, `texsync.el`'s URL header and `try.el` name the new repository and folder; the
package, its modes and its file keep the name `texsync`. The user's init file (in
`omarchy-customizations`) loads it from `~/repos/emacs-texsync`. Moving the folder itself, and
this session's history with it, is a command the user runs after closing the session.

## 2026-10-03 21:43 CEST — Builds made by agents now carry SyncTeX data

**Decision (user).** The one-off compile command in the user's global agent instructions gets
`-synctex=1` (pdflatex and latexmk forms), with a line saying why: texsync, and ctrl+click in
viewers, need `build/file.synctex.gz`. This closes the open question of the 12:09 entry; texsync
keeps rebuilding a PDF that lacks the file, for builds made some other way.

**Also.** The user's guard hook against LaTeX runs without an output directory no longer
mistakes data for commands (quoted strings, here-document bodies; the script of `bash -c` is
still checked). Its 18 test cases pass; the old hook got 6 wrong, one a real miss
(`bash -c "<engine> … 2>&1"` under `systemd-run`).

