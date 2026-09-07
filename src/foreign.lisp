;;;; foreign.lisp -- collect dylibs the app dlopen'd and relocate them.
;;;;
;;;; The executable is never rewritten: SBCL appends the core image to the
;;;; Mach-O file and install_name_tool is not guaranteed to preserve it.
;;;; Instead every bundled dylib gets its inter-library references rewritten
;;;; to @loader_path/<name>, and RUNTIME.LISP pushes Contents/Frameworks onto
;;;; cffi:*foreign-library-directories* so CFFI finds them by absolute path.

(in-package #:asdf-macos-app)

(defparameter +system-library-prefixes+
  '("/usr/lib/" "/System/" "/Library/Frameworks/")
  "Paths under these are provided by macOS and are never copied.")

(defun system-library-p (path)
  (some (lambda (p) (uiop:string-prefix-p p path)) +system-library-prefixes+))

;;; ---- inside the child image, before the dump -----------------------

(defun loaded-foreign-libraries ()
  "Absolute pathnames of foreign libraries CFFI has open in this image."
  (let ((pkg (find-package "CFFI")))
    (when pkg
      (let ((lister (find-symbol "LIST-FOREIGN-LIBRARIES" pkg))
            (pather (find-symbol "FOREIGN-LIBRARY-PATHNAME" pkg)))
        (when (and lister pather (fboundp lister) (fboundp pather))
          (remove nil
                  (mapcar (lambda (lib)
                            (let ((p (ignore-errors (funcall pather lib))))
                              (when p
                                (let ((truename (probe-file p)))
                                  (when truename
                                    (uiop:native-namestring truename))))))
                          (funcall lister :loaded-only t))))))))

(defun write-foreign-manifest (spec extra)
  (let ((libs (remove-duplicates
               (remove-if #'system-library-p
                          (append (mapcar (lambda (x)
                                            (uiop:native-namestring
                                             (or (probe-file x)
                                                 (barf "No such library: ~a" x))))
                                          extra)
                                  (loaded-foreign-libraries)))
               :test #'string=)))
    (ensure-directories-exist (foreign-manifest-path spec))
    (with-open-file (s (foreign-manifest-path spec)
                       :direction :output :if-exists :supersede)
      (with-standard-io-syntax
        (let ((*package* (find-package :keyword)))
          (prin1 libs s)
          (terpri s))))
    libs))

(defun read-foreign-manifest (spec)
  (let ((p (foreign-manifest-path spec)))
    (when (probe-file p)
      (with-open-file (s p)
        (with-standard-io-syntax
          (let ((*package* (find-package :keyword))
                (*read-eval* nil))
            (read s nil nil)))))))

;;; ---- in the parent, after the dump ---------------------------------

(defun parse-otool-dependencies (text)
  "Install names from `otool -L` output. The first line names the file itself
and is dropped; the first entry that follows is usually the file's own id,
which is harmless because it resolves to something already visited."
  (loop for line in (rest (uiop:split-string text :separator '(#\Newline)))
        for trimmed = (string-trim '(#\Space #\Tab #\Return) line)
        for name = (first (uiop:split-string trimmed :separator '(#\Space)))
        when (and (plusp (length name)) (find #\/ name))
          collect name))

(defun otool-dependencies (path)
  (parse-otool-dependencies
   (run (list "/usr/bin/otool" "-L" (uiop:native-namestring path)))))

(defvar *rpath-cache* nil)

(defun tokens (line)
  (remove "" (uiop:split-string line :separator '(#\Space #\Tab #\Return))
          :test #'string=))

(defun parse-otool-rpaths (text)
  "LC_RPATH values from `otool -l` output, in load-command order.
Separated from the process call so it can be tested against captured output."
  (let ((rpaths '())
        (in-rpath nil))
    (dolist (line (uiop:split-string text :separator '(#\Newline)))
      (let ((tok (tokens line)))
        (cond ((string= (or (first tok) "") "cmd")
               (setf in-rpath (string= (or (second tok) "") "LC_RPATH")))
              ((and in-rpath (string= (or (first tok) "") "path"))
               ;; "         path /opt/homebrew/lib (offset 12)" -- the value may
               ;; contain spaces, so slice rather than take the token.
               (let* ((start (+ (search "path " line) 5))
                      (end (search " (offset " line :start2 start))
                      (value (string-trim " " (subseq line start end))))
                 (pushnew value rpaths :test #'string=)
                 (setf in-rpath nil))))))
    (nreverse rpaths)))

(defun mach-o-rpaths (path)
  (parse-otool-rpaths
   (run (list "/usr/bin/otool" "-l" (uiop:native-namestring path)))))

(defun cached-rpaths (path)
  (if *rpath-cache*
      (multiple-value-bind (v found) (gethash path *rpath-cache*)
        (if found v (setf (gethash path *rpath-cache*) (mach-o-rpaths path))))
      (mach-o-rpaths path)))

(defun expand-loader-variables (path origin)
  "Substitute @loader_path / @executable_path in PATH using ORIGIN's directory.
During a build we have no executable to speak of, so both resolve the same way."
  (let ((dir (uiop:native-namestring (uiop:pathname-directory-pathname origin))))
    (loop for var in '("@loader_path/" "@executable_path/")
          when (uiop:string-prefix-p var path)
            do (return (concatenate 'string dir (subseq path (length var))))
          finally (return path))))

(defun resolve-install-name (name origin)
  "Turn an install name into a real path, or NIL if we cannot or should not.
ORIGIN is the Mach-O file that referenced NAME; its LC_RPATH entries are what
@rpath expands against."
  (labels ((real (p)
             (let ((p (probe-file p)))
               (when (and p (not (system-library-p (uiop:native-namestring p))))
                 (uiop:native-namestring p)))))
    (cond
      ((system-library-p name) nil)
      ((uiop:string-prefix-p "@rpath/" name)
       (let ((tail (subseq name (length "@rpath/"))))
         (loop for rpath in (cached-rpaths origin)
               for base = (expand-loader-variables rpath origin)
               for candidate = (real (merge-pathnames
                                      tail (uiop:ensure-directory-pathname base)))
               when candidate return candidate)))
      ((uiop:string-prefix-p "@" name)
       (real (expand-loader-variables name origin)))
      (t (real name)))))

(defun transitive-libraries (roots)
  "Close ROOTS over their non-system dependencies."
  (let ((seen (make-hash-table :test #'equal))
        (queue (copy-list roots)))
    (loop while queue
          for path = (pop queue)
          unless (gethash path seen)
            do (setf (gethash path seen) t)
               (dolist (dep (otool-dependencies path))
                 (let ((real (resolve-install-name dep path)))
                   (cond ((and real (not (gethash real seen))) (push real queue))
                         ((and (null real) (uiop:string-prefix-p "@" dep))
                          (note "warning: ~a references ~a but no LC_RPATH ~
                                 resolves it; the bundle may fail at runtime"
                                path dep))))))
    (sort (loop for k being the hash-keys of seen collect k) #'string<)))

(defun relocate-foreign-libraries (spec)
  "Copy every recorded dylib (and its dependencies) into Contents/Frameworks
and rewrite their ids and cross-references to @loader_path."
  (unless (macos-p)
    (let ((roots (read-foreign-manifest spec)))
      (when roots
        (note "not on macOS: ~d foreign librar~:@p left unbundled" (length roots))))
    (return-from relocate-foreign-libraries nil))
  (let* ((*rpath-cache* (make-hash-table :test #'equal))
         (roots (read-foreign-manifest spec))
         (all (and roots (transitive-libraries roots)))
         (dest (frameworks-dir spec))
         (basenames (make-hash-table :test #'equal)))
    (when all
      (ensure-directories-exist dest)
      ;; 1. copy
      (dolist (lib all)
        (let ((base (file-namestring lib)))
          (when (gethash base basenames)
            (barf "Two different libraries are both named ~a: ~a and ~a"
                  base (gethash base basenames) lib))
          (setf (gethash base basenames) lib)
          (uiop:copy-file lib (uiop:subpathname dest base))))
      ;; 2. rewrite ids and cross references
      (dolist (lib all)
        (let* ((base (file-namestring lib))
               (copy (uiop:native-namestring (uiop:subpathname dest base))))
          (run (list "/usr/bin/install_name_tool"
                     "-id" (format nil "@loader_path/~a" base) copy))
          (dolist (dep (otool-dependencies lib))
            (let* ((real (resolve-install-name dep lib))
                   (dbase (and real (file-namestring real))))
              (when (and dbase (gethash dbase basenames)
                         (not (string= dep (format nil "@loader_path/~a" dbase))))
                (run (list "/usr/bin/install_name_tool"
                           "-change" dep (format nil "@loader_path/~a" dbase)
                           copy)))))
          ;; install_name_tool invalidates any existing signature
          (run (list "/usr/bin/codesign" "--remove-signature" copy)
               :ignore-error-status t))))
    all))
