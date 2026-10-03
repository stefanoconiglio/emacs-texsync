# emacs-texsync

Emacs minor mode: LaTeX source on the left, its PDF (pdf-tools) on the right, kept in step.
The package and its modes are called `texsync` (`texsync.el`, `texsync-mode`); the repository
was called `texsync` until 2026-10-03.

- Move or scroll in the source → the PDF follows: Beamer shows the frame's slide, other
  documents scroll so the line at point is at the same height in both windows.
- Scroll or page the PDF → the source follows: the frame of the slide, or the line typeset a
  third of the way down the PDF, at the same height. The window you act on leads.
- Ctrl+click (or double-click) in the PDF → jump to the exact source.
- Save, or pause 1.5 s after typing → latexmk compiles into `build/` and the PDF reloads.
  The pause **saves the file**; `(setq texsync-compile-idle-delay nil)` compiles only when you
  save. `C-c C-c` is no longer needed (if you use it, texsync waits for AUCTeX's run).
- `C-c C-v` (AUCTeX View) opens the PDF window at the place of point.

Needs graphical Emacs (not `emacs -nw`), [pdf-tools](https://github.com/vedang/pdf-tools)
with continuous scrolling (`pdf-roll.el`), AUCTeX and latexmk. Tested with Emacs 31.1 (pgtk,
Wayland), pdf-tools 20260102 from MELPA, AUCTeX 14.1.2 and TeX Live. How it works:
[DESIGN.md](DESIGN.md); what was tried and measured: [RESEARCH_LOG.md](RESEARCH_LOG.md).

## Install

```
git clone https://github.com/stefanoconiglio/emacs-texsync ~/repos/emacs-texsync
```

then the Setup below, with that path.

## Try it

```
/usr/bin/emacs -Q -l ~/repos/emacs-texsync/try.el FILE.tex
```

Then `C-c C-v`. Your own init file is not loaded.

## Setup

```elisp
(add-to-list 'load-path "~/repos/emacs-texsync")  ; your clone
(require 'texsync)
(pdf-tools-install :no-query)
;; texsync in graphical frames; terminal Emacs keeps its usual viewer
(add-hook 'LaTeX-mode-hook
          (lambda () (when (display-graphic-p) (texsync-mode 1))))
```

For a file `\input` by a main file in another directory, set `TeX-master` (texsync guesses it
only when exactly one file in the same directory inputs it).

## What it is, and switching it off

Two minor modes; the major modes stay AUCTeX's LaTeX mode and pdf-tools' PDF view.

- `texsync-mode`, in a `.tex` buffer (the setup below turns it on in graphical Emacs). The
  mode line shows **Sync**, or **Sync:off** while following is paused.
- `texsync-pdf-mode`, turned on by texsync in the PDF buffer it shows: ctrl+click and
  double-click jump to the source.

Two ways to stop it:

- **`M-x texsync-toggle-follow`** pauses the following, both ways, for the whole document (all
  its files), from a source buffer or from the PDF. Compiling, `C-c C-v` and ctrl+click keep
  working. Run it again to resume: the PDF then jumps to the place of point. With a prefix
  argument it switches on (positive) or off (zero or negative). It has no key of its own; bind
  one if you use it often, e.g. `(keymap-set texsync-mode-map "C-c t" #'texsync-toggle-follow)`.
- **`M-x texsync-mode`** turns texsync off in that buffer altogether: no following, no
  compiling on save or pause, and AUCTeX's View goes back to your usual viewer.

## Options

`M-x customize-group RET texsync`:

- `texsync-output-dir` (`"build"`): latexmk's output directory, relative to the main file.
- `texsync-compile-idle-delay` (1.5 s; nil: compile only on save).
- `texsync-compile-on-save` (t).
- `texsync-sync-delay` (0.15 s after the last motion).
- `texsync-beamer-overlay` (`last`; or `first`): which overlay of a frame to show.
- `texsync-pdf-anchor` (0.33): height in the PDF window whose text the source follows.
- `texsync-structural-line-regexp`, `texsync-search-radius`: lines skipped when looking for a
  position.

Commands: `texsync-view`, `texsync-sync`, `texsync-compile` (with `C-u`, a forced rebuild),
`texsync-toggle-follow`.

A PDF built by something else without `-synctex=1` (a plain `pdflatex` run, a Makefile) cannot
be synced: texsync says so in the echo area and rebuilds it once with latexmk. If you also build
your documents some other way, pass `-synctex=1` there too.

## Tests

```
make test       # batch ERT tests; compile the fixtures with latexmk
make gui-test   # takes over the screen (fullscreen Emacs) for about a minute
```

## License

GPL-3.0-or-later, like Emacs, AUCTeX and pdf-tools. See [LICENSE](LICENSE).
