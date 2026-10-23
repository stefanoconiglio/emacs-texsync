;;; dyad-test.el --- Tests for dyad  -*- lexical-binding: t -*-

;; Run with `make test'.  The integration tests compile the fixtures with
;; latexmk into a temporary directory and query SyncTeX through epdfinfo.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'dyad)

(defconst dyad-test-dir
  (file-name-directory (or load-file-name buffer-file-name)))

;; The copies of the PDFs shown go to a temporary directory, not the user's cache.
(setq dyad-view-directory (make-temp-file "dyad-views-" t))

(defun dyad-test--copy-fixtures ()
  "Copy the fixtures into a fresh temporary directory and return it."
  (let ((dir (make-temp-file "dyad-test-" t)))
    (copy-directory (expand-file-name "fixtures" dyad-test-dir) dir nil t t)
    (file-name-as-directory dir)))

(defun dyad-test--latexmk (master)
  "Compile MASTER synchronously with dyad's command; fail the test on error.
Then copy the build to the PDF dyad shows, as dyad's own compile does."
  (let ((default-directory (file-name-directory master)))
    (make-directory dyad-output-dir t)
    (should (zerop (apply #'call-process (car dyad-latexmk-command) nil nil nil
                          (append (cdr dyad-latexmk-command)
                                  (list (concat "-outdir=" dyad-output-dir)
                                        (file-name-nondirectory master))))))
    (dyad--refresh-view master)
    (should (file-exists-p (dyad--pdf-file master)))))

(defun dyad-test--goto-line (n)
  (goto-char (point-min))
  (forward-line (1- n)))

(defmacro dyad-test--in-file (file &rest body)
  "Run BODY in a buffer visiting FILE, then kill the buffer."
  (declare (indent 1))
  `(let ((buf (let ((large-file-warning-threshold nil)) (find-file-noselect ,file))))
     (unwind-protect (with-current-buffer buf ,@body)
       (kill-buffer buf))))

;;;; Pure functions

