;;;; op.lisp -- the ASDF extension proper.
;;;;
;;;; Classes are interned in the ASDF package so that a .asd file can say
;;;;   :class :macos-app-system
;;;;   :build-operation "macos-app-op"
;;;; without needing our package to exist at read time.

(in-package #:asdf-macos-app)

;;; ------------------------------------------------------------------
;;; system class

(defclass asdf::macos-app-system (asdf:system)
  ((identifier    :initarg :bundle-identifier    :initform nil :reader app-identifier)
   (bundle-name   :initarg :bundle-name          :initform nil :reader app-bundle-name)
   (display-name  :initarg :bundle-display-name  :initform nil :reader app-display-name)
   (exe-name      :initarg :bundle-executable    :initform nil :reader app-exe-name)
   (short-version :initarg :bundle-short-version :initform nil :reader app-short-version)
   (icon          :initarg :bundle-icon          :initform nil :reader app-icon)
   (min-system    :initarg :bundle-minimum-system-version
                  :initform "11.0" :reader app-min-system)
   (agent         :initarg :bundle-agent         :initform nil :reader app-agent-p)
   (hidpi         :initarg :bundle-high-resolution :initform t :reader app-hidpi-p)
   (category      :initarg :bundle-category      :initform nil :reader app-category)
   (principal     :initarg :bundle-principal-class :initform nil
                  :reader app-principal-class)
   (copyright     :initarg :bundle-copyright     :initform nil :reader app-copyright)
   (url-schemes   :initarg :bundle-url-schemes   :initform nil :reader app-url-schemes)
   (doc-types     :initarg :bundle-document-types :initform nil :reader app-doc-types)
   (extra-plist   :initarg :bundle-info-plist    :initform nil :reader app-extra-plist)
   (resources     :initarg :bundle-resources     :initform nil :reader app-resources)
   (log           :initarg :bundle-log           :initform t   :reader app-log-p)
   (log-max       :initarg :bundle-log-max-bytes :initform 1048576
                  :reader app-log-max-bytes)
   (foreign-libs  :initarg :bundle-foreign-libraries
                  :initform nil :reader app-foreign-libraries)
   (output-dir    :initarg :bundle-output-directory
                  :initform nil :reader app-output-directory)
   (identity      :initarg :code-signing-identity :initform nil :reader app-identity)
   (entitlements  :initarg :entitlements         :initform :sbcl-default
                  :reader app-entitlements)
   (hardened      :initarg :hardened-runtime     :initform t :reader app-hardened-p)
   (compression   :initarg :compression          :initform nil :reader app-compression)))

;;; ------------------------------------------------------------------
;;; operations

(defclass asdf::macos-app-op (asdf::non-propagating-operation) ()
  (:documentation "Build a complete .app bundle. Runs the image dump in a
child Lisp, because SAVE-LISP-AND-DIE terminates the process that calls it."))

(defclass asdf::macos-app-image-op (asdf::selfward-operation)
  ((asdf::selfward-operation :initform 'asdf:load-op :allocation :class))
  (:documentation "Dump the executable into Contents/MacOS/. This is what the
child Lisp performs; it never returns."))

;;; ------------------------------------------------------------------
;;; system -> spec

(defparameter +bundle-env-var+ "ASDF_MACOS_APP_BUNDLE")

(defun default-bundle-name (system)
  (or (app-bundle-name system)
      (let ((bp (asdf::component-build-pathname system)))
        (and bp (pathname-name (pathname bp))))
      (string-capitalize (asdf:component-name system))))

(defun bundle-root-for (system)
  (or (let ((env (uiop:getenv +bundle-env-var+)))
        (and env (plusp (length env)) (uiop:ensure-directory-pathname env)))
      (uiop:subpathname
       (or (app-output-directory system)
           (asdf:system-source-directory system))
       (format nil "~a.app/" (default-bundle-name system)))))

(defun system-app-spec (system)
  (let ((name (default-bundle-name system)))
    (make-app-spec
     :root (bundle-root-for system)
     :final-root (bundle-root-for system)
     :name name
     :display-name (app-display-name system)
     :identifier (or (app-identifier system)
                     (barf "System ~a needs :BUNDLE-IDENTIFIER, e.g. \"com.example.~a\"."
                           (asdf:component-name system)
                           (asdf:component-name system)))
     :version (or (asdf:component-version system) "0.0.0")
     :short-version (app-short-version system)
     :executable-name (or (app-exe-name system)
                          (string-downcase (asdf:component-name system)))
     :icon (let ((i (app-icon system)))
             (and i (merge-pathnames i (asdf:system-source-directory system))))
     :minimum-system-version (app-min-system system)
     :agent-p (app-agent-p system)
     :high-resolution-p (app-hidpi-p system)
     :category (app-category system)
     :principal-class (app-principal-class system)
     :copyright (app-copyright system)
     :url-schemes (app-url-schemes system)
     :document-types (app-doc-types system)
     :extra-plist (app-extra-plist system)
     :resources (mapcar (lambda (entry)
                          (flet ((resolve (p)
                                   (merge-pathnames
                                    p (asdf:system-source-directory system))))
                            (if (consp entry)
                                (cons (resolve (car entry)) (cdr entry))
                                (resolve entry))))
                        (app-resources system))
     :log-p (app-log-p system)
     :log-max-bytes (app-log-max-bytes system)
     :foreign-libraries (mapcar (lambda (l)
                                  (merge-pathnames
                                   l (asdf:system-source-directory system)))
                                (app-foreign-libraries system))
     :signing-identity (app-identity system)
     :entitlements (app-entitlements system)
     :hardened-runtime-p (app-hardened-p system)
     :compression (app-compression system))))

;;; ------------------------------------------------------------------
;;; child process

(defvar *child-lisp* nil
  "Path to the SBCL used for the image dump. Defaults to the running one.")

(defvar *child-lisp-options* nil
  "Extra command line options for the child, appended before the --evals.")

(defun child-lisp ()
  (or *child-lisp*
      (uiop:getenv "SBCL")
      #+sbcl (uiop:native-namestring sb-ext:*runtime-pathname*)
      #-sbcl (barf "Set MACOS-APP:*CHILD-LISP*; only SBCL is supported.")))

(defun central-registry-directories ()
  "Directory entries of ASDF:*CENTRAL-REGISTRY*. ASDF evaluates these entries;
we deliberately do not. A pathname or string is taken as is and a symbol is
read for its value, which covers the usual *DEFAULT-PATHNAME-DEFAULTS* idiom;
anything else is skipped rather than evaluated, because assembling a build
should not run arbitrary forms found in a special variable."
  (loop for entry in asdf:*central-registry*
        for value = (typecase entry
                      ((or pathname string) entry)
                      (symbol (and (boundp entry) (symbol-value entry)))
                      (t nil))
        when (typep value '(or pathname string))
          collect (ignore-errors (uiop:ensure-directory-pathname value))))

(defun child-source-registry-form (system)
  "An explicit source registry for the child, one (:directory ...) per system
in the resolved dependency closure. Inheriting configuration alone is not
enough: the parent may have found systems through asdf:*central-registry* or a
search function (ocicl, say) that the child's own configuration cannot see.

This is passed inside the bootstrap file rather than through the environment.
CL_SOURCE_REGISTRY would work for a small project, but the closure of a large
one can outgrow the argument and environment limit, and a file has no such
bound."
  (let* ((closure (cons (asdf:find-system "asdf-macos-app")
                        (dependency-closure (asdf:component-name system))))
         (dirs (remove-duplicates
                (remove nil (append (mapcar #'asdf:system-source-directory closure)
                                    (central-registry-directories)))
                :test #'equal :from-end t)))
    `(:source-registry
      ,@(mapcar (lambda (d) (list :directory (uiop:native-namestring d))) dirs)
      :inherit-configuration)))

(defun child-environment (spec)
  (let ((overrides (list (cons +bundle-env-var+
                               (uiop:native-namestring (spec-root spec))))))
    (append (loop for (k . v) in overrides collect (format nil "~a=~a" k v))
            (remove-if (lambda (entry)
                         (some (lambda (o)
                                 (uiop:string-prefix-p
                                  (concatenate 'string (car o) "=") entry))
                               overrides))
                       #+sbcl (sb-ext:posix-environ)
                       #-sbcl nil))))

(defparameter +child-phases+
  '((:configuring     . "configuring the source registry")
    (:reading-system  . "reading the .asd (a dependency system may be unfindable)")
    (:loading-system  . "compiling and loading the system")
    (:dumping-image   . "dumping the executable"))
  "What each phase means, for the parent's error message.")

(defun cl-user-symbol (name)
  "Symbols in the bootstrap must be readable by the child before any of our
packages exist there, so they live in CL-USER."
  (intern name (find-package :cl-user)))

(defun child-bootstrap-forms (asd system-name status-file registry)
  "The forms the child --loads. Built as data and printed, rather than
interpolated into a template: a template is read as one opaque string, so an
arity or quoting mistake in it is only caught, if at all, by the compiler in
the child. Self-contained plain CL, because it must be able to report a
failure in LOAD-ASD itself -- which happens before this extension is loaded
in the child."
  (let ((status (cl-user-symbol "*STATUS-FILE*"))
        (phase (cl-user-symbol "*PHASE*"))
        (report (cl-user-symbol "REPORT-STATUS"))
        (enter (cl-user-symbol "ENTER-PHASE"))
        (condition (cl-user-symbol "CONDITION"))
        (new-phase (cl-user-symbol "NEW-PHASE"))
        (stream (cl-user-symbol "STREAM"))
        (out (cl-user-symbol "OUT"))
        (e (cl-user-symbol "E")))
    `((require :asdf)
      (defparameter ,status ,(uiop:native-namestring status-file))
      (defparameter ,phase :startup)
      (defun ,report (&optional ,condition)
        (with-open-file (,out ,status :direction :output :if-exists :supersede)
          (write (list :phase ,phase
                       :error (and ,condition (princ-to-string ,condition))
                       :backtrace
                       (and ,condition
                            (with-output-to-string (,stream)
                              (ignore-errors
                               (uiop:print-backtrace :stream ,stream
                                                     :condition ,condition)))))
                 :stream ,out :readably nil :escape t :pretty nil)))
      (defun ,enter (,new-phase) (setf ,phase ,new-phase) (,report))
      (handler-bind ((error (lambda (,e) (,report ,e) (uiop:quit 1))))
        (,enter :configuring)
        (asdf:initialize-source-registry ',registry)
        (,enter :reading-system)
        (asdf:load-asd ,(uiop:native-namestring asd))
        (,enter :loading-system)
        (asdf:load-system ,system-name)
        (,enter :dumping-image)
        (asdf:operate 'asdf::macos-app-image-op ,system-name)))))

(defun write-child-bootstrap (stream forms)
  (with-standard-io-syntax
    (let ((*print-pretty* nil) (*print-readably* nil) (*print-escape* t))
      (dolist (form forms)
        (prin1 form stream)
        (terpri stream)))))

(defun read-child-status (status-file)
  (when (probe-file status-file)
    (ignore-errors
     (with-open-file (s status-file)
       (with-standard-io-syntax
         (let ((*read-eval* nil) (*package* (find-package :keyword)))
           (read s nil nil)))))))

(defun child-failure (code status)
  (let* ((phase (getf status :phase))
         (what (cdr (assoc phase +child-phases+))))
    (cond
      ((null status)
       (barf "Child Lisp exited ~d before it could report anything. It most ~
              likely could not start or could not (require :asdf)." code))
      ((null (getf status :error))
       ;; a phase was entered but no condition recorded: a hard crash, most
       ;; likely heap exhaustion during the dump
       (barf "Child Lisp died during ~a (exit ~d) without signalling a ~
              condition. Try a larger --dynamic-space-size via ~
              MACOS-APP:*CHILD-LISP-OPTIONS*."
             (or what phase) code))
      (t
       (barf "Child Lisp failed while ~a:~%~a~@[~%~%~a~]"
             (or what phase) (getf status :error) (getf status :backtrace))))))

(defun dump-in-child (system spec)
  (uiop:with-temporary-file (:pathname status :keep nil :type "sexp")
    (uiop:with-temporary-file (:pathname boot :keep nil :type "lisp"
                               :stream bs :direction :output)
      (write-child-bootstrap
       bs (child-bootstrap-forms (asdf:system-source-file system)
                                 (asdf:component-name system)
                                 status
                                 (child-source-registry-form system)))
      :close-stream
      (let ((cmd (append (list (child-lisp))
                         #+sbcl (list "--dynamic-space-size"
                                      (princ-to-string
                                       (max 2048 (floor (sb-ext:dynamic-space-size)
                                                        (* 1024 1024)))))
                         (list "--disable-debugger")
                         *child-lisp-options*
                         (list "--load" (uiop:native-namestring boot)))))
        (format *standard-output* "~&; dumping image: ~{~a ~}~%" cmd)
        (let ((code (nth-value 2 (uiop:run-program
                                  cmd
                                  :environment (child-environment spec)
                                  :output :interactive
                                  :error-output :interactive
                                  :ignore-error-status t))))
          (unless (zerop code)
            (child-failure code (read-child-status status)))))))
  (unless (probe-file (core-path spec))
    (barf "Child Lisp reported success but ~a does not exist."
          (uiop:native-namestring (core-path spec))))
  (core-path spec))

;;; ------------------------------------------------------------------
;;; staging: build beside the target, then move into place

(defun sibling-directory (dir suffix)
  (let ((dirs (pathname-directory dir)))
    (make-pathname :directory (append (butlast dirs)
                                      (list (format nil ".~a~a"
                                                    (car (last dirs)) suffix)))
                   :name nil :type nil :version nil :defaults dir)))

(defun unique-suffix (tag)
  (format nil ".~a-~36r" tag (random (expt 36 8) (make-random-state t))))

(defun mv (from to)
  "Move a directory. rename(2) is atomic, which is the point of the staging
scheme; it only fails across filesystems, and staging, trash and target are
always siblings. /bin/mv is the fallback for that case."
  (let ((from (string-right-trim "/" (uiop:native-namestring from)))
        (to (string-right-trim "/" (uiop:native-namestring to))))
    (or #+sbcl (ignore-errors (sb-posix:rename from to) t)
        (progn (run (list "/bin/mv" from to)) t))))

(defvar *replace-complete-bundle* nil
  "Bind to T to allow an incomplete build to replace a complete one.")

(defun commit-bundle (staging final)
  "Move STAGING onto FINAL. The previous bundle is set aside first so that a
failure here leaves the old one intact rather than nothing at all."
  ;; The marker is only worth writing if something acts on it: replacing a
  ;; signed, relocated bundle with a layout-only stub is exactly the mistake it
  ;; exists to prevent.
  (when (and (incomplete-bundle-p staging)
             (complete-bundle-p final)
             (not *replace-complete-bundle*))
    (barf "Refusing to replace the complete bundle at ~a with one built ~
           without the macOS toolchain. Delete it first, or bind ~
           MACOS-APP:*REPLACE-COMPLETE-BUNDLE* to T."
          (uiop:native-namestring final)))
  (let ((trash (and (probe-file final)
                    (sibling-directory final (unique-suffix "trash")))))
    (when trash (mv final trash))
    (handler-bind ((error (lambda (e) (declare (ignore e))
                            (when trash (ignore-errors (mv trash final))))))
      (mv staging final))
    (when trash (uiop:delete-directory-tree trash :validate t))
    final))

;;; ------------------------------------------------------------------
;;; freshness: skip the child dump when nothing has changed

(defvar *force-image-dump* nil
  "Bind to T to dump the image even when the existing one looks current.")

(defun dependency-name (spec)
  "Reduce an ASDF :depends-on entry to a system name, or NIL."
  (typecase spec
    (string spec)
    (symbol (string-downcase (symbol-name spec)))
    (cons (case (first spec)
            (:version (dependency-name (second spec)))
            (:feature (dependency-name (third spec)))
            (:require nil)
            (t nil)))
    (t nil)))

(defun source-components (component)
  (if (typep component 'asdf:parent-component)
      (loop for c in (asdf:component-children component)
            append (source-components c))
      (list component)))

(defun dependency-closure (name &optional (seen (make-hash-table :test #'equal)))
  "Every system NAME transitively depends on, as system objects, including
NAME itself. Systems the parent cannot resolve are skipped rather than fatal;
they may still be findable from the child's own configuration."
  (let ((sys (and name (ignore-errors (asdf:find-system name nil)))))
    (when (and sys (not (gethash (asdf:component-name sys) seen)))
      (setf (gethash (asdf:component-name sys) seen) t)
      (cons sys (loop for d in (asdf:system-depends-on sys)
                      append (dependency-closure (dependency-name d) seen))))))

(defun system-input-files (name)
  "Every .asd and source file that could affect NAME's image, transitively."
  (loop for sys in (dependency-closure name)
        append (remove nil (cons (asdf:system-source-file sys)
                                 (mapcar #'asdf:component-pathname
                                         (source-components sys))))))

(defun newest-input-date (system)
  (loop for f in (append (system-input-files (asdf:component-name system))
                         (system-input-files "asdf-macos-app"))
        for d = (and f (uiop:safe-file-write-date f))
        when d maximize d))

(defun current-image (system spec)
  "Pathname of a previously built core we can reuse, or NIL.

The core rather than the executable: the executable is a copy of the SBCL
runtime now, which is the same file every time and says nothing about whether
this system has been rebuilt."
  (unless *force-image-dump*
    (let* ((previous (uiop:subpathname (spec-final-root spec)
                                       (format nil "Contents/Resources/~a"
                                               +core-name+)))
           (stamp (uiop:safe-file-write-date previous)))
      (when (and stamp (> stamp (newest-input-date system)))
        previous))))

(defun reuse-image (spec previous)
  (let ((core (core-path spec)))
    (ensure-directories-exist core)
    (run (list "/bin/cp" "-p" (uiop:native-namestring previous)
               (uiop:native-namestring core)))
    ;; the manifest was written by the child alongside the image it describes
    (let ((old-manifest (uiop:subpathname (spec-final-root spec)
                                          "Contents/Resources/foreign-libraries.sexp")))
      (when (probe-file old-manifest)
        (ensure-directories-exist (foreign-manifest-path spec))
        (uiop:copy-file old-manifest (foreign-manifest-path spec))))
    (format *standard-output* "~&; image is current, reusing it~%")
    exe))

;;; ------------------------------------------------------------------
;;; ASDF glue

(defmethod asdf:output-files ((o asdf::macos-app-op)
                              (s asdf::macos-app-system))
  ;; A real file rather than the bundle directory, so that ASDF's timestamp
  ;; bookkeeping has something it can stat.
  (values (list (info-plist-path (system-app-spec s))) t))

(defmethod asdf:output-files ((o asdf::macos-app-image-op)
                              (s asdf::macos-app-system))
  (values (list (executable-path (system-app-spec s))) t))

(defmethod asdf:operation-done-p ((o asdf::macos-app-op)
                                  (s asdf::macos-app-system))
  nil)

(defmethod asdf:perform ((o asdf::macos-app-image-op)
                         (s asdf::macos-app-system))
  ;; Runs in the child. Everything after DUMP-IMAGE is unreachable.
  (let* ((spec (system-app-spec s))
         (out (core-path spec)))
    (ensure-directories-exist out)
    (write-foreign-manifest spec (spec-foreign-libraries spec))
    ;; Resolve the entry point NOW. Deferring it to launch time means a typo
    ;; produces a perfectly valid bundle that dies on double-click.
    (let ((named (or (asdf::component-entry-point s)
                     (barf "System ~a needs an :ENTRY-POINT."
                           (asdf:component-name s)))))
      (setf *entry-point*
            (handler-case (resolve-entry-point named)
              (error (e) (barf "Entry point ~s is not callable: ~a" named e)))))
    (setf *app-name* (spec-name spec)
          *log-to-file* (spec-log-p spec)
          *log-max-bytes* (spec-log-max-bytes spec))
    ;; UIOP has no :entry-point argument; the toplevel comes from this special,
    ;; which RESTORE-IMAGE funcalls. *LISP-INTERACTION* must be NIL or a
    ;; returning toplevel drops into the REPL instead of exiting.
    (setf uiop:*image-entry-point* '%app-toplevel
          uiop:*lisp-interaction* nil)
    ;; A CORE, not an executable, and this is the decision the whole design
    ;; turns on.  SAVE-LISP-AND-DIE :EXECUTABLE T appends the core to the SBCL
    ;; runtime's Mach-O -- past the end of __LINKEDIT and past the code
    ;; signature -- and codesign then refuses the file outright:
    ;;
    ;;   main executable failed strict validation
    ;;
    ;; for a Developer ID as much as for ad hoc, and whether or not the old
    ;; signature is stripped first.  Measured: __LINKEDIT and the signature both
    ;; end at byte 410,952 of a 47,782,952-byte image.  An executable image
    ;; therefore cannot be signed, cannot be notarised, and cannot be shipped.
    ;;
    ;; Dumped as a core it is an ordinary data file, sealed as a resource, and
    ;; the runtime beside it is a clean signable Mach-O.  INSTALL-RUNTIME puts
    ;; the two together.
    ;;
    ;; SAVE-LISP-AND-DIE rather than UIOP:DUMP-IMAGE, for :TOPLEVEL.  UIOP passes
    ;; a toplevel only when dumping an executable; without one the restored core
    ;; runs SBCL's own toplevel first, which prints the banner, parses argv as
    ;; SBCL options, and dies on the application's own arguments before the
    ;; entry point ever runs.
    (apply #'sb-ext:save-lisp-and-die out
           :executable nil
           :toplevel #'uiop:restore-image
           (when (spec-compression spec)
             (list :compression (spec-compression spec))))))

(defun install-runtime (spec)
  "Put the SBCL runtime in MacOS/ and link the core beside it.

The runtime is copied rather than dumped into, so it stays exactly the Mach-O
the SBCL build produced -- which is a file codesign accepts.  The link is what
lets the runtime find its core with no arguments; see CORE-LINK-PATH."
  (let ((exe (executable-path spec))
        (link (core-link-path spec)))
    (ensure-directories-exist exe)
    (unless (probe-file (core-path spec))
      (barf "No core at ~a to build a runnable bundle around."
            (uiop:native-namestring (core-path spec))))
    (run (list "/bin/cp" "-p"
               (uiop:native-namestring sb-ext:*runtime-pathname*)
               (uiop:native-namestring exe)))
    ;; -p preserved the runtime's mode, which is read-only in a Homebrew
    ;; install; the copy has to be writable for codesign to sign it in place.
    (run (list "/bin/chmod" "755" (uiop:native-namestring exe)))
    ;; DELETE-FILE unconditionally, errors ignored: a DANGLING symlink is
    ;; invisible to PROBE-FILE but still occupies the name, and ln would fail on
    ;; it.  A rebuild into a reused staging directory is exactly when that
    ;; happens.
    (ignore-errors (delete-file link))
    (run (list "/bin/ln" "-s"
               (format nil "../Resources/~a" +core-name+)
               (uiop:native-namestring link)))
    exe))

(defmethod asdf:perform ((o asdf::macos-app-op)
                         (s asdf::macos-app-system))
  (require-macos "Building a .app bundle")
  (let* ((spec (system-app-spec s))
         (final (spec-final-root spec))
         (staging (sibling-directory final (unique-suffix "staging")))
         (previous (current-image s spec)))
    ;; Everything is assembled off to one side; a failed build must not leave a
    ;; half-written .app that Finder will happily try to launch.
    (setf (spec-root spec) staging)
    (let ((committed nil))
      (unwind-protect
         (progn
           (make-skeleton spec :clean t)
           (unless (macos-p) (write-incomplete-marker spec))
           (write-info-plist spec)
           (write-pkginfo spec)
           (install-icon spec)
           (install-resources spec)
           (if previous
               (reuse-image spec previous)
               (dump-in-child s spec))
           (install-runtime spec)
           (relocate-foreign-libraries spec)
           (sign-bundle spec)
           (commit-bundle staging final)
           (setf committed t)
           (format *standard-output* "~&; built ~a~%"
                   (uiop:native-namestring final))
           final)
        (when (probe-file staging)
          (ignore-errors (uiop:delete-directory-tree staging :validate t)))
        ;; ASDF made Foo.app/Contents before PERFORM ran. If we never committed,
        ;; that stub is the only thing at the destination and it must not
        ;; survive a failed build.
        (unless committed
          (when (empty-bundle-stub-p final)
            (ignore-errors (uiop:delete-directory-tree
                            (uiop:ensure-directory-pathname final)
                            :validate t))))))))

;;; ------------------------------------------------------------------
;;; driver

(defun make-app (system &rest keys &key force-image &allow-other-keys)
  "Build SYSTEM's .app bundle. Returns the bundle pathname.
FORCE-IMAGE re-dumps the executable even if the existing one looks current."
  ;; A fresh session rather than :FORCE. ASDF rejects :FORCE in a nested
  ;; OPERATE, which would make MAKE-APP uncallable from inside any :perform
  ;; method; and without something to reset the session, a second MAKE-APP in
  ;; the same image finds the action already visited and does nothing at all.
  (let ((*force-image-dump* force-image))
    (asdf/session:call-with-asdf-session
     (lambda ()
       (apply #'asdf:operate 'asdf::macos-app-op system
              (uiop:remove-plist-key :force-image keys)))
     :override t))
  (bundle-root-for (asdf:find-system system)))
