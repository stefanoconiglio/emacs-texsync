;; frame-level forward sync, for the smoke test only
(defun smoke-sync-to-line (line)
  (let* ((src (get-file-buffer (expand-file-name "deck/deck.tex" smoke-dir)))
         (srcwin (get-buffer-window src))
         (pdfwin (get-buffer-window "deck.pdf")))
    (with-selected-window srcwin
      (goto-char (point-min)) (forward-line (1- line)) (recenter 5)
      (let* ((end (save-excursion (re-search-forward "^[ \t]*\\\\end{frame}") (line-number-at-pos)))
             (r (pdf-info-synctex-forward-search (buffer-file-name) end 1
                                                 (buffer-file-name (window-buffer pdfwin)))))
        (with-selected-window pdfwin (pdf-view-goto-page (alist-get 'page r)))
        (list :cursor line :frame-end end :page (alist-get 'page r))))))