(ert-deftest dyad-test-frame-bounds ()
  "Every line of the fixture deck maps to its frame; comments and gaps to nil."
  (dyad-test--in-file (expand-file-name "fixtures/deck.tex" dyad-test-dir)
    (let ((frames '((7 . 11) (13 . 19) (21 . 26) (28 . 30))))
      (dotimes (i 32)
        (let* ((line (1+ i))
               (want (cl-find-if (lambda (f) (<= (car f) line (cdr f))) frames)))
          (dyad-test--goto-line line)
          (should (equal (cons line (dyad-frame-bounds)) (cons line want))))))))

(ert-deftest dyad-test-structural-lines ()
  (with-temp-buffer
    (insert "text\n\n% comment\n\\begin{equation}\n\\end{equation}\n"
            "\\begin{subequations}\\label{x}\n\\input{sec}\n"
            "\\begin{frame}{Title}\n  x = 1 \\\\\n\\section{A}\n")
    (should (equal (mapcar #'dyad--structural-p (number-sequence 1 10))
                   '(nil t t t t t t nil nil nil)))))

(ert-deftest dyad-test-candidate-lines ()
  (let ((dyad-search-radius 3))
    (should (equal (dyad--candidate-lines 10 100) '(10 9 11 8 12 7 13)))
    (should (equal (dyad--candidate-lines 2 100) '(2 1 3 4 5)))
    (should (equal (dyad--candidate-lines 99 100) '(99 98 100 97 96)))))

(ert-deftest dyad-test-overlay-page ()
  (let ((ranges '((1 . 1) (2 . 4) (5 . 5))))
    (let ((dyad-beamer-overlay 'last))
      (should (equal (mapcar (lambda (p) (dyad-overlay-page p ranges)) '(1 2 3 4 5 9))
                     '(1 4 4 4 5 9))))
    (let ((dyad-beamer-overlay 'first))
      (should (equal (mapcar (lambda (p) (dyad-overlay-page p ranges)) '(1 2 3 4 5))
                     '(1 2 2 2 5))))))

(ert-deftest dyad-test-guess-master ()
  (let* ((dir (file-name-as-directory (make-temp-file "dyad-master-" t)))
         (sec (expand-file-name "sec.tex" dir)))
    (with-temp-file sec (insert "Some text.\n"))
    (with-temp-file (expand-file-name "main.tex" dir)
      (insert "\\documentclass{article}\n\\begin{document}\n\\input{sec}\n\\end{document}\n"))
    (with-temp-file (expand-file-name "notes.tex" dir)
      (insert "\\documentclass{article}\n% \\input{sec}\n"))
    (should (equal (dyad-guess-master sec) (expand-file-name "main.tex" dir)))
    ;; A second main file that inputs sec makes the guess ambiguous.
    (with-temp-file (expand-file-name "other.tex" dir)
      (insert "\\documentclass{beamer}\n\\input{sec.tex}\n"))
    (should (null (dyad-guess-master sec)))
    (delete-directory dir t)))

(ert-deftest dyad-test-master-file ()
  (let* ((dir (dyad-test--copy-fixtures)))
    (dyad-test--in-file (expand-file-name "paper/sec.tex" dir)
      (should (equal (dyad-master-file) (expand-file-name "paper/main.tex" dir))))
    (dyad-test--in-file (expand-file-name "paper/main.tex" dir)
      (should (equal (dyad-master-file) (expand-file-name "paper/main.tex" dir))))
    (dyad-test--in-file (expand-file-name "paper/sec.tex" dir)
      (setq-local TeX-master "../deck")
      (setq dyad--master nil)
      (should (equal (dyad-master-file) (expand-file-name "deck.tex" dir))))
    (delete-directory dir t)))

(ert-deftest dyad-test-local-master ()
  "A `TeX-master' from .dir-locals.el or the file's local variables wins.
dyad is turned on from `LaTeX-mode-hook', as in the setup, which runs
before Emacs applies those variables; each deck is a main file of its own."
  (let* ((dir (file-name-as-directory (make-temp-file "dyad-local-master-" t)))
         (sub (file-name-as-directory (expand-file-name "sub" dir)))
         (deck "\\documentclass{beamer}\n\\begin{document}\n\\begin{frame}x\\end{frame}\n\\end{document}\n")
         (LaTeX-mode-hook (list #'dyad-mode))
         (enable-local-variables :safe))
    (make-directory sub)
    (with-temp-file (expand-file-name "all.tex" dir)
      (insert "\\documentclass{beamer}\n\\usepackage{docmute}\n\\begin{document}\n"
              "\\input{a}\n\\input{sub/b}\n\\end{document}\n"))
    (with-temp-file (expand-file-name "a.tex" dir) (insert deck))
    (with-temp-file (expand-file-name ".dir-locals.el" dir)
      (prin1 '((nil . ((TeX-master . "all.tex")))) (current-buffer)))
    (with-temp-file (expand-file-name "b.tex" sub)
      (insert deck "% Local Variables:\n% TeX-master: \"../all\"\n% End:\n"))
    (dyad-test--in-file (expand-file-name "a.tex" dir)
      (should dyad-mode)
      (should (equal (dyad-master-file) (expand-file-name "all.tex" dir))))
    (dyad-test--in-file (expand-file-name "b.tex" sub)
      (should (equal (dyad-master-file) (expand-file-name "all.tex" dir))))
    (dyad-test--in-file (expand-file-name "all.tex" dir)
      (should (equal (dyad-master-file) (expand-file-name "all.tex" dir))))
    ;; without local variables, a deck is still its own main file
    (delete-file (expand-file-name ".dir-locals.el" dir))
    (setq dir-locals-directory-cache nil)
    (dyad-test--in-file (expand-file-name "a.tex" dir)
      (should (equal (dyad-master-file) (expand-file-name "a.tex" dir))))
    (delete-directory dir t)))

(ert-deftest dyad-test-lecture-with-header ()
  "A lecture whose class is in an \\input header and that names itself with % !TEX root."
  (let* ((dir (dyad-test--copy-fixtures))
         (lecture (expand-file-name "lectures/lecture.tex" dir)))
    (dyad-test--in-file lecture
      (should (equal (dyad-master-file) lecture)))
    (dyad-test--in-file (expand-file-name "lectures/part.tex" dir)
      (should (equal (dyad-master-file) lecture)))   ; `% !TEX root=' without spaces
    (should (equal (dyad--documentclass lecture) "beamer"))
    (should (dyad--beamer-p lecture))
    (delete-directory dir t)))

;;;; The copy shown

(ert-deftest dyad-test-view-copy ()
  "The PDF shown is a copy of a finished build, with its SyncTeX data.
A build still being written is not copied: the copy stays as it was."
  (let* ((dir (dyad-test--copy-fixtures))
         (master (expand-file-name "paper/main.tex" dir))
         (sec (expand-file-name "paper/sec.tex" dir))
         (built (dyad--built-pdf master))
         (pdf (dyad--pdf-file master)))
    (dyad-test--latexmk master)
    (should-not (equal pdf built))
    (should (string-prefix-p (file-name-as-directory dyad-view-directory) pdf))
    (should (equal (dyad--master-of-pdf pdf) master))
    (should (equal (dyad--master-of-pdf built) master))
    (should (dyad--synctex-file pdf))
    (should (equal (dyad--mtime pdf) (dyad--mtime built)))
    (should (dyad--forward sec 5 pdf))           ; SyncTeX answers from the copy
    (should-not (dyad--refresh-view master))     ; the copy is the latest build
    (let ((stamp (dyad--file-stamp pdf))
          (bytes (with-temp-buffer
                   (set-buffer-multibyte nil)
                   (insert-file-contents-literally built)
                   (buffer-substring (point-min) (/ (point-max) 2)))))
      ;; latexmk's PDF half written, as pdflatex leaves it mid-run
      (sleep-for 1.1)
      (let ((coding-system-for-write 'binary)) (write-region bytes nil built))
      (should-not (dyad--complete-pdf-p built))
      (should-not (dyad--build-ready-p master))
      (should-not (dyad--refresh-view master))
      (should (equal (dyad--file-stamp pdf) stamp))
      (should (dyad--complete-pdf-p pdf))
      ;; and a SyncTeX file being written means a run is going on
      (dyad-test--latexmk master)
      (with-temp-file (concat (file-name-sans-extension built) ".synctex(busy)"))
      (should-not (dyad--build-ready-p master)))
    (pdf-info-close pdf)
    (delete-directory dir t)))

(ert-deftest dyad-test-view-during-compile ()
  "While latexmk rewrites its PDF, the copy shown stays readable.
pdf-tools reads the PDF afresh at every query here: the built PDF fails
some of them mid-run (the test sees the problem), the copy none."
  (let* ((dir (make-temp-file "dyad-test-long-" t))
         (master (expand-file-name "long.tex" dir))
         (built (dyad--built-pdf master))
         (pdf (dyad--pdf-file master))
         (built-errors 0) (view-errors 0) (samples 0))
    (with-temp-file master
      (insert "\\documentclass{article}\n\\usepackage{lipsum}\n\\begin{document}\n"
              "\\lipsum[1-150]\n\\lipsum[1-150]\n\\lipsum[1-150]\n\\end{document}\n"))
    (dyad-test--latexmk master)
    (dyad-compile master t)                      ; forced: latexmk rewrites the PDF
    (let ((proc (gethash master dyad--processes)))
      (while (process-live-p proc)
        (cl-incf samples)
        (dolist (f (list built pdf))
          (condition-case nil
              (progn (pdf-info-close f) (pdf-info-number-of-pages f))
            (error (if (equal f built) (cl-incf built-errors) (cl-incf view-errors)))))
        (accept-process-output proc 0.01))
      (while (gethash master dyad--processes) (accept-process-output proc 0.05)))
    (message "dyad-test-view-during-compile: %d samples, built PDF unreadable %d times, copy %d"
             samples built-errors view-errors)
    (should (> samples 5))
    (should (> built-errors 0))
    (should (= view-errors 0))
    (should (equal (dyad--mtime pdf) (dyad--mtime built)))   ; the new build is shown
    (pdf-info-close pdf)
    (pdf-info-close built)
    (delete-directory dir t)))

(ert-deftest dyad-test-external-build ()
  "A build made by another program is copied once it has settled."
  (let* ((dir (dyad-test--copy-fixtures))
         (master (expand-file-name "paper/main.tex" dir))
         (built (dyad--built-pdf master))
         (pdf (dyad--pdf-file master)))
    (dyad-test--latexmk master)
    (let ((old (dyad--mtime pdf))
          (default-directory (file-name-directory master)))
      (sleep-for 1.1)
      ;; another program rebuilds latexmk's PDF
      (should (zerop (apply #'call-process (car dyad-latexmk-command) nil nil nil
                            (append (cdr dyad-latexmk-command)
                                    (list "-g" (concat "-outdir=" dyad-output-dir)
                                          (file-name-nondirectory master))))))
      (should-not (equal (dyad--mtime built) old))
      (dyad--poll-master master)                 ; first sight: not settled yet
      (should (equal (dyad--mtime pdf) old))
      (dyad--poll-master master)                 ; unchanged since: copied
      (should (equal (dyad--mtime pdf) (dyad--mtime built))))
    (delete-directory dir t)))

(ert-deftest dyad-test-adopt-pdf-buffer ()
  "A buffer visiting latexmk's PDF is switched over to the copy; killing it
deletes the copy."
  (let* ((dir (dyad-test--copy-fixtures))
         (master (expand-file-name "paper/main.tex" dir))
         (built (dyad--built-pdf master))
         (pdf (dyad--pdf-file master)))
    (dyad-test--latexmk master)
    (let ((buf (let ((auto-mode-alist nil) (large-file-warning-threshold nil))
                 (find-file-noselect built))))
      (unwind-protect
          (progn
            (should (eq (dyad--pdf-buffer pdf nil) buf))
            (should (equal (buffer-file-name buf) pdf))
            (should-not (buffer-modified-p buf))
            (should (timerp dyad--poll-timer)))
        (kill-buffer buf)
        (dyad--stop-poll)))
    (should-not (file-exists-p (file-name-directory pdf)))
    (delete-directory dir t)))

(ert-deftest dyad-test-view-cache-bounded ()
  "Old copies are pruned, new ones kept; nothing outside the cache is deleted."
  (let* ((old (expand-file-name "old-0123456789" dyad-view-directory))
         (new (expand-file-name "new-0123456789" dyad-view-directory))
         (outside (make-temp-file "dyad-outside-" t)))
    (make-directory old t)
    (make-directory new t)
    (set-file-times old (time-subtract nil (days-to-time 8)))
    (dyad--prune-views)
    (should-not (file-exists-p old))
    (should (file-exists-p new))
    (dyad--delete-view-dir outside)              ; outside the cache: refused
    (should (file-exists-p outside))
    (dyad--delete-view-dir dyad-view-directory) ; the cache itself: refused
    (should (file-exists-p dyad-view-directory))
    (dyad--delete-view-dir new)
    (should-not (file-exists-p new))
    (delete-directory outside t)))

;;;; Against real SyncTeX output

(ert-deftest dyad-test-beamer-targets ()
  "Every line of every frame shows that frame's slide, first or last overlay."
  (let* ((dir (dyad-test--copy-fixtures))
         (master (expand-file-name "deck.tex" dir))
         (pdf (dyad--pdf-file master)))
    (dyad-test--latexmk master)
    (should (equal (dyad--nav-ranges master) '((1 . 1) (2 . 4) (5 . 5) (6 . 6))))
    (dyad-test--in-file master
      (dolist (overlay '(last first))
        (let ((dyad-beamer-overlay overlay)
              (want (if (eq overlay 'last)
                        '(((7 . 11) . 1) ((13 . 19) . 4) ((21 . 26) . 5) ((28 . 30) . 6))
                      '(((7 . 11) . 1) ((13 . 19) . 2) ((21 . 26) . 5) ((28 . 30) . 6)))))
          (dotimes (i 32)
            (let* ((line (1+ i))
                   (frame (cl-find-if (lambda (f) (<= (caar f) line (cdar f))) want)))
              (dyad-test--goto-line line)
              (should (equal (list overlay line (dyad-beamer-target pdf master))
                             (list overlay line (cdr frame)))))))))
    ;; page -> frame start, as used for ctrl+clicks on verbatim frames
    (should (equal (mapcar (lambda (p) (dyad-frame-at-page master pdf p)) '(1 2 3 4 5 6 7))
                   '(7 13 13 13 21 28 nil)))
    ;; the same through one lookup per page, the verbatim frame (.vrb) included
    (should (equal (mapcar (lambda (p) (cdr (dyad-beamer-source master pdf p))) '(1 2 3 4 5 6))
                   '(7 13 13 13 21 28)))
    (pdf-info-close pdf)
    (delete-directory dir t)))

(ert-deftest dyad-test-lecture-targets ()
  "The lecture fixture, both ways: frames, \\section slides, a frame in an \\input file.
Pages: 1 Outline, 2 the \\AtBeginSection slide of Alpha, 3 First, 4 the
slide of Beta, 5 Middle (part.tex), 6 Last (\\subsection Gamma has no slide)."
  (let* ((dir (dyad-test--copy-fixtures))
         (master (expand-file-name "lectures/lecture.tex" dir))
         (part (expand-file-name "lectures/part.tex" dir))
         (pdf (dyad--pdf-file master)))
    (dyad-test--latexmk master)
    (dyad-test--in-file master
      ;; source -> PDF: (line . slide); nil on lines between frames that are not sectioning
      (dolist (case '((16 . 1) (19 . 2) (20 . nil) (22 . 3) (25 . 4) (29 . 6) (32 . 6) (35 . nil)))
        (dyad-test--goto-line (car case))
        (should (equal (cons (car case) (dyad-beamer-target pdf master)) case))))
    (dyad-test--in-file part
      (dyad-test--goto-line 3)
      (should (equal (dyad-master-file) master))
      (should (equal (dyad-beamer-target pdf master) 5)))
    ;; PDF -> source: the frame's first line, or the \\section line of its slide
    (should (equal (mapcar (lambda (p) (dyad-beamer-source master pdf p)) '(1 2 3 4 5 6))
                   (list (cons master 15) (cons master 19) (cons master 21)
                         (cons master 25) (cons part 2) (cons master 31))))
    (pdf-info-close pdf)
    (delete-directory dir t)))

(ert-deftest dyad-test-paper-targets ()
  "Each sentence line maps to where that sentence starts in the PDF.
The ground truth is pdf-tools' text search for the sentence's first words.

Known exception (DESIGN.md, \"Page-break artifact\"): the first line of a
paragraph that starts just after a page break also has SyncTeX records
at the foot of the previous page, and epdfinfo returns that one.  Such
lines are counted, not failed; there can be at most one per page break."
  (let* ((dir (dyad-test--copy-fixtures))
         (master (expand-file-name "paper/main.tex" dir))
         (pdf (dyad--pdf-file master))
         (checked 0)
         (artifacts nil)
         prev)
    (dyad-test--latexmk master)
    (dyad-test--in-file (expand-file-name "paper/sec.tex" dir)
      (goto-char (point-min))
      (while (re-search-forward "^Paragraph \\([0-9]+\\) sentence \\([0-9]+\\)" nil t)
        (let* ((words (match-string 0))
               (first-of-paragraph (equal (match-string 2) "1"))
               (target (dyad-paper-target pdf))
               (hit (car (pdf-info-search-string words nil pdf)))
               (page (alist-get 'page hit))
               (y (nth 1 (car (alist-get 'edges hit)))))
          (should hit)
          (if (and first-of-paragraph
                   (= (car target) (1- page)) (> (cdr target) 0.75) (< y 0.3))
              (push words artifacts)
            (should (equal (list words (car target)) (list words page)))
            (should (< (abs (- (cdr target) y)) 0.02))
            ;; reading order: never back up the page
            (when prev
              (should (or (> (car target) (car prev))
                          (>= (cdr target) (- (cdr prev) 0.002)))))
            (setq prev target))
          (cl-incf checked)))
      (should (= checked 60))
      (should (<= (length artifacts) (1- (pdf-info-number-of-pages pdf))))
      (message "page-break artifacts: %S" artifacts)
      ;; A structural line takes the position of the line above it.
      (goto-char (point-min))
      (re-search-forward "^\\\\begin{equation}")
      (let ((here (dyad-paper-target pdf)))
        (forward-line -1)
        (should (equal here (dyad-paper-target pdf)))))
    (pdf-info-close pdf)
    (delete-directory dir t)))

(ert-deftest dyad-test-bibliography-and-memo ()
  "PDF -> source on the references page: the \\bibliography line, at once.
SyncTeX answers there with the .bbl file LaTeX wrote.  A second call
asks SyncTeX nothing: answers are remembered until the PDF changes."
  (let* ((dir (dyad-test--copy-fixtures))
         (master (expand-file-name "paper/main.tex" dir))
         (pdf (dyad--pdf-file master))
         (asked 0)
         (count (lambda (&rest _) (setq asked (1+ asked)))))
    (dyad-test--latexmk master)
    (advice-add 'pdf-info-synctex-backward-search :before count)
    (unwind-protect
        (let* ((page (alist-get 'page (car (pdf-info-search-string "TeXbook" nil pdf))))
               (hit (car (pdf-info-search-string "TeXbook" nil pdf)))
               (y (nth 1 (car (alist-get 'edges hit))))
               (r (dyad--source-at pdf page y)))
          (should (equal (list (nth 0 r) (nth 1 r)) (list master 15)))
          (should (<= asked 2))
          (setq asked 0)
          (should (equal (dyad--source-at pdf page y) r))
          (should (= asked 0)))
      (advice-remove 'pdf-info-synctex-backward-search count))
    (pdf-info-close pdf)
    (delete-directory dir t)))

(ert-deftest dyad-test-toggle-follow ()
  "`dyad-toggle-follow' pauses the following for every file of the document."
  (let* ((dir (dyad-test--copy-fixtures))
         (main (expand-file-name "paper/main.tex" dir))
         (sec (expand-file-name "paper/sec.tex" dir))
         (bufs (mapcar (lambda (f) (let ((large-file-warning-threshold nil))
                                     (find-file-noselect f)))
                       (list main sec))))
    (unwind-protect
        (progn
          (dolist (b bufs) (with-current-buffer b (dyad-mode 1)))
          (with-current-buffer (cadr bufs)
            (should (eq (dyad-toggle-follow) nil))
            (should-not (cl-some (lambda (b) (buffer-local-value 'dyad-follow b)) bufs))
            ;; the mode line's lighter, (:eval ...); format-mode-line gives "" in batch
            (should (equal (eval (cadr (cadr (assq 'dyad-mode minor-mode-alist))) t)
                           " Sync:off"))
            ;; a command in a paused source schedules nothing
            (switch-to-buffer (current-buffer))
            (setq dyad--timer nil)
            (dyad--post-command)
            (should-not dyad--timer)
            (should (eq (dyad-toggle-follow) t))
            (should (cl-every (lambda (b) (buffer-local-value 'dyad-follow b)) bufs))
            (dyad--post-command)
            (should (timerp dyad--timer))
            (cancel-timer dyad--timer)
            ;; and with an argument: off whatever the state
            (dyad-toggle-follow -1)
            (should-not (buffer-local-value 'dyad-follow (car bufs)))))
      (dolist (b bufs) (with-current-buffer b (set-buffer-modified-p nil)) (kill-buffer b))
      (delete-directory dir t))))

(ert-deftest dyad-test-missing-synctex ()
  "A PDF built without -synctex=1 is rebuilt once, forced, and lookups then work.
SyncTeX answers looked up while the data was missing are not kept."
  (let* ((dir (dyad-test--copy-fixtures))
         (master (expand-file-name "paper/main.tex" dir))
         (sec (expand-file-name "paper/sec.tex" dir))
         (pdf (dyad--pdf-file master)))
    (dyad-test--latexmk master)
    ;; a build without SyncTeX data: neither latexmk's PDF nor the copy has any
    (delete-file (dyad--synctex-file (dyad--built-pdf master)))
    (delete-file (dyad--synctex-file pdf))
    (should-not (dyad--synctex-file pdf))
    (should-not (dyad--forward sec 5 pdf))   ; nothing to look up, remembered as nil
    (should-not (dyad--ensure-synctex master pdf))
    (let ((proc (gethash master dyad--processes)))
      (should (process-live-p proc))
      (should (member "-g" (process-command proc)))
      ;; asked once per PDF: no second rebuild while this one runs
      (should-not (dyad--ensure-synctex master pdf))
      (should-not (gethash master dyad--pending))
      ;; until the sentinel has run: it copies the new build, SyncTeX data included
      (while (gethash master dyad--processes) (accept-process-output proc 0.1)))
    (should (dyad--synctex-file pdf))
    (should (dyad--ensure-synctex master pdf))
    (should (dyad--forward sec 5 pdf))       ; the nil above was not kept
    (pdf-info-close pdf)
    (delete-directory dir t)))

(ert-deftest dyad-test-compile-only-on-save ()
  "By default an edit schedules no save and no compile; saving does compile."
  (let* ((dir (dyad-test--copy-fixtures))
         (main (expand-file-name "paper/main.tex" dir))
         (buf (let ((large-file-warning-threshold nil)) (find-file-noselect main)))
         (compiled nil)
         (spy (lambda (&rest _) (setq compiled t))))
    (should (null (default-value 'dyad-compile-idle-delay)))
    (advice-add 'dyad-compile :override spy)
    (unwind-protect
        (with-current-buffer buf
          (dyad-mode 1)
          (goto-char (point-max))
          (insert "% an edit\n")
          (should-not dyad--idle-timer)          ; nothing will save or compile
          (should (buffer-modified-p))
          (let ((dyad-compile-idle-delay 1.5))   ; the option still works when set
            (insert "% another\n")
            (should (timerp dyad--idle-timer))
            (cancel-timer dyad--idle-timer))
          (setq compiled nil)
          (save-buffer)
          (let ((end (+ (float-time) 3)))            ; compile-on-save runs on a 0.3 s timer
            (while (and (not compiled) (< (float-time) end))
              (accept-process-output nil 0.05)))
          (should compiled))
      (advice-remove 'dyad-compile spy)
      (with-current-buffer buf (set-buffer-modified-p nil))
      (kill-buffer buf)
      (delete-directory dir t))))

(ert-deftest dyad-test-build-status ()
  "The mode lines say Building while a build runs, Build failed after a failed
one until a good one, and see builds by other programs through .synctex(busy)."
  (let* ((dir (dyad-test--copy-fixtures))
         (master (expand-file-name "paper/main.tex" dir))
         (view (dyad--pdf-file master))
         (buf (let ((large-file-warning-threshold nil)) (find-file-noselect master)))
         (status (lambda () (substring-no-properties (dyad--status master))))
         (lighter (lambda () (with-current-buffer buf
                               (substring-no-properties (dyad--lighter)))))
         (pdf-lighter (lambda () (with-temp-buffer
                                   (setq buffer-file-name view)
                                   (prog1 (substring-no-properties (dyad--pdf-lighter))
                                     (setq buffer-file-name nil)))))
         (build (lambda ()
                  (dyad-compile master)
                  (let ((proc (gethash master dyad--processes)))
                    (should (process-live-p proc))
                    (should (string-prefix-p " Building " (funcall status)))
                    (should (string-match-p "\\` Sync Building [0-9]+s\\'" (funcall lighter)))
                    (should (string-prefix-p " Building " (funcall pdf-lighter)))
                    (while (process-live-p proc) (accept-process-output proc 0.1))
                    (accept-process-output nil 0.1)))))  ; let the sentinel run
    (unwind-protect
        (progn
          (with-current-buffer buf (dyad-mode 1) (dyad-master-file))
          (should (equal (funcall status) ""))
          ;; a good build: Building, then nothing
          (funcall build)
          (should (equal (funcall status) ""))
          (should (equal (funcall lighter) " Sync"))
          (should (zerop (hash-table-count dyad--builds)))
          ;; a failed build: Build failed, and it stays
          (with-current-buffer buf
            (goto-char (point-min))
            (re-search-forward "^\\\\section{Conclusion}")
            (insert "\n\\undefinedcommand\n")
            (let ((dyad-compile-on-save nil)) (save-buffer)))
          (funcall build)
          (should (equal (funcall status) " Build failed"))
          (should (equal (funcall lighter) " Sync Build failed"))
          (should (equal (funcall pdf-lighter) " Build failed"))
          (should (buffer-live-p (gethash master dyad--failed)))
          (should (string-match-p "FAILED" (with-current-buffer (dyad--log-buffer master)
                                             (dyad--log-header))))
          ;; fixed: the next good build clears it
          (with-current-buffer buf
            (goto-char (point-min))
            (re-search-forward "^\\\\undefinedcommand\n")
            (replace-match "")
            (let ((dyad-compile-on-save nil)) (save-buffer)))
          (funcall build)
          (should (equal (funcall status) ""))
          ;; a build by another program: seen by the poll through .synctex(busy)
          (let ((busy (expand-file-name "build/main.synctex(busy)" (file-name-directory master))))
            (with-temp-file busy (insert "x"))
            (dyad--poll-master master)
            (should (string-prefix-p " Building " (funcall status)))
            (delete-file busy)
            (dyad--poll-master master)
            (should (equal (funcall status) ""))
            ;; a busy file left by a run that died is not a build
            (with-temp-file busy (insert "x"))
            (set-file-times busy (time-subtract nil 300))
            (dyad--poll-master master)
            (should (equal (funcall status) ""))))
      (clrhash dyad--builds)
      (clrhash dyad--failed)
      (with-current-buffer buf (set-buffer-modified-p nil))
      (kill-buffer buf)
      (ignore-errors (pdf-info-close view))
      (delete-directory dir t))))

(defun dyad-test--break (file)
  "Put an undefined command before FILE's \\end{document} and save it."
  (dyad-test--in-file file
    (goto-char (point-max))
    (re-search-backward "^\\\\end{document}")
    (insert "\\undefinedcommand\n")
    (let ((dyad-compile-on-save nil)) (save-buffer))))

(ert-deftest dyad-test-refused-retry ()
  "After a failed build, with the sources unchanged, latexmk refuses to try
again (\"gave an error in previous invocation\"); dyad forces one rebuild,
so the log shows the real errors, and a forced run that fails stops there.
For one document and for a book's part."
  (let* ((dir (dyad-test--copy-fixtures))
         ;; a document with no bibliography: latexmk would rerun bibtex
         (master (let ((f (expand-file-name "plain.tex" dir)))
                   (with-temp-file f
                     (insert "\\documentclass{article}\n\\begin{document}\nText.\n\\end{document}\n"))
                   f))
         (log (lambda (m) (with-current-buffer (dyad--log-buffer m) (buffer-string))))
         (build (lambda ()
                  (dyad-compile master)
                  (let ((end (+ (float-time) 120)))
                    ;; the forced run starts from the first one's sentinel
                    (while (and (gethash master dyad--builds) (< (float-time) end))
                      (accept-process-output nil 0.1))))))
    (unwind-protect
        (progn
          (dyad-test--break master)
          ;; the first failed build is reported as it is
          (funcall build)
          (should-not (string-match-p (regexp-quote dyad--retry-note) (funcall log master)))
          (should (string-match-p "FAILED" (funcall log master)))
          ;; unchanged: latexmk refuses, dyad forces the rebuild, once
          (funcall build)
          (let ((text (funcall log master)))
            (should (string-match-p (regexp-quote dyad--retry-note) text))
            (should (string-match-p " -g " text))
            (should (string-match-p "Undefined control sequence" text))
            (should-not (string-match-p "gave an error in previous invocation" text))
            (should (string-match-p "FAILED" text)))
          (should (buffer-live-p (gethash master dyad--failed)))
          (should-not (gethash master dyad--processes))
          ;; a book: its broken part is forced, the others are not rebuilt
          (let* ((dyad-glue t)
                 (book (expand-file-name "book/book.tex" dir))
                 (d2 (expand-file-name "book/d2.tex" dir)))
            (dyad-test--break d2)
            (dyad-test--build-book book)
            (should-not (string-match-p (regexp-quote dyad--retry-note) (funcall log book)))
            (dyad-test--build-book book)
            (let ((text (funcall log book)))
              (should (string-match-p (regexp-quote dyad--retry-note) text))
              (should (string-match-p " -g -outdir[^ ]* d2\\.tex" text))
              (should-not (string-match-p " -g -outdir[^ ]* d1\\.tex" text))
              (should (string-match-p "d2.tex FAILED" text)))))
      (clrhash dyad--builds)
      (clrhash dyad--failed)
      (delete-directory dir t))))

(ert-deftest dyad-test-log-pane ()
  "The build log pane: made once under the PDF window, latexmk's output arriving
in it with the pane at the end, a header saying building, then built."
  (let* ((dir (dyad-test--copy-fixtures))
         (master (expand-file-name "paper/main.tex" dir))
         (header (lambda () (with-current-buffer (dyad--log-buffer master)
                              (substring-no-properties (dyad--log-header))))))
    (unwind-protect
        (save-window-excursion
          (delete-other-windows)
          (let* ((pwin (selected-window))   ; stands in for the PDF window
                 (w (progn (set-window-buffer pwin (get-buffer-create "*fake pdf*"))
                           (dyad--log-window pwin master t))))
            (should (window-parameter w 'dyad-log))
            (should (= (window-total-height w) dyad-log-height))
            (should (window-dedicated-p w))
            (should (window-preserved-size w))           ; its height is kept
            (should (eq (window-buffer w) (dyad--log-buffer master)))
            (should (eq (dyad--log-window pwin master t) w))   ; not a second pane
            (should (= (length (window-list)) 2))
            (should (string-match-p "no build yet" (funcall header)))
            (dyad-compile master)
            (let ((proc (gethash master dyad--processes)))
              (should (string-match-p "\\` Building main\\.tex \\.\\.\\. [0-9]+ s\\'" (funcall header)))
              (while (process-live-p proc) (accept-process-output proc 0.1))
              (accept-process-output nil 0.1))
            (with-current-buffer (dyad--log-buffer master)
              (should (string-match-p "\\$ latexmk" (buffer-string)))
              (should (string-match-p "Latexmk" (buffer-string)))      ; latexmk's own output
              (should (string-match-p "--- built in [0-9.]+ s ---" (buffer-string)))
              (should (= (window-point w) (point-max))))
            (should (string-match-p "\\` Built main\\.tex in [0-9.]+ s at [0-9][0-9]:[0-9][0-9]\\'"
                                    (funcall header)))
            ;; a second main file of the same name has a log of its own
            (let ((other (expand-file-name "lectures/main.tex" dir)))
              (should-not (eq (dyad--log-buffer other) (dyad--log-buffer master))))))
      (clrhash dyad--builds)
      (clrhash dyad--failed)
      (ignore-errors (pdf-info-close (dyad--pdf-file master)))
      (delete-directory dir t))))

(ert-deftest dyad-test-book-parts-many ()
  "All parts of a book with many, read with nothing cached (the check that a
part is a whole document searches too, and must not move the parser)."
  (let* ((dyad-glue t)
         (dir (file-name-as-directory (make-temp-file "dyad-book-" t)))
         (names (mapcar (lambda (i) (format "deck-%d---with-a-long-name" i)) (number-sequence 1 7))))
    (dolist (n names)
      (with-temp-file (expand-file-name (concat n ".tex") dir)
        ;; \\begin{document} far into the file, after a long comment (as in
        ;; real decks): a search there used to move the parser past later parts
        (insert "\\documentclass{beamer}\n\\input{header}\n"
                (mapconcat (lambda (_) "% a long comment line about this deck, its plan and its sources")
                           (number-sequence 1 40) "\n")
                "\n\\begin{document}\n"
                "\\begin{frame}{X}\n  x\n\\end{frame}\n\\end{document}\n")))
    (with-temp-file (expand-file-name "header.tex" dir) (insert "\\usepackage{amsmath}\n"))
    (with-temp-file (expand-file-name "all.tex" dir)
      (insert "\\documentclass{beamer}\n\\input{header}\n\\usepackage{docmute}\n"
              "\\newcommand{\\deck}[1]{\\part{#1}\\input{#1}}\n\\begin{document}\n"
              (mapconcat (lambda (n) (format "\\deck{%s}" n)) names "\n")
              "\n% \\deck{commented-out}\n\\end{document}\n"))
    (clrhash dyad--file-cache)
    (should (equal (mapcar #'file-name-base (dyad--book-parts (expand-file-name "all.tex" dir)))
                   names))
    (delete-directory dir t)))

(defun dyad-test--build-book (book &optional file)
  "Build BOOK (only FILE's part when FILE is one) and wait until it is glued."
  (dyad-compile book nil file)
  (let ((end (+ (float-time) 120)))
    (while (and (or (process-live-p (gethash book dyad--processes))
                    (gethash book dyad--book-pending))
                (< (float-time) end))
      (accept-process-output nil 0.1))
    (accept-process-output nil 0.2)))

(ert-deftest dyad-test-book ()
  "A book glued from two decks: its parts, the glued PDF and its layout,
lookups both ways through the parts (a verbatim slide included), the
combined frame ranges, a save rebuilding only its part, a restart.
Books are glued only when `dyad-glue' is on; it is off by default."
  (should-not (default-value 'dyad-glue))
  (let* ((dyad-glue t)
         (dir (dyad-test--copy-fixtures))
         (book (expand-file-name "book/book.tex" dir))
         (d1 (expand-file-name "book/d1.tex" dir))
         (d2 (expand-file-name "book/d2.tex" dir))
         (view (dyad--pdf-file book)))
    (unwind-protect
        (progn
          ;; parts: the whole documents its body includes, in order
          (should (equal (dyad--book-parts book) (list d1 d2)))
          (should-not (dyad--book-parts d1))
          (should-not (dyad--book-parts (expand-file-name "paper/main.tex" dir)))
          (should-not (dyad--book-parts (expand-file-name "lectures/lecture.tex" dir)))
          (let ((dyad-glue nil)) (should-not (dyad--book-parts book)))
          ;; build: every part, then glued
          (dyad-test--build-book book)
          (should (string-match-p "built and glued" (with-current-buffer (dyad--log-buffer book)
                                                      (buffer-string))))
          (should (file-exists-p view))
          (should (= (dyad--pdf-pages view) 6))
          (should (equal (mapcar (lambda (l) (list (nth 0 l) (nth 1 l) (nth 2 l)))
                                 (dyad--book-layout book))
                         (list (list d1 1 3) (list d2 4 3))))
          (should (equal (dyad--nav-ranges book) '((1 . 1) (2 . 3) (4 . 4) (5 . 5) (6 . 6))))
          (should (dyad--ensure-synctex book view))
          ;; source -> glued PDF: each frame's slide, shifted by its part's offset
          (dolist (case (list (list d1 5 1) (list d1 10 3) (list d2 5 4) (list d2 9 5) (list d2 15 6)))
            (dyad-test--in-file (car case)
              (should (equal (dyad-master-file) (car case)))   ; no TeX-master in the fixture
              (dyad-test--goto-line (nth 1 case))
              (should (equal (list (nth 1 case) (dyad-beamer-target view book))
                             (list (nth 1 case) (nth 2 case))))))
          ;; glued PDF -> source: the part's file, the frame's first line
          (should (equal (mapcar (lambda (p) (dyad-beamer-source book view p)) '(1 2 3 4 5 6))
                         (list (cons d1 4) (cons d1 8) (cons d1 8)
                               (cons d2 4) (cons d2 8) (cons d2 12))))   ; 6: verbatim (.vrb)
          ;; a save of d1 rebuilds d1 only
          (let ((m2 (dyad--mtime (dyad--built-pdf d2)))
                (m1 (dyad--mtime (dyad--built-pdf d1)))
                (v (dyad--mtime view)))
            (dyad-test--in-file d1
              (goto-char (point-min))
              (re-search-forward "First deck, first slide\\.")
              (insert " Edited.")
              (let ((dyad-compile-on-save nil)) (save-buffer)))
            (dyad-test--build-book book d1)
            (should-not (equal m1 (dyad--mtime (dyad--built-pdf d1))))
            (should (equal m2 (dyad--mtime (dyad--built-pdf d2))))
            (should-not (equal v (dyad--mtime view))))
          ;; a restart: the layout comes back from the sidecar
          (clrhash dyad--file-cache)
          (clrhash dyad--memo)
          (should (equal (cdr (dyad--book-part-at book 5)) 2))
          (should (equal (dyad-beamer-source book view 5) (cons d2 8))))
      (clrhash dyad--builds)
      (clrhash dyad--failed)
      (dolist (f (list view (dyad--pdf-file d1) (dyad--pdf-file d2)))
        (ignore-errors (pdf-info-close f)))
      (delete-directory dir t))))

(provide 'dyad-test)
;;; dyad-test.el ends here
