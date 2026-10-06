;;; gui-test.el --- texsync in a graphical Emacs  -*- lexical-binding: t -*-

;; Run with `make gui-test' (needs a graphical display; a window opens for
;; about half a minute).  It exercises what batch tests cannot: commands
;; going through the command loop (`post-command-hook', timers), pdf-tools
;; windows in continuous mode, and the compile -> revert -> re-sync path.
;; Results go to the file named by $TEXSYNC_GUI_LOG; the exit status is the
;; number of failed checks.

;;; Code:

(require 'cl-lib)
(require 'backtrace)
(package-initialize)
(defconst gui-test--dir (file-name-directory load-file-name))
(add-to-list 'load-path (expand-file-name ".." gui-test--dir))
(require 'texsync)
(require 'tex nil t)

(defvar gui-test--failures 0)
(defvar gui-test--log nil)

(defun gui-test--say (fmt &rest args)
  (push (apply #'format fmt args) gui-test--log))

(defun gui-test--check (what ok &optional detail)
  (gui-test--say "%s  %s%s" (if ok "PASS" "FAIL") what
                 (if detail (format "  [%s]" detail) ""))
  (unless ok (cl-incf gui-test--failures)))

(defun gui-test--tick (secs)
  "Redisplay, then let timers and processes run for SECS seconds.
Not `sit-for': it returns at once while any input event (a focus change
from the window manager) is pending, and then skips redisplay."
  (redisplay t)
  (accept-process-output nil secs))

(defun gui-test--wait (secs)
  "Let timers, processes and redisplay run for SECS seconds."
  (let ((end (+ (float-time) secs)))
    (while (< (float-time) end)
      (gui-test--tick 0.05))
    (redisplay t)))

(defun gui-test--wait-for (secs pred)
  "Wait up to SECS seconds for PRED to return non-nil; return its value."
  (let ((end (+ (float-time) secs)) v)
    (while (and (not (setq v (funcall pred))) (< (float-time) end))
      (gui-test--tick 0.1))
    v))

(defun gui-test--latexmk (master)
  (let ((default-directory (file-name-directory master)))
    (make-directory texsync-output-dir t)
    (zerop (apply #'call-process (car texsync-latexmk-command) nil nil nil
                  (append (cdr texsync-latexmk-command)
                          (list (concat "-outdir=" texsync-output-dir)
                                (file-name-nondirectory master)))))))

(defun gui-test--keys (keys)
  "Type KEYS as the user would, through the command loop."
  (execute-kbd-macro (kbd keys)))

(defun gui-test--goto (line)
  (gui-test--keys (format "M-g g %d RET" line)))

(defun gui-test--clear-messages ()
  (with-current-buffer (messages-buffer)
    (let ((inhibit-read-only t)) (erase-buffer))))

(defun gui-test--errors-logged ()
  "Error lines in *Messages* since the last clear."
  (with-current-buffer (messages-buffer)
    (cl-remove-if-not
     (lambda (l) (string-match-p "error\\|Error\\|texsync:" l))
     (split-string (buffer-string) "\n" t))))

(defun gui-test--pdf-page (pbuf)
  (with-selected-window (get-buffer-window pbuf)
    (pdf-view-current-page)))

(defun gui-test--line-of (regexp)
  (save-excursion
    (goto-char (point-min))
    (re-search-forward regexp)
    (line-number-at-pos)))

(defun gui-test--alignment (pwin pdf words)
  "Pixel distance between WORDS' height in PWIN and point's height in its window.
nil when WORDS is not on a page shown in PWIN."
  (let* ((hit (car (pdf-info-search-string words nil pdf)))
         (page (alist-get 'page hit))
         (y (nth 1 (car (alist-get 'edges hit))))
         (frac (texsync--point-fraction))
         (src-px (* frac (window-body-height nil t))))
    (with-selected-window pwin
      (let* ((cur (pdf-view-current-page))
             (vscroll (window-vscroll nil t))
             (h (cdr (pdf-view-image-size t pwin page)))
             (pdf-px (cond ((= page cur) (- (* y h) vscroll))
                           ((= page (1+ cur))
                            (+ (- (cdr (pdf-view-image-size t pwin cur)) vscroll)
                               pdf-roll-vertical-margin (* y h))))))
        (cond ((null pdf-px) nil)
              ;; The PDF cannot scroll above its first page: in a small window a
              ;; line near the start cannot be lowered to point's height.
              ((and (= cur 1) (= vscroll 0) (< pdf-px src-px)) 0)
              (t (abs (- pdf-px src-px))))))))

(defun gui-test--ctrl-click (src-win pwin pdf words wobble)
  "Ctrl+click WORDS in PWIN with real mouse events, starting from SRC-WIN.
WOBBLE moves the pointer 2 px between press and release, as on a touchpad.
Return (BUFFER-NAME . LINE-TEXT) of the selected window afterwards."
  (let* ((hit (car (pdf-info-search-string words nil pdf)))
         (page (alist-get 'page hit))
         (e (car (alist-get 'edges hit))))
    (with-selected-window pwin (pdf-view-goto-page page))
    ;; pdf-roll draws pages lazily: aim only once the page is an image
    (gui-test--wait-for 2 (lambda ()
                            (redisplay t)
                            (posn-image (posn-at-x-y 40 40 pwin))))
    (let* ((size (with-current-buffer (window-buffer pwin) (pdf-view-image-size t pwin page)))
           (want-x (round (* (/ (+ (nth 0 e) (nth 2 e)) 2) (car size))))
           (want-y (round (* (/ (+ (nth 1 e) (nth 3 e)) 2) (cdr size))))
           ;; window coordinates of that image point: correct for the image's offset
           (probe (posn-at-x-y want-x want-y pwin))
           (obj (posn-object-x-y probe))
           (x (+ want-x (- want-x (car obj))))
           (y (+ want-y (- want-y (cdr obj))))
           (p1 (posn-at-x-y x y pwin))
           (p2 (posn-at-x-y (+ x (if wobble 2 0)) y pwin)))
      (gui-test--say "   click at %S: area %S image %S binding %S" (cons x y)
                     (posn-area p1) (and (posn-image p1) t)
                     (with-selected-window pwin (key-binding (vector (list 'C-mouse-1 p1)) nil nil p1)))
      (select-window src-win)
      (execute-kbd-macro
       (vconcat (list (list 'C-down-mouse-1 p1))
                (when wobble (list (list 'mouse-movement p2)))
                (list (list 'C-mouse-1 p2))))
      ;; pdf-tools re-sends clicks on text through `unread-command-events';
      ;; the command loop would run them next, a keyboard macro does not.
      (while unread-command-events
        (execute-kbd-macro (vector (pop unread-command-events))))
      (gui-test--wait 0.7)
      (cons (buffer-name (window-buffer (selected-window)))
            (with-current-buffer (window-buffer (selected-window))
              (buffer-substring-no-properties (line-beginning-position) (line-end-position)))))))

(defun gui-test--wheel (pwin n)
  "N mouse-wheel steps down over PWIN, as the user's wheel or touchpad sends them."
  (let ((posn (posn-at-x-y 40 40 pwin)))
    (execute-kbd-macro (vconcat (make-list n (list 'wheel-down posn))))))

(defun gui-test--alignment-at (pwin page y)
  "Pixel distance between height Y of PAGE in PWIN and point's line in its window."
  (let* ((frac (texsync--point-fraction))
         (src-px (and frac (* frac (window-body-height nil t)))))
    (when frac
      (with-selected-window pwin
        (let* ((cur (pdf-view-current-page))
               (vscroll (window-vscroll nil t))
               (pdf-px (cond ((= page cur) (- (* y (texsync--page-height pwin page)) vscroll))
                             ((= page (1+ cur))
                              (+ (- (texsync--page-height pwin cur) vscroll)
                                 pdf-roll-vertical-margin
                                 (* y (texsync--page-height pwin page)))))))
          (cond ((null pdf-px) nil)
                ;; the source window cannot scroll above the buffer's first line
                ((and (= (window-start (frame-first-window)) 1) (< src-px pdf-px)) 0)
                (t (abs (- pdf-px src-px)))))))))

(defun gui-test--deck (dir)
  (let* ((master (expand-file-name "deck.tex" dir))
         (pdf (texsync--pdf-file master)))
    (gui-test--check "deck compiles" (gui-test--latexmk master))
    (find-file master)
    (delete-other-windows)
    (texsync-mode 1)
    (gui-test--clear-messages)
    (texsync-view)
    (let ((pbuf (find-buffer-visiting pdf)))
      (gui-test--check "View shows the deck PDF beside the source"
                       (and pbuf (get-buffer-window pbuf)
                            (eq (window-buffer (selected-window)) (current-buffer))))
      (let ((texsync-beamer-overlay 'last))
        (dolist (case '((8 . 1) (16 . 4) (23 . 5) (29 . 6) (14 . 4) (10 . 1)))
          (gui-test--goto (car case))
          (gui-test--wait 0.5)
          (gui-test--check (format "deck: cursor on line %d shows slide %d" (car case) (cdr case))
                           (= (gui-test--pdf-page pbuf) (cdr case))
                           (gui-test--pdf-page pbuf))))
      ;; Ctrl+click on the slide of frame Two (lines 13-19): the source goes to
      ;; that frame and the PDF stays put.
      (gui-test--goto 29)
      (gui-test--wait 0.5)
      (let ((pwin (get-buffer-window pbuf)))
        (with-selected-window pwin (pdf-view-goto-page 3))
        (select-window pwin)
        (let ((size (pdf-view-image-size)))
          (pdf-sync-backward-search (/ (car size) 2) (/ (cdr size) 2)))
        (gui-test--wait 0.7)
        (gui-test--check "ctrl+click: source window selected, point inside frame Two"
                         (and (eq (window-buffer (selected-window)) (find-buffer-visiting master))
                              (<= 13 (line-number-at-pos) 19))
                         (line-number-at-pos))
        (gui-test--check "ctrl+click: the PDF does not move afterwards"
                         (= (gui-test--pdf-page pbuf) 3) (gui-test--pdf-page pbuf))
        ;; The verbatim frame Three (lines 21-26) is typeset from Beamer's .vrb file.
        (with-selected-window pwin (pdf-view-goto-page 5))
        (select-window pwin)
        (let ((size (pdf-view-image-size)))
          (pdf-sync-backward-search (/ (car size) 2) (/ (cdr size) 2)))
        (gui-test--wait 0.7)
        (gui-test--check "ctrl+click on a verbatim frame: the .tex source, frame Three"
                         (and (equal (buffer-file-name (window-buffer (selected-window))) master)
                              (<= 21 (line-number-at-pos) 26))
                         (list (buffer-name (window-buffer (selected-window)))
                               (line-number-at-pos)))))
    ;; The PDF leads: next slide in the PDF window.
    (let ((pwin (get-buffer-window (find-buffer-visiting pdf)))
          (srcw (get-buffer-window (find-buffer-visiting master))))
      (select-window srcw)
      (gui-test--goto 8)                  ; frame One, slide 1
      (gui-test--wait 0.5)
      (select-window pwin)
      (gui-test--keys "n")                ; next slide: frame Two
      (gui-test--wait 0.7)
      (gui-test--check "deck: next slide in the PDF puts the source in frame Two"
                       (with-selected-window srcw (<= 13 (line-number-at-pos) 19))
                       (with-selected-window srcw (line-number-at-pos)))
      (gui-test--check "deck: the PDF stays on that slide"
                       (= (gui-test--pdf-page (find-buffer-visiting pdf)) 2)
                       (gui-test--pdf-page (find-buffer-visiting pdf))))
    ;; The user's habit: C-c C-c View, and C-c C-c LaTeX (save + AUCTeX's own run).
    (select-window (get-buffer-window (find-buffer-visiting master)))
    (setq texsync--last nil)
    (gui-test--keys "C-c C-c View RET")
    (gui-test--wait 0.7)
    (gui-test--check "C-c C-c View shows the PDF through texsync" texsync--last texsync--last)
    (let ((overlap nil) (seen-auctex nil) (texsync-after nil))
      (goto-char (point-max))
      (insert "\n")
      (setq-local TeX-save-query nil)     ; as in the user's config: save without asking
      (gui-test--keys "C-c C-c LaTeX RET")
      (gui-test--wait-for
       40 (lambda ()
            (let ((a (texsync--auctex-process))
                  (b (process-live-p (gethash master texsync--processes))))
              (when (and a b) (setq overlap t))
              (when a (setq seen-auctex t))
              (when (and b seen-auctex (not a)) (setq texsync-after t)))
            (and (not (texsync--auctex-process))
                 (not (process-live-p (gethash master texsync--processes)))
                 (not (buffer-modified-p)))))
      (gui-test--wait-for 5 (lambda ()
                              (when (process-live-p (gethash master texsync--processes))
                                (setq texsync-after t))))
      (gui-test--wait-for 40 (lambda () (not (process-live-p (gethash master texsync--processes)))))
      (gui-test--check "C-c C-c LaTeX: AUCTeX runs, then texsync, never both at once"
                       (and seen-auctex texsync-after (not overlap))
                       (list :auctex seen-auctex :texsync-after texsync-after :overlap overlap)))
    (gui-test--check "deck: nothing logged as an error" (null (gui-test--errors-logged))
                     (gui-test--errors-logged))))

(defun gui-test--paper (dir)
  (let* ((master (expand-file-name "paper/main.tex" dir))
         (sec (expand-file-name "paper/sec.tex" dir))
         (pdf (texsync--pdf-file master)))
    (gui-test--check "paper compiles" (gui-test--latexmk master))
    (find-file sec)
    (delete-other-windows)
    (texsync-mode 1)
    (gui-test--check "sec.tex finds its main file" (equal (texsync-master-file) master))
    (gui-test--clear-messages)
    (texsync-view)
    (let* ((pbuf (find-buffer-visiting pdf))
           (pwin (get-buffer-window pbuf)))
      (gui-test--check "paper PDF in continuous mode"
                       (buffer-local-value 'pdf-view-roll-minor-mode pbuf))
      (cl-flet ((aligned (what)
                  (let* ((words (save-excursion
                                  (beginning-of-line)
                                  (and (looking-at "Paragraph [0-9]+ sentence [0-9]+")
                                       (match-string 0))))
                         (d (and words (gui-test--alignment pwin pdf words))))
                    (gui-test--check (format "%s: \"%s\" at the same height in both windows"
                                             what words)
                                     (and d (< d 25)) d))))
        (gui-test--goto (gui-test--line-of "^Paragraph 5 sentence 3"))
        (gui-test--keys "C-a")
        (gui-test--wait 0.5)
        (aligned "cursor motion")
        (dotimes (_ 2)
          ;; a tall window reaches the end of sec.tex: that just ends the scrolling
          (condition-case nil (gui-test--keys "C-v") (end-of-buffer nil))
          (gui-test--wait 0.5)
          ;; after C-v point is at the top; go to the first sentence line in
          ;; view with a command, as the user would
          (let ((line (save-excursion
                        (and (or (re-search-forward "^Paragraph" nil t)
                                 (re-search-backward "^Paragraph" nil t))
                             (line-number-at-pos)))))
            (when line
              (gui-test--goto line)
              (gui-test--wait 0.5)))
          (aligned "after C-v"))
        ;; The PDF leads: wheel over the PDF while the source window is selected.
        (let ((src-win (selected-window)))
          (setq texsync-trace nil)
          (gui-test--wheel pwin 6)
          (let ((after (texsync--pdf-state pwin)))
            (gui-test--wait 0.7)
            (gui-test--say "   trace: %S" (reverse texsync-trace))
            (gui-test--say "   source window: start line %d, point line %d, point visible %S"
                           (line-number-at-pos (window-start src-win))
                           (line-number-at-pos (window-point src-win))
                           (pos-visible-in-window-p (window-point src-win) src-win))
            (setq texsync-trace 'off)
            (gui-test--check "wheel over the PDF: it stays where it was scrolled"
                             (equal (texsync--pdf-state pwin) after)
                             (list after (texsync--pdf-state pwin)))
            (gui-test--check "wheel over the PDF: the source window keeps the focus"
                             (eq (selected-window) src-win))
            (let* ((anchor (texsync--pdf-point-at pwin texsync-pdf-anchor))
                   (target (texsync-paper-target pdf))
                   (d (and target (gui-test--alignment-at pwin (car target) (cdr target)))))
              ;; Independent check: SyncTeX types point's line within 0.2 page of the
              ;; anchor (its text may start on the page before, if it wraps there).
              (gui-test--check "wheel over the PDF: point's line is typeset near the PDF's anchor"
                               (let ((here (cons (buffer-file-name) (line-number-at-pos))))
                                 (cl-some (lambda (dy)
                                            (let ((r (ignore-errors
                                                       (pdf-info-synctex-backward-search
                                                        (car anchor) 0.25
                                                        (min 1.0 (max 0.0 (+ (cdr anchor) dy))) pdf))))
                                              (and r (equal (cons (expand-file-name (alist-get 'filename r))
                                                                  (alist-get 'line r))
                                                            here))))
                                          '(0 0.05 -0.05 0.1 -0.1 0.15 -0.15 0.2 -0.2)))
                               (list :anchor anchor :point-line target))
              (gui-test--check "wheel over the PDF: point's line and its text at the same height"
                               (and d (< d 25)) d))))
        ;; Ctrl+click with real mouse events.
        (let ((src-win (selected-window))
              (words "Paragraph 4 sentence 2"))
          (with-current-buffer pbuf (texsync-pdf-mode -1))
          (let ((r (gui-test--ctrl-click src-win pwin pdf words t)))
            (gui-test--check "without texsync-pdf-mode a wobbly ctrl+click is lost (pdf-tools)"
                             (not (string-prefix-p words (cdr r))) r))
          (with-current-buffer pbuf (texsync-pdf-mode 1))
          (dolist (wobble '(nil t))
            (select-window src-win)
            (goto-char (point-min))
            (setq texsync-trace nil)
            (let ((r (gui-test--ctrl-click src-win pwin pdf words wobble)))
              (gui-test--say "   trace: %S" (reverse texsync-trace))
              (setq texsync-trace 'off)
              (gui-test--check (format "ctrl+click%s on \"%s\" goes to its source line"
                                       (if wobble " with a wobble" "") words)
                               (and (equal (car r) "sec.tex") (string-prefix-p words (cdr r)))
                               r))))
        (gui-test--goto (gui-test--line-of "^Paragraph 10 sentence 4"))
        (gui-test--wait 0.5)
        ;; Edit, pause, and let texsync save, compile, reload and re-sync (idle
        ;; compiling is off by default; the edits are made with it on).
        (let ((mtime (file-attribute-modification-time (file-attributes pdf))))
          (let ((texsync-compile-idle-delay 1.5))
            (save-excursion
              (goto-char (point-min))
              (forward-line 1)
              (dotimes (k 10)
                (insert (format "Inserted sentence %d for the reload test, enough words for a line.\n" k)))))
          (gui-test--check
           "with texsync-compile-idle-delay set, a pause after an edit saves and recompiles"
           (gui-test--wait-for
            30 (lambda ()
                 (and (not (buffer-modified-p))
                      (zerop (hash-table-count texsync--processes))
                      (not (equal mtime (file-attribute-modification-time
                                         (file-attributes pdf)))))))
           (list :buffer (buffer-name) :selected (buffer-name (window-buffer (selected-window)))
                 :modified (buffer-modified-p) :texsync texsync-mode
                 :running (hash-table-count texsync--processes)
                 :pdf-changed (not (equal mtime (file-attribute-modification-time
                                                 (file-attributes pdf)))))))
        (gui-test--wait 1.0)
        (gui-test--keys "C-a")
        (gui-test--wait 0.5)
        (aligned "after the reload")))
    (gui-test--check "paper: nothing logged as an error" (null (gui-test--errors-logged))
                     (gui-test--errors-logged))))

(defun gui-test-run ()
  ;; A tiling window manager would size the window by what else is open.
  (set-frame-parameter nil 'fullscreen 'fullboth)
  (gui-test--wait 1.5)
  (gui-test--say "frame %dx%d px" (frame-pixel-width) (frame-pixel-height))
  (let ((dir (file-name-as-directory (make-temp-file "texsync-gui-" t))))
    (copy-directory (expand-file-name "fixtures" gui-test--dir) dir nil t t)
    (let (bt)
      (condition-case err
          (handler-bind ((error (lambda (_) (setq bt (backtrace-to-string)))))
            (gui-test--deck dir)
            (gui-test--paper dir))
        (error (gui-test--check "no Lisp error" nil (error-message-string err))
               (gui-test--say "%s" (substring bt 0 (min 3000 (length bt)))))))
    (gui-test--say "%d failed" gui-test--failures)
    (with-temp-file (or (getenv "TEXSYNC_GUI_LOG") "/dev/stderr")
      (insert (mapconcat #'identity (reverse gui-test--log) "\n") "\n"))
    (dolist (b (buffer-list))
      (with-current-buffer b (set-buffer-modified-p nil)))
    (delete-directory dir t)
    (kill-emacs gui-test--failures)))

(run-with-timer 1 nil #'gui-test-run)

;;; gui-test.el ends here
