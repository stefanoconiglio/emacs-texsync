# emacs-latex-dyad

Emacs minor mode: LaTeX source on the left, its PDF (pdf-tools) on the right, kept in step.
The package and its modes are called `dyad` (`dyad.el`, `dyad-mode`), after the two bound
as one. It was called `texsync` until 2026-10-23, a name too close to SyncTeX, the TeX
engines' map between source and PDF that it reads for every jump.

- Move or scroll in the source → the PDF follows: Beamer shows the frame's slide, other
  documents scroll so the line at point is at the same height in both windows.
- Scroll or page the PDF → the source follows: the frame of the slide, or the line typeset a
  third of the way down the PDF, at the same height. The window you act on leads.
- Ctrl+click (or double-click) in the PDF → jump to the exact source.
- Save → latexmk compiles into `build/` and the PDF reloads. Nothing compiles until you save.
  To compile also after a pause in typing (which then saves the file for you), set
  `dyad-compile-idle-delay` to a number of seconds. `C-c C-c` is no longer needed (if you use
  it, dyad waits for AUCTeX's run).
- `C-c C-v` (AUCTeX View) opens the PDF window at the place of point.
- While anything rebuilds the PDF (dyad, AUCTeX, a script or an agent running latexmk, VS
  Code), you keep seeing the previous one: the PDF window shows a copy, replaced only by a
  finished build. A build made by another program shows as soon as it is finished.

Needs graphical Emacs (not `emacs -nw`), [pdf-tools](https://github.com/vedang/pdf-tools)
with continuous scrolling (`pdf-roll.el`), AUCTeX and latexmk. Tested with Emacs 31.1 (pgtk,
Wayland), pdf-tools 20260102 from MELPA, AUCTeX 14.1.2 and TeX Live.

## How it works

- **SyncTeX, through pdf-tools.** latexmk builds with `-synctex=1`, and every jump between the
  source and the PDF is a SyncTeX search answered by pdf-tools' `epdfinfo`.
- **Beamer goes by frame, not by line.** Beamer typesets a frame's body only at `\end{frame}`, so
  every SyncTeX record of a frame points to that line, and a line near a frame's top would land a
  slide early. dyad searches with the `\end{frame}` of the frame around point instead: on a
  73-slide deck that was right for every frame, where line by line was right for about half of
  the lines.
- **Other documents go by height.** The line at point is shown at the same height in the PDF as
  in the source. Lines with unreliable records (blank lines, `\begin`/`\end`, `\label`,
  `\input`…) borrow the position of a nearby line of text.
- **The window you last acted on leads**, decided after every command (for the mouse wheel, the
  window under the pointer); the other one follows after a short pause (`dyad-sync-delay`).
  From the PDF, the source follows the line typeset at `dyad-pdf-anchor` (a third of the way
  down).
- **The PDF shown is a copy.** pdflatex rewrites its PDF in place while it runs, and pdf-tools
  reading it then shows garbage. So dyad shows a copy (in `dyad-view-directory`) and
  replaces it only when a build has finished, whoever started that build.

## Install

```
git clone https://github.com/stefanoconiglio/emacs-latex-dyad ~/repos/emacs-latex-dyad
```

then the Setup below, with that path.

## Try it

```
/usr/bin/emacs -Q -l ~/repos/emacs-latex-dyad/try.el FILE.tex
```

Then `C-c C-v`. Your own init file is not loaded.

## Setup

```elisp
(add-to-list 'load-path "~/repos/emacs-latex-dyad")  ; your clone
(require 'dyad)
(pdf-tools-install :no-query)
;; dyad in graphical frames; terminal Emacs keeps its usual viewer
(add-hook 'LaTeX-mode-hook
          (lambda () (when (display-graphic-p) (dyad-mode 1))))
```

For a file `\input` by a main file in another directory, set `TeX-master` (dyad guesses it
only when exactly one file in the same directory inputs it).

`TeX-master` can also come from the file's local variables or from a `.dir-locals.el`. One
`.dir-locals.el` line, for example, makes every deck of a folder follow a combined PDF built from
a file that `\input`s them all, even though each deck is a document of its own:

```elisp
((nil . ((TeX-master . "all-decks.tex"))))
```

## What it is, and switching it off

Two minor modes; the major modes stay AUCTeX's LaTeX mode and pdf-tools' PDF view.

- `dyad-mode`, in a `.tex` buffer (the setup below turns it on in graphical Emacs). The
  mode line shows **Sync**, or **Sync:off** while following is paused.
- `dyad-pdf-mode`, turned on by dyad in the PDF buffer it shows: ctrl+click and
  double-click jump to the source.

Under the PDF, a small pane shows the build log: latexmk's output scrolls past while it works,
and its top line says **Building ... 12 s**, **Built in 6.2 s at 23:10** or **Build FAILED**.
`(setq dyad-log-height nil)` removes the pane; a number sets its height in lines (6).
While the PDF is being built, both mode lines also say **Building 12s** (counting); after a
failed build they say **Build failed** until the next good one (click it for the build log).
Saving again after a failed build with nothing changed makes latexmk refuse to try again ("gave
an error in previous invocation"); dyad then forces one rebuild, so the log shows the real
errors, and a build that failed only because of a bad helper file in `build/` can succeed. Builds
started by another program (VS Code, a terminal) show too, once dyad sees pdflatex running.

The PDF's size: dyad fits a slide to its pane (`P` in the PDF) and a paper's page to the
pane's width (`W`). `+` and `-` zoom to a fixed size, which stays when the pane is resized
later, so a slide can end up larger than its pane; `P` or `W` fits it again. `0` shows the
page at 100%, not fitted.

Two ways to stop it:

- **`M-x dyad-toggle-follow`** pauses the following, both ways, for the whole document (all
  its files), from a source buffer or from the PDF. Compiling, `C-c C-v` and ctrl+click keep
  working. Run it again to resume: the PDF then jumps to the place of point. With a prefix
  argument it switches on (positive) or off (zero or negative). It has no key of its own; bind
  one if you use it often, e.g. `(keymap-set dyad-mode-map "C-c t" #'dyad-toggle-follow)`.
- **`M-x dyad-mode`** turns dyad off in that buffer altogether: no following, no
  compiling on save, and AUCTeX's View goes back to your usual viewer.

## A book: lectures built one by one, shown glued (off by default)

A book, a main file whose body includes whole documents (a course file with `\input`s of
lectures through the docmute package, for example), is built and shown as one document, like
any other. With `(setq dyad-glue t)`, dyad instead builds each lecture on its own and
shows them glued into one PDF:

- saving a lecture rebuilds only that lecture (a few seconds instead of the whole course);
- the glued PDF syncs both ways, ctrl+click included, through each lecture's own SyncTeX data;
- it is a preview: page numbers are each lecture's own, the pages the course file adds
  (`\part` pages) are absent, and the section list (`o` in the PDF) is empty;
- `M-x dyad-compile-whole` builds the real course, as one document, into `build/` (to hand
  out).

Needs `qpdf`.

## Options

`M-x customize-group RET dyad`:

- `dyad-output-dir` (`"build"`): latexmk's output directory, relative to the main file.
- `dyad-view-directory` (`~/.cache/dyad`): where the copies of the PDFs shown live, one
  folder per document, deleted when its PDF buffer is killed or Emacs exits (and, if left by a
  crash, after 7 days unused).
- `dyad-glue` (nil): t builds a book lecture by lecture and shows the lectures glued.
- `dyad-log-height` (6): lines of the build log pane under the PDF; nil: no pane.
- `dyad-compile-idle-delay` (nil: compile only when you save; a number of seconds: also after
  that long without typing, saving the file first).
- `dyad-compile-on-save` (t).
- `dyad-sync-delay` (0.15 s after the last motion).
- `dyad-beamer-overlay` (`last`; or `first`): which overlay of a frame to show.
- `dyad-pdf-anchor` (0.33): height in the PDF window whose text the source follows.
- `dyad-structural-line-regexp`, `dyad-search-radius`: lines skipped when looking for a
  position.

Commands: `dyad-view`, `dyad-sync`, `dyad-compile` (with `C-u`, a forced rebuild),
`dyad-compile-whole` (a book as one document), `dyad-toggle-follow`.

A PDF built by something else without `-synctex=1` (a plain `pdflatex` run, a Makefile) cannot
be synced: dyad says so in the echo area and rebuilds it once with latexmk. If you also build
your documents some other way, pass `-synctex=1` there too.

## Tests

```
make test       # batch ERT tests; compile the fixtures with latexmk
make gui-test   # takes over the screen (fullscreen Emacs) for about a minute
```

## License

GPL-3.0-or-later, like Emacs, AUCTeX and pdf-tools. See [LICENSE](LICENSE).
