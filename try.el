;;; try.el --- Try dyad without touching your init file  -*- lexical-binding: t -*-

;; /usr/bin/emacs -Q -l ~/repos/emacs-dyad/try.el FILE.tex
;;
;; Opens FILE.tex with dyad-mode on.
;; C-c C-v shows the PDF on the right (compiling first if build/ has none).
;; Saving recompiles.

;;; Code:

(package-initialize)
(require 'pdf-tools)
(pdf-tools-install :no-query)
(add-to-list 'load-path (file-name-directory load-file-name))
(require 'dyad)
(setq inhibit-startup-screen t)
(add-hook 'LaTeX-mode-hook #'dyad-mode)
;; With omarchy-follow on the load path (-L DIR), Emacs and the PDF also take
;; the colours of the Omarchy theme.
(when (require 'omarchy-follow nil t)
  (omarchy-follow-mode 1))

;;; try.el ends here
