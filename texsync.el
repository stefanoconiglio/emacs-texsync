;;; texsync.el --- Keep a pdf-tools view in step with the LaTeX source  -*- lexical-binding: t -*-

;; Author: Stefano Coniglio
;; URL: https://github.com/stefanoconiglio/texsync
;; Version: 0.1
;; Package-Requires: ((emacs "29.1") (pdf-tools "1.1"))
;; Keywords: tex
;; SPDX-License-Identifier: GPL-3.0-or-later

;; This program is free software: you can redistribute it and/or modify it
;; under the terms of the GNU General Public License as published by the Free
;; Software Foundation, either version 3 of the License, or (at your option)
;; any later version.  See the file LICENSE.

;;; Commentary:

;; `texsync-mode' shows the PDF of a LaTeX document in a pdf-tools window
;; beside the source and keeps the two in step, both ways:
;;
;; - Moving or scrolling in the source moves the PDF: Beamer shows the slide
;;   of the frame around point; other documents scroll so that the line at
;;   point sits at the same height in both windows.
;; - Scrolling or paging the PDF moves the source: the frame of the slide
;;   shown, or the line typeset a third of the way down the PDF window.
;;   Whichever window the last command acted on leads.
;; - Ctrl+click (or double-click) in the PDF jumps to the source (pdf-sync).
;; - Saving compiles with latexmk into `texsync-output-dir'; so does a pause
;;   in typing (`texsync-compile-idle-delay').
;;
;; DESIGN.md explains how and why.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'pdf-info)
(require 'pdf-view)
(require 'pdf-sync)
(require 'pdf-roll nil t)

(defvar TeX-master)
(defvar texsync-mode)
(defvar TeX-output-dir)
(defvar TeX-view-program-list)
(defvar TeX-view-program-selection)
(defvar pdf-view-roll-minor-mode)
(defvar pdf-roll-vertical-margin)
(declare-function pdf-roll-set-vscroll "pdf-roll")
(declare-function pdf-roll-page-overlay "pdf-roll")
(declare-function TeX-process "tex")
(declare-function TeX-master-file "tex")
(declare-function pdf-view-roll-minor-mode "pdf-roll")

;;;; Options

(defgroup texsync nil
  "Keep a pdf-tools view in step with the LaTeX source."
  :group 'tex
  :prefix "texsync-")

(defcustom texsync-output-dir "build"
  "Directory, relative to the main file, that receives latexmk's output."
  :type 'string)

(defcustom texsync-latexmk-command
  '("latexmk" "-pdf" "-synctex=1" "-interaction=nonstopmode" "-file-line-error")
  "Command and options for latexmk.
`-outdir=' with `texsync-output-dir' and the main file are appended."
  :type '(repeat string))

(defcustom texsync-compile-on-save t
  "Non-nil means saving a source file compiles its main file."
  :type 'boolean)

(defcustom texsync-compile-idle-delay 1.5
  "Seconds of idleness after an edit before the buffer is saved and compiled.
nil means only an explicit save compiles."
  :type '(choice (const :tag "Off" nil) number))

(defcustom texsync-sync-delay 0.15
  "Seconds after the last cursor motion or scroll before the PDF follows."
  :type 'number)

(defcustom texsync-beamer-overlay 'last
  "Which overlay of a Beamer frame to show: `first' or `last'."
  :type '(choice (const first) (const last)))

(defcustom texsync-structural-line-regexp
  (concat
   ;; blank or comment-only
   "^[ \t]*\\(?:%.*\\)?$"
   ;; a lone \begin{..} or \end{..}, possibly with a \label
   "\\|^[ \t]*\\\\\\(?:begin\\|end\\){[^}]*}[ \t]*"
   "\\(?:\\\\label{[^}]*}\\)?[ \t]*\\(?:%.*\\)?$"
   ;; commands that typeset nothing at their own line
   "\\|^[ \t]*\\\\\\(?:input\\|include\\|label\\|clearpage\\|newpage"
   "\\|pagebreak\\|maketitle\\|bibliographystyle\\|bibliography\\)\\_>")
  "Lines whose SyncTeX position is unreliable.
For such a line the PDF follows the nearest line that is not one."
  :type 'regexp)

(defcustom texsync-pdf-anchor 0.33
  "Height in the PDF window, as a fraction, whose text the source follows.
When the PDF leads, the source line typeset there is put at the same
height of the source window."
  :type 'number)

(defcustom texsync-search-radius 8
  "How many lines above and below point to try when point's line has no position."
  :type 'integer)

;;;; State

(defvar-local texsync--master nil
  "Cached absolute name of the main file of this buffer.")

(defvar texsync--timer nil
  "The pending sync, in either direction: the window acted on last leads.")
(defvar-local texsync--idle-timer nil)
(defvar-local texsync--last nil
  "The last placement: target and the PDF window state right after it.")
(defvar-local texsync--suppress-until 0
  "`float-time' before which automatic syncing is skipped (after a backward jump).")
(defvar-local texsync--configured nil
  "Non-nil in a PDF buffer that texsync has set up.")

(defvar texsync--processes (make-hash-table :test 'equal)
  "Main file -> running latexmk process.")
(defvar texsync--pending (make-hash-table :test 'equal)
  "Main files whose sources changed while latexmk was running.")
(defvar texsync--show-after (make-hash-table :test 'equal)
  "Main file -> source buffer that asked to see the PDF once it exists.")
(defvar texsync--file-cache (make-hash-table :test 'equal)
  "(KIND . FILE) -> (MTIME . VALUE), for facts read from files.")

;;;; Files

(defun texsync--cached (kind file fn)
  "Value of FN on FILE, recomputed only when FILE's mtime changes.
KIND separates different facts about the same file."
  (let* ((mtime (file-attribute-modification-time (file-attributes file)))
         (key (cons kind file))
         (hit (gethash key texsync--file-cache)))
    (if (and hit (equal (car hit) mtime))
        (cdr hit)
      (let ((v (funcall fn file)))
        (puthash key (cons mtime v) texsync--file-cache)
        v))))

(defun texsync--read-head (file)
  "First 20000 characters of FILE, as a string."
  (with-temp-buffer
    (insert-file-contents file nil 0 20000)
    (buffer-string)))

(defconst texsync--documentclass-re "^[^%\n]*\\\\documentclass\\(?:\\[[^]]*\\]\\)?{\\([^}]*\\)}")

(defun texsync--documentclass (file)
  "The document class named in FILE, or nil if FILE has no \\documentclass."
  (texsync--cached
   'class file
   (lambda (f)
     (let ((head (texsync--read-head f)))
       (when (string-match texsync--documentclass-re head)
         (match-string 1 head))))))

(defun texsync--inputs-p (main file)
  "Non-nil when MAIN \\input's, \\include's or \\subfile's FILE."
  (let ((base (file-name-sans-extension (file-name-nondirectory file))))
    (with-temp-buffer
      (insert-file-contents main)
      (goto-char (point-min))
      (re-search-forward
       (concat "^[^%\n]*\\\\\\(?:input\\|include\\|subfile\\){[ \t]*\\(?:\\./\\)?"
               (regexp-quote base) "\\(?:\\.tex\\)?[ \t]*}")
       nil t))))

(defun texsync-guess-master (file)
  "The main file of FILE when exactly one candidate exists, else nil.
A candidate is a .tex file in FILE's directory that has a
\\documentclass and inputs FILE."
  (let ((cands (cl-remove-if-not
                (lambda (f)
                  (and (not (file-equal-p f file))
                       (texsync--documentclass f)
                       (texsync--inputs-p f file)))
                (directory-files (file-name-directory file) t "\\.tex\\'"))))
    (when (= (length cands) 1)
      (car cands))))

(defun texsync-master-file ()
  "Absolute name of the main .tex file of the current buffer, or nil."
  (or texsync--master
      (setq texsync--master
            (when-let* ((file (buffer-file-name)))
              (cond
               ((and (boundp 'TeX-master) (stringp TeX-master))
                (let ((m (expand-file-name TeX-master (file-name-directory file))))
                  (if (file-name-extension m) m (concat m ".tex"))))
               ((save-excursion
                  (save-restriction
                    (widen)
                    (goto-char (point-min))
                    (re-search-forward texsync--documentclass-re nil t)))
                file)
               (t (texsync-guess-master file)))))))

(defun texsync--outdir (master)
  "Absolute output directory of MASTER."
  (expand-file-name texsync-output-dir (file-name-directory master)))

(defun texsync--pdf-file (master)
  "The PDF that latexmk makes from MASTER."
  (expand-file-name (concat (file-name-base master) ".pdf") (texsync--outdir master)))

(defun texsync--beamer-p (master)
  "Non-nil when MASTER is a Beamer document."
  (equal (texsync--documentclass master) "beamer"))

(defun texsync--nav-ranges (master)
  "Page ranges (FIRST . LAST) of the frames of MASTER, from its .nav file."
  (let ((nav (expand-file-name (concat (file-name-base master) ".nav")
                               (texsync--outdir master))))
    (when (file-readable-p nav)
      (texsync--cached
       'nav nav
       (lambda (f)
         (with-temp-buffer
           (insert-file-contents f)
           (goto-char (point-min))
           (let (ranges)
             (while (re-search-forward
                     "\\\\beamer@framepages *{\\([0-9]+\\)}{\\([0-9]+\\)}" nil t)
               (push (cons (string-to-number (match-string 1))
                           (string-to-number (match-string 2)))
                     ranges))
             (nreverse ranges))))))))

;;;; Source positions

(defun texsync--code-search (regexp backward)
  "Move to the next match of REGEXP outside a comment; nil if none.
Search backwards when BACKWARD is non-nil.  Point ends at the match start."
  (let (found)
    (while (and (not found)
                (if backward
                    (re-search-backward regexp nil t)
                  (re-search-forward regexp nil t)))
      (let ((start (match-beginning 0)))
        (unless (save-excursion
                  (goto-char start)
                  (re-search-backward "\\(?:^\\|[^\\]\\)%" (line-beginning-position) t))
          (goto-char start)
          (setq found start))
        (unless (or found backward)
          (goto-char (1+ start)))))
    found))

(defun texsync-frame-bounds ()
  "Line numbers (BEGIN . END) of the Beamer frame around point, or nil."
  (save-excursion
    (save-restriction
      (widen)
      (let ((line (line-number-at-pos)))
        (end-of-line)
        (when (texsync--code-search "\\\\begin{frame}" t)
          (let ((b (line-number-at-pos)))
            (forward-char 1)
            (when (texsync--code-search "\\\\end{frame}" nil)
              (let ((e (line-number-at-pos)))
                (when (>= e line)
                  (cons b e))))))))))

(defun texsync--structural-p (line)
  "Non-nil when LINE of the current buffer is a structural line."
  (save-excursion
    (goto-char (point-min))
    (forward-line (1- line))
    (looking-at-p texsync-structural-line-regexp)))

(defun texsync--candidate-lines (line last)
  "LINE, then the lines around it, nearest first and upward first, within 1..LAST."
  (cons line
        (cl-loop for d from 1 to texsync-search-radius
                 append (cl-remove-if-not (lambda (l) (<= 1 l last))
                                          (list (- line d) (+ line d))))))

(defun texsync--forward (file line pdf)
  "SyncTeX forward search for LINE of FILE in PDF, or nil."
  (condition-case nil
      (pdf-info-synctex-forward-search file line 1 pdf)
    (error nil)))

(defun texsync--good-box-p (edges)
  "Non-nil when EDGES look like text, not an empty or page-sized box."
  (pcase-let ((`(,x1 ,y1 ,x2 ,y2) edges))
    (and (> (- x2 x1) 0.001) (< (- y2 y1) 0.5))))

(defun texsync-paper-target (pdf)
  "Where the line at point is in PDF, as (PAGE . Y).
Y is the top of the line's text as a fraction of the page height.
Structural lines and empty or page-sized boxes are skipped in favour
of the nearest other line."
  (let* ((file (buffer-file-name))
         (last (save-restriction (widen) (line-number-at-pos (point-max)))))
    (cl-loop for l in (texsync--candidate-lines (line-number-at-pos) last)
             for r = (and (not (texsync--structural-p l))
                          (texsync--forward file l pdf))
             when (and r (texsync--good-box-p (alist-get 'edges r)))
             return (cons (alist-get 'page r) (nth 1 (alist-get 'edges r))))))

(defun texsync-beamer-target (pdf master)
  "The PDF page of the frame around point, or nil outside frames.
Beamer typesets a frame at its \\end{frame} line, so that is the line
looked up; `texsync-beamer-overlay' picks the overlay."
  (when-let* ((fb (texsync-frame-bounds))
              (r (texsync--forward (buffer-file-name) (cdr fb) pdf)))
    (texsync-overlay-page (alist-get 'page r) (texsync--nav-ranges master))))

(defun texsync-overlay-page (page ranges)
  "The page to show for a frame that SyncTeX puts on PAGE, given frame RANGES."
  (let ((r (cl-find-if (lambda (r) (<= (car r) page (cdr r))) ranges)))
    (cond ((null r) page)
          ((eq texsync-beamer-overlay 'last) (cdr r))
          (t (car r)))))

(defun texsync--point-fraction ()
  "Height of point's line in the selected window, as a fraction of its height."
  ;; A long wrapped line may begin above the window start.
  (when-let* ((xy (posn-x-y (posn-at-point (max (line-beginning-position)
                                                (window-start))))))
    (min 1.0 (max 0.0 (/ (float (cdr xy)) (max 1 (window-body-height nil t)))))))

;;;; The PDF window

(defun texsync--pdf-buffer (pdf create)
  "The buffer visiting PDF; with CREATE, visit it if needed."
  (or (find-buffer-visiting pdf)
      (when create
        (let ((buf (let ((large-file-warning-threshold nil))
                     (find-file-noselect pdf))))
          ;; Without `pdf-tools-install', .pdf files open in doc-view.
          (with-current-buffer buf
            (unless (derived-mode-p 'pdf-view-mode)
              (pdf-view-mode)))
          buf))))

(defun texsync--pdf-window (pbuf create)
  "A window of the selected frame that shows PBUF.
With CREATE, show PBUF in the window to the right, splitting if needed."
  (or (get-buffer-window pbuf)
      (when create
        (let ((w (or (window-in-direction 'right) (split-window-right))))
          (set-window-buffer w pbuf)
          w))))

(defvar texsync-pdf-mode-map
  (let ((map (make-sparse-keymap)))
    ;; pdf-view binds these presses to text selection, which follows the
    ;; mouse and drops the release if the pointer moves at all (a touchpad
    ;; click), so pdf-sync's jump bound to the release never runs.
    (define-key map [C-down-mouse-1] #'ignore)
    (define-key map [double-down-mouse-1] #'ignore)
    (define-key map [C-mouse-1] #'pdf-sync-backward-search-mouse)
    (define-key map [double-mouse-1] #'pdf-sync-backward-search-mouse)
    map)
  "Keys of `texsync-pdf-mode'.")

(define-minor-mode texsync-pdf-mode
  "In a PDF shown by texsync, ctrl+click or double-click jumps to the source."
  :keymap texsync-pdf-mode-map)

(defun texsync--setup-pdf (pwin beamer)
  "Set up the PDF buffer shown in PWIN once: fit, scrolling, no auto-revert.
BEAMER non-nil fits whole slides; otherwise pages scroll continuously."
  (with-selected-window pwin
    (unless texsync--configured
      (setq texsync--configured t)
      ;; texsync reverts after a successful compile; reverting mid-compile breaks.
      (setq-local global-auto-revert-ignore-buffer t)
      (when (bound-and-true-p auto-revert-mode) (auto-revert-mode -1))
      (unless (bound-and-true-p pdf-sync-minor-mode) (pdf-sync-minor-mode 1))
      (texsync-pdf-mode 1)
      (if beamer
          (pdf-view-fit-page-to-window)
        (when (fboundp 'pdf-view-roll-minor-mode)
          (pdf-view-roll-minor-mode 1)
          ;; Its mode-line indicator measures the selected window, which is
          ;; the source window here, and errors on every redisplay in roll mode.
          (when (bound-and-true-p pdf-misc-size-indication-minor-mode)
            (pdf-misc-size-indication-minor-mode -1)))
        (pdf-view-fit-width-to-window)))))

(defun texsync--window-state (pwin)
  "What a user's scrolling in PWIN would change."
  ;; pdf-view keeps the page per window in the PDF buffer, not the source buffer.
  (with-current-buffer (window-buffer pwin)
    (list (pdf-view-current-page pwin) (window-vscroll pwin t) (window-start pwin))))

(defun texsync--pdf-state (pwin)
  "Page and vscroll of PWIN: what scrolling the PDF changes, set at once."
  (with-current-buffer (window-buffer pwin)
    (list (pdf-view-current-page pwin) (window-vscroll pwin t))))

(defun texsync--place (pwin target fn)
  "Call FN to show TARGET in PWIN, unless PWIN is still where TARGET left it."
  (unless (and (equal (car texsync--last) target)
               (equal (cdr texsync--last) (texsync--window-state pwin)))
    (funcall fn)
    (setq texsync--last (cons target (texsync--window-state pwin))))
  ;; The PDF now agrees with the source: no reason for it to lead.
  (set-window-parameter pwin 'texsync-synced (texsync--pdf-state pwin)))

(defun texsync--show-page (pwin page)
  "Show PAGE in PWIN."
  (with-selected-window pwin
    (unless (eq page (pdf-view-current-page))
      (pdf-view-goto-page page))))

(defun texsync--page-height (pwin page)
  "Displayed height in pixels of PAGE in PWIN, without rendering it.
pdf-roll renders pages lazily; asking a not yet rendered page for its
image size signals an error."
  (with-current-buffer (window-buffer pwin)
    (cdr (pdf-view-desired-image-size page pwin))))

(defun texsync--show-position (pwin page y frac)
  "Scroll PWIN so that height Y of PAGE (a fraction) is at FRAC of its height."
  (with-selected-window pwin
    ;; After a revert, roll mode builds its page overlays at the next redisplay.
    (when (and (bound-and-true-p pdf-view-roll-minor-mode)
               (not (pdf-roll-page-overlay 1 pwin)))
      (redisplay t))
    (let ((offset (round (- (* y (texsync--page-height pwin page))
                            (* frac (window-body-height pwin t))))))
      (if (bound-and-true-p pdf-view-roll-minor-mode)
          (progn
            ;; A negative offset starts the window on an earlier page.
            (while (and (< offset 0) (> page 1))
              (setq page (1- page)
                    offset (+ offset pdf-roll-vertical-margin
                              (texsync--page-height pwin page))))
            (setf (pdf-view-current-page pwin) page)
            (pdf-roll-set-vscroll (max 0 offset) pwin)
            (force-window-update pwin))
        (unless (eq page (pdf-view-current-page))
          (pdf-view-goto-page page))
        (image-set-window-vscroll (max 0 offset))))))

;;;; Syncing

(defun texsync-sync (&optional display)
  "Make the PDF show the place of point.
With DISPLAY (interactively), open and show the PDF if it is not shown."
  (interactive (list t))
  (let* ((master (texsync-master-file))
         (pdf (and master (texsync--pdf-file master))))
    (cond
     ((null master)
      (when display
        (user-error "texsync: cannot tell the main file; set `TeX-master'")))
     ((not (file-exists-p pdf))
      (when display
        (puthash master (current-buffer) texsync--show-after)
        (texsync-compile master)
        (message "texsync: compiling %s; the PDF opens when it is ready"
                 (file-name-nondirectory master))))
     (t
      (when-let* ((pbuf (texsync--pdf-buffer pdf display))
                  (pwin (texsync--pdf-window pbuf display)))
        (let ((beamer (texsync--beamer-p master)))
          (texsync--setup-pdf pwin beamer)
          (if beamer
              (when-let* ((page (texsync-beamer-target pdf master)))
                (texsync--place pwin page
                                (lambda () (texsync--show-page pwin page))))
            (when-let* ((target (texsync-paper-target pdf))
                        (frac (texsync--point-fraction)))
              (texsync--place pwin (list (car target) (cdr target) frac)
                              (lambda ()
                                (texsync--show-position
                                 pwin (car target) (cdr target) frac)))))))))))

(defun texsync-view ()
  "Show the PDF at the place of point.  Used as AUCTeX's viewer."
  (interactive)
  (setq texsync--last nil)
  (texsync-sync t))

(defun texsync--sync-from (win)
  "Make the PDF follow the source shown in WIN."
  (when (window-live-p win)
    (with-current-buffer (window-buffer win)
      (when (and texsync-mode (>= (float-time) texsync--suppress-until))
        (with-selected-window win
          (condition-case err
              (texsync-sync)
            (error (message "texsync: %s" (error-message-string err)))))))))

(defvar texsync-trace 'off
  "Unless `off', a list onto which texsync pushes its scheduling decisions.")

(defun texsync--schedule (fn win)
  "Call FN on WIN after `texsync-sync-delay' seconds without further commands."
  (unless (eq texsync-trace 'off)
    (push (list (format-time-string "%T.%3N") fn (buffer-name (window-buffer win))
                this-command (car-safe last-input-event))
          texsync-trace))
  (when (timerp texsync--timer)
    (cancel-timer texsync--timer))
  (setq texsync--timer (run-with-timer texsync-sync-delay nil fn win)))

(defconst texsync--jump-commands
  '(pdf-sync-backward-search-mouse ignore pdf-util-image-map-mouse-event-proxy nil)
  "Commands in the PDF that must not make the source follow it.
The proxy re-sends clicks on text (an image-map area) without the area;
nil is an undefined key.")

(defun texsync--command-window ()
  "The window the last command acted on.
For mouse events, such as the wheel, the window under the pointer:
Emacs scrolls it without selecting it."
  (let ((ev last-input-event))
    (cond ((memq this-command '(scroll-other-window scroll-other-window-down))
           (ignore-errors (other-window-for-scrolling)))
          ((and (consp ev) (posnp (event-start ev))
                (windowp (posn-window (event-start ev))))
           (posn-window (event-start ev)))
          (t (selected-window)))))

(defun texsync--post-command ()
  "Let the window the last command acted on lead the next sync."
  (let* ((win (texsync--command-window))
         (buf (and (window-live-p win) (window-buffer win))))
    (when buf
      (cond ((buffer-local-value 'texsync-mode buf)
             (texsync--schedule #'texsync--sync-from win))
            ((and (buffer-local-value 'texsync-pdf-mode buf)
                  (not (memq this-command texsync--jump-commands))
                  (not (eq (car-safe last-input-event) 'mouse-movement))
                  ;; only when the command moved the PDF (not a click to select)
                  (not (equal (texsync--pdf-state win)
                              (window-parameter win 'texsync-synced))))
             (texsync--schedule #'texsync--sync-from-pdf win))))))

;;;; The PDF leads

(defun texsync--source-window (pdf)
  "A window of the selected frame with a texsync source whose PDF is PDF."
  (cl-find-if (lambda (w)
                (with-current-buffer (window-buffer w)
                  (and texsync-mode
                       (when-let* ((m (texsync-master-file)))
                         (equal (texsync--pdf-file m) pdf)))))
              (window-list nil 'nomini)))

(defun texsync--pdf-point-at (pwin frac)
  "(PAGE . Y) of the PDF at height FRAC of PWIN, Y a fraction of the page height."
  (with-selected-window pwin
    (let ((page (pdf-view-current-page))
          (px (+ (window-vscroll nil t) (* frac (window-body-height nil t)))))
      (when (bound-and-true-p pdf-view-roll-minor-mode)
        (let ((n (pdf-cache-number-of-pages)) h)
          (while (and (< page n)
                      (> px (setq h (texsync--page-height pwin page))))
            (setq px (- px h pdf-roll-vertical-margin)
                  page (1+ page)))))
      (cons page (min 1.0 (max 0.0 (/ px (float (texsync--page-height pwin page)))))))))

(defun texsync--file-line-structural-p (file line)
  "Non-nil when LINE of FILE is a structural line (see `texsync--structural-p')."
  (let ((buf (find-buffer-visiting file)))
    (if buf
        (with-current-buffer buf
          (save-restriction (widen) (texsync--structural-p line)))
      (with-temp-buffer
        (insert-file-contents file)
        (texsync--structural-p line)))))

(defun texsync--source-at (pdf page y)
  "Source of the text at height Y of PAGE, as (FILE LINE PAGE2 Y2), or nil.
PAGE2 and Y2 are where that line's text starts.  Heights around Y are
tried, nearest first.  A backward search result counts only if it is not
a structural line and a forward search of it starts on PAGE at or above
the height tried: between pages or in a margin, SyncTeX's nearest record
can belong to any line.  Only if no height gives such a line, a line
starting on the page before is taken (a long paragraph on one source
line)."
  (let (later)
    (or (cl-loop
         for dy in '(0 0.02 -0.02 0.04 -0.04 0.07 -0.07 0.1 -0.1 0.15 -0.15)
         for yy = (+ y dy)
         when (<= 0 yy 1)
         do (let* ((r (condition-case nil
                          (pdf-info-synctex-backward-search page 0.25 yy pdf)
                        (error nil)))
                   (file (and r (expand-file-name (alist-get 'filename r))))
                   (line (and r (alist-get 'line r)))
                   (fw (and file (string-suffix-p ".tex" file) (file-exists-p file)
                            line (> line 0)
                            (not (texsync--file-line-structural-p file line))
                            (texsync--forward file line pdf)))
                   (p2 (and fw (alist-get 'page fw)))
                   (y2 (and fw (nth 1 (alist-get 'edges fw)))))
              (cond ((and fw (eql p2 page) (<= y2 (+ yy 0.05)))
                     (cl-return (list file line p2 y2)))
                    ((and fw (eql p2 (1- page)) (null later))
                     (setq later (list file line p2 y2))))))
        later)))

(defun texsync--pdf-px (pwin page y)
  "Height Y of PAGE in PWIN, in pixels from the top of the window."
  (with-selected-window pwin
    (let ((cur (pdf-view-current-page))
          (px (- (window-vscroll nil t))))
      (while (< cur page)
        (setq px (+ px (texsync--page-height pwin cur) pdf-roll-vertical-margin)
              cur (1+ cur)))
      (while (> cur page)
        (setq cur (1- cur)
              px (- px (texsync--page-height pwin cur) pdf-roll-vertical-margin)))
      (+ px (* y (texsync--page-height pwin page))))))

(defun texsync--show-source (swin file line frac)
  "Show LINE of FILE in SWIN at FRAC of its height, with point there.
SWIN is not selected."
  (let ((buf (or (find-buffer-visiting file) (find-file-noselect file))))
    (with-current-buffer buf
      (unless (bound-and-true-p texsync-mode) (texsync-mode 1)))
    (unless (eq (window-buffer swin) buf)
      (set-window-buffer swin buf))
    (with-selected-window swin
      (goto-char (point-min))
      (forward-line (1- line))
      (recenter (max 0 (round (* frac (window-body-height))))))))

(defun texsync-sync-source (pwin)
  "Make the source follow the PDF shown in PWIN.
Beamer: the frame of the slide shown.  Other documents: the line typeset
at `texsync-pdf-anchor' of the window, put at the same height."
  (let* ((pdf (buffer-file-name (window-buffer pwin)))
         (swin (and pdf (texsync--source-window pdf))))
    (when swin
      (let ((master (with-current-buffer (window-buffer swin) (texsync-master-file))))
        (if (texsync--beamer-p master)
            (let* ((page (with-current-buffer (window-buffer pwin) (pdf-view-current-page pwin)))
                   (line (texsync-frame-at-page master pdf page))
                   (here (with-selected-window swin
                           (and (equal (buffer-file-name) master) (texsync-frame-bounds)))))
              ;; Leave point alone when it is already in that frame.
              (when (and line (not (equal (car here) line)))
                (texsync--show-source swin master line 0.1)))
          (pcase-let* ((`(,page . ,y) (texsync--pdf-point-at pwin texsync-pdf-anchor))
                       (`(,file ,line ,p2 ,y2) (texsync--source-at pdf page y)))
            (unless (eq texsync-trace 'off)
              (push (list 'pdf-leads :anchor (cons page y)
                          :file (and file (file-name-nondirectory file)) :line line
                          :start (and p2 (cons p2 y2)))
                    texsync-trace))
            (when file
              ;; Put the line where its text starts in the PDF window, not at
              ;; the anchor, so that both sit at the same height.
              (let ((frac (/ (texsync--pdf-px pwin p2 y2)
                             (float (window-body-height pwin t)))))
                (texsync--show-source swin file line (min 0.95 (max 0.0 frac)))))))))))

(defun texsync--sync-from-pdf (pwin)
  "Make the source follow PWIN, then remember PWIN's state as synced."
  (when (and (window-live-p pwin)
             (buffer-local-value 'texsync-pdf-mode (window-buffer pwin)))
    (condition-case err
        (texsync-sync-source pwin)
      (error (message "texsync: %s" (error-message-string err))))
    (set-window-parameter pwin 'texsync-synced (texsync--pdf-state pwin))))

(defun texsync--frames (master)
  "Line pairs (BEGIN . END) of all frames of MASTER, in order."
  (with-temp-buffer
    (insert-file-contents master)
    (goto-char (point-min))
    (let (frames)
      (while (texsync--code-search "\\\\begin{frame}" nil)
        (let ((b (line-number-at-pos)))
          (forward-char 1)
          (when (texsync--code-search "\\\\end{frame}" nil)
            (push (cons b (line-number-at-pos)) frames)
            (forward-char 1))))
      (nreverse frames))))

(defun texsync-frame-at-page (master pdf page)
  "The first line of the frame of MASTER typeset on PAGE of PDF, or nil.
Binary search over the frames: pages grow with the frames' order."
  (let* ((frames (vconcat (texsync--frames master)))
         (ranges (texsync--nav-ranges master))
         (lo 0) (hi (1- (length frames))) found)
    (while (and (not found) (<= lo hi))
      (let* ((mid (/ (+ lo hi) 2))
             (r (texsync--forward master (cdr (aref frames mid)) pdf))
             (p (and r (alist-get 'page r)))
             (range (and p (or (cl-find-if (lambda (x) (<= (car x) p (cdr x))) ranges)
                               (cons p p)))))
        (cond ((null range) (setq hi -1))
              ((< page (car range)) (setq hi (1- mid)))
              ((> page (cdr range)) (setq lo (1+ mid)))
              (t (setq found (car (aref frames mid)))))))
    found))

(defun texsync--redirect-vrb (file _line _column)
  "Send a ctrl+click on a verbatim Beamer frame to that frame's source.
SyncTeX attributes such frames to Beamer's temporary .vrb file.
Called by pdf-sync in the PDF window."
  (when (and (string-suffix-p ".vrb" file) (derived-mode-p 'pdf-view-mode))
    (let* ((pdf (buffer-file-name))
           (dir (file-name-directory pdf))
           (out (file-name-as-directory texsync-output-dir))
           (srcdir (if (string-suffix-p out dir)
                       (substring dir 0 (- (length dir) (length out)))
                     dir))
           (master (expand-file-name (concat (file-name-base pdf) ".tex") srcdir)))
      (when-let* (((file-exists-p master))
                  (line (texsync-frame-at-page master pdf (pdf-view-current-page))))
        (list master line 0)))))

(defun texsync--after-backward-jump ()
  "After ctrl+click in the PDF: keep the PDF still, and in Beamer go to the frame."
  (when (bound-and-true-p texsync-mode)
    ;; A sync still pending would move away from the place just clicked.
    (when (timerp texsync--timer)
      (cancel-timer texsync--timer))
    (setq texsync--suppress-until (+ (float-time) 0.5))
    (when-let* ((m (texsync-master-file)))
      (when (and (texsync--beamer-p m)
                 (save-excursion
                   (beginning-of-line)
                   (looking-at-p "[ \t]*\\\\end{frame}")))
        (when-let* ((fb (texsync-frame-bounds)))
          (goto-char (point-min))
          (forward-line (1- (car fb))))))))

;;;; Compiling

(defun texsync-compile (&optional master)
  "Compile MASTER (default: this buffer's main file) with latexmk, asynchronously.
A request while a compile runs queues one more run after it."
  (interactive)
  (let ((master (or master (texsync-master-file))))
    (unless master
      (user-error "texsync: cannot tell the main file; set `TeX-master'"))
    (if (process-live-p (gethash master texsync--processes))
        (puthash master t texsync--pending)
      (let ((default-directory (file-name-directory master))
            (buf (get-buffer-create
                  (format "*texsync %s*" (file-name-nondirectory master)))))
        (make-directory texsync-output-dir t)
        (with-current-buffer buf
          (let ((inhibit-read-only t)) (erase-buffer)))
        (puthash master
                 (make-process
                  :name "texsync-latexmk"
                  :buffer buf
                  :noquery t
                  :command (append texsync-latexmk-command
                                   (list (concat "-outdir=" texsync-output-dir)
                                         (file-name-nondirectory master)))
                  :sentinel (lambda (proc _event) (texsync--compiled master proc)))
                 texsync--processes)))))

(defun texsync--compiled (master proc)
  "Handle the end of latexmk run PROC on MASTER."
  (when (memq (process-status proc) '(exit signal))
    (remhash master texsync--processes)
    (if (and (eq (process-status proc) 'exit) (zerop (process-exit-status proc)))
        (texsync--reload master)
      (message "texsync: %s did not compile; see buffer %s"
               (file-name-nondirectory master) (buffer-name (process-buffer proc))))
    (when (gethash master texsync--pending)
      (remhash master texsync--pending)
      (texsync-compile master))))

(defun texsync--reload (master)
  "Reload the PDF of MASTER and sync it again."
  (let ((pbuf (find-buffer-visiting (texsync--pdf-file master)))
        (asker (gethash master texsync--show-after)))
    (when pbuf
      (with-current-buffer pbuf
        (pdf-view-revert-buffer nil t)))
    (remhash master texsync--show-after)
    (cond
     ((buffer-live-p asker)
      (with-current-buffer asker (texsync-view)))
     (t
      ;; Let redisplay show the reverted PDF first.
      (run-with-timer 0.1 nil #'texsync--resync master)))))

(defun texsync--resync (master)
  "Sync the selected window again if it shows a source of MASTER."
  (with-current-buffer (window-buffer (selected-window))
    (when (and (bound-and-true-p texsync-mode)
               (equal (texsync-master-file) master))
      (setq texsync--last nil)
      (condition-case err
          (texsync-sync)
        (error (message "texsync: %s" (error-message-string err)))))))

(defun texsync--after-change (&rest _)
  (when texsync-compile-idle-delay
    (when (timerp texsync--idle-timer)
      (cancel-timer texsync--idle-timer))
    (setq texsync--idle-timer
          (run-with-idle-timer texsync-compile-idle-delay nil
                               #'texsync--idle-save (current-buffer)))))

(defun texsync--idle-save (buf)
  (when (and (buffer-live-p buf) (buffer-modified-p buf))
    (with-current-buffer buf
      (let ((save-silently t))
        (save-buffer)))))

(defun texsync--after-save ()
  ;; AUCTeX's C-c C-c saves first and then starts its own run; wait a moment
  ;; to see it, so that two TeX runs never write the same build/ files.
  (when texsync-compile-on-save
    (run-with-timer 0.3 nil #'texsync--compile-after-auctex (current-buffer))))

(defun texsync--auctex-process ()
  "AUCTeX's live process for this buffer's main file, or nil."
  (and (fboundp 'TeX-process) (fboundp 'TeX-master-file)
       (let ((proc (ignore-errors (TeX-process (TeX-master-file)))))
         (and (process-live-p proc) proc))))

(defun texsync--compile-after-auctex (buf)
  "Compile BUF's main file once no AUCTeX run for it is going on."
  (when (buffer-live-p buf)
    (with-current-buffer buf
      (if (texsync--auctex-process)
          (run-with-timer 1 nil #'texsync--compile-after-auctex buf)
        (texsync-compile)))))

;;;; Mode

;;;###autoload
(define-minor-mode texsync-mode
  "Keep the PDF of this LaTeX file in step with point.

Moving or scrolling in the source moves the PDF; AUCTeX's View
\(\\[TeX-view]) or \\[texsync-view] shows it.  Ctrl+click in the PDF goes
back.  Saving, or pausing after an edit, compiles with latexmk."
  :lighter " Sync"
  (if texsync-mode
      (progn
        (setq texsync--master nil
              texsync--last nil)
        (when-let* ((m (texsync-master-file)))
          (unless (or (and (boundp 'TeX-master) (stringp TeX-master))
                      (file-equal-p m (buffer-file-name)))
            (setq-local TeX-master
                        (file-name-sans-extension
                         (file-relative-name m (file-name-directory (buffer-file-name)))))))
        (setq-local TeX-output-dir texsync-output-dir)
        (setq-local TeX-view-program-list
                    (cons '("texsync" texsync-view)
                          (and (boundp 'TeX-view-program-list) TeX-view-program-list)))
        (setq-local TeX-view-program-selection '((output-pdf "texsync")))
        (add-hook 'after-change-functions #'texsync--after-change nil t)
        (add-hook 'after-save-hook #'texsync--after-save nil t))
    (remove-hook 'after-change-functions #'texsync--after-change t)
    (remove-hook 'after-save-hook #'texsync--after-save t)
    (dolist (v '(TeX-output-dir TeX-view-program-list TeX-view-program-selection))
      (kill-local-variable v))))

(add-hook 'post-command-hook #'texsync--post-command)
(add-hook 'pdf-sync-backward-hook #'texsync--after-backward-jump)
(add-hook 'pdf-sync-backward-redirect-functions #'texsync--redirect-vrb)

(provide 'texsync)
;;; texsync.el ends here
