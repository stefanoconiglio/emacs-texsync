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
