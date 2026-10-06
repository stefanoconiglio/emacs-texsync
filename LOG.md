# Change log

What changed in the code, per working session. What was tried, measured and concluded is in
RESEARCH_LOG.md; how the code works, in DESIGN.md.

## 2026-10-01

- `texsync.el` 0.1: source and pdf-tools PDF in one frame; Beamer by frame, papers at the same
  height; ctrl+click back; latexmk on save or pause (ec019d9).
- Main file from `% !TEX root` or `\begin{document}`; class from a preamble `\input` header or a
  `.nav` file (a0ba9df).
- Beamer `\section` slides both ways; one SyncTeX lookup per slide, frames in `\input` files;
  `.bbl`/`.toc`/`.vrb` answers sent to their source; answers memoized (544c92b).
- `texsync-toggle-follow` and an empty `texsync-mode-map` (6ff15e6).

## 2026-10-03

- `texsync--ensure-synctex`: a PDF without SyncTeX data (built without `-synctex=1`) is
  rebuilt once, forced, instead of every lookup failing quietly; checked in both directions.
- `texsync-compile` takes FORCE (prefix argument): latexmk `-g`.
- The memo of SyncTeX answers is also keyed on the SyncTeX file's modification time.
- Test `texsync-test-missing-synctex` (13 tests). DESIGN.md and README.md updated.
- Reported by the user as "texsync mode is off": it was on; the deck's PDF had been built at
  00:10 by a plain pdflatex run without SyncTeX. Rebuilt it through texsync in the user's Emacs.
- Repository renamed `texsync` → `emacs-texsync` on GitHub (the old URL redirects); local folder
  to become `~/repos/emacs-texsync`. README (title, clone line, paths), the URL header of
  `texsync.el` and `try.el`'s usage line updated. The package keeps its name, `texsync`.

## 2026-10-04

- `TeX-master` from a file's local variables or from `.dir-locals.el` is honoured: the main file
  is found again from a buffer-local `hack-local-variables-hook` (`texsync--find-master`, split
  out of `texsync-mode`). Before, the mode, turned on from `LaTeX-mode-hook`, cached the main
  file before Emacs applied those variables, and they were ignored.
- Test `texsync-test-local-master` (14 tests). DESIGN.md (main file, tests) and README.md
  (`TeX-master` from `.dir-locals.el`, with an example) updated.


## 2026-10-06

- `texsync-compile-idle-delay` defaults to nil: only saving compiles. The 1.5 s pause after an
  edit saved the buffer and rebuilt the PDF, far more often than wanted (user's report). The
  option still works when set to a number.
- Test `texsync-test-compile-only-on-save` (15 tests); the GUI test sets the delay itself for
  its idle-compile check. README, DESIGN.md, `try.el` and the mode's docstring say "saving
  compiles".
- RESEARCH_LOG.md: three decision labels no longer name an author.

## 2026-10-06 (evening)

- The PDF window shows a copy of latexmk's PDF (`texsync-view-directory`, default
  `~/.cache/texsync`), replaced only by a finished build (`texsync--refresh-view`: `%%EOF`, no
  `.synctex(busy)`, copied to temporary names and renamed, the PDF last). `texsync--pdf-file` now
  names the copy, `texsync--built-pdf` latexmk's file.
- Builds by other programs are shown once settled: `texsync--poll`, every second while a copy is
  shown; a buffer visiting latexmk's PDF is switched over to the copy; the copy is deleted with
  its buffer; the frame ranges come from the copy's `.nav`.
- The cache stays bounded: copies deleted with their buffer, all of this Emacs's on
  `kill-emacs-hook`, and directories unused for 7 days when texsync loads; never outside
  `texsync-view-directory`.
- Tests: five new (copy and half-written build refused, PDF readable during a compile, build by
  another program, buffer switched over, cache pruning); the compile helper copies the build;
  the GUI test keeps its copies in a temporary directory; 20 / 20.

## 2026-10-06 (night)

- Build status in the mode lines: `Building Ns` while a build runs (the source's lighter and a new
  lighter for `texsync-pdf-mode`), `Build failed` after a failed texsync build until a good one
  (mouse-1: the log buffer); `texsync: built <main> in N s` in the echo area.
  `texsync--builds`, `texsync--failed`, `texsync--status`, `texsync--lighter`,
  `texsync--pdf-lighter`, a 1 s ticker while a build runs; `texsync--poll-master` sees other
  programs' builds through `.synctex(busy)` (stale after 2 min).
- Test `texsync-test-build-status` (21 tests). DESIGN.md (Compiling, Tests) and README.
