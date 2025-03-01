;;; lisp/lib/files.el -*- lexical-binding: t; -*-
;;; Commentary:
;;; Code:

(defun doom-files--build-checks (spec &optional directory)
  "Converts a simple nested series of or/and forms into a series of
`file-exists-p' checks.

For example

  (doom-files--build-checks
    '(or A (and B C))
    \"~\")

Returns (not precisely, but effectively):

  '(let* ((_directory \"~\")
          (A (expand-file-name A _directory))
          (B (expand-file-name B _directory))
          (C (expand-file-name C _directory)))
     (or (and (file-exists-p A) A)
         (and (if (file-exists-p B) B)
              (if (file-exists-p C) C))))

This is used by `file-exists-p!' and `project-file-exists-p!'."
  (declare (pure t) (side-effect-free t))
  (if (and (listp spec)
           (memq (car spec) '(or and)))
      (cons (car spec)
            (cl-loop for it in (cdr spec)
                     collect (doom-files--build-checks it directory)))
    (let ((filevar (make-symbol "file")))
      `(let ((,filevar ,spec))
         (and (stringp ,filevar)
              ,(if directory
                   `(let ((default-directory ,directory))
                      (file-exists-p ,filevar))
                 `(file-exists-p ,filevar))
              ,filevar)))))

;;;###autoload
(defun doom-path (&rest segments)
  "Return an path expanded after concatenating SEGMENTS with path separators.

Ignores `nil' elements in SEGMENTS, and is intended as a fast compromise between
`expand-file-name' (slow, but accurate), `file-name-concat' (fast, but
inaccurate)."
  ;; PERF: An empty `file-name-handler-alist' = faster `expand-file-name'.
  (let (file-name-handler-alist)
    (expand-file-name
     ;; PERF: avoid the overhead of `apply' in the trivial case. This function
     ;;   is used a lot, so every bit counts.
     (if (cdr segments)
         (apply #'file-name-concat segments)
       (car segments)))))

;;;###autoload
(defun doom-glob (&rest segments)
  "Return file list matching the glob created by joining SEGMENTS.

The returned file paths will be relative to `default-directory', unless SEGMENTS
concatenate into an absolute path.

Returns nil if no matches exist.
Ignores `nil' elements in SEGMENTS.
If the glob ends in a slash, only returns matching directories."
  (declare (side-effect-free t))
  (let* (case-fold-search
         file-name-handler-alist
         (path (apply #'file-name-concat segments))
         (full? (file-name-absolute-p path)))
    (if (string-suffix-p "/" path)
        (cl-delete-if-not #'file-directory-p (file-expand-wildcards (substring path 0 -1) full?))
      (file-expand-wildcards path full?))))

;;;###autoload
(define-obsolete-function-alias 'doom-dir 'doom-path "3.0.0")

;;;###autoload
(cl-defun doom-files-in
    (paths &rest rest
           &key
           filter
           map
           (full t)
           (follow-symlinks t)
           (type 'files)
           (relative-to (unless full default-directory))
           (depth 99999)
           (mindepth 0)
           (match "/[^._][^/]+"))
  "Return a list of files/directories in PATHS (one string or a list of them).

FILTER is a function or symbol that takes one argument (the path). If it returns
non-nil, the entry will be excluded.

MAP is a function or symbol which will be used to transform each entry in the
results.

TYPE determines what kind of path will be included in the results. This can be t
(files and folders), 'files or 'dirs.

By default, this function returns paths relative to PATH-OR-PATHS if it is a
single path. If it a list of paths, this function returns absolute paths.
Otherwise, by setting RELATIVE-TO to a path, the results will be transformed to
be relative to it.

The search recurses up to DEPTH and no further. DEPTH is an integer.

MATCH is a string regexp. Only entries that match it will be included."
  (let (result)
    (dolist (file (mapcan (doom-rpartial #'doom-glob "*") (ensure-list paths)))
      (cond ((file-directory-p file)
             (appendq!
              result
              (and (memq type '(t dirs))
                   (string-match-p match file)
                   (not (and filter (funcall filter file)))
                   (not (and (file-symlink-p file)
                             (not follow-symlinks)))
                   (<= mindepth 0)
                   (list (if relative-to
                             (file-relative-name file relative-to)
                           file)))
              (and (>= depth 1)
                   (apply #'doom-files-in file
                          (append (list :mindepth (1- mindepth)
                                        :depth (1- depth)
                                        :relative-to relative-to
                                        :map nil)
                                  rest)))))
            ((and (memq type '(t files))
                  (string-match-p match file)
                  (not (and filter (funcall filter file)))
                  (<= mindepth 0))
             (push (if relative-to
                       (file-relative-name file relative-to)
                     file)
                   result))))
    (if map
        (mapcar map result)
      result)))

;;;###autoload
(defun doom-file-cookie-p (file &optional cookie null-value)
  "Returns the evaluated result of FORM in a ;;;###COOKIE FORM at the top of
FILE.

If COOKIE doesn't exist, or cookie isn't within the first 256 bytes of FILE,
return NULL-VALUE."
  (unless (file-exists-p file)
    (signal 'file-missing file))
  (unless (file-readable-p file)
    (error "%S is unreadable" file))
  (with-temp-buffer
    (insert-file-contents file nil 0 256)
    (if (re-search-forward (format "^;;;###%s " (regexp-quote (or cookie "if")))
                           nil t)
        (let* ((load-file-name file)
               (doom--current-module (doom-module-from-path file))
               (doom--current-flags (doom-module-get (car doom--current-module) (cdr doom--current-module) :flags)))
          (eval (sexp-at-point) t))
      null-value)))

;;;###autoload
(defmacro file-exists-p! (files &optional directory)
  "Returns non-nil if the FILES in DIRECTORY all exist.

DIRECTORY is a path; defaults to `default-directory'.

Returns the last file found to meet the rules set by FILES, which can be a
single file or nested compound statement of `and' and `or' statements."
  `(let ((p ,(doom-files--build-checks files directory)))
     (and p (expand-file-name p ,directory))))

;;;###autoload
(defun doom-file-size (file &optional dir)
  "Returns the size of FILE (in DIR) in bytes."
  (let ((file (expand-file-name file dir)))
    (unless (file-exists-p file)
      (error "Couldn't find file %S" file))
    (unless (file-readable-p file)
      (error "File %S is unreadable; can't acquire its filesize"
             file))
    (nth 7 (file-attributes file))))

(defvar w32-get-true-file-attributes)
;;;###autoload
(defun doom-directory-size (dir)
  "Returns the size of FILE (in DIR) in kilobytes."
  (unless (file-directory-p dir)
    (error "Directory %S does not exist" dir))
  (if (executable-find "du")
      (/ (string-to-number (cdr (doom-call-process "du" "-sb" dir)))
         1024.0)
    ;; REVIEW This is slow and terribly inaccurate, but it's something
    (let ((w32-get-true-file-attributes t)
          (file-name-handler-alist dir)
          (max-lisp-eval-depth 5000)
          (sum 0.0))
      (dolist (attrs (directory-files-and-attributes dir nil nil t) sum)
        (unless (member (car attrs) '("." ".."))
          (cl-incf
           sum (if (eq (nth 1 attrs) t) ; is directory
                   (doom-directory-size (expand-file-name (car attrs) dir))
                 (/ (nth 8 attrs) 1024.0))))))))


;;
;;; File read/write

(defmacro doom--with-prepared-file-buffer (file coding mode &rest body)
  "Create a temp buffer and prepare it for file IO in BODY."
  (declare (indent 3))
  (let ((nmask (make-symbol "new-mask"))
        (omask (make-symbol "old-mask")))
    `(let* ((,nmask ,mode)
            (,omask (if ,nmask (default-file-modes))))
       (unwind-protect
           (with-temp-buffer
             (if ,nmask (set-default-file-modes ,nmask))
             (let* ((buffer-file-name (doom-path ,file))
                    (coding-system-for-read  (or ,coding 'binary))
                    (coding-system-for-write (or coding-system-for-write coding-system-for-read 'binary)))
               (unless (eq coding-system-for-read 'binary)
                 (set-buffer-multibyte nil)
                 (setq-local buffer-file-coding-system 'binary))
               ,@body))
         (if ,nmask (set-default-file-modes ,omask))))))

;;;###autoload
(cl-defun doom-file-read
    (file &key
          (by 'buffer-string)
          (coding (or coding-system-for-read 'utf-8))
          noerror
          beg end)
  "Read FILE and return its contents.

Set BY to change how its contents are consumed. It accepts any function, to be
called with no arguments and expected to return the contents as any arbitrary
data. By default, BY is set to `buffer-string'. Otherwise, BY recognizes these
special values:

'insert      -- insert FILE's contents into the current buffer before point.
'read        -- read the first form in FILE and return it as a single S-exp.
'read*       -- read all forms in FILE and return it as a list of S-exps.
'(read . N)  -- read the first N (an integer) S-exps in FILE.

CODING dictates the encoding of the buffer. This defaults to `utf-8'.

If NOERROR is non-nil, don't throw an error if FILE doesn't exist. This will
still throw an error if FILE is unreadable, however.

If BEG and/or END are integers, only that region will be read from FILE."
  (when (or (not noerror)
            (file-exists-p file))
    (let ((old-buffer (current-buffer)))
      (doom--with-prepared-file-buffer file coding nil
        (if (not (eq coding-system-for-read 'binary))
            (insert-file-contents buffer-file-name nil beg end)
          (insert-file-contents-literally buffer-file-name nil beg end))
        (pcase by
          ('insert
           (insert-into-buffer old-buffer)
           t)
          ('buffer-string
           (buffer-substring-no-properties (point-min) (point-max)))
          ('read
           (condition-case _ (read (current-buffer)) (end-of-file)))
          ('(read . ,i)
           (let (forms)
             (condition-case _
                 (dotimes (_ i) (push (read (current-buffer)) forms))
               (end-of-file))
             (nreverse forms)))
          ('read*
           (let (forms)
             (condition-case _
                 (while t (push (read (current-buffer)) forms))
               (end-of-file))
             (nreverse forms)))
          (fn (funcall fn)))))))

;;;###autoload
(cl-defun doom-file-write
    (file contents
          &key
          append
          (coding 'utf-8)  ; default: `utf-8'
          mode             ; default: `default-file-modes' (#o755)
          (mkdir    'parents)
          (insertfn #'insert)
          (printfn  #'prin1))
  "Write CONTENTS (a string or list of forms) to FILE (a string path).

If CONTENTS is list of forms. Any literal strings in the list are inserted
verbatim, as text followed by a newline, with `insert'. Sexps are inserted with
`prin1'. BY is the function to use to emit

MODE dictates the permissions of the file. If FILE already exists, its
permissions will be changed.

CODING dictates the encoding to read/write with (see `coding-system-for-write').
If set to nil, `binary' is used.

APPEND dictates where CONTENTS will be written. If neither is set,
the file will be overwritten. If both are, the contents will be written to both
ends. Set either APPEND or PREPEND to `noerror' to silently ignore read errors."
  (doom--with-prepared-file-buffer file coding mode
    (let ((contents (ensure-list contents))
          datum)
      (while (setq datum (pop contents))
        (cond ((stringp datum)
               (funcall
                insertfn (if (or (string-suffix-p "\n" datum)
                                 (stringp (cadr contents)))
                             datum
                           (concat datum "\n"))))
              ((bufferp datum)
               (insert-buffer-substring datum))
              ((let ((standard-output (current-buffer))
                     (print-quoted t)
                     (print-level nil)
                     (print-length nil))
                 (funcall printfn datum))))))
    (let (write-region-annotate-functions
          write-region-post-annotation-function)
      (when mkdir
        (make-directory (file-name-directory buffer-file-name)
                        (eq mkdir 'parents)))
      (write-region nil nil buffer-file-name append :silent))
    buffer-file-name))

;;;###autoload
(defmacro with-file-contents! (file &rest body)
  "Create a temporary buffer with FILE's contents and execute BODY in it.

The point is at the beginning of the buffer afterwards.

A convenience macro to express the common `with-temp-buffer' +
`insert-file-contents' idiom more succinctly, enforce `utf-8', and perform some
optimizations for `binary' IO."
  (declare (indent 1))
  `(doom--with-prepared-file-buffer ,file (or coding-system-for-read 'utf-8) nil
     (doom-file-read buffer-file-name :by 'insert :coding coding-system-for-read)
     (goto-char (point-min))
     ,@body))

;;;###autoload
(defmacro with-file! (file &rest body)
  "Evaluate BODY in a temp buffer, then write its contents to FILE.

Unlike `with-temp-file', this uses the `utf-8' encoding by default and performs
some optimizations for `binary' IO."
  (declare (indent 1))
  `(doom--with-prepared-file-buffer ,file (or coding-system-for-read 'utf-8) nil
     (prog1 (progn ,@body)
       (doom-file-write buffer-file-name (current-buffer)
                        :coding (or coding-system-for-write 'utf-8)))))


;;
;;; Helpers

(defun doom-files--update-refs (&rest files)
  "Ensure FILES are updated in `recentf', `magit' and `save-place'."
  (let (toplevels)
    (dolist (file files)
      (when (featurep 'vc)
        (vc-file-clearprops file)
        (when-let (buffer (get-file-buffer file))
          (with-current-buffer buffer
            (vc-refresh-state))))
      (when (featurep 'magit)
        (when-let (default-directory (magit-toplevel (file-name-directory file)))
          (cl-pushnew default-directory toplevels)))
      (unless (file-readable-p file)
        (when (bound-and-true-p recentf-mode)
          (recentf-remove-if-non-kept file))
        (when (and (bound-and-true-p projectile-mode)
                   (doom-project-p)
                   (projectile-file-cached-p file (doom-project-root)))
          (projectile-purge-file-from-cache file))))
    (dolist (default-directory toplevels)
      (magit-refresh))
    (when (bound-and-true-p save-place-mode)
      (save-place-forget-unreadable-files))))


;;
;;; Commands

;;;###autoload
(defun doom/delete-this-file (&optional path force-p)
  "Delete PATH, kill its buffers and expunge it from vc/magit cache.

If PATH is not specified, default to the current buffer's file.

If FORCE-P, delete without confirmation."
  (interactive
   (list (buffer-file-name (buffer-base-buffer))
         current-prefix-arg))
  (let* ((path (or path (buffer-file-name (buffer-base-buffer))))
         (short-path (abbreviate-file-name path)))
    (unless (and path (file-exists-p path))
      (user-error "Buffer is not visiting any file"))
    (unless (file-exists-p path)
      (error "File doesn't exist: %s" path))
    (unless (or force-p (y-or-n-p (format "Really delete %S?" short-path)))
      (user-error "Aborted"))
    (let ((buf (current-buffer)))
      (unwind-protect
          (progn (delete-file path t) t)
        (if (file-exists-p path)
            (error "Failed to delete %S" short-path)
          ;; Ensures that windows displaying this buffer will be switched to
          ;; real buffers (`doom-real-buffer-p')
          (doom/kill-this-buffer-in-all-windows buf t)
          (doom-files--update-refs path)
          (message "Deleted %S" short-path))))))

;;;###autoload
(defun doom/copy-this-file (new-path &optional force-p)
  "Copy current buffer's file to NEW-PATH.

If FORCE-P, overwrite the destination file if it exists, without confirmation."
  (interactive
   (list (read-file-name "Copy file to: ")
         current-prefix-arg))
  (unless (and buffer-file-name (file-exists-p buffer-file-name))
    (user-error "Buffer is not visiting any file"))
  (let ((old-path (buffer-file-name (buffer-base-buffer)))
        (new-path (expand-file-name new-path)))
    (make-directory (file-name-directory new-path) 't)
    (copy-file old-path new-path (or force-p 1))
    (doom-files--update-refs old-path new-path)
    (message "File copied to %S" (abbreviate-file-name new-path))))

;;;###autoload
(defun doom/move-this-file (new-path &optional force-p)
  "Move current buffer's file to NEW-PATH.

If FORCE-P, overwrite the destination file if it exists, without confirmation."
  (interactive
   (list (read-file-name "Move file to: ")
         current-prefix-arg))
  (unless (and buffer-file-name (file-exists-p buffer-file-name))
    (user-error "Buffer is not visiting any file"))
  (let ((old-path (buffer-file-name (buffer-base-buffer)))
        (new-path (expand-file-name new-path)))
    (when (directory-name-p new-path)
      (setq new-path (concat new-path (file-name-nondirectory old-path))))
    (make-directory (file-name-directory new-path) 't)
    (rename-file old-path new-path (or force-p 1))
    (set-visited-file-name new-path t t)
    (doom-files--update-refs old-path new-path)
    (message "File moved to %S" (abbreviate-file-name new-path))))

(defun doom--sudo-file-path (file)
  (let ((host (or (file-remote-p file 'host) "localhost")))
    (concat "/" (when (file-remote-p file)
                  (concat (file-remote-p file 'method) ":"
                          (if-let (user (file-remote-p file 'user))
                              (concat user "@" host)
                            host)
                          "|"))
            "sudo:root@" host
            ":" (or (file-remote-p file 'localname)
                    file))))

;;;###autoload
(defun doom/sudo-find-file (file)
  "Open FILE as root."
  (interactive "FOpen file as root: ")
  (find-file (doom--sudo-file-path file)))

;;;###autoload
(defun doom/sudo-this-file ()
  "Open the current file as root."
  (interactive)
  (find-file
   (doom--sudo-file-path
    (or buffer-file-name
        (when (or (derived-mode-p 'dired-mode)
                  (derived-mode-p 'wdired-mode))
          default-directory)))))

;;;###autoload
(defun doom/sudo-save-buffer ()
  "Save this file as root."
  (interactive)
  (let ((file (doom--sudo-file-path buffer-file-name)))
    (if-let (buffer (find-file-noselect file))
        (let ((origin (current-buffer)))
          (copy-to-buffer buffer (point-min) (point-max))
          (unwind-protect
              (with-current-buffer buffer
                (save-buffer))
            (unless (eq origin buffer)
              (kill-buffer buffer))
            (with-current-buffer origin
              (revert-buffer t t))))
      (user-error "Unable to open %S" file))))

;;;###autoload
(defun doom/remove-recent-file (file)
  "Remove FILE from your recently-opened-files list."
  (interactive
   (list (completing-read "Remove recent file: " recentf-list
                          nil t)))
  (setq recentf-list (delete file recentf-list))
  (recentf-save-list)
  (message "Removed %S from `recentf-list'" (abbreviate-file-name file)))

(provide 'doom-lib '(files))
;;; files.el ends here
