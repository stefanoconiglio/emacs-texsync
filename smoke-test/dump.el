;;; dump.el --- query SyncTeX through pdf-tools' epdfinfo, in batch.  -*- lexical-binding: t -*-
;; Usage: emacs --batch -l dump.el PDF OUT SRC1 SRC2 ...
;; Writes "F src line page y1 y2" for every source line (forward search) and
;; "B page y src line" for a grid of points on every page (backward search).

(package-initialize)
(require 'pdf-info)

(let* ((args command-line-args-left)
       (pdf (expand-file-name (pop args)))
       (out (pop args))
       (srcs (mapcar #'expand-file-name args))
       (npages (pdf-info-number-of-pages pdf)))
  (setq command-line-args-left nil)
  (with-temp-file out
    (dolist (src srcs)
      (let ((n (with-temp-buffer (insert-file-contents src)
                                 (count-lines (point-min) (point-max)))))
        (dotimes (i n)
          (let* ((line (1+ i))
                 (r (condition-case nil
                        (pdf-info-synctex-forward-search src line 1 pdf)
                      (error nil))))
            (when r
              (let ((e (alist-get 'edges r)))
                (insert (format "F %s %d %d %.4f %.4f %.4f\n"
                                (file-name-nondirectory src) line
                                (alist-get 'page r) (nth 1 e) (nth 3 e) (nth 0 e)))))))))
    (dotimes (p npages)
      (dolist (y '(0.1 0.2 0.3 0.4 0.5 0.6 0.7 0.8 0.9))
        (let ((r (condition-case nil
                     (pdf-info-synctex-backward-search (1+ p) 0.5 y pdf)
                   (error nil))))
          (when r
            (insert (format "B %d %.2f %s %d\n" (1+ p) y
                            (file-name-nondirectory (alist-get 'filename r))
                            (alist-get 'line r)))))))))
