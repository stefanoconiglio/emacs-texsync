;;; dyad.el --- Keep a pdf-tools view in step with the LaTeX source  -*- lexical-binding: t -*-

;; Author: Stefano Coniglio
;; URL: https://github.com/stefanoconiglio/emacs-latex-dyad
;; Version: 0.1
;; Package-Requires: ((emacs "29.1") (pdf-tools "1.1"))
;; Keywords: tex
;; SPDX-License-Identifier: GPL-3.0-or-later

;; This program is free software: you can redistribute it and/or modify it
;; under the terms of the GNU General Public License as published by the Free
;; Software Foundation, either version 3 of the License, or (at your option)
;; any later version.  See the file LICENSE.

;;; Commentary:

;; `dyad-mode' shows the PDF of a LaTeX document in a pdf-tools window
;; beside the source and keeps the two in step, both ways:
;;
;; - Moving or scrolling in the source moves the PDF: Beamer shows the slide
;;   of the frame around point; other documents scroll so that the line at
;;   point sits at the same height in both windows.
;; - Scrolling or paging the PDF moves the source: the frame of the slide
;;   shown, or the line typeset a third of the way down the PDF window.
;;   Whichever window the last command acted on leads.
;; - Ctrl+click (or double-click) in the PDF jumps to the source (pdf-sync).
;; - Saving compiles with latexmk into `dyad-output-dir', and nothing
;;   else does (unless `dyad-compile-idle-delay' is set).
;; - The PDF window shows a copy of latexmk's PDF, replaced only by a finished
;;   build, dyad's or anyone else's: a PDF being written never shows.
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
(defvar dyad-mode)
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

(defgroup dyad nil
  "Keep a pdf-tools view in step with the LaTeX source."
  :group 'tex
  :prefix "dyad-")

(defcustom dyad-output-dir "build"
  "Directory, relative to the main file, that receives latexmk's output."
  :type 'string)

(defcustom dyad-view-directory
  (expand-file-name "dyad" (or (getenv "XDG_CACHE_HOME") "~/.cache"))
  "Where dyad keeps the copies of the PDFs it shows.
The PDF window shows a copy of latexmk's PDF, replaced only by a finished
build, so a PDF being rewritten (by dyad, AUCTeX or any other program)
never shows half-written.  One subdirectory per main file; outside the
document's folder, so that a synced folder does not upload the copies."
  :type 'directory)

(defcustom dyad-latexmk-command
  '("latexmk" "-pdf" "-synctex=1" "-interaction=nonstopmode" "-file-line-error")
  "Command and options for latexmk.
`-outdir=' with `dyad-output-dir' and the main file are appended."
  :type '(repeat string))

(defcustom dyad-glue nil
  "Non-nil: build a book part by part and show the parts' PDFs glued.
A book is a main file whose body includes two or more files that are
whole documents themselves (each with its own \\begin{document}, as with
the docmute package).  Saving one of them builds only that part, and the
PDF shown is the parts' PDFs glued together (qpdf), a preview: page
numbers are each part's own, and what the book file adds around the
parts is not there.  `dyad-compile-whole' builds the real book.
nil (the default): a book is built and shown as one document, like any
other."
  :type 'boolean)

(defcustom dyad-log-height 6
  "Lines of the build log pane under the PDF, or nil for no pane.
The pane shows latexmk's output as it comes, under a line that says
whether a build runs, how long it took, or that it failed."
  :type '(choice (const :tag "No pane" nil) integer))

(defcustom dyad-compile-on-save t
  "Non-nil means saving a source file compiles its main file."
  :type 'boolean)

(defcustom dyad-compile-idle-delay nil
  "nil: only saving compiles.  A number: also compile after that many
seconds without typing after an edit, saving the buffer first."
  :type '(choice (const :tag "Off" nil) number))

(defcustom dyad-sync-delay 0.15
  "Seconds after the last cursor motion or scroll before the PDF follows."
  :type 'number)

(defcustom dyad-beamer-overlay 'last
  "Which overlay of a Beamer frame to show: `first' or `last'."
  :type '(choice (const first) (const last)))

(defcustom dyad-structural-line-regexp
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

(defcustom dyad-pdf-anchor 0.33
  "Height in the PDF window, as a fraction, whose text the source follows.
When the PDF leads, the source line typeset there is put at the same
height of the source window."
  :type 'number)

(defcustom dyad-search-radius 8
  "How many lines above and below point to try when point's line has no position."
  :type 'integer)

;;;; State

(defvar-local dyad--master nil
  "Cached absolute name of the main file of this buffer.")

(defvar-local dyad-follow t
  "Non-nil: the PDF and the source follow each other in this buffer's document.
Toggle with \\[dyad-toggle-follow]; compiling, \\[dyad-view] and ctrl+click
work either way.")

(defvar dyad--timer nil
  "The pending sync, in either direction: the window acted on last leads.")
(defvar-local dyad--idle-timer nil)
(defvar-local dyad--last nil
  "The last placement: target and the PDF window state right after it.")
(defvar-local dyad--suppress-until 0
  "`float-time' before which automatic syncing is skipped (after a backward jump).")
(defvar-local dyad--configured nil
  "Non-nil in a PDF buffer that dyad has set up.")

(defvar dyad--processes (make-hash-table :test 'equal)
  "Main file -> running latexmk process.")
(defvar dyad--pending (make-hash-table :test 'equal)
  "Main files whose sources changed while latexmk was running.")
(defvar dyad--show-after (make-hash-table :test 'equal)
  "Main file -> source buffer that asked to see the PDF once it exists.")
(defvar dyad--file-cache (make-hash-table :test 'equal)
  "(KIND . FILE) -> (MTIME . VALUE), for facts read from files.")

;;;; Files

(defun dyad--cached (kind file fn)
  "Value of FN on FILE, recomputed only when FILE's mtime changes.
KIND separates different facts about the same file."
  (let* ((mtime (file-attribute-modification-time (file-attributes file)))
         (key (cons kind file))
         (hit (gethash key dyad--file-cache)))
    (if (and hit (equal (car hit) mtime))
        (cdr hit)
      (let ((v (funcall fn file)))
        (puthash key (cons mtime v) dyad--file-cache)
        v))))

(defun dyad--read-head (file)
  "First 20000 characters of FILE, as a string."
  (with-temp-buffer
    (insert-file-contents file nil 0 20000)
    (buffer-string)))

(defconst dyad--documentclass-re "^[^%\n]*\\\\documentclass\\(?:\\[[^]]*\\]\\)?{\\([^}]*\\)}")

(defconst dyad--begin-document-re "^[^%\n]*\\\\begin{document}")

(defconst dyad--tex-root-re
  "^[ \t]*%+[ \t]*!TeX[ \t]+root[ \t]*=[ \t]*\\(.*?\\)[ \t]*$"
  "The `% !TEX root = FILE' comment of TeXShop, TeXstudio and LaTeX Workshop.")

(defun dyad--tex-file (name dir)
  "NAME, relative to DIR, as an absolute .tex file name."
  (let ((f (expand-file-name name dir)))
    (if (file-name-extension f) f (concat f ".tex"))))

(defun dyad--preamble-inputs (head file)
  "Files that HEAD, the start of FILE, inputs before \\begin{document}."
  (let ((end (or (and (string-match dyad--begin-document-re head) (match-beginning 0))
                 (length head)))
        (start 0) files)
    (while (and (string-match "^[^%\n]*\\\\input{[ \t]*\\([^}]+?\\)[ \t]*}" head start)
                (< (match-beginning 0) end))
      (let ((f (dyad--tex-file (match-string 1 head) (file-name-directory file))))
        (when (file-readable-p f) (push f files)))
      (setq start (match-end 0)))
    (nreverse files)))

(defun dyad--documentclass (file)
  "The document class of FILE, or nil if it names none.
A class set in a header that the preamble \\inputs counts too."
  (dyad--cached
   'class file
   (lambda (f)
     (let ((head (dyad--read-head f)))
       (if (string-match dyad--documentclass-re head)
           (match-string 1 head)
         (cl-loop for inc in (dyad--preamble-inputs head f)
                  for h = (dyad--read-head inc)
                  when (string-match dyad--documentclass-re h)
                  return (match-string 1 h)))))))

(defun dyad--main-file-p (file)
  "Non-nil when FILE is a main file: it has a \\documentclass or a \\begin{document}."
  (dyad--cached
   'main file
   (lambda (f)
     (with-temp-buffer
       (insert-file-contents f)
       (goto-char (point-min))
       (or (re-search-forward dyad--documentclass-re nil t)
           (progn (goto-char (point-min))
                  (re-search-forward dyad--begin-document-re nil t)))))))

(defun dyad--inputs-p (main file)
  "Non-nil when MAIN \\input's, \\include's or \\subfile's FILE."
  (let ((base (file-name-sans-extension (file-name-nondirectory file))))
    (with-temp-buffer
      (insert-file-contents main)
      (goto-char (point-min))
      (re-search-forward
       (concat "^[^%\n]*\\\\\\(?:input\\|include\\|subfile\\){[ \t]*\\(?:\\./\\)?"
               (regexp-quote base) "\\(?:\\.tex\\)?[ \t]*}")
       nil t))))

(defun dyad-guess-master (file)
  "The main file of FILE when exactly one candidate exists, else nil.
A candidate is a .tex file in FILE's directory that is a main file
\(`dyad--main-file-p') and inputs FILE."
  (let ((cands (cl-remove-if-not
                (lambda (f)
                  (and (not (file-equal-p f file))
                       (dyad--main-file-p f)
                       (dyad--inputs-p f file)))
                (directory-files (file-name-directory file) t "\\.tex\\'"))))
    (when (= (length cands) 1)
      (car cands))))

(defun dyad-master-file ()
  "Absolute name of the main .tex file of the current buffer, or nil.
In order: a string `TeX-master'; a `% !TEX root = FILE' comment in the
first lines; the buffer itself if it has a \\documentclass or a
\\begin{document}; `dyad-guess-master'."
  (or dyad--master
      (setq dyad--master
            (when-let* ((file (buffer-file-name)))
              (let ((dir (file-name-directory file)))
                (save-excursion
                  (save-restriction
                    (widen)
                    (cond
                     ((and (boundp 'TeX-master) (stringp TeX-master))
                      (dyad--tex-file TeX-master dir))
                     ((progn (goto-char (point-min))
                             (let ((case-fold-search t))
                               (re-search-forward dyad--tex-root-re
                                                  (line-end-position 20) t)))
                      (dyad--tex-file (match-string 1) dir))
                     ((progn (goto-char (point-min))
                             (or (re-search-forward dyad--documentclass-re nil t)
                                 (progn (goto-char (point-min))
                                        (re-search-forward dyad--begin-document-re nil t))))
                      file)
                     (t (dyad-guess-master file))))))))))

(defun dyad--outdir (master)
  "Absolute output directory of MASTER."
  (expand-file-name dyad-output-dir (file-name-directory master)))

(defun dyad--built-pdf (master)
  "The PDF that latexmk makes from MASTER."
  (expand-file-name (concat (file-name-base master) ".pdf") (dyad--outdir master)))

(defvar dyad--view-masters (make-hash-table :test 'equal)
  "PDF shown by dyad (a copy) -> its main file.")

(defun dyad--pdf-file (master)
  "The PDF that dyad shows for MASTER: a copy of `dyad--built-pdf'.
It lives in `dyad-view-directory' and changes only by
`dyad--refresh-view', when a build is finished."
  (let* ((master (expand-file-name master))
         (dir (expand-file-name (format "%s-%s" (file-name-base master)
                                        (substring (md5 master) 0 10))
                                dyad-view-directory))
         (view (expand-file-name (concat (file-name-base master) ".pdf") dir)))
    (puthash view master dyad--view-masters)
    view))

(defun dyad--beamer-p (master)
  "Non-nil when MASTER is a Beamer document.
Its class is beamer, or (class set elsewhere) Beamer wrote a .nav file."
  (or (equal (dyad--documentclass master) "beamer")
      (file-exists-p (expand-file-name (concat (file-name-base master) ".nav")
                                       (dyad--outdir master)))))

(defun dyad--nav-ranges (master)
  "Page ranges (FIRST . LAST) of the frames of MASTER.
A book's are its parts', shifted to the glued pages."
  (if-let* ((parts (dyad--book-parts master)))
      (cl-loop for part in parts
               for off = (dyad--book-offset master part)
               when off
               append (mapcar (lambda (r) (cons (+ off (car r)) (+ off (cdr r))))
                              (dyad--single-nav-ranges part)))
    (dyad--single-nav-ranges master)))

(defun dyad--single-nav-ranges (master)
  "Page ranges (FIRST . LAST) of the frames of MASTER, from its .nav file.
The copy made with the PDF shown, when there is one: the .nav in the
output directory may belong to a build still being written."
  (let ((nav (cl-find-if #'file-readable-p
                         (list (concat (file-name-sans-extension (dyad--pdf-file master)) ".nav")
                               (expand-file-name (concat (file-name-base master) ".nav")
                                                 (dyad--outdir master))))))
    (when nav
      (dyad--cached
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

(defun dyad--code-search (regexp backward)
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

(defun dyad-frame-bounds ()
  "Line numbers (BEGIN . END) of the Beamer frame around point, or nil."
  (save-excursion
    (save-restriction
      (widen)
      (let ((line (line-number-at-pos)))
        (end-of-line)
        (when (dyad--code-search "\\\\begin{frame}" t)
          (let ((b (line-number-at-pos)))
            (forward-char 1)
            (when (dyad--code-search "\\\\end{frame}" nil)
              (let ((e (line-number-at-pos)))
                (when (>= e line)
                  (cons b e))))))))))

(defun dyad--structural-p (line)
  "Non-nil when LINE of the current buffer is a structural line."
  (save-excursion
    (goto-char (point-min))
    (forward-line (1- line))
    (looking-at-p dyad-structural-line-regexp)))

(defun dyad--candidate-lines (line last)
  "LINE, then the lines around it, nearest first and upward first, within 1..LAST."
  (cons line
        (cl-loop for d from 1 to dyad-search-radius
                 append (cl-remove-if-not (lambda (l) (<= 1 l last))
                                          (list (- line d) (+ line d))))))

(defvar dyad--memo (make-hash-table :test 'equal)
  "PDF -> (MTIME . TABLE): SyncTeX answers for the PDF as last compiled.")

(defun dyad--synctex-file (pdf)
  "PDF's SyncTeX file, or nil when there is none."
  (let ((base (file-name-sans-extension pdf)))
    (cl-find-if #'file-exists-p (list (concat base ".synctex.gz") (concat base ".synctex")))))

(defun dyad--memoized (pdf key fn)
  "FN's value for KEY, remembered until PDF or its SyncTeX file changes on disk."
  (let* ((mtime (list (file-attribute-modification-time (file-attributes pdf))
                      (let ((st (dyad--synctex-file pdf)))
                        (and st (file-attribute-modification-time (file-attributes st))))))
         (entry (gethash pdf dyad--memo)))
    (unless (and entry (equal (car entry) mtime))
      (setq entry (cons mtime (make-hash-table :test 'equal)))
      (puthash pdf entry dyad--memo))
    (let ((hit (gethash key (cdr entry) 'none)))
      (if (not (eq hit 'none))
          hit
        (puthash key (funcall fn) (cdr entry))))))

(defun dyad--forward (file line pdf)
  "SyncTeX forward search for LINE of FILE in PDF, or nil.
In a book's glued PDF: in the part FILE is (or that includes it), its
page shifted to the glued pages."
  (if-let* ((book (dyad--book-of-view pdf)))
      (let* ((parts (dyad--book-parts book))
             (order (if (member file parts) (cons file (remove file parts)) parts)))
        (cl-loop for part in order
                 for r = (dyad--single-forward file line (dyad--pdf-file part))
                 for off = (dyad--book-offset book part)
                 when (and r off)
                 return (cons (cons 'page (+ off (alist-get 'page r)))
                              (assq-delete-all 'page (copy-sequence r)))))
    (dyad--single-forward file line pdf)))

(defun dyad--single-forward (file line pdf)
  "SyncTeX forward search for LINE of FILE in PDF (one document), or nil."
  (dyad--memoized
   pdf (list 'fwd file line)
   (lambda ()
     (condition-case nil
         (pdf-info-synctex-forward-search file line 1 pdf)
       (error nil)))))

(defun dyad--master-of-pdf (pdf)
  "The main .tex file whose PDF is PDF: a copy shown by dyad, or the
PDF that latexmk wrote (it sits in `dyad-output-dir')."
  (or (gethash pdf dyad--view-masters)
      (dyad--master-of-built-pdf pdf)))

(defun dyad--master-of-built-pdf (pdf)
  "The main .tex file of PDF, a file in `dyad-output-dir'."
  (let* ((dir (file-name-directory pdf))
         (out (file-name-as-directory dyad-output-dir))
         (srcdir (if (string-suffix-p out dir)
                     (substring dir 0 (- (length dir) (length out)))
                   dir))
         (master (expand-file-name (concat (file-name-base pdf) ".tex") srcdir)))
    (and (file-exists-p master) master)))

(defun dyad--command-line (file regexp)
  "Line of the first match of REGEXP outside a comment in FILE's body, or nil.
The body starts at \\begin{document}: a preamble may name the command in
a definition (an \\AtBeginSection outline, say)."
  (with-temp-buffer
    (insert-file-contents file)
    (goto-char (point-min))
    (dyad--code-search dyad--begin-document-re nil)
    (when (dyad--code-search regexp nil)
      (line-number-at-pos))))

(defconst dyad--aux-commands
  '(("bbl" . "\\\\\\(?:bibliography\\|printbibliography\\)\\_>")
    ("toc" . "\\\\tableofcontents")
    ("lof" . "\\\\listoffigures")
    ("lot" . "\\\\listoftables")
    ("ind" . "\\\\printindex"))
  "Files LaTeX writes and reads back, and the command that reads each.")

(defun dyad--aux-source (file pdf page)
  "The source line for SyncTeX's answer FILE, a file LaTeX wrote, as (FILE . LINE).
A verbatim Beamer frame (.vrb) is the frame typeset on PAGE; a
bibliography (.bbl), table of contents (.toc) and the like are the line
of the command that reads it in the main file's body; in a Beamer
document, the frame typeset on PAGE.  nil for other files."
  (when-let* ((master (dyad--master-of-pdf pdf))
              (ext (file-name-extension file)))
    (if (or (equal ext "vrb") (dyad--beamer-p master))
        ;; in Beamer, the frame typeset on PAGE (an outline frame for .toc)
        (when-let* ((line (dyad-frame-at-page master pdf page)))
          (cons master line))
      (when-let* ((re (cdr (assoc ext dyad--aux-commands)))
                  (line (dyad--command-line master re)))
        (cons master line)))))

(defun dyad--backward (pdf page x y)
  "The source of point (X, Y) of PAGE in PDF, as (FILE LINE . FROM-AUX), or nil.
In a book's glued PDF: in the part on PAGE, at its own page."
  (if-let* ((book (dyad--book-of-view pdf))
            (at (dyad--book-part-at book page)))
      (dyad--single-backward (dyad--pdf-file (car at)) (cdr at) x y)
    (dyad--single-backward pdf page x y)))

(defun dyad--single-backward (pdf page x y)
  "The source of point (X, Y) of PAGE in PDF, as (FILE LINE . FROM-AUX), or nil.
X and Y are fractions of the page.  An answer in a file LaTeX wrote is
sent to its source (`dyad--aux-source'), and FROM-AUX is then t."
  (dyad--memoized
   pdf (list 'bwd page (round (* 1000 x)) (round (* 1000 y)))
   (lambda ()
     (let* ((r (condition-case nil
                   (pdf-info-synctex-backward-search page x y pdf)
                 (error nil)))
            (file (and r (expand-file-name (alist-get 'filename r))))
            (line (and r (alist-get 'line r))))
       (cond ((null file) nil)
             ((and (string-suffix-p ".tex" file) line (> line 0) (file-exists-p file))
              (cons file (cons line nil)))
             (t (when-let* ((src (dyad--aux-source file pdf page)))
                  (cons (car src) (cons (cdr src) t)))))))))

(defun dyad--good-box-p (edges)
  "Non-nil when EDGES look like text, not an empty or page-sized box."
  (pcase-let ((`(,x1 ,y1 ,x2 ,y2) edges))
    (and (> (- x2 x1) 0.001) (< (- y2 y1) 0.5))))

(defun dyad-paper-target (pdf)
  "Where the line at point is in PDF, as (PAGE . Y).
Y is the top of the line's text as a fraction of the page height.
Structural lines and empty or page-sized boxes are skipped in favour
of the nearest other line."
  (let* ((file (buffer-file-name))
         (last (save-restriction (widen) (line-number-at-pos (point-max)))))
    (cl-loop for l in (dyad--candidate-lines (line-number-at-pos) last)
             for r = (and (not (dyad--structural-p l))
                          (dyad--forward file l pdf))
             when (and r (dyad--good-box-p (alist-get 'edges r)))
             return (cons (alist-get 'page r) (nth 1 (alist-get 'edges r))))))

(defconst dyad--sectioning-re
  "^[ \t]*\\\\\\(?:part\\|section\\|subsection\\|subsubsection\\)\\*?[ \t]*[[{]"
  "A line that starts a sectioning command.")

(defun dyad--frame-page (file end pdf master)
  "The page to show for the frame of FILE that ends on line END."
  (when-let* ((r (dyad--forward file end pdf)))
    (dyad-overlay-page (alist-get 'page r) (dyad--nav-ranges master))))

(defun dyad-beamer-target (pdf master)
  "The PDF page for point in a Beamer document, or nil.
In a frame: its slide.  Beamer typesets a frame at its \\end{frame}
line, so that is the line looked up; `dyad-beamer-overlay' picks the
overlay.  On a \\section (or \\subsection...) line between frames: the
slide that line makes (an outline from \\AtBeginSection), if SyncTeX
puts one there, otherwise the first slide after it.  Other lines
between frames: nil."
  (let ((file (buffer-file-name)))
    (if-let* ((fb (dyad-frame-bounds)))
        (dyad--frame-page file (cdr fb) pdf master)
      (when (save-excursion (beginning-of-line) (looking-at-p dyad--sectioning-re))
        (let* ((line (line-number-at-pos))
               (r (dyad--forward file line pdf))
               (page (alist-get 'page r)))
          (if (and page (equal (dyad--backward pdf page 0.5 0.5) (cons file (cons line nil))))
              page
            ;; no slide of its own: the section starts with the next frame
            (save-excursion
              (when (dyad--code-search "\\\\begin{frame}" nil)
                (when-let* ((fb (dyad-frame-bounds)))
                  (dyad--frame-page file (cdr fb) pdf master))))))))))

(defun dyad-overlay-page (page ranges)
  "The page to show for a frame that SyncTeX puts on PAGE, given frame RANGES."
  (let ((r (cl-find-if (lambda (r) (<= (car r) page (cdr r))) ranges)))
    (cond ((null r) page)
          ((eq dyad-beamer-overlay 'last) (cdr r))
          (t (car r)))))

(defun dyad--point-fraction ()
  "Height of point's line in the selected window, as a fraction of its height."
  ;; A long wrapped line may begin above the window start.
  (when-let* ((xy (posn-x-y (posn-at-point (max (line-beginning-position)
                                                (window-start))))))
    (min 1.0 (max 0.0 (/ (float (cdr xy)) (max 1 (window-body-height nil t)))))))

;;;; The copy shown

;; pdflatex rewrites the PDF in place from its first page on, and a viewer
;; that reads it meanwhile (pdf-tools draws pages lazily) gets a broken file:
;; the PDF buffer's raw bytes show through.  So the PDF window shows a copy,
;; replaced by a rename once a build is finished, whoever ran it.

(defun dyad--file-stamp (file)
  "Size and modification time of FILE, or nil when it does not exist."
  (when-let* ((a (file-attributes file)))
    (list (file-attribute-size a) (file-attribute-modification-time a))))

(defun dyad--mtime (file)
  "Modification time of FILE, or nil when it does not exist."
  (when-let* ((a (file-attributes file)))
    (file-attribute-modification-time a)))

(defun dyad--complete-pdf-p (file)
  "Non-nil when FILE ends like a finished PDF: %%EOF in its last kilobyte."
  (when-let* ((a (file-attributes file))
              (size (file-attribute-size a)))
    (and (> size 0)
         (with-temp-buffer
           (set-buffer-multibyte nil)
           (insert-file-contents-literally file nil (max 0 (- size 1024)) size)
           (goto-char (point-min))
           (search-forward "%%EOF" nil t)))))

(defun dyad--build-ready-p (master)
  "Non-nil when latexmk's PDF of MASTER is a finished build.
The PDF ends like a finished one, and no SyncTeX file is being written
\(pdflatex writes NAME.synctex(busy) until its run ends)."
  (let ((pdf (dyad--built-pdf master)))
    (and (file-exists-p pdf)
         (not (file-exists-p (concat (file-name-sans-extension pdf) ".synctex(busy)")))
         (dyad--complete-pdf-p pdf))))

(defun dyad--refresh-view (master)
  "Make the PDF dyad shows for MASTER current; non-nil if it changed.
A book (`dyad--book-parts') is glued from its parts' copies."
  (if-let* ((parts (dyad--book-parts master)))
      (dyad--refresh-book master parts)
    (dyad--refresh-single-view master)))

(defun dyad--refresh-single-view (master)
  "Copy MASTER's finished build to the PDF dyad shows; non-nil if it changed.
Nothing happens while the build is being written, or when the copy is the
latest build already.  The SyncTeX file goes along when the same run wrote
it (it is not older than the PDF), and so does the .nav file.  Each file is
copied to a temporary name and renamed into place, the PDF last, and only
if none of them changed while it was being copied."
  (let ((built (dyad--built-pdf master))
        (view (dyad--pdf-file master)))
    (when (and (dyad--build-ready-p master)
               (not (equal (dyad--mtime built) (dyad--mtime view))))
      (make-directory (file-name-directory view) t)
      (let* ((base (file-name-sans-extension built))
             (vbase (file-name-sans-extension view))
             (st (let ((f (dyad--synctex-file built)))
                   (and f (not (time-less-p (dyad--mtime f) (dyad--mtime built))) f)))
             (nav (let ((f (concat base ".nav"))) (and (file-exists-p f) f)))
             ;; (FROM . TO), the PDF last
             (pairs (append (and st (list (cons st (concat vbase (substring st (length base))))))
                            (and nav (list (cons nav (concat vbase ".nav"))))
                            (list (cons built view))))
             (copies nil)
             (ok t))
        (dolist (pair pairs)
          (when ok
            (let ((stamp (dyad--file-stamp (car pair)))
                  (tmp (make-temp-file (expand-file-name ".copy-" (file-name-directory view)))))
              (push (cons tmp (cdr pair)) copies)
              (condition-case nil
                  (progn
                    (copy-file (car pair) tmp t t)
                    (unless (equal stamp (dyad--file-stamp (car pair)))
                      (setq ok nil)))
                (error (setq ok nil))))))
        ;; the last copy made is the PDF's
        (setq ok (and ok (dyad--complete-pdf-p (car (car copies)))))
        (if (not ok)
            (progn
              (dolist (c copies) (ignore-errors (delete-file (car c))))
              nil)
          ;; a build without SyncTeX data must not keep the old data
          (unless st
            (dolist (ext '(".synctex.gz" ".synctex"))
              (ignore-errors (delete-file (concat vbase ext)))))
          (dolist (c (reverse copies))
            (rename-file (car c) (cdr c) t))
          t)))))

(defun dyad--delete-view-dir (dir)
  "Delete DIR, the directory of a copy, if it lies inside `dyad-view-directory'."
  (let ((root (file-name-as-directory (expand-file-name dyad-view-directory)))
        (dir (and dir (file-name-as-directory (expand-file-name dir)))))
    (when (and dir (string-prefix-p root dir) (not (equal root dir)))
      (ignore-errors (delete-directory dir t)))))

(defun dyad--forget-view ()
  "When a buffer showing a copy is killed, delete the copy's directory."
  (when-let* ((file (buffer-file-name))
              ((gethash file dyad--view-masters)))
    (dyad--delete-view-dir (file-name-directory file))))

(defun dyad--forget-all-views ()
  "Delete the copies this Emacs made.
On `kill-emacs-hook': buffers' `kill-buffer-hook' does not run when Emacs exits."
  (maphash (lambda (view _) (dyad--delete-view-dir (file-name-directory view)))
           dyad--view-masters))

(defun dyad--prune-views (&optional days)
  "Delete the copies' directories unused for DAYS (default 7): left by a crash."
  (let ((limit (time-subtract nil (days-to-time (or days 7)))))
    (dolist (dir (ignore-errors (directory-files dyad-view-directory t "\\`[^.]")))
      (when (and (file-directory-p dir) (time-less-p (dyad--mtime dir) limit))
        (dyad--delete-view-dir dir)))))

(add-hook 'kill-emacs-hook #'dyad--forget-all-views)
(dyad--prune-views)

(defun dyad--watch-view ()
  "In a buffer showing a copy: delete it with the buffer, look for new builds."
  (when (and (buffer-file-name) (gethash (buffer-file-name) dyad--view-masters))
    (add-hook 'kill-buffer-hook #'dyad--forget-view nil t)
    (dyad--start-poll)))

;;;; The PDF window

(defun dyad--pdf-buffer (pdf create)
  "The buffer visiting PDF; with CREATE, visit it if needed.
A buffer visiting latexmk's own PDF is switched over to PDF, the copy."
  (or (find-buffer-visiting pdf)
      (dyad--adopt-pdf-buffer pdf)
      (when create
        (let ((buf (let ((large-file-warning-threshold nil))
                     (find-file-noselect pdf))))
          ;; Without `pdf-tools-install', .pdf files open in doc-view.
          (with-current-buffer buf
            (unless (derived-mode-p 'pdf-view-mode)
              (pdf-view-mode)))
          buf))))

(defun dyad--adopt-pdf-buffer (view)
  "Switch a buffer visiting latexmk's PDF over to VIEW, its copy; return it.
Its windows stay where they are."
  (when-let* ((master (gethash view dyad--view-masters))
              (buf (find-buffer-visiting (dyad--built-pdf master)))
              ((or (file-exists-p view) (dyad--refresh-view master))))
    (with-current-buffer buf
      (set-visited-file-name view t)
      (set-buffer-modified-p nil)
      (if (derived-mode-p 'pdf-view-mode)
          (pdf-view-revert-buffer nil t)
        (revert-buffer t t t))
      (dyad--watch-view))
    buf))

(defun dyad--pdf-window (pbuf create)
  "A window of the selected frame that shows PBUF.
With CREATE, show PBUF in the window to the right, splitting if needed."
  (or (get-buffer-window pbuf)
      (when create
        (let ((w (let ((r (window-in-direction 'right)))
                   ;; not the log pane under a PDF window: the window above it
                   (when (and r (window-parameter r 'dyad-log))
                     (setq r (window-in-direction 'above r)))
                   (or r (split-window-right)))))
          (set-window-buffer w pbuf)
          ;; pdf-tools files the overlay a window draws its pages in under
          ;; the window selected when it first meets the window
          ;; (vedang/pdf-tools#349).  Met from the source window (the log
          ;; pane redraws the PDF), it goes to another entry: pages then
          ;; change but are never drawn, and the PDF looks frozen.
          (with-selected-window w (image-mode-winprops w))
          w))))

(defvar dyad-pdf-mode-map
  (let ((map (make-sparse-keymap)))
    ;; pdf-view binds these presses to text selection, which follows the
    ;; mouse and drops the release if the pointer moves at all (a touchpad
    ;; click), so pdf-sync's jump bound to the release never runs.
    (define-key map [C-down-mouse-1] #'ignore)
    (define-key map [double-down-mouse-1] #'ignore)
    (define-key map [C-mouse-1] #'dyad-pdf-click)
    (define-key map [double-mouse-1] #'dyad-pdf-click)
    map)
  "Keys of `dyad-pdf-mode'.")

(defun dyad-pdf-click (ev)
  "Go to the source of the place clicked in the PDF (ctrl+click, double-click).
pdf-sync's backward search, except in a book's glued PDF, which has no
SyncTeX data of its own: there the clicked page is looked up in its part."
  (interactive "@e")
  (if (not (dyad--book-of-view (buffer-file-name)))
      (pdf-sync-backward-search-mouse ev)
    (let* ((posn (event-start ev))
           (xy (posn-object-x-y posn))
           (page (if (bound-and-true-p pdf-view-roll-minor-mode)
                     (/ (+ (posn-point posn) 3) 4)
                   (pdf-view-current-page)))
           (size (and (posn-image posn) (pdf-view-image-size t nil page)))
           (src (and size
                     (dyad--backward (buffer-file-name) page
                                        (/ (car xy) (float (car size)))
                                        (/ (cdr xy) (float (cdr size)))))))
      (cond
       ((null size) (user-error "Outside of image area"))
       ((null src) (message "dyad: no source found for this place"))
       (t
        (pop-to-buffer (or (find-buffer-visiting (car src)) (find-file-noselect (car src)))
                       (bound-and-true-p pdf-sync-backward-display-action))
        (unless (bound-and-true-p dyad-mode) (dyad-mode 1))
        (push-mark)
        (goto-char (point-min))
        (forward-line (1- (cadr src)))
        (run-hooks 'pdf-sync-backward-hook))))))

(define-minor-mode dyad-pdf-mode
  "In a PDF shown by dyad, ctrl+click or double-click jumps to the source.
The mode line says when the PDF is being built, or when its build failed."
  :lighter (:eval (dyad--pdf-lighter))
  :keymap dyad-pdf-mode-map)

(defun dyad--setup-pdf (pwin beamer)
  "Set up the PDF buffer shown in PWIN once: fit, scrolling, no auto-revert.
BEAMER non-nil fits whole slides; otherwise pages scroll continuously."
  (with-current-buffer (window-buffer pwin)
    (dyad--watch-view))
  (with-selected-window pwin
    (unless dyad--configured
      (setq dyad--configured t)
      ;; dyad reverts after a successful compile; reverting mid-compile breaks.
      (setq-local global-auto-revert-ignore-buffer t)
      (when (bound-and-true-p auto-revert-mode) (auto-revert-mode -1))
      (unless (bound-and-true-p pdf-sync-minor-mode) (pdf-sync-minor-mode 1))
      (dyad-pdf-mode 1)
      (if beamer
          (pdf-view-fit-page-to-window)
        (when (fboundp 'pdf-view-roll-minor-mode)
          (pdf-view-roll-minor-mode 1)
          ;; Its mode-line indicator measures the selected window, which is
          ;; the source window here, and errors on every redisplay in roll mode.
          (when (bound-and-true-p pdf-misc-size-indication-minor-mode)
            (pdf-misc-size-indication-minor-mode -1)))
        (pdf-view-fit-width-to-window)))))

(defun dyad--window-state (pwin)
  "What a user's scrolling in PWIN would change."
  ;; pdf-view keeps the page per window in the PDF buffer, not the source buffer.
  (with-current-buffer (window-buffer pwin)
    (list (pdf-view-current-page pwin) (window-vscroll pwin t) (window-start pwin))))

(defun dyad--pdf-state (pwin)
  "Page and vscroll of PWIN: what scrolling the PDF changes, set at once."
  (with-current-buffer (window-buffer pwin)
    (list (pdf-view-current-page pwin) (window-vscroll pwin t))))

(defun dyad--place (pwin target fn)
  "Call FN to show TARGET in PWIN, unless PWIN is still where TARGET left it."
  (unless (and (equal (car dyad--last) target)
               (equal (cdr dyad--last) (dyad--window-state pwin)))
    (funcall fn)
    (setq dyad--last (cons target (dyad--window-state pwin))))
  ;; The PDF now agrees with the source: no reason for it to lead.
  (set-window-parameter pwin 'dyad-synced (dyad--pdf-state pwin)))

(defun dyad--show-page (pwin page)
  "Show PAGE in PWIN."
  (with-selected-window pwin
    (unless (eq page (pdf-view-current-page))
      (pdf-view-goto-page page))))

(defun dyad--page-height (pwin page)
  "Displayed height in pixels of PAGE in PWIN, without rendering it.
pdf-roll renders pages lazily; asking a not yet rendered page for its
image size signals an error."
  (with-current-buffer (window-buffer pwin)
    (cdr (pdf-view-desired-image-size page pwin))))

(defun dyad--show-position (pwin page y frac)
  "Scroll PWIN so that height Y of PAGE (a fraction) is at FRAC of its height."
  (with-selected-window pwin
    ;; After a revert, roll mode builds its page overlays at the next redisplay.
    (when (and (bound-and-true-p pdf-view-roll-minor-mode)
               (not (pdf-roll-page-overlay 1 pwin)))
      (redisplay t))
    (let ((offset (round (- (* y (dyad--page-height pwin page))
                            (* frac (window-body-height pwin t))))))
      (if (bound-and-true-p pdf-view-roll-minor-mode)
          (progn
            ;; A negative offset starts the window on an earlier page.
            (while (and (< offset 0) (> page 1))
              (setq page (1- page)
                    offset (+ offset pdf-roll-vertical-margin
                              (dyad--page-height pwin page))))
            (setf (pdf-view-current-page pwin) page)
            (pdf-roll-set-vscroll (max 0 offset) pwin)
            (force-window-update pwin))
        (unless (eq page (pdf-view-current-page))
          (pdf-view-goto-page page))
        (image-set-window-vscroll (max 0 offset))))))

;;;; Syncing

(defun dyad-sync (&optional display)
  "Make the PDF show the place of point.
With DISPLAY (interactively), open and show the PDF if it is not shown."
  (interactive (list t))
  (let* ((master (dyad-master-file))
         (pdf (and master (dyad--pdf-file master))))
    (cond
     ((null master)
      (when display
        (user-error "dyad: cannot tell the main file; set `TeX-master'")))
     ((and (not (file-exists-p pdf)) (not (dyad--refresh-view master)))
      (when display
        (puthash master (current-buffer) dyad--show-after)
        (if (file-exists-p (dyad--built-pdf master))
            ;; latexmk's PDF is being written: shown once it is finished
            (progn
              (dyad--start-poll)
              (message "dyad: %s is being built; the PDF opens when it is ready"
                       (file-name-nondirectory master)))
          (dyad-compile master)
          (message "dyad: compiling %s; the PDF opens when it is ready"
                   (file-name-nondirectory master)))))
     (t
      (when-let* ((pbuf (dyad--pdf-buffer pdf display))
                  (pwin (dyad--pdf-window pbuf display)))
        (let ((beamer (dyad--beamer-p master)))
          (dyad--setup-pdf pwin beamer)
          ;; the build log pane under it: made when the PDF is shown on request
          (dyad--log-window pwin master display)
          (cond
           ;; without SyncTeX data there is nothing to look up (rebuilt once)
           ((not (dyad--ensure-synctex master pdf)))
           (beamer
              (when-let* ((page (dyad-beamer-target pdf master)))
                (dyad--place pwin page
                                (lambda () (dyad--show-page pwin page)))))
           (t
            (when-let* ((target (dyad-paper-target pdf))
                        ;; the same pixel row as point, as a fraction of the PDF
                        ;; window (lower than the source's when the log pane is
                        ;; under it)
                        (frac (let ((f (dyad--point-fraction)))
                                (and f (min 1.0 (/ (* f (window-body-height nil t))
                                                   (float (window-body-height pwin t))))))))
              (dyad--place pwin (list (car target) (cdr target) frac)
                              (lambda ()
                                (dyad--show-position
                                 pwin (car target) (cdr target) frac))))))))))))

(defun dyad-view ()
  "Show the PDF at the place of point.  Used as AUCTeX's viewer."
  (interactive)
  (setq dyad--last nil)
  (dyad-sync t))

(defun dyad--sync-from (win)
  "Make the PDF follow the source shown in WIN."
  (when (window-live-p win)
    (with-current-buffer (window-buffer win)
      (when (and dyad-mode (>= (float-time) dyad--suppress-until))
        (with-selected-window win
          (condition-case err
              (dyad-sync)
            (error (message "dyad: %s" (error-message-string err)))))))))

(defvar dyad-trace 'off
  "Unless `off', a list onto which dyad pushes its scheduling decisions.")

(defun dyad--schedule (fn win)
  "Call FN on WIN after `dyad-sync-delay' seconds without further commands."
  (unless (eq dyad-trace 'off)
    (push (list (format-time-string "%T.%3N") fn (buffer-name (window-buffer win))
                this-command (car-safe last-input-event))
          dyad-trace))
  (when (timerp dyad--timer)
    (cancel-timer dyad--timer))
  (setq dyad--timer (run-with-timer dyad-sync-delay nil fn win)))

(defconst dyad--jump-commands
  '(pdf-sync-backward-search-mouse dyad-pdf-click ignore
    pdf-util-image-map-mouse-event-proxy nil)
  "Commands in the PDF that must not make the source follow it.
The proxy re-sends clicks on text (an image-map area) without the area;
nil is an undefined key.")

(defun dyad--command-window ()
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

(defun dyad--post-command ()
  "Let the window the last command acted on lead the next sync."
  (let* ((win (dyad--command-window))
         (buf (and (window-live-p win) (window-buffer win))))
    (when buf
      (cond ((buffer-local-value 'dyad-mode buf)
             (when (buffer-local-value 'dyad-follow buf)
               (dyad--schedule #'dyad--sync-from win)))
            ((and (buffer-local-value 'dyad-pdf-mode buf)
                  (not (memq this-command dyad--jump-commands))
                  (not (eq (car-safe last-input-event) 'mouse-movement))
                  ;; only when the command moved the PDF (not a click to select)
                  (not (equal (dyad--pdf-state win)
                              (window-parameter win 'dyad-synced))))
             (dyad--schedule #'dyad--sync-from-pdf win))))))

;;;; The PDF leads

(defun dyad--source-window (pdf)
  "A window of the selected frame with a dyad source whose PDF is PDF.
Only sources that follow (`dyad-follow') count."
  (cl-find-if (lambda (w)
                (with-current-buffer (window-buffer w)
                  (and dyad-mode dyad-follow
                       (when-let* ((m (dyad-master-file)))
                         (equal (dyad--pdf-file m) pdf)))))
              (window-list nil 'nomini)))

(defun dyad--pdf-point-at (pwin frac)
  "(PAGE . Y) of the PDF at height FRAC of PWIN, Y a fraction of the page height."
  (with-selected-window pwin
    (let ((page (pdf-view-current-page))
          (px (+ (window-vscroll nil t) (* frac (window-body-height nil t)))))
      (when (bound-and-true-p pdf-view-roll-minor-mode)
        (let ((n (pdf-cache-number-of-pages)) h)
          (while (and (< page n)
                      (> px (setq h (dyad--page-height pwin page))))
            (setq px (- px h pdf-roll-vertical-margin)
                  page (1+ page)))))
      (cons page (min 1.0 (max 0.0 (/ px (float (dyad--page-height pwin page)))))))))

(defun dyad--file-line-structural-p (file line)
  "Non-nil when LINE of FILE is a structural line (see `dyad--structural-p')."
  (let ((buf (find-buffer-visiting file)))
    (if buf
        (with-current-buffer buf
          (save-restriction (widen) (dyad--structural-p line)))
      (with-temp-buffer
        (insert-file-contents file)
        (dyad--structural-p line)))))

(defun dyad--source-at (pdf page y)
  "Source of the text at height Y of PAGE, as (FILE LINE PAGE2 Y2), or nil.
PAGE2 and Y2 are where that line's text starts.  Heights around Y are
tried, nearest first.  A backward search result counts only if it is not
a structural line and a forward search of it starts on PAGE at or above
the height tried: between pages or in a margin, SyncTeX's nearest record
can belong to any line.  Only if no height gives such a line, a line
starting on the page before is taken (a long paragraph on one source
line), and failing that a structural line (the title's \\maketitle).
Text from a file LaTeX wrote (the bibliography) is the line of the
command that reads it, put at the height tried.  Each answer is checked
once per call; answers are remembered until the PDF changes."
  (let (later seen structural)
    (or (cl-loop
         for dy in '(0 0.02 -0.02 0.04 -0.04 0.07 -0.07 0.1 -0.1 0.15 -0.15)
         for yy = (+ y dy)
         when (<= 0 yy 1)
         do (pcase-let* ((src (dyad--backward pdf page 0.25 yy))
                         (`(,file ,line . ,from-aux) src))
              (cond
               ((or (null src) (member src seen)))   ; asked already: skip
               (from-aux
                ;; text LaTeX read back from a file it wrote (a bibliography):
                ;; the command that reads it, at the height tried
                (cl-return (list file line page yy)))
               ((dyad--file-line-structural-p file line)
                (push src seen)
                ;; \maketitle, a lone \end{...}: only if nothing better turns up
                (unless structural (setq structural (list file line page yy))))
               (t
                (push src seen)
                (let* ((fw (let ((r (dyad--forward file line pdf)))
                             ;; an empty or page-sized box is no place for the
                             ;; line (page-break glue at the foot of a page)
                             (and r (dyad--good-box-p (alist-get 'edges r)) r)))
                       (p2 (and fw (alist-get 'page fw)))
                       (y2 (and fw (nth 1 (alist-get 'edges fw)))))
                  (cond ((and fw (eql p2 page) (<= y2 (+ yy 0.05)))
                         (cl-return (list file line p2 y2)))
                        ((and fw (eql p2 (1- page)) (null later))
                         (setq later (list file line p2 y2)))))))))
        later
        structural)))

(defun dyad--pdf-px (pwin page y)
  "Height Y of PAGE in PWIN, in pixels from the top of the window."
  (with-selected-window pwin
    (let ((cur (pdf-view-current-page))
          (px (- (window-vscroll nil t))))
      (while (< cur page)
        (setq px (+ px (dyad--page-height pwin cur) pdf-roll-vertical-margin)
              cur (1+ cur)))
      (while (> cur page)
        (setq cur (1- cur)
              px (- px (dyad--page-height pwin cur) pdf-roll-vertical-margin)))
      (+ px (* y (dyad--page-height pwin page))))))

(defun dyad--show-source (swin file line frac)
  "Show LINE of FILE in SWIN at FRAC of its height, with point there.
SWIN is not selected."
  (let ((buf (or (find-buffer-visiting file) (find-file-noselect file))))
    (with-current-buffer buf
      (unless (bound-and-true-p dyad-mode) (dyad-mode 1)))
    (unless (eq (window-buffer swin) buf)
      (set-window-buffer swin buf))
    (with-selected-window swin
      (goto-char (point-min))
      (forward-line (1- line))
      (recenter (max 0 (round (* frac (window-body-height))))))))

(defun dyad-sync-source (pwin)
  "Make the source follow the PDF shown in PWIN.
Beamer: the frame of the slide shown.  Other documents: the line typeset
at `dyad-pdf-anchor' of the window, put at the same height."
  (let* ((pdf (buffer-file-name (window-buffer pwin)))
         (swin (and pdf (dyad--source-window pdf))))
    (when swin
      (let ((master (with-current-buffer (window-buffer swin) (dyad-master-file))))
        (cond
         ((not (dyad--ensure-synctex master pdf)))
         ((dyad--beamer-p master)
            (pcase-let* ((page (with-current-buffer (window-buffer pwin)
                                 (pdf-view-current-page pwin)))
                         (`(,file . ,line) (dyad-beamer-source master pdf page))
                         (here (with-selected-window swin
                                 (and (equal (buffer-file-name) file)
                                      (or (car (dyad-frame-bounds))
                                          (line-number-at-pos))))))
              ;; Leave point alone when it is already in that frame (or on that line).
              (when (and file (not (equal here line)))
                (dyad--show-source swin file line 0.1))))
         (t
          (pcase-let* ((`(,page . ,y) (dyad--pdf-point-at pwin dyad-pdf-anchor))
                       (`(,file ,line ,p2 ,y2) (dyad--source-at pdf page y)))
            (unless (eq dyad-trace 'off)
              (push (list 'pdf-leads :anchor (cons page y)
                          :file (and file (file-name-nondirectory file)) :line line
                          :start (and p2 (cons p2 y2)))
                    dyad-trace))
            (when file
              ;; Put the line where its text starts in the PDF window, not at
              ;; the anchor, so that both sit at the same height.
              ;; the same pixel row as the text in the PDF, as a fraction of
              ;; the source window (the PDF window may be lower: log pane)
              (let ((frac (/ (dyad--pdf-px pwin p2 y2)
                             (float (window-body-height swin t)))))

                (dyad--show-source swin file line (min 0.95 (max 0.0 frac))))))))))))

(defun dyad--sync-from-pdf (pwin)
  "Make the source follow PWIN, then remember PWIN's state as synced."
  (when (and (window-live-p pwin)
             (buffer-local-value 'dyad-pdf-mode (window-buffer pwin)))
    (condition-case err
        (dyad-sync-source pwin)
      (error (message "dyad: %s" (error-message-string err))))
    (set-window-parameter pwin 'dyad-synced (dyad--pdf-state pwin))))

(defun dyad--frames (master)
  "Line pairs (BEGIN . END) of all frames of MASTER, in order."
  (with-temp-buffer
    (insert-file-contents master)
    (goto-char (point-min))
    (let (frames)
      (while (dyad--code-search "\\\\begin{frame}" nil)
        (let ((b (line-number-at-pos)))
          (forward-char 1)
          (when (dyad--code-search "\\\\end{frame}" nil)
            (push (cons b (line-number-at-pos)) frames)
            (forward-char 1))))
      (nreverse frames))))

(defun dyad--file-frames (file)
  "Frames of FILE as line pairs (BEGIN . END), read when FILE changes on disk."
  (dyad--cached 'frames file #'dyad--frames))

(defun dyad-beamer-source (master pdf page)
  "The source line of PAGE of a Beamer PDF, as (FILE . LINE), or nil.
LINE begins the frame typeset on PAGE, or is the line outside frames
that made the page (a \\section with an \\AtBeginSection slide).
SyncTeX is asked once, at the page's centre; frames in \\input files are
found too.  When that fails, the frame of MASTER on PAGE is searched
for (`dyad-frame-at-page')."
  (or (pcase-let ((`(,file ,line . ,_) (dyad--backward pdf page 0.5 0.5)))
        (when file
          (let ((fr (cl-find-if (lambda (f) (<= (car f) line (cdr f)))
                                (dyad--file-frames file))))
            (cons file (if fr (car fr) line)))))
      (when-let* ((line (dyad-frame-at-page master pdf page)))
        (cons master line))))

(defun dyad-frame-at-page (master pdf page)
  "The first line of the frame of MASTER typeset on PAGE of PDF, or nil.
Binary search over the frames: pages grow with the frames' order."
  (let* ((frames (vconcat (dyad--frames master)))
         (ranges (dyad--nav-ranges master))
         (lo 0) (hi (1- (length frames))) found)
    (while (and (not found) (<= lo hi))
      (let* ((mid (/ (+ lo hi) 2))
             (r (dyad--forward master (cdr (aref frames mid)) pdf))
             (p (and r (alist-get 'page r)))
             (range (and p (or (cl-find-if (lambda (x) (<= (car x) p (cdr x))) ranges)
                               (cons p p)))))
        (cond ((null range) (setq hi -1))
              ((< page (car range)) (setq hi (1- mid)))
              ((> page (cdr range)) (setq lo (1+ mid)))
              (t (setq found (car (aref frames mid)))))))
    found))

(defun dyad--redirect-aux (file _line _column)
  "Send a ctrl+click on text from a file LaTeX wrote to its source.
SyncTeX attributes verbatim Beamer frames to the .vrb file, a
bibliography to the .bbl file, and so on (`dyad--aux-source').
Called by pdf-sync in the PDF window."
  (when (and (derived-mode-p 'pdf-view-mode)
             (not (string-suffix-p ".tex" file))
             (buffer-file-name))
    (let* ((ev last-input-event)
           ;; the clicked page: in continuous mode it need not be the current one
           (page (or (and (bound-and-true-p pdf-view-roll-minor-mode)
                          (consp ev) (posnp (event-start ev))
                          (integerp (posn-point (event-start ev)))
                          (/ (+ (posn-point (event-start ev)) 3) 4))
                     (pdf-view-current-page))))
      (when-let* ((src (dyad--aux-source file (buffer-file-name) page)))
        (list (car src) (cdr src) 0)))))

(defun dyad--after-backward-jump ()
  "After ctrl+click in the PDF: keep the PDF still, and in Beamer go to the frame."
  (when (bound-and-true-p dyad-mode)
    ;; A sync still pending would move away from the place just clicked.
    (when (timerp dyad--timer)
      (cancel-timer dyad--timer))
    (setq dyad--suppress-until (+ (float-time) 0.5))
    (when-let* ((m (dyad-master-file)))
      (when (and (dyad--beamer-p m)
                 (save-excursion
                   (beginning-of-line)
                   (looking-at-p "[ \t]*\\\\end{frame}")))
        (when-let* ((fb (dyad-frame-bounds)))
          (goto-char (point-min))
          (forward-line (1- (car fb))))))))

;;;; Compiling

;;;; Books: built part by part, shown glued

;; A book's parts are whole documents included by its body (with docmute):
;; each is built alone into the output directory, copied like any PDF dyad
;; shows (`dyad--refresh-single-view'), and the copies are glued with qpdf
;; into the PDF shown for the book.  A sidecar file next to it records where
;; each part starts; lookups go to the part's own SyncTeX data and shift pages.

(defconst dyad--part-command-re
  "\\\\[A-Za-z@]+\\*?[ \t]*{[ \t]*\\([^{}%\n]+?\\)[ \t]*}"
  "A command with one braced argument, which may name a part of a book.")

(defun dyad--standalone-p (file)
  "Non-nil when FILE is a whole document: it has a \\begin{document}."
  (dyad--cached
   'standalone file
   (lambda (f)
     (with-temp-buffer
       (insert-file-contents f)
       (goto-char (point-min))
       (and (re-search-forward dyad--begin-document-re nil t) t)))))

(defun dyad--book-parts (master)
  "The parts of MASTER when it is a book, in order, else nil.
Parts are the files named in a command argument in MASTER's body that are
whole documents; at least two make a book.  nil when `dyad-glue' is nil."
  (when (and dyad-glue master (file-readable-p master))
    (let ((parts
           (dyad--cached
            'book master
            (lambda (f)
              (with-temp-buffer
                (insert-file-contents f)
                (goto-char (point-min))
                (let ((dir (file-name-directory f)) parts)
                  (when (dyad--code-search dyad--begin-document-re nil)
                    (forward-line 1)
                    (while (and (dyad--code-search dyad--part-command-re nil)
                                (looking-at dyad--part-command-re))
                      ;; the end first: dyad--standalone-p searches too
                      (let ((file (dyad--tex-file (match-string 1) dir))
                            (end (match-end 0)))
                        (when (and (file-readable-p file)
                                   (not (file-equal-p file f))
                                   (not (member file parts))
                                   (dyad--standalone-p file))
                          (push file parts))
                        (goto-char end))))
                  (nreverse parts)))))))
      (when (cdr parts)
        ;; the parts' copies map back to the parts (lookups, .vrb redirects)
        (mapc #'dyad--pdf-file parts)
        parts))))

(defun dyad--book-of-view (pdf)
  "The book whose glued PDF is PDF, or nil."
  (let ((master (gethash pdf dyad--view-masters)))
    (and master (dyad--book-parts master) master)))

(defun dyad--layout-file (book)
  "The sidecar of BOOK's glued PDF: its parts and where each starts."
  (concat (file-name-sans-extension (dyad--pdf-file book)) ".parts"))

(defun dyad--book-layout (book)
  "BOOK's layout: a list of (PART FIRST-PAGE PAGES COPY-MTIME), or nil.
Read from the sidecar written with the glued PDF."
  (let ((f (dyad--layout-file book)))
    (when (file-readable-p f)
      (dyad--cached
       'layout f
       (lambda (file)
         (ignore-errors
           (with-temp-buffer
             (insert-file-contents file)
             (read (current-buffer)))))))))

(defun dyad--pdf-pages (pdf)
  "Number of pages of PDF (qpdf), or nil."
  (with-temp-buffer
    (and (eql 0 (call-process "qpdf" nil t nil "--show-npages" pdf))
         (string-to-number (buffer-string)))))

(defun dyad--refresh-book (book parts)
  "Glue the copies of BOOK's PARTS into the PDF shown for BOOK.
Non-nil if it changed.
Each part's finished build is copied first.  Nothing happens while a part
has no copy yet, or when the glued PDF is up to date with the copies."
  (mapc #'dyad--refresh-single-view parts)
  (let* ((copies (mapcar #'dyad--pdf-file parts))
         (view (dyad--pdf-file book))
         (layout (dyad--book-layout book)))
    (when (and (cl-every #'file-exists-p copies)
               (executable-find "qpdf")
               (not (and (file-exists-p view)
                         (equal (mapcar #'car layout) parts)
                         (cl-every (lambda (l c) (equal (nth 3 l) (dyad--mtime c)))
                                   layout copies))))
      (make-directory (file-name-directory view) t)
      (let* ((tmp (make-temp-file (expand-file-name ".glue-" (file-name-directory view)) nil ".pdf"))
             (side (concat tmp ".parts"))
             (first 1)
             (new-layout
              (cl-loop for part in parts
                       for copy in copies
                       for n = (dyad--pdf-pages copy)
                       collect (list part first n (dyad--mtime copy))
                       do (setq first (+ first (or n 0)))))
             (ok (and (cl-every #'caddr new-layout)
                      ;; qpdf exits 3 when it only warns: --warning-exit-0
                      (eql 0 (apply #'call-process "qpdf" nil nil nil
                                    "--warning-exit-0" "--empty" "--pages"
                                    (append copies (list "--" tmp)))))))
        (if (not ok)
            (progn (ignore-errors (delete-file tmp)) nil)
          (with-temp-file side (prin1 new-layout (current-buffer)))
          (rename-file side (dyad--layout-file book) t)
          (rename-file tmp view t)
          t)))))

(defun dyad--book-part-at (book page)
  "The part of BOOK on glued PAGE, as (PART . LOCAL-PAGE), or nil."
  (cl-loop for (part first n) in (dyad--book-layout book)
           when (and n (<= first page (+ first n -1)))
           return (cons part (1+ (- page first)))))

(defun dyad--book-offset (book part)
  "Pages of BOOK before PART."
  (let ((l (assoc part (dyad--book-layout book))))
    (and l (1- (nth 1 l)))))

;;;; Build status in the mode lines

;; While a build runs, the source's and the PDF's mode lines say
;; "Building 12s"; after a failed build, "Build failed" until the next good
;; one.  The state lives in two tables, kept up to date by `dyad-compile'
;; and its sentinel (dyad's own builds) and by `dyad--poll' (builds by
;; other programs); the mode-line code only reads them, never the disk.

(defvar dyad--builds (make-hash-table :test 'equal)
  "Main file -> (START . OWN) of the build running: start time, and
whether it is dyad's own run (or another program's, seen by the poll).")

(defvar dyad--failed (make-hash-table :test 'equal)
  "Main file -> log buffer of its last dyad build, when that build failed.")

(defvar dyad--last-built (make-hash-table :test 'equal)
  "Main file -> (TIME . SECONDS) of its last good dyad build.")

(defvar dyad--tick-timer nil
  "Timer that redraws the mode lines every second while a build runs.")

(defun dyad--tick ()
  "Redraw the mode lines; stop when no build runs."
  (force-mode-line-update t)
  (when (zerop (hash-table-count dyad--builds))
    (cancel-timer dyad--tick-timer)
    (setq dyad--tick-timer nil)))

(defun dyad--build-started (master own)
  "Note that a build of MASTER runs; OWN non-nil for dyad's own run."
  (unless (gethash master dyad--builds)
    (puthash master (cons (float-time) own) dyad--builds))
  (unless (timerp dyad--tick-timer)
    (setq dyad--tick-timer (run-with-timer 1 1 #'dyad--tick)))
  (force-mode-line-update t))

(defun dyad--build-ended (master ok &optional log)
  "Note that the build of MASTER ended; OK nil means it failed (LOG: its buffer).
Return the seconds it took, or nil."
  (let ((entry (gethash master dyad--builds)))
    (remhash master dyad--builds)
    (if ok
        (progn
          (remhash master dyad--failed)
          (when entry
            (puthash master (cons (current-time) (- (float-time) (car entry)))
                     dyad--last-built)))
      (puthash master (or log t) dyad--failed))
    (force-mode-line-update t)
    (and entry (- (float-time) (car entry)))))

(defun dyad--status (master)
  "Mode-line text for MASTER's build: building, failed, or empty."
  (cond
   ((null master) "")
   ((gethash master dyad--builds)
    (propertize (format " Building %ds"
                        (round (- (float-time) (car (gethash master dyad--builds)))))
                'face 'warning
                'help-echo "dyad: the PDF is being built"))
   ((gethash master dyad--failed)
    (let ((log (gethash master dyad--failed))
          (map (make-sparse-keymap)))
      (define-key map [mode-line mouse-1]
                  (lambda () (interactive)
                    (if (buffer-live-p (get-buffer log))
                        (display-buffer log)
                      (message "dyad: the build log is gone"))))
      (propertize " Build failed" 'face 'error 'local-map map 'mouse-face 'mode-line-highlight
                  'help-echo (format "dyad: the last build failed; mouse-1: show %s"
                                     (if (bufferp log) (buffer-name log) log)))))
   (t "")))

(defun dyad--lighter ()
  "Mode-line text of `dyad-mode': Sync or Sync:off, and the build status."
  (concat (if dyad-follow " Sync" " Sync:off")
          ;; the cached main file: no file is read during redisplay
          (dyad--status dyad--master)))

(defun dyad--pdf-lighter ()
  "Mode-line text of `dyad-pdf-mode': the build status of its main file."
  (dyad--status (and (buffer-file-name)
                        (gethash (buffer-file-name) dyad--view-masters))))

;;;; The build log pane

(defvar-local dyad--log-master nil
  "In a build log buffer: its main file.")

(defvar dyad--log-buffers (make-hash-table :test 'equal)
  "Main file -> its build log buffer.")

(defun dyad--log-buffer (master)
  "The build log buffer of MASTER, `*dyad NAME*' (NAME<2> for a second
main file of the same name), made once."
  (let ((buf (gethash master dyad--log-buffers)))
    (unless (buffer-live-p buf)
      (let* ((name (format "*dyad %s*" (file-name-nondirectory master)))
             (old (get-buffer name)))
        ;; a log of this main file from before (or from an older dyad): reuse it
        (setq buf (if (and old (member (buffer-local-value 'dyad--log-master old)
                                       (list nil master)))
                      old
                    (generate-new-buffer name))))
      (with-current-buffer buf
        (setq dyad--log-master master
              truncate-lines t
              header-line-format '(:eval (dyad--log-header))))
      (puthash master buf dyad--log-buffers))
    buf))

(defun dyad--log-header ()
  "Header line of a build log: what the build of its main file is doing."
  (let* ((master dyad--log-master)
         (name (and master (file-name-nondirectory master)))
         (run (and master (gethash master dyad--builds)))
         (last (and master (gethash master dyad--last-built))))
    (cond
     ((null master) "")
     (run
      (propertize (format " %s %s ... %d s"
                          (if (cdr run) "Building" "Another program is building")
                          name (round (- (float-time) (car run))))
                  'face 'warning))
     ((gethash master dyad--failed)
      (propertize (format " Build of %s FAILED: the errors are in the log below" name)
                  'face 'error))
     (last
      (propertize (format " Built %s in %.1f s at %s" name (cdr last)
                          (format-time-string "%H:%M" (car last)))
                  'face 'success))
     (t (format " %s: no build yet" name)))))

(defun dyad--log-filter (proc string)
  "Append latexmk's output STRING to its log, and keep the log panes at its end."
  (when (buffer-live-p (process-buffer proc))
    (with-current-buffer (process-buffer proc)
      (save-excursion
        (goto-char (process-mark proc))
        (insert string)
        (set-marker (process-mark proc) (point)))
      (dolist (w (get-buffer-window-list (current-buffer) nil t))
        (set-window-point w (point-max))))))

(defun dyad--log-append (master text)
  "Append TEXT to MASTER's build log, keeping its panes at the end."
  (with-current-buffer (dyad--log-buffer master)
    (save-excursion (goto-char (point-max)) (insert text))
    (dolist (w (get-buffer-window-list (current-buffer) nil t))
      (set-window-point w (point-max)))))

(defun dyad--log-window (pwin master &optional create)
  "The log pane under the PDF window PWIN, showing MASTER's build log.
An existing pane (window parameter `dyad-log') is switched to MASTER's
log; with CREATE, a missing one is made by splitting PWIN, unless
`dyad-log-height' is nil or PWIN is too low."
  (let ((w (cl-find-if (lambda (w) (window-parameter w 'dyad-log))
                       (window-list (window-frame pwin) 'nomini)))
        (log (dyad--log-buffer master)))
    (when (and (null w) create dyad-log-height
               (> (window-total-height pwin) (+ dyad-log-height 10)))
      (setq w (split-window pwin (- dyad-log-height) 'below))
      (set-window-parameter w 'dyad-log t)
      ;; the PDF window got lower: draw its pages at the new size
      (with-current-buffer (window-buffer pwin)
        (when (derived-mode-p 'pdf-view-mode)
          (pdf-view-redisplay pwin))))
    (when (and w (not (eq (window-buffer w) log)))
      (set-window-dedicated-p w nil)
      (set-window-buffer w log)
      (set-window-point w (with-current-buffer log (point-max))))
    (when w
      (set-window-dedicated-p w t)
      ;; keep its height when other panes change (recorded for the log buffer
      ;; it shows: preserving applies only while the window shows that buffer)
      (window-preserve-size w nil t))
    w))

(defvar dyad--synctex-asked (make-hash-table :test 'equal)
  "PDF -> its modification time when a rebuild for missing SyncTeX data was asked.")

(defun dyad--ensure-synctex (master pdf)
  "Non-nil when PDF has SyncTeX data; otherwise rebuild MASTER, once per PDF.
A PDF built by something else (a plain pdflatex run, a Makefile) has no
.synctex.gz, and every lookup would fail quietly.  The rebuild is forced:
latexmk may hold the PDF up to date."
  (if-let* ((parts (dyad--book-parts master)))
      ;; a glued PDF has no SyncTeX file: its parts' copies do
      (let ((missing (cl-remove-if (lambda (p) (dyad--synctex-file (dyad--pdf-file p)))
                                   parts)))
        (when (and missing (not (process-live-p (gethash master dyad--processes))))
          (let ((key (concat pdf "#parts")))
            (unless (equal (gethash key dyad--synctex-asked) (dyad--mtime pdf))
              (puthash key (dyad--mtime pdf) dyad--synctex-asked)
              (message "dyad: some parts of %s have no SyncTeX data; rebuilding them"
                       (file-name-nondirectory master))
              (dyad--compile-book master t missing))))
        (null missing))
  (or (dyad--synctex-file pdf)
      (let ((mtime (file-attribute-modification-time (file-attributes pdf))))
        (unless (equal (gethash pdf dyad--synctex-asked) mtime)
          (puthash pdf mtime dyad--synctex-asked)
          (message "dyad: %s has no SyncTeX data (built without -synctex=1?); rebuilding it"
                   (file-name-nondirectory pdf))
          (dyad-compile master t))
        nil))))

(defun dyad--refused-retry-p (proc)
  "Non-nil when latexmk run PROC refused to retry an earlier failed run.
After a failed run, with the sources unchanged, latexmk answers \"Nothing to
do\" and fails again at once, \"gave an error in previous invocation\";
only a forced run (-g) tries again."
  (when (buffer-live-p (process-buffer proc))
    (with-current-buffer (process-buffer proc)
      (save-excursion
        (goto-char (or (process-get proc 'dyad-start) (point-min)))
        (search-forward "gave an error in previous invocation of latexmk" nil t)))))

(defconst dyad--retry-note
  "latexmk would not retry its earlier failed run (sources unchanged): forcing a rebuild"
  "The log's line when a refused retry is forced.")

(defun dyad-compile (&optional master force file)
  "Compile MASTER (default: this buffer's main file) with latexmk, asynchronously.
A request while a compile runs queues one more run after it.  With FORCE
\(interactively, a prefix argument), latexmk rebuilds even when it holds
the PDF up to date (-g).  A book (`dyad-glue') is built part by part:
only FILE's part when FILE (default: this buffer's file) is one, else
every part (latexmk skips those that are up to date)."
  (interactive (list nil current-prefix-arg))
  (let* ((master (or master (dyad-master-file)))
         (file (or file (buffer-file-name)))
         (parts (dyad--book-parts master)))
    (unless master
      (user-error "dyad: cannot tell the main file; set `TeX-master'"))
    (if parts
        (dyad--compile-book
         master force
         (if (member file parts)
             ;; FILE's part, and any part never built (the glue needs them all)
             (cons file (cl-remove-if (lambda (p) (or (equal p file)
                                                      (file-exists-p (dyad--built-pdf p))))
                                      parts))
           parts))
      (dyad--compile-single master force))))

(defun dyad-compile-whole ()
  "Build the whole book of this buffer, as one document (not glued).
The PDF is latexmk's, in the output directory, to hand out: its page
numbers and the pages the book file adds are the real ones.  The PDF
shown stays the glued one."
  (interactive)
  (let ((master (or (dyad-master-file)
                    (user-error "dyad: cannot tell the main file; set `TeX-master'"))))
    (if (process-live-p (gethash master dyad--processes))
        (user-error "dyad: a build of %s is running; try again when it ends"
                    (file-name-nondirectory master))
      (dyad--compile-single master nil)
      (message "dyad: building the whole of %s into %s"
               (file-name-nondirectory master) (dyad--built-pdf master)))))

(defun dyad--compile-single (master force &optional note)
  "Compile MASTER with latexmk as one document; see `dyad-compile'.
NOTE, a line, goes into the log before the command."
  (progn
    (if (process-live-p (gethash master dyad--processes))
        (puthash master t dyad--pending)
      (let* ((default-directory (file-name-directory master))
             (buf (dyad--log-buffer master))
             (command (append dyad-latexmk-command
                              (and force '("-g"))
                              (list (concat "-outdir=" dyad-output-dir)
                                    (file-name-nondirectory master)))))
        (make-directory dyad-output-dir t)
        (with-current-buffer buf
          (let ((inhibit-read-only t))
            (erase-buffer)
            (when note
              (insert (format "%s %s\n" (format-time-string "%H:%M:%S") note)))
            (insert (format "%s $ %s\n" (format-time-string "%H:%M:%S")
                            (mapconcat #'shell-quote-argument command " ")))))
        (puthash master
                 (make-process
                  :name "dyad-latexmk"
                  :buffer buf
                  :noquery t
                  :command command
                  :filter #'dyad--log-filter
                  :sentinel (lambda (proc _event) (dyad--compiled master proc force)))
                 dyad--processes)
        (with-current-buffer buf
          (let ((proc (gethash master dyad--processes)))
            (set-marker (process-mark proc) (point-max))
            (process-put proc 'dyad-start (point-max))))
        (dyad--build-started master t)
        ;; the log pane under the PDF, when the PDF is shown
        (when-let* ((pbuf (find-buffer-visiting (dyad--pdf-file master)))
                    (pwin (get-buffer-window pbuf)))
          (dyad--log-window pwin master t))))))

(defvar dyad--book-pending (make-hash-table :test 'equal)
  "Book -> parts asked for while a build of the book was running.")

(defun dyad--part-busy-p (part)
  "Non-nil when another program is building PART now (a fresh .synctex(busy))."
  (let ((mt (dyad--mtime (concat (file-name-sans-extension (dyad--built-pdf part))
                                    ".synctex(busy)"))))
    (and mt (< (float-time (time-since mt)) 120))))

(defun dyad--compile-book (book force parts)
  "Build PARTS of BOOK one after another, then show them glued.
The output of every part goes to BOOK's build log.  A request while the
book builds is kept and built after it."
  (if (process-live-p (gethash book dyad--processes))
      (puthash book (cl-union parts (gethash book dyad--book-pending) :test #'equal)
               dyad--book-pending)
    (with-current-buffer (dyad--log-buffer book)
      (let ((inhibit-read-only t)) (erase-buffer)))
    (dyad--build-started book t)
    (when-let* ((pbuf (find-buffer-visiting (dyad--pdf-file book)))
                (pwin (get-buffer-window pbuf)))
      (dyad--log-window pwin book t))
    (dyad--book-step book force parts)))

(defun dyad--book-step (book force queue &optional force-first)
  "Build the first part of QUEUE, then the rest; at the end, show BOOK.
FORCE-FIRST forces the first part only (a refused retry, forced)."
  (cond
   ((null queue) (dyad--book-done book t))
   ((dyad--part-busy-p (car queue))
    ;; another program is writing this part's files: wait for it
    (dyad--log-append book (format "%s %s is being built by another program; waiting\n"
                                      (format-time-string "%H:%M:%S")
                                      (file-name-nondirectory (car queue))))
    (run-with-timer 2 nil #'dyad--book-step book force queue))
   (t
    (let* ((part (car queue))
           (default-directory (file-name-directory part))
           (log (dyad--log-buffer book))
           (forced (or force force-first))
           (command (append dyad-latexmk-command
                            (and forced '("-g"))
                            (list (concat "-outdir=" dyad-output-dir)
                                  (file-name-nondirectory part)))))
      (make-directory dyad-output-dir t)
      (dyad--log-append book (format "%s $ %s\n" (format-time-string "%H:%M:%S")
                                        (mapconcat #'shell-quote-argument command " ")))
      (let ((proc (make-process
                   :name "dyad-latexmk"
                   :buffer log
                   :noquery t
                   :command command
                   :filter #'dyad--log-filter
                   :sentinel
                   (lambda (proc _event)
                     (when (memq (process-status proc) '(exit signal))
                       (cond
                        ((and (eq (process-status proc) 'exit)
                              (zerop (process-exit-status proc)))
                         (dyad--book-step book force (cdr queue)))
                        ((and (not forced) (dyad--refused-retry-p proc))
                         (dyad--log-append book (format "%s %s\n" (format-time-string "%H:%M:%S")
                                                           dyad--retry-note))
                         (dyad--book-step book force queue t))
                        (t
                         (dyad--log-append
                          book (format "%s %s FAILED (exit %s)\n" (format-time-string "%H:%M:%S")
                                       (file-name-nondirectory part) (process-exit-status proc)))
                         (dyad--book-done book nil))))))))
        (with-current-buffer log
          (set-marker (process-mark proc) (point-max))
          (process-put proc 'dyad-start (point-max)))
        (puthash book proc dyad--processes))))))

(defun dyad--book-done (book ok)
  "End of a build of BOOK's parts: glue and show them if OK.
Then build what was asked for meanwhile."
  (remhash book dyad--processes)
  (let ((secs (dyad--build-ended book ok (dyad--log-buffer book))))
    (dyad--log-append
     book (format "\n%s --- %s%s ---\n" (format-time-string "%H:%M:%S")
                  (if ok "built and glued" "FAILED")
                  (if secs (format " in %.1f s" secs) "")))
    (if ok
        (progn
          (dyad--reload book)
          (message "dyad: built %s%s" (file-name-nondirectory book)
                   (if secs (format " in %.1f s" secs) "")))
      (message "dyad: %s did not compile; see buffer %s"
               (file-name-nondirectory book) (buffer-name (dyad--log-buffer book)))))
  (when-let* ((more (gethash book dyad--book-pending)))
    (remhash book dyad--book-pending)
    (dyad--compile-book book nil more)))

(defun dyad--compiled (master proc &optional forced)
  "Handle the end of latexmk run PROC on MASTER (FORCED: run with -g).
A run that latexmk refused to retry is run again, forced, once."
  (when (memq (process-status proc) '(exit signal))
    (remhash master dyad--processes)
    (let ((ok (and (eq (process-status proc) 'exit) (zerop (process-exit-status proc)))))
      (if (and (not ok) (not forced) (dyad--refused-retry-p proc))
          ;; still Building in the mode lines; the queued request waits for it
          (dyad--compile-single master t dyad--retry-note)
        (dyad--compile-ended master proc ok)))))

(defun dyad--compile-ended (master proc ok)
  "Report the end of latexmk run PROC on MASTER (OK: it succeeded).
Then run what was asked for meanwhile."
  (let ((secs (dyad--build-ended master ok (process-buffer proc))))
    (dyad--log-append
     master (format "\n%s --- %s%s ---\n" (format-time-string "%H:%M:%S")
                    (if ok "built" (format "FAILED (exit %s)" (process-exit-status proc)))
                    (if secs (format " in %.1f s" secs) "")))
    (if ok
        (progn
          (dyad--reload master)
          (message "dyad: built %s%s" (file-name-nondirectory master)
                   (if secs (format " in %.1f s" secs) "")))
      (message "dyad: %s did not compile; see buffer %s"
               (file-name-nondirectory master) (buffer-name (process-buffer proc)))))
  (when (gethash master dyad--pending)
    (remhash master dyad--pending)
    (dyad-compile master)))

(defun dyad--reload (master)
  "Show MASTER's new build: copy it to the PDF shown, revert that, sync again."
  (dyad--refresh-view master)
  (dyad--show-build master))

(defun dyad--show-build (master)
  "Revert the PDF buffer of MASTER and sync again (or show the PDF to the
source that asked for it)."
  (let ((pbuf (find-buffer-visiting (dyad--pdf-file master)))
        (asker (gethash master dyad--show-after)))
    (when pbuf
      (with-current-buffer pbuf
        (pdf-view-revert-buffer nil t)))
    (remhash master dyad--show-after)
    (cond
     ((buffer-live-p asker)
      (with-current-buffer asker (dyad-view)))
     (t
      ;; Let redisplay show the reverted PDF first.
      (run-with-timer 0.1 nil #'dyad--resync master)))))

(defun dyad--resync (master)
  "Sync the selected window again if it shows a source of MASTER."
  (with-current-buffer (window-buffer (selected-window))
    (when (and (bound-and-true-p dyad-mode) dyad-follow
               (equal (dyad-master-file) master))
      (setq dyad--last nil)
      (condition-case err
          (dyad-sync)
        (error (message "dyad: %s" (error-message-string err)))))))

;;;; Builds by other programs

;; AUCTeX's C-c C-c, an agent's latexmk run, VS Code: dyad's sentinel does
;; not see these builds, so a timer looks at the built PDFs once a second
;; while dyad shows a PDF (or a source waits for one).

(defvar dyad--poll-timer nil
  "Timer of `dyad--poll', running while dyad shows a PDF.")

(defvar dyad--poll-stamps (make-hash-table :test 'equal)
  "Main file -> size and time of its built PDF at the previous poll.")

(defun dyad--shown-masters ()
  "Main files whose copy has a buffer, or whose PDF a source waits for."
  (let (masters)
    (maphash (lambda (view master)
               (when (find-buffer-visiting view) (push master masters)))
             dyad--view-masters)
    (maphash (lambda (master _) (push master masters)) dyad--show-after)
    (delete-dups masters)))

(defun dyad--poll-master (master)
  "Show a build of MASTER made by another program, once it has settled.
Settled: the built PDF has the size and time it had at the previous poll
\(latexmk reruns pdflatex at once), it is finished, and no dyad run is
going on (its sentinel shows its own builds)."
  (let* ((parts (dyad--book-parts master))
         ;; a book: its parts' builds
         (stamp (let ((stamps (mapcar (lambda (m) (dyad--file-stamp (dyad--built-pdf m)))
                                      (or parts (list master)))))
                  (and (cl-every #'identity stamps) stamps)))
         (own (process-live-p (gethash master dyad--processes))))
    ;; another program building: pdflatex writes NAME.synctex(busy) while it
    ;; runs (a run that died leaves it behind: stale after 2 min)
    (unless own
      (let ((busy (cl-some #'dyad--part-busy-p (or parts (list master))))
            (entry (gethash master dyad--builds)))
        (cond ((and busy (not entry)) (dyad--build-started master nil))
              ((and (not busy) entry (not (cdr entry)))
               (remhash master dyad--builds)
               (force-mode-line-update t)))))
    (when (and stamp
               (equal stamp (gethash master dyad--poll-stamps))
               (not own)
               (dyad--refresh-view master))
      ;; a good build by another program clears an earlier failure
      (remhash master dyad--failed)
      (force-mode-line-update t)
      (dyad--show-build master))
    (puthash master stamp dyad--poll-stamps)))

(defun dyad--poll ()
  "Look for finished builds of the PDFs shown; stop when none is shown."
  (let ((masters (dyad--shown-masters)))
    (if (null masters)
        (dyad--stop-poll)
      (dolist (master masters)
        (condition-case err
            (dyad--poll-master master)
          (error (message "dyad: %s" (error-message-string err))))))))

(defun dyad--start-poll ()
  "Start `dyad--poll' every second, unless it runs already."
  (unless (timerp dyad--poll-timer)
    (setq dyad--poll-timer (run-with-timer 1 1 #'dyad--poll))))

(defun dyad--stop-poll ()
  "Stop `dyad--poll'."
  (when (timerp dyad--poll-timer)
    (cancel-timer dyad--poll-timer))
  (setq dyad--poll-timer nil))

(defun dyad--after-change (&rest _)
  (when dyad-compile-idle-delay
    (when (timerp dyad--idle-timer)
      (cancel-timer dyad--idle-timer))
    (setq dyad--idle-timer
          (run-with-idle-timer dyad-compile-idle-delay nil
                               #'dyad--idle-save (current-buffer)))))

(defun dyad--idle-save (buf)
  (when (and (buffer-live-p buf) (buffer-modified-p buf))
    (with-current-buffer buf
      (let ((save-silently t))
        (save-buffer)))))

(defun dyad--after-save ()
  ;; AUCTeX's C-c C-c saves first and then starts its own run; wait a moment
  ;; to see it, so that two TeX runs never write the same build/ files.
  (when dyad-compile-on-save
    (run-with-timer 0.3 nil #'dyad--compile-after-auctex (current-buffer))))

(defun dyad--auctex-process ()
  "AUCTeX's live process for this buffer's main file, or nil."
  (and (fboundp 'TeX-process) (fboundp 'TeX-master-file)
       (let ((proc (ignore-errors (TeX-process (TeX-master-file)))))
         (and (process-live-p proc) proc))))

(defun dyad--compile-after-auctex (buf)
  "Compile BUF's main file once no AUCTeX run for it is going on."
  (when (buffer-live-p buf)
    (with-current-buffer buf
      (if (dyad--auctex-process)
          (run-with-timer 1 nil #'dyad--compile-after-auctex buf)
        (dyad-compile nil nil (buffer-file-name))))))

;;;; Mode

(defun dyad--document-buffers (pdf)
  "The dyad source buffers whose PDF is PDF."
  (cl-remove-if-not (lambda (b)
                      (with-current-buffer b
                        (and (bound-and-true-p dyad-mode)
                             (when-let* ((m (dyad-master-file)))
                               (equal (dyad--pdf-file m) pdf)))))
                    (buffer-list)))

(defun dyad-toggle-follow (&optional arg)
  "Switch the PDF and the source following each other off or on.
For the whole document of the current buffer: all its source files, from
a source buffer or from its PDF.  Without ARG, toggle; with ARG, on if
it is positive, off otherwise.
Compiling, \\[dyad-view] and ctrl+click work either way; switching it
back on brings the PDF to the place of point."
  (interactive "P")
  (let* ((pdf (cond ((bound-and-true-p dyad-mode)
                     (dyad--pdf-file (or (dyad-master-file)
                                            (user-error "dyad: no main file"))))
                    ((bound-and-true-p dyad-pdf-mode) (buffer-file-name))
                    (t (user-error "dyad: not a dyad source or PDF buffer"))))
         (bufs (dyad--document-buffers pdf))
         (on (if (memq arg '(nil toggle))
                 (not (and bufs (buffer-local-value 'dyad-follow (car bufs))))
                 (> (prefix-numeric-value arg) 0))))
    (dolist (b bufs)
      (with-current-buffer b
        (setq dyad-follow on
              dyad--last nil)))
    (when (timerp dyad--timer) (cancel-timer dyad--timer))
    (force-mode-line-update t)
    (when on
      (when-let* ((w (dyad--source-window pdf)))
        (with-selected-window w (dyad-sync))))
    (message "dyad: following %s%s" (if on "on" "off")
             (if on "" " (M-x dyad-toggle-follow to switch it back on)"))
    on))

(defun dyad--find-master ()
  "Find the main file of this buffer anew.
A guess (`dyad-guess-master') is kept in a buffer-local `TeX-master', so
AUCTeX's own commands agree.  Run when the mode is turned on and again by
`hack-local-variables-hook', after the local variables are applied."
  (setq dyad--master nil
        dyad--last nil)
  (when-let* ((m (dyad-master-file)))
    (unless (or (and (boundp 'TeX-master) (stringp TeX-master))
                (file-equal-p m (buffer-file-name)))
      (setq-local TeX-master
                  (file-name-sans-extension
                   (file-relative-name m (file-name-directory (buffer-file-name))))))))

;;;###autoload
(define-minor-mode dyad-mode
  "Keep the PDF of this LaTeX file in step with point.

Moving or scrolling in the source moves the PDF, and the other way
round; AUCTeX's View (\\[TeX-view]) or \\[dyad-view] shows it.
Ctrl+click in the PDF goes back.  Saving compiles with latexmk.
\\[dyad-toggle-follow] pauses the following both ways (the mode line
then says Sync:off); turning this mode off stops everything, compiling
included, in this buffer."
  :lighter (:eval (dyad--lighter))
  ;; empty: C-c + letter is the user's (e.g. C-c t for `dyad-toggle-follow')
  :keymap (make-sparse-keymap)
  (if dyad-mode
      (progn
        (dyad--find-master)
        ;; Turned on from a mode hook, the mode runs before Emacs applies the
        ;; file's local variables and .dir-locals.el; a `TeX-master' set there
        ;; must replace the main file found now.
        (add-hook 'hack-local-variables-hook #'dyad--find-master nil t)
        (setq-local TeX-output-dir dyad-output-dir)
        (setq-local TeX-view-program-list
                    (cons '("dyad" dyad-view)
                          (and (boundp 'TeX-view-program-list) TeX-view-program-list)))
        (setq-local TeX-view-program-selection '((output-pdf "dyad")))
        (add-hook 'after-change-functions #'dyad--after-change nil t)
        (add-hook 'after-save-hook #'dyad--after-save nil t))
    (remove-hook 'after-change-functions #'dyad--after-change t)
    (remove-hook 'after-save-hook #'dyad--after-save t)
    (remove-hook 'hack-local-variables-hook #'dyad--find-master t)
    (dolist (v '(TeX-output-dir TeX-view-program-list TeX-view-program-selection))
      (kill-local-variable v))))

(add-hook 'post-command-hook #'dyad--post-command)
(add-hook 'pdf-sync-backward-hook #'dyad--after-backward-jump)
(add-hook 'pdf-sync-backward-redirect-functions #'dyad--redirect-aux)

(provide 'dyad)
;;; dyad.el ends here
