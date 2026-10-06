;;; texsync-test.el --- Tests for texsync  -*- lexical-binding: t -*-

;; Run with `make test'.  The integration tests compile the fixtures with
;; latexmk into a temporary directory and query SyncTeX through epdfinfo.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'texsync)

(defconst texsync-test-dir
  (file-name-directory (or load-file-name buffer-file-name)))

;; The copies of the PDFs shown go to a temporary directory, not the user's cache.
(setq texsync-view-directory (make-temp-file "texsync-views-" t))

(defun texsync-test--copy-fixtures ()
  "Copy the fixtures into a fresh temporary directory and return it."
  (let ((dir (make-temp-file "texsync-test-" t)))
    (copy-directory (expand-file-name "fixtures" texsync-test-dir) dir nil t t)
    (file-name-as-directory dir)))

(defun texsync-test--latexmk (master)
  "Compile MASTER synchronously with texsync's command; fail the test on error.
Then copy the build to the PDF texsync shows, as texsync's own compile does."
  (let ((default-directory (file-name-directory master)))
    (make-directory texsync-output-dir t)
    (should (zerop (apply #'call-process (car texsync-latexmk-command) nil nil nil
                          (append (cdr texsync-latexmk-command)
                                  (list (concat "-outdir=" texsync-output-dir)
                                        (file-name-nondirectory master))))))
    (texsync--refresh-view master)
    (should (file-exists-p (texsync--pdf-file master)))))

(defun texsync-test--goto-line (n)
  (goto-char (point-min))
  (forward-line (1- n)))

(defmacro texsync-test--in-file (file &rest body)
  "Run BODY in a buffer visiting FILE, then kill the buffer."
  (declare (indent 1))
  `(let ((buf (let ((large-file-warning-threshold nil)) (find-file-noselect ,file))))
     (unwind-protect (with-current-buffer buf ,@body)
       (kill-buffer buf))))

;;;; Pure functions

