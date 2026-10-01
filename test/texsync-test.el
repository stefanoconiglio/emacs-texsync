;;; texsync-test.el --- Tests for texsync  -*- lexical-binding: t -*-

;; Run with `make test'.  The integration tests compile the fixtures with
;; latexmk into a temporary directory and query SyncTeX through epdfinfo.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'texsync)

(defconst texsync-test-dir
  (file-name-directory (or load-file-name buffer-file-name)))

(defun texsync-test--copy-fixtures ()
  "Copy the fixtures into a fresh temporary directory and return it."
  (let ((dir (make-temp-file "texsync-test-" t)))
    (copy-directory (expand-file-name "fixtures" texsync-test-dir) dir nil t t)
    (file-name-as-directory dir)))

(defun texsync-test--latexmk (master)
  "Compile MASTER synchronously with texsync's command; fail the test on error."
  (let ((default-directory (file-name-directory master)))
    (make-directory texsync-output-dir t)
    (should (zerop (apply #'call-process (car texsync-latexmk-command) nil nil nil
                          (append (cdr texsync-latexmk-command)
                                  (list (concat "-outdir=" texsync-output-dir)
                                        (file-name-nondirectory master))))))))

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

(provide 'texsync-test)
;;; texsync-test.el ends here
