;;; gui-init.el --- smoke test: source left, pdf-tools right.  -*- lexical-binding: t -*-
(package-initialize)
(require 'pdf-tools)
(pdf-tools-install :no-query)
(setq frame-title-format "latexsync-smoke"
      inhibit-startup-screen t)
(require 'server)
(setq server-name "latexsync-smoke")
(server-start)
(let ((dir (file-name-directory load-file-name)))
  (find-file (expand-file-name "deck/deck.tex" dir))
  (delete-other-windows)
  (let ((right (split-window-right)))
    (with-selected-window right
      (find-file (expand-file-name "deck/build/deck.pdf" dir))
      (pdf-view-fit-page-to-window))))