(ert-deftest texsync-test-frame-bounds ()
  "Every line of the fixture deck maps to its frame; comments and gaps to nil."
  (texsync-test--in-file (expand-file-name "fixtures/deck.tex" texsync-test-dir)
    (let ((frames '((7 . 11) (13 . 19) (21 . 26) (28 . 30))))
      (dotimes (i 32)
        (let* ((line (1+ i))
               (want (cl-find-if (lambda (f) (<= (car f) line (cdr f))) frames)))
          (texsync-test--goto-line line)
          (should (equal (cons line (texsync-frame-bounds)) (cons line want))))))))

(ert-deftest texsync-test-structural-lines ()
  (with-temp-buffer
    (insert "text\n\n% comment\n\\begin{equation}\n\\end{equation}\n"
            "\\begin{subequations}\\label{x}\n\\input{sec}\n"
            "\\begin{frame}{Title}\n  x = 1 \\\\\n\\section{A}\n")
    (should (equal (mapcar #'texsync--structural-p (number-sequence 1 10))
                   '(nil t t t t t t nil nil nil)))))

(ert-deftest texsync-test-candidate-lines ()
  (let ((texsync-search-radius 3))
    (should (equal (texsync--candidate-lines 10 100) '(10 9 11 8 12 7 13)))
    (should (equal (texsync--candidate-lines 2 100) '(2 1 3 4 5)))
    (should (equal (texsync--candidate-lines 99 100) '(99 98 100 97 96)))))

(ert-deftest texsync-test-overlay-page ()
  (let ((ranges '((1 . 1) (2 . 4) (5 . 5))))
    (let ((texsync-beamer-overlay 'last))
      (should (equal (mapcar (lambda (p) (texsync-overlay-page p ranges)) '(1 2 3 4 5 9))
                     '(1 4 4 4 5 9))))
    (let ((texsync-beamer-overlay 'first))
      (should (equal (mapcar (lambda (p) (texsync-overlay-page p ranges)) '(1 2 3 4 5))
                     '(1 2 2 2 5))))))

(ert-deftest texsync-test-guess-master ()
  (let* ((dir (file-name-as-directory (make-temp-file "texsync-master-" t)))
         (sec (expand-file-name "sec.tex" dir)))
    (with-temp-file sec (insert "Some text.\n"))
    (with-temp-file (expand-file-name "main.tex" dir)
      (insert "\\documentclass{article}\n\\begin{document}\n\\input{sec}\n\\end{document}\n"))
    (with-temp-file (expand-file-name "notes.tex" dir)
      (insert "\\documentclass{article}\n% \\input{sec}\n"))
    (should (equal (texsync-guess-master sec) (expand-file-name "main.tex" dir)))
    ;; A second main file that inputs sec makes the guess ambiguous.
    (with-temp-file (expand-file-name "other.tex" dir)
      (insert "\\documentclass{beamer}\n\\input{sec.tex}\n"))
    (should (null (texsync-guess-master sec)))
    (delete-directory dir t)))

(ert-deftest texsync-test-master-file ()
  (let* ((dir (texsync-test--copy-fixtures)))
    (texsync-test--in-file (expand-file-name "paper/sec.tex" dir)
      (should (equal (texsync-master-file) (expand-file-name "paper/main.tex" dir))))
    (texsync-test--in-file (expand-file-name "paper/main.tex" dir)
      (should (equal (texsync-master-file) (expand-file-name "paper/main.tex" dir))))
    (texsync-test--in-file (expand-file-name "paper/sec.tex" dir)
      (setq-local TeX-master "../deck")
      (setq texsync--master nil)
      (should (equal (texsync-master-file) (expand-file-name "deck.tex" dir))))
    (delete-directory dir t)))

(ert-deftest texsync-test-local-master ()
  "A `TeX-master' from .dir-locals.el or the file's local variables wins.
texsync is turned on from `LaTeX-mode-hook', as in the setup, which runs
before Emacs applies those variables; each deck is a main file of its own."
  (let* ((dir (file-name-as-directory (make-temp-file "texsync-local-master-" t)))
         (sub (file-name-as-directory (expand-file-name "sub" dir)))
         (deck "\\documentclass{beamer}\n\\begin{document}\n\\begin{frame}x\\end{frame}\n\\end{document}\n")
         (LaTeX-mode-hook (list #'texsync-mode))
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
    (texsync-test--in-file (expand-file-name "a.tex" dir)
      (should texsync-mode)
      (should (equal (texsync-master-file) (expand-file-name "all.tex" dir))))
    (texsync-test--in-file (expand-file-name "b.tex" sub)
      (should (equal (texsync-master-file) (expand-file-name "all.tex" dir))))
    (texsync-test--in-file (expand-file-name "all.tex" dir)
      (should (equal (texsync-master-file) (expand-file-name "all.tex" dir))))
    ;; without local variables, a deck is still its own main file
    (delete-file (expand-file-name ".dir-locals.el" dir))
    (setq dir-locals-directory-cache nil)
    (texsync-test--in-file (expand-file-name "a.tex" dir)
      (should (equal (texsync-master-file) (expand-file-name "a.tex" dir))))
    (delete-directory dir t)))

(ert-deftest texsync-test-lecture-with-header ()
  "A lecture whose class is in an \\input header and that names itself with % !TEX root."
  (let* ((dir (texsync-test--copy-fixtures))
         (lecture (expand-file-name "lectures/lecture.tex" dir)))
    (texsync-test--in-file lecture
      (should (equal (texsync-master-file) lecture)))
    (texsync-test--in-file (expand-file-name "lectures/part.tex" dir)
      (should (equal (texsync-master-file) lecture)))   ; `% !TEX root=' without spaces
    (should (equal (texsync--documentclass lecture) "beamer"))
    (should (texsync--beamer-p lecture))
    (delete-directory dir t)))

;;;; The copy shown

(ert-deftest texsync-test-view-copy ()
  "The PDF shown is a copy of a finished build, with its SyncTeX data.
A build still being written is not copied: the copy stays as it was."
  (let* ((dir (texsync-test--copy-fixtures))
         (master (expand-file-name "paper/main.tex" dir))
         (sec (expand-file-name "paper/sec.tex" dir))
         (built (texsync--built-pdf master))
         (pdf (texsync--pdf-file master)))
    (texsync-test--latexmk master)
    (should-not (equal pdf built))
    (should (string-prefix-p (file-name-as-directory texsync-view-directory) pdf))
    (should (equal (texsync--master-of-pdf pdf) master))
    (should (equal (texsync--master-of-pdf built) master))
    (should (texsync--synctex-file pdf))
    (should (equal (texsync--mtime pdf) (texsync--mtime built)))
    (should (texsync--forward sec 5 pdf))           ; SyncTeX answers from the copy
    (should-not (texsync--refresh-view master))     ; the copy is the latest build
    (let ((stamp (texsync--file-stamp pdf))
          (bytes (with-temp-buffer
                   (set-buffer-multibyte nil)
                   (insert-file-contents-literally built)
                   (buffer-substring (point-min) (/ (point-max) 2)))))
      ;; latexmk's PDF half written, as pdflatex leaves it mid-run
      (sleep-for 1.1)
      (let ((coding-system-for-write 'binary)) (write-region bytes nil built))
      (should-not (texsync--complete-pdf-p built))
      (should-not (texsync--build-ready-p master))
      (should-not (texsync--refresh-view master))
      (should (equal (texsync--file-stamp pdf) stamp))
      (should (texsync--complete-pdf-p pdf))
      ;; and a SyncTeX file being written means a run is going on
      (texsync-test--latexmk master)
      (with-temp-file (concat (file-name-sans-extension built) ".synctex(busy)"))
      (should-not (texsync--build-ready-p master)))
    (pdf-info-close pdf)
    (delete-directory dir t)))

(ert-deftest texsync-test-view-during-compile ()
  "While latexmk rewrites its PDF, the copy shown stays readable.
pdf-tools reads the PDF afresh at every query here: the built PDF fails
some of them mid-run (the test sees the problem), the copy none."
  (let* ((dir (make-temp-file "texsync-test-long-" t))
         (master (expand-file-name "long.tex" dir))
         (built (texsync--built-pdf master))
         (pdf (texsync--pdf-file master))
         (built-errors 0) (view-errors 0) (samples 0))
    (with-temp-file master
      (insert "\\documentclass{article}\n\\usepackage{lipsum}\n\\begin{document}\n"
              "\\lipsum[1-150]\n\\lipsum[1-150]\n\\lipsum[1-150]\n\\end{document}\n"))
    (texsync-test--latexmk master)
    (texsync-compile master t)                      ; forced: latexmk rewrites the PDF
    (let ((proc (gethash master texsync--processes)))
      (while (process-live-p proc)
        (cl-incf samples)
        (dolist (f (list built pdf))
          (condition-case nil
              (progn (pdf-info-close f) (pdf-info-number-of-pages f))
            (error (if (equal f built) (cl-incf built-errors) (cl-incf view-errors)))))
        (accept-process-output proc 0.01))
      (while (gethash master texsync--processes) (accept-process-output proc 0.05)))
    (message "texsync-test-view-during-compile: %d samples, built PDF unreadable %d times, copy %d"
             samples built-errors view-errors)
    (should (> samples 5))
    (should (> built-errors 0))
    (should (= view-errors 0))
    (should (equal (texsync--mtime pdf) (texsync--mtime built)))   ; the new build is shown
    (pdf-info-close pdf)
    (pdf-info-close built)
    (delete-directory dir t)))

(ert-deftest texsync-test-external-build ()
  "A build made by another program is copied once it has settled."
  (let* ((dir (texsync-test--copy-fixtures))
         (master (expand-file-name "paper/main.tex" dir))
         (built (texsync--built-pdf master))
         (pdf (texsync--pdf-file master)))
    (texsync-test--latexmk master)
    (let ((old (texsync--mtime pdf))
          (default-directory (file-name-directory master)))
      (sleep-for 1.1)
      ;; another program rebuilds latexmk's PDF
      (should (zerop (apply #'call-process (car texsync-latexmk-command) nil nil nil
                            (append (cdr texsync-latexmk-command)
                                    (list "-g" (concat "-outdir=" texsync-output-dir)
                                          (file-name-nondirectory master))))))
      (should-not (equal (texsync--mtime built) old))
      (texsync--poll-master master)                 ; first sight: not settled yet
      (should (equal (texsync--mtime pdf) old))
      (texsync--poll-master master)                 ; unchanged since: copied
      (should (equal (texsync--mtime pdf) (texsync--mtime built))))
    (delete-directory dir t)))

(ert-deftest texsync-test-adopt-pdf-buffer ()
  "A buffer visiting latexmk's PDF is switched over to the copy; killing it
deletes the copy."
  (let* ((dir (texsync-test--copy-fixtures))
         (master (expand-file-name "paper/main.tex" dir))
         (built (texsync--built-pdf master))
         (pdf (texsync--pdf-file master)))
    (texsync-test--latexmk master)
    (let ((buf (let ((auto-mode-alist nil) (large-file-warning-threshold nil))
                 (find-file-noselect built))))
      (unwind-protect
          (progn
            (should (eq (texsync--pdf-buffer pdf nil) buf))
            (should (equal (buffer-file-name buf) pdf))
            (should-not (buffer-modified-p buf))
            (should (timerp texsync--poll-timer)))
        (kill-buffer buf)
        (texsync--stop-poll)))
    (should-not (file-exists-p (file-name-directory pdf)))
    (delete-directory dir t)))

(ert-deftest texsync-test-view-cache-bounded ()
  "Old copies are pruned, new ones kept; nothing outside the cache is deleted."
  (let* ((old (expand-file-name "old-0123456789" texsync-view-directory))
         (new (expand-file-name "new-0123456789" texsync-view-directory))
         (outside (make-temp-file "texsync-outside-" t)))
    (make-directory old t)
    (make-directory new t)
    (set-file-times old (time-subtract nil (days-to-time 8)))
    (texsync--prune-views)
    (should-not (file-exists-p old))
    (should (file-exists-p new))
    (texsync--delete-view-dir outside)              ; outside the cache: refused
    (should (file-exists-p outside))
    (texsync--delete-view-dir texsync-view-directory) ; the cache itself: refused
    (should (file-exists-p texsync-view-directory))
    (texsync--delete-view-dir new)
    (should-not (file-exists-p new))
    (delete-directory outside t)))

;;;; Against real SyncTeX output

(ert-deftest texsync-test-beamer-targets ()
  "Every line of every frame shows that frame's slide, first or last overlay."
  (let* ((dir (texsync-test--copy-fixtures))
         (master (expand-file-name "deck.tex" dir))
         (pdf (texsync--pdf-file master)))
    (texsync-test--latexmk master)
    (should (equal (texsync--nav-ranges master) '((1 . 1) (2 . 4) (5 . 5) (6 . 6))))
    (texsync-test--in-file master
      (dolist (overlay '(last first))
        (let ((texsync-beamer-overlay overlay)
              (want (if (eq overlay 'last)
                        '(((7 . 11) . 1) ((13 . 19) . 4) ((21 . 26) . 5) ((28 . 30) . 6))
                      '(((7 . 11) . 1) ((13 . 19) . 2) ((21 . 26) . 5) ((28 . 30) . 6)))))
          (dotimes (i 32)
            (let* ((line (1+ i))
                   (frame (cl-find-if (lambda (f) (<= (caar f) line (cdar f))) want)))
              (texsync-test--goto-line line)
              (should (equal (list overlay line (texsync-beamer-target pdf master))
                             (list overlay line (cdr frame)))))))))
    ;; page -> frame start, as used for ctrl+clicks on verbatim frames
    (should (equal (mapcar (lambda (p) (texsync-frame-at-page master pdf p)) '(1 2 3 4 5 6 7))
                   '(7 13 13 13 21 28 nil)))
    ;; the same through one lookup per page, the verbatim frame (.vrb) included
    (should (equal (mapcar (lambda (p) (cdr (texsync-beamer-source master pdf p))) '(1 2 3 4 5 6))
                   '(7 13 13 13 21 28)))
    (pdf-info-close pdf)
    (delete-directory dir t)))

(ert-deftest texsync-test-lecture-targets ()
  "The lecture fixture, both ways: frames, \\section slides, a frame in an \\input file.
Pages: 1 Outline, 2 the \\AtBeginSection slide of Alpha, 3 First, 4 the
slide of Beta, 5 Middle (part.tex), 6 Last (\\subsection Gamma has no slide)."
  (let* ((dir (texsync-test--copy-fixtures))
         (master (expand-file-name "lectures/lecture.tex" dir))
         (part (expand-file-name "lectures/part.tex" dir))
         (pdf (texsync--pdf-file master)))
    (texsync-test--latexmk master)
    (texsync-test--in-file master
      ;; source -> PDF: (line . slide); nil on lines between frames that are not sectioning
      (dolist (case '((16 . 1) (19 . 2) (20 . nil) (22 . 3) (25 . 4) (29 . 6) (32 . 6) (35 . nil)))
        (texsync-test--goto-line (car case))
        (should (equal (cons (car case) (texsync-beamer-target pdf master)) case))))
    (texsync-test--in-file part
      (texsync-test--goto-line 3)
      (should (equal (texsync-master-file) master))
      (should (equal (texsync-beamer-target pdf master) 5)))
    ;; PDF -> source: the frame's first line, or the \\section line of its slide
    (should (equal (mapcar (lambda (p) (texsync-beamer-source master pdf p)) '(1 2 3 4 5 6))
                   (list (cons master 15) (cons master 19) (cons master 21)
                         (cons master 25) (cons part 2) (cons master 31))))
    (pdf-info-close pdf)
    (delete-directory dir t)))

(ert-deftest texsync-test-paper-targets ()
  "Each sentence line maps to where that sentence starts in the PDF.
The ground truth is pdf-tools' text search for the sentence's first words.

Known exception (DESIGN.md, \"Page-break artifact\"): the first line of a
paragraph that starts just after a page break also has SyncTeX records
at the foot of the previous page, and epdfinfo returns that one.  Such
lines are counted, not failed; there can be at most one per page break."
  (let* ((dir (texsync-test--copy-fixtures))
         (master (expand-file-name "paper/main.tex" dir))
         (pdf (texsync--pdf-file master))
         (checked 0)
         (artifacts nil)
         prev)
    (texsync-test--latexmk master)
    (texsync-test--in-file (expand-file-name "paper/sec.tex" dir)
      (goto-char (point-min))
      (while (re-search-forward "^Paragraph \\([0-9]+\\) sentence \\([0-9]+\\)" nil t)
        (let* ((words (match-string 0))
               (first-of-paragraph (equal (match-string 2) "1"))
               (target (texsync-paper-target pdf))
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
      (let ((here (texsync-paper-target pdf)))
        (forward-line -1)
        (should (equal here (texsync-paper-target pdf)))))
    (pdf-info-close pdf)
    (delete-directory dir t)))

(ert-deftest texsync-test-bibliography-and-memo ()
  "PDF -> source on the references page: the \\bibliography line, at once.
SyncTeX answers there with the .bbl file LaTeX wrote.  A second call
asks SyncTeX nothing: answers are remembered until the PDF changes."
  (let* ((dir (texsync-test--copy-fixtures))
         (master (expand-file-name "paper/main.tex" dir))
         (pdf (texsync--pdf-file master))
         (asked 0)
         (count (lambda (&rest _) (setq asked (1+ asked)))))
    (texsync-test--latexmk master)
    (advice-add 'pdf-info-synctex-backward-search :before count)
    (unwind-protect
        (let* ((page (alist-get 'page (car (pdf-info-search-string "TeXbook" nil pdf))))
               (hit (car (pdf-info-search-string "TeXbook" nil pdf)))
               (y (nth 1 (car (alist-get 'edges hit))))
               (r (texsync--source-at pdf page y)))
          (should (equal (list (nth 0 r) (nth 1 r)) (list master 15)))
          (should (<= asked 2))
          (setq asked 0)
          (should (equal (texsync--source-at pdf page y) r))
          (should (= asked 0)))
      (advice-remove 'pdf-info-synctex-backward-search count))
    (pdf-info-close pdf)
    (delete-directory dir t)))

(ert-deftest texsync-test-toggle-follow ()
  "`texsync-toggle-follow' pauses the following for every file of the document."
  (let* ((dir (texsync-test--copy-fixtures))
         (main (expand-file-name "paper/main.tex" dir))
         (sec (expand-file-name "paper/sec.tex" dir))
         (bufs (mapcar (lambda (f) (let ((large-file-warning-threshold nil))
                                     (find-file-noselect f)))
                       (list main sec))))
    (unwind-protect
        (progn
          (dolist (b bufs) (with-current-buffer b (texsync-mode 1)))
          (with-current-buffer (cadr bufs)
            (should (eq (texsync-toggle-follow) nil))
            (should-not (cl-some (lambda (b) (buffer-local-value 'texsync-follow b)) bufs))
            ;; the mode line's lighter, (:eval ...); format-mode-line gives "" in batch
            (should (equal (eval (cadr (cadr (assq 'texsync-mode minor-mode-alist))) t)
                           " Sync:off"))
            ;; a command in a paused source schedules nothing
            (switch-to-buffer (current-buffer))
            (setq texsync--timer nil)
            (texsync--post-command)
            (should-not texsync--timer)
            (should (eq (texsync-toggle-follow) t))
            (should (cl-every (lambda (b) (buffer-local-value 'texsync-follow b)) bufs))
            (texsync--post-command)
            (should (timerp texsync--timer))
            (cancel-timer texsync--timer)
            ;; and with an argument: off whatever the state
            (texsync-toggle-follow -1)
            (should-not (buffer-local-value 'texsync-follow (car bufs)))))
      (dolist (b bufs) (with-current-buffer b (set-buffer-modified-p nil)) (kill-buffer b))
      (delete-directory dir t))))

(ert-deftest texsync-test-missing-synctex ()
  "A PDF built without -synctex=1 is rebuilt once, forced, and lookups then work.
SyncTeX answers looked up while the data was missing are not kept."
  (let* ((dir (texsync-test--copy-fixtures))
         (master (expand-file-name "paper/main.tex" dir))
         (sec (expand-file-name "paper/sec.tex" dir))
         (pdf (texsync--pdf-file master)))
    (texsync-test--latexmk master)
    ;; a build without SyncTeX data: neither latexmk's PDF nor the copy has any
    (delete-file (texsync--synctex-file (texsync--built-pdf master)))
    (delete-file (texsync--synctex-file pdf))
    (should-not (texsync--synctex-file pdf))
    (should-not (texsync--forward sec 5 pdf))   ; nothing to look up, remembered as nil
    (should-not (texsync--ensure-synctex master pdf))
    (let ((proc (gethash master texsync--processes)))
      (should (process-live-p proc))
      (should (member "-g" (process-command proc)))
      ;; asked once per PDF: no second rebuild while this one runs
      (should-not (texsync--ensure-synctex master pdf))
      (should-not (gethash master texsync--pending))
      ;; until the sentinel has run: it copies the new build, SyncTeX data included
      (while (gethash master texsync--processes) (accept-process-output proc 0.1)))
    (should (texsync--synctex-file pdf))
    (should (texsync--ensure-synctex master pdf))
    (should (texsync--forward sec 5 pdf))       ; the nil above was not kept
    (pdf-info-close pdf)
    (delete-directory dir t)))

(ert-deftest texsync-test-compile-only-on-save ()
  "By default an edit schedules no save and no compile; saving does compile."
  (let* ((dir (texsync-test--copy-fixtures))
         (main (expand-file-name "paper/main.tex" dir))
         (buf (let ((large-file-warning-threshold nil)) (find-file-noselect main)))
         (compiled nil)
         (spy (lambda (&rest _) (setq compiled t))))
    (should (null (default-value 'texsync-compile-idle-delay)))
    (advice-add 'texsync-compile :override spy)
    (unwind-protect
        (with-current-buffer buf
          (texsync-mode 1)
          (goto-char (point-max))
          (insert "% an edit\n")
          (should-not texsync--idle-timer)          ; nothing will save or compile
          (should (buffer-modified-p))
          (let ((texsync-compile-idle-delay 1.5))   ; the option still works when set
            (insert "% another\n")
            (should (timerp texsync--idle-timer))
            (cancel-timer texsync--idle-timer))
          (setq compiled nil)
          (save-buffer)
          (let ((end (+ (float-time) 3)))            ; compile-on-save runs on a 0.3 s timer
            (while (and (not compiled) (< (float-time) end))
              (accept-process-output nil 0.05)))
          (should compiled))
      (advice-remove 'texsync-compile spy)
      (with-current-buffer buf (set-buffer-modified-p nil))
      (kill-buffer buf)
      (delete-directory dir t))))

(ert-deftest texsync-test-build-status ()
  "The mode lines say Building while a build runs, Build failed after a failed
one until a good one, and see builds by other programs through .synctex(busy)."
  (let* ((dir (texsync-test--copy-fixtures))
         (master (expand-file-name "paper/main.tex" dir))
         (view (texsync--pdf-file master))
         (buf (let ((large-file-warning-threshold nil)) (find-file-noselect master)))
         (status (lambda () (substring-no-properties (texsync--status master))))
         (lighter (lambda () (with-current-buffer buf
                               (substring-no-properties (texsync--lighter)))))
         (pdf-lighter (lambda () (with-temp-buffer
                                   (setq buffer-file-name view)
                                   (prog1 (substring-no-properties (texsync--pdf-lighter))
                                     (setq buffer-file-name nil)))))
         (build (lambda ()
                  (texsync-compile master)
                  (let ((proc (gethash master texsync--processes)))
                    (should (process-live-p proc))
                    (should (string-prefix-p " Building " (funcall status)))
                    (should (string-match-p "\\` Sync Building [0-9]+s\\'" (funcall lighter)))
                    (should (string-prefix-p " Building " (funcall pdf-lighter)))
                    (while (process-live-p proc) (accept-process-output proc 0.1))
                    (accept-process-output nil 0.1)))))  ; let the sentinel run
    (unwind-protect
        (progn
          (with-current-buffer buf (texsync-mode 1) (texsync-master-file))
          (should (equal (funcall status) ""))
          ;; a good build: Building, then nothing
          (funcall build)
          (should (equal (funcall status) ""))
          (should (equal (funcall lighter) " Sync"))
          (should (zerop (hash-table-count texsync--builds)))
          ;; a failed build: Build failed, and it stays
          (with-current-buffer buf
            (goto-char (point-min))
            (re-search-forward "^\\\\section{Conclusion}")
            (insert "\n\\undefinedcommand\n")
            (let ((texsync-compile-on-save nil)) (save-buffer)))
          (funcall build)
          (should (equal (funcall status) " Build failed"))
          (should (equal (funcall lighter) " Sync Build failed"))
          (should (equal (funcall pdf-lighter) " Build failed"))
          (should (buffer-live-p (gethash master texsync--failed)))
          ;; fixed: the next good build clears it
          (with-current-buffer buf
            (goto-char (point-min))
            (re-search-forward "^\\\\undefinedcommand\n")
            (replace-match "")
            (let ((texsync-compile-on-save nil)) (save-buffer)))
          (funcall build)
          (should (equal (funcall status) ""))
          ;; a build by another program: seen by the poll through .synctex(busy)
          (let ((busy (expand-file-name "build/main.synctex(busy)" (file-name-directory master))))
            (with-temp-file busy (insert "x"))
            (texsync--poll-master master)
            (should (string-prefix-p " Building " (funcall status)))
            (delete-file busy)
            (texsync--poll-master master)
            (should (equal (funcall status) ""))
            ;; a busy file left by a run that died is not a build
            (with-temp-file busy (insert "x"))
            (set-file-times busy (time-subtract nil 300))
            (texsync--poll-master master)
            (should (equal (funcall status) ""))))
      (clrhash texsync--builds)
      (clrhash texsync--failed)
      (with-current-buffer buf (set-buffer-modified-p nil))
      (kill-buffer buf)
      (ignore-errors (pdf-info-close view))
      (delete-directory dir t))))

(provide 'texsync-test)
;;; texsync-test.el ends here
