;;; esqlite-helm.el --- Define helm source for sqlite database

;; Author: Masahiro Hayashi <mhayashi1120@gmail.com>
;; Keywords: data
;; URL: https://github.com/mhayashi1120/Emacs-esqlite
;; Emacs: GNU Emacs 24 or later
;; Package-Requires: ((esqlite "0.2.0") (helm "20131207.845"))
;; Version: 0.2.1

;; This program is free software; you can redistribute it and/or
;; modify it under the terms of the GNU General Public License as
;; published by the Free Software Foundation; either version 3, or (at
;; your option) any later version.

;; This program is distributed in the hope that it will be useful, but
;; WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
;; General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with GNU Emacs; see the file COPYING.  If not, write to the
;; Free Software Foundation, Inc., 51 Franklin Street, Fifth Floor,
;; Boston, MA 02110-1301, USA.

;;; Commentary:

;;; TODO:
;; * GLOB syntax is greater than LIKE syntax
;;   http://pokutuna.hatenablog.com/entry/20111113/1321126659

;; * add samples

;;; Code:

(eval-when-compile
  (require 'cl))

(require 'esqlite)
(require 'pcsv)

;; do not require helm

(declare-function helm-log "helm")
(declare-function helm-get-current-source "helm")

(defvar helm-pattern)
(defvar helm-async-processes)

;;;
;;; Esqlite for helm
;;;

(defvar esqlite-helm-history nil)

(defface esqlite-helm-finish
  '((t (:foreground "Green")))
  "Face used in mode line when sqlite is finish."
  :group 'helm-grep)

;;;###autoload
(defun esqlite-helm-define (source)
  "This function provides extension while `helm' source composing.
Normally, should not override `candidates-process', `candidates',
 `candidate-transformer' directive.

Following esqlite specific directive:

* `sqlite-db' File name of sqlite database or esqlite stream.
* `sqlite-async' Indicate SOURCE is async.

You must choose `sqlite-table' or `sqlite-composer' directive.

* `sqlite-table' Table name of result set. This directive only meaningful
     `sqlite-composer' is not specified.
  `sqlite-column' Column name of you desired to search.
  `sqlite-display-column' Column name of select.
* `sqlite-composer' Function which accept one argument `helm-pattern' and return
    a sql query string.

Following default directive:
`real-to-display' directive accept a list of string, generated by SELECT statement
 from `sqlite-composer' or `sqlite-table'. Default behavior is displaying all columns
 of SELECT. `volatile'

Other helm directive is overridable.

If SOURCE doesn't contain `sqlite-async', you should add LIMIT statement
 to SQL which composed by `sqlite-composer'.
 See the syntax of LIMIT statement.
http://www.sqlite.org/lang_select.html

Example:
\(helm (esqlite-helm-define
         `((sqlite-db . \"/path/to/some/sqlite.db\")
           (sqlite-table . \"tbl1\"))))
"
  (let ((file-or-stream (assoc-default 'sqlite-db source))
        (composer (assoc-default 'sqlite-composer source))
        (async (assoc 'sqlite-async source))
        file stream)
    (cond
     ((stringp file-or-stream)
      (setq file file-or-stream))
     ((esqlite-stream-p file-or-stream)
      (setq stream file-or-stream))
     (t
      (error "esqlite-helm: Not a valid filename or stream sqlite-db:%s" file)))
    (cond
     ((and composer (not (functionp composer)))
      (error "esqlite-helm: Not a valid function `sqlite-composer'"))
     ((and (null composer))
      (setq composer (esqlite-helm--construct-composer
                      file-or-stream source))))
    (let ((result
           ;; dequote all cdr to `cons' the list
           `((name . ,"esqlite")
             (real-to-display . ,'esqlite-helm-make-one-line)
             ,@(cond
                (stream
                 `((candidates
                    .
                    (lambda ()
                      (esqlite-helm-call-stream
                       ,stream
                       (funcall ',composer helm-pattern))))
                   ;; suppress caching
                   (volatile)))
                (async
                 `((candidates-process
                    .
                    (lambda ()
                      (esqlite-helm-start-command
                       ,file
                       (funcall ',composer helm-pattern))))
                   (candidate-transformer . esqlite-helm-hack-for-multiline)))
                (t
                 `((candidates
                    .
                    (lambda ()
                      (esqlite-helm-call-command
                       ,file
                       (funcall ',composer helm-pattern))))
                   ;; suppress caching
                   (volatile))))
             (match . ,'identity)
             (history . ,'esqlite-helm-history))))
      (dolist (s source)
        (let ((cell (assq (car-safe s) result)))
          (cond
           (cell
            (setcdr cell (cdr s)))
           (t
            (setq result (cons s result))))))
      result)))

(defun esqlite-helm--construct-composer (file-or-stream source)
  (let* ((table (assoc-default 'sqlite-table source))
         (column (assoc-default 'sqlite-column source))
         (dispcolumn (assoc-default 'sqlite-display-column source))
         (columns (esqlite-read-table-columns file-or-stream table))
         (limit (or (assoc-default 'candidate-number-limit source) 100)))
    (unless table
      (error "esqlite-helm: `sqlite-table' is missing"))
    (let ((dispcolumns (if dispcolumn (list dispcolumn) columns)))
      `(lambda (pattern)
         (let ((dispcolumns ',dispcolumns)
               (table ,table)
               (limit ,limit)
               (search-columns ',(if column (list column) columns))
               (likepat (esqlite-helm-glob-to-fuzzy-like pattern)))
           (esqlite-prepare
            '("SELECT %O{dispcolumns}"
              " FROM  %o{table}"
              " WHERE %s{where}"
              " LIMIT %s{limit}")
            :where (mapconcat
                    (lambda (col)
                      (esqlite-prepare
                       "%o{col} LIKE %T{likepat} ESCAPE '\\'"
                       :col col))
                    search-columns
                    " OR ")
            :dispcolumns dispcolumns
            :table table
            :limit limit))))))

(defun esqlite-helm-match-function (cand)
  (string-match (esqlite-helm-glob-to-regexp helm-pattern) cand))

(defun esqlite-helm-call-stream (stream query)
  (condition-case err
      (mapcar
       'esqlite-helm--construct-row
       (esqlite-stream-read stream query))
    (error
     (helm-log "Error: esqlite-helm %s"
               (replace-regexp-in-string
                "\n" ""
                (prin1-to-string (cdr err)))))))

(defun esqlite-helm-call-command (file query)
  (condition-case err
      (mapcar
       'esqlite-helm--construct-row
       (with-temp-buffer
         (unless (zerop (esqlite-call-csv-process file query ""))
           (error "esqlite: Process exited abnormally %s" (buffer-string)))
         (goto-char (point-min))
         (pcsv-parse-buffer)))
    (error
     (helm-log "Error: esqlite %s"
               (replace-regexp-in-string
                "\n" ""
                (prin1-to-string (cdr err)))))))

(defun esqlite-helm-start-command (file query)
  "Initialize async locate process for `helm-source-locate'."
  ;; esqlite-helm implementation ignore NULL. (NULL is same as a empty string)
  (let ((proc (esqlite-start-csv-process file query "")))
    (set-process-sentinel proc 'esqlite-helm--process-sentinel)
    proc))

(defun esqlite-helm--process-sentinel (proc event)
  (when (memq (process-status proc) '(exit signal))
    (let ((buf (process-buffer proc)))
      (when (buffer-live-p buf)
        (kill-buffer buf)))
    (unless (zerop (process-exit-status proc))
      (helm-log "Error: esqlite %s"
                (replace-regexp-in-string "\n" "" event)))))

(defun esqlite-helm-hack-for-multiline (candidates)
  ;; helm split csv stream by newline. restore the csv as one text
  ;; and try to parse it.

  ;; No newline in one value. (No problem)
  ;; OUTPUT-STRING: a,b\nc,d\ne CANDIDATES: ("a,b" "c,d") INCOMPLETE-LINE: "e"
  ;; OUTPUT-STRING: a,b\nc,d\n  CANDIDATES: ("a,b" "c,d") INCOMPLETE-LINE: ""
  ;; OUTPUT-STRING: a,b\nc,d    CANDIDATES: ("a,b")       INCOMPLETE-LINE: "c,d"

  ;; There is newline and quote by double-quote.
  ;; OUTPUT-STRING: a,b\nc,"d\nD"\ne CANDIDATES: ("a,b" "c,\"d\nD\"") INCOMPLETE-LINE: "e"
  ;; OUTPUT-STRING: a,b\nc,"d\nD"\n  CANDIDATES: ("a,b" "c,\"d\nD\"") INCOMPLETE-LINE: ""
  ;; OUTPUT-STRING: a,b\nc,"d\nD"    CANDIDATES: ("a,b" "c,\"d")      INCOMPLETE-LINE: "D\""
  ;; OUTPUT-STRING: a,b\nc,"d\nD     CANDIDATES: ("a,b" "c,\"d")      INCOMPLETE-LINE: "D"
  ;; OUTPUT-STRING: a,b\nc,"d\n      CANDIDATES: ("a,b" "c,\"d")      INCOMPLETE-LINE: ""
  ;; OUTPUT-STRING: a,b\nc,"d        CANDIDATES: ("a,b")              INCOMPLETE-LINE: "c,\"d"
  (condition-case err
      (let* ((rawtext (concat (mapconcat 'identity candidates "\n") "\n"))
             (source (helm-get-current-source))
             (incomplete-info (assq 'incomplete-line source)))
        (destructuring-bind (data rest) (esqlite-helm--read-csv rawtext)
          (setcdr incomplete-info (concat rest (cdr incomplete-info)))
          data))
    (error
     (message "%s" err)
     nil)))

;; try to read STRING until end.
;; csv line may not terminated and may contain newline.
(defun esqlite-helm--read-csv (string)
  (with-temp-buffer
    (insert string)
    (goto-char (point-min))
    (let ((res '())
          (start (point)))
      (condition-case nil
          (while (not (eobp))
            (let ((ln (esqlite--read-csv-line)))
              (setq start (point))
              (setq res (cons (esqlite-helm--construct-row ln) res))))
        (invalid-read-syntax))
      (list (nreverse res)
            (buffer-substring-no-properties start (point-max))))))

(defun esqlite-helm--construct-row (csv-line)
  ;; TODO investigate it! helm seems ignore first item of list. what is it?
  (cons 'dummy csv-line))


;;;
;;; Any utilities
;;;

(defun esqlite-helm-make-one-line (row &optional width)
  "To display TEXT as a helm line."
  (let* ((text (mapconcat (lambda (x)
                            (cond
                             ((stringp x) x)
                             ((eq x :null) "")
                             (t "")))
                          row " "))
         (oneline (replace-regexp-in-string "\n" " " text)))
    (truncate-string-to-width oneline (or width (window-width)))))

;;FIXME regexp-quote
(defun esqlite-helm-glob-to-regexp (glob &optional escape-char)
  (esqlite-parse-replace
   glob
   '((?* . ".*")
     (?? . ".?")
     (?\\ (?* . "*") (?\? . "?") (?\\ . "\\")))))

(defun esqlite-helm-split-fuzzy-glob (glob &optional escape-char)
  (let (prefix suffix)
    (cond
     ((string-match "\\`\\^" glob)
      (setq glob (substring glob 1)))
     ((string-match "\\`\\\\\\^" glob)
      ;; escaped ^.
      (setq glob (substring glob 1)
            prefix t))
     (t
      (setq prefix t)))
    (cond
     ((and (eq escape-char ?\\)
           (string-match "\\`\\(?:\\\\.\\|[^\\\\]\\)*\\\\$\\'" glob))
      ;; end with escaped `$'.
      ;; consider "\\$" <- escaped backslash end with `$'
      (setq glob (concat (substring glob 0 -2) "$"))
      (setq suffix t))
     ((and (not (eq escape-char ?\\))
           ;; end with escaped `$' "\\$"
           (string-match "\\\\\\$\\'" glob))
      (setq glob (concat (substring glob 0 -2) "$"))
      (setq suffix t))
     ((string-match "\\$\\'" glob)
      ;; end of non-escaped `$'
      (setq glob (substring glob 0 -1)))
     (t
      (setq suffix t)))
    (list prefix glob suffix)))

;;;###autoload
(defun esqlite-helm-glob-to-like (glob &optional escape-char)
  "Convenient function to provide unix like GLOB convert to sql like pattern.

`*' Like glob, match to text more equal zero.
`?' Like glob, match to a char in text.

Above syntax can escape by \\ (backslash). But no relation to ESCAPE-CHAR.
See related information at `esqlite-escape-like'.

e.g. hoge*foo -> hoge%foo
     hoge?foo -> hoge_foo"
  (esqlite-parse-replace
   glob
   (esqlite-escape--like-table
    escape-char
    `((?* . "%")
      (?\? . "_")
      (?\\ (?\* . "*")
           (?\? . "?")
           ,@(if (or (eq ?\\ escape-char) (null escape-char))
                 '((?\\ . "\\\\"))
               '((?\\ . "\\"))))))))

;;;###autoload
(defun esqlite-helm-glob-to-fuzzy-like (glob &optional escape-char)
  "Convert pseudo GLOB to like syntax to support helm behavior.

Following extended syntax:

`^': Like regexp, match to start of text.
`$': Like regexp, match to end of text.

Above syntax can escape by \\ (backslash). But no relation to ESCAPE-CHAR.
See related information at `esqlite-escape-like'.

ESCAPE-CHAR pass to `esqlite-helm-glob-to-like'"
  (destructuring-bind (prefix pattern suffix)
      (esqlite-helm-split-fuzzy-glob glob (or escape-char ?\\))
    (concat
     (and prefix "%")
     (esqlite-helm-glob-to-like pattern escape-char)
     (and suffix "%"))))

;;;###autoload
(defun esqlite-helm-glob-to-fuzzy-glob (glob)
  "Convert GLOB to fuzzy glob to support helm behavior

There are extended syntax `^' `$'. See `esqlite-helm-glob-to-fuzzy-like'."
  (destructuring-bind (prefix pattern suffix)
      (esqlite-helm-split-fuzzy-glob glob)
    (concat
     (and prefix "*")
     pattern
     (and suffix "*"))))

(provide 'esqlite-helm)

;;; esqlite-helm.el ends here
