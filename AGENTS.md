# Working on texsync

For an agent (or a person) changing this repository.

- **Read first:** DESIGN.md (the code as it is: algorithms, options, tests) and RESEARCH_LOG.md
  (what was tried, measured, and got wrong). Most of the subtle points are in the log.
- **Keep them current:** a change to structure, algorithms, options or tests updates DESIGN.md in
  the same commit; each experiment, finding or decision gets a dated entry in RESEARCH_LOG.md
  (time from `date`), negative results and mistakes included.
- **Tests:** `make compile` (warnings are errors) and `make test` (batch ERT, headless, ~10 s;
  needs latexmk and pdf-tools' epdfinfo) before every commit.
- **`make gui-test` opens a fullscreen Emacs for about a minute and takes over the screen.** Run
  it only when the machine is free, and ask the person at it first. Its checks send keys and
  mouse events through `execute-kbd-macro`, so the command loop and timers run as for a user;
  a check that calls a function directly does not test what a click or a key does.
- **LaTeX output never goes into a source directory:** compile with `latexmk -outdir=build` (or
  `pdflatex -output-directory=build`), creating `build/` first.
- **pdf-tools pitfalls met so far** (details in the log): per-window state lives in the PDF
  buffer (read it there); pdf-roll draws pages lazily (size pages with
  `pdf-view-desired-image-size`); clicks on text come through an image-map proxy command that
  re-queues the event; the ctrl+press is a drag tracker that drops the release.
- **Batch Emacs:** file-notify events and pdf-tools' re-queued clicks arrive through the input
  queue; wait with `read-event`, not `accept-process-output` or `sit-for`.
