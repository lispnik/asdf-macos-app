;;;; runtime.lisp -- code that survives the image dump and runs inside the .app.

(in-package #:asdf-macos-app)

(defvar *bundle-root* nil
  "Pathname of the .app directory this image is running from, or NIL.")

(defvar *entry-point* nil
  "User entry point, stashed before the dump. A string, symbol or function.")

(defvar *log-to-file* t
  "When true, *standard-output* and *error-output* are redirected to
~/Library/Logs/<bundle-name>.log, since Finder-launched apps have no tty.
Set from the system's :BUNDLE-LOG option at dump time.")

(defvar *log-max-bytes* 1048576
  "Rotate the log once it exceeds this. NIL disables rotation, which means an
app that logs on every launch grows a file forever.")

(defvar *app-name* "app")

(defun running-in-bundle-p () (and *bundle-root* t))

(defun bundle-root ()
  (or *bundle-root*
      (setf *bundle-root* (locate-bundle-root))))

(defun locate-bundle-root ()
  "Walk up from the running executable looking for Foo.app/Contents/MacOS/exe."
  (let* ((exe (or (ignore-errors (uiop:argv0))
                  #+sbcl (namestring sb-ext:*runtime-pathname*)))
         (dirs (and exe (pathname-directory (uiop:parse-native-namestring exe)))))
    (when (and dirs (>= (length dirs) 4))
      (let ((tail (last dirs 2))
            (appdir (car (last dirs 3))))
        (when (and (equal (first tail) "Contents")
                   (equal (second tail) "MacOS")
                   (stringp appdir)
                   (uiop:string-suffix-p appdir ".app"))
          (make-pathname :directory (butlast dirs 2)
                         :name nil :type nil :version nil))))))

(defun bundle-subdir (&rest components)
  (let ((root (bundle-root)))
    (when root
      (uiop:merge-pathnames*
       (uiop:parse-unix-namestring (format nil "~{~a/~}" components))
       root))))

(defun bundle-resource (&optional relative)
  "Pathname of Contents/Resources, or of RELATIVE within it."
  (let ((res (bundle-subdir "Contents" "Resources")))
    (if (and res relative)
        (uiop:merge-pathnames* (uiop:parse-unix-namestring relative) res)
        res)))

(defun bundle-frameworks ()
  (bundle-subdir "Contents" "Frameworks"))

;;; ------------------------------------------------------------------
;;; toplevel

(defun resolve-entry-point (spec)
  (etypecase spec
    (function spec)
    (symbol (fdefinition spec))
    (string
     (let ((sym (uiop:safe-read-from-string spec :package :cl-user)))
       (unless (and (symbolp sym) (fboundp sym))
         (error "Entry point ~s does not name a function." spec))
       (fdefinition sym)))))

(defun register-foreign-directory ()
  "Push Contents/Frameworks onto CFFI's search path, if CFFI is present."
  (let ((dir (bundle-frameworks))
        (pkg (find-package "CFFI")))
    (when (and dir pkg)
      (let ((var (find-symbol "*FOREIGN-LIBRARY-DIRECTORIES*" pkg)))
        (when (and var (boundp var))
          (pushnew dir (symbol-value var) :test #'equal))))))

(defparameter +log-override-variable+ "MACOS_APP_LOG"
  "Environment variable that redirects the app's log. Useful for debugging a
shipped bundle, and for tests that must not write to the real home directory.")

(defun app-log-file ()
  (let ((override (uiop:getenv +log-override-variable+)))
    (if (and override (plusp (length override)))
        (uiop:parse-native-namestring override)
        (merge-pathnames (format nil "Library/Logs/~a.log" *app-name*)
                         (user-homedir-pathname)))))

(defun rotate-log (log)
  "Keep one previous generation, so a long-lived app cannot fill the disk."
  (let ((size (ignore-errors
               (with-open-file (s log :element-type '(unsigned-byte 8))
                 (file-length s)))))
    (when (and size *log-max-bytes* (> size *log-max-bytes*))
      (ignore-errors
       (uiop:rename-file-overwriting-target
        log (make-pathname :type (format nil "~a.1" (or (pathname-type log) "log"))
                           :defaults log))))))

(defun clean-arguments (args)
  "Finder used to pass -psn_0_NNNN; drop anything that looks like it."
  (remove-if (lambda (a) (and (stringp a) (uiop:string-prefix-p "-psn_" a)))
             args))

(defun %app-toplevel ()
  "The dumped image's entry point. Sets up the bundle environment, then
calls the user's entry point."
  (setf *bundle-root* (locate-bundle-root))
  ;; Finder launches with cwd = /
  (setf *default-pathname-defaults* (user-homedir-pathname))
  (register-foreign-directory)
  (let ((log (and *log-to-file* (running-in-bundle-p) (app-log-file))))
    (flet ((go! ()
             (setf uiop:*command-line-arguments*
                   (clean-arguments uiop:*command-line-arguments*))
             (funcall (resolve-entry-point *entry-point*))))
      (handler-case
          (if log
              (progn
                (ensure-directories-exist log)
                (rotate-log log)
                (with-open-file (out log :direction :output
                                         :if-exists :append
                                         :if-does-not-exist :create)
                  (let ((*standard-output* out)
                        (*error-output* out)
                        (*trace-output* out))
                    (go!))))
              (go!))
        (error (e)
          (when log
            (ignore-errors
             (with-open-file (out log :direction :output
                                      :if-exists :append
                                      :if-does-not-exist :create)
               (format out "~&Fatal: ~a~%" e)
               (uiop:print-backtrace :stream out :condition e))))
          (uiop:quit 70))))
    (uiop:quit 0)))
