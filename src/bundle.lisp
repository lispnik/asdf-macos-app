;;;; bundle.lisp -- the .app directory layout.

(in-package #:asdf-macos-app)

(defstruct (app-spec (:conc-name spec-))
  root                                  ; where we are building right now
  final-root                            ; where it ends up on success
  (name "App")                          ; CFBundleName
  display-name                          ; CFBundleDisplayName
  identifier                            ; CFBundleIdentifier (required)
  (version "0.0.0")                     ; CFBundleVersion
  short-version                         ; CFBundleShortVersionString
  (executable-name "app")               ; Contents/MacOS/<this>
  icon                                  ; source .icns or .png, or NIL
  (minimum-system-version "11.0")
  agent-p                               ; LSUIElement
  (high-resolution-p t)
  category                              ; LSApplicationCategoryType
  principal-class                       ; NSPrincipalClass, e.g. "NSApplication"
  copyright
  url-schemes                           ; list of strings
  document-types                        ; list of DSL dicts
  extra-plist                           ; alist of key -> DSL value
  resources                             ; extra files/dirs for Contents/Resources
  (log-p t)                             ; redirect stdio to a log file at runtime
  (log-max-bytes 1048576)               ; rotate the log past this size
  foreign-libraries                     ; extra dylibs to bundle
  signing-identity                      ; NIL, "-", or "Developer ID Application: ..."
  (entitlements :sbcl-default)          ; :sbcl-default | pathname | NIL
  (hardened-runtime-p t)
  compression)                          ; NIL, T, or 0-22 for zstd

(defun sanitize-version (version &optional what)
  "Apple accepts one to three period-separated integers and nothing else, so
\"1.4.2-alpha\" or an ASDF version with a git suffix is rejected outright by
notarytool. Reduce to the leading numeric components."
  (let* ((raw (or version "0"))
         (parts (loop for field in (uiop:split-string raw :separator ".")
                      for digits = (subseq field 0 (or (position-if-not #'digit-char-p field)
                                                       (length field)))
                      while (plusp (length digits))
                      collect (format nil "~d" (parse-integer digits))))
         (clean (format nil "~{~a~^.~}" (or (subseq parts 0 (min 3 (length parts)))
                                            '("0")))))
    (when (and what (string/= clean raw))
      (note "~a ~s is not a valid Apple version; using ~s." what raw clean))
    clean))

(defun contents-dir  (spec) (uiop:subpathname (spec-root spec) "Contents/"))
(defun macos-dir     (spec) (uiop:subpathname (contents-dir spec) "MacOS/"))
(defun resources-dir (spec) (uiop:subpathname (contents-dir spec) "Resources/"))
(defun frameworks-dir(spec) (uiop:subpathname (contents-dir spec) "Frameworks/"))

(defun executable-path (spec)
  (uiop:subpathname (macos-dir spec) (spec-executable-name spec)))

(defparameter +core-name+ "sbcl.core"
  "What the core must be called for the runtime to find it unaided.

Not a choice.  With no --core argument and no SBCL_HOME -- which is what
LaunchServices gives a double-clicked application -- the runtime looks for a
core of exactly this name beside its own executable.  Rename it and the bundle
starts SBCL's REPL into a log file instead of running the application.")

(defun core-path (spec)
  "Where the core actually lives: a sealed resource.

Contents/Resources/, and NOT Contents/MacOS/, because codesign treats every
file in MacOS/ as nested code and refuses a bundle containing one it cannot
sign: `code object is not signed at all / In subcomponent: .../MacOS/sbcl.core'.
That holds however the file is permissioned."
  (uiop:subpathname (resources-dir spec) +core-name+))

(defun core-link-path (spec)
  "The symbolic link in MacOS/ that points at the core in Resources/.

This is what reconciles the two constraints above: the runtime finds a core
named sbcl.core beside itself, and codesign sees a symlink -- which it seals as
an ordinary resource rather than trying to sign as code."
  (uiop:subpathname (macos-dir spec) +core-name+))

(defun info-plist-path (spec)
  (uiop:subpathname (contents-dir spec) "Info.plist"))

(defun foreign-manifest-path (spec)
  (uiop:subpathname (resources-dir spec) "foreign-libraries.sexp"))

;;; ------------------------------------------------------------------

(defun make-skeleton (spec &key clean)
  (when (and clean (probe-file (spec-root spec)))
    (uiop:delete-directory-tree (spec-root spec) :validate t))
  (dolist (d (list (macos-dir spec) (resources-dir spec) (frameworks-dir spec)))
    (ensure-directories-exist d))
  (spec-root spec))

(defparameter *incomplete-build-marker* "INCOMPLETE-BUILD"
  "Name of the file dropped into Contents/ when the bundle was assembled
without the macOS toolchain.")

(defun incomplete-bundle-p (bundle)
  "True if BUNDLE was assembled without the macOS toolchain."
  (and (probe-file (uiop:subpathname (uiop:ensure-directory-pathname bundle)
                                     (format nil "Contents/~a"
                                             *incomplete-build-marker*)))
       t))

(defun bundle-executable (bundle)
  "The single file in BUNDLE's Contents/MacOS, if there is one."
  (first (uiop:directory-files
          (uiop:subpathname (uiop:ensure-directory-pathname bundle)
                            "Contents/MacOS/"))))

(defun complete-bundle-p (bundle)
  "A bundle that actually holds an executable and was built with the toolchain.
Note that ASDF creates the output directory before PERFORM runs, so the mere
existence of Foo.app/Contents means nothing."
  (and (bundle-executable bundle) (not (incomplete-bundle-p bundle)) t))

(defun files-under (directory)
  "Every regular file at or below DIRECTORY."
  (let ((directory (uiop:ensure-directory-pathname directory)))
    (when (uiop:directory-exists-p directory)
      (append (uiop:directory-files directory)
              (loop for d in (uiop:subdirectories directory)
                    append (files-under d))))))

(defun empty-bundle-stub-p (bundle)
  "True for the bare Foo.app/Contents that ASDF's ENSURE-ALL-DIRECTORIES-EXIST
leaves behind when a build fails before anything is committed. Deliberately
strict: this predicate authorises deleting a directory tree, so it demands the
tree hold no files whatsoever rather than merely lack an executable."
  (let ((bundle (uiop:ensure-directory-pathname bundle)))
    (and (uiop:directory-exists-p bundle)
         (null (files-under bundle)))))

(defun write-incomplete-marker (spec)
  "An off-macOS bundle looks exactly like a real one. Say so in the bundle
itself, so it cannot be mistaken for something shippable."
  (let ((p (uiop:subpathname (contents-dir spec) *incomplete-build-marker*)))
    (with-open-file (s p :direction :output :if-exists :supersede)
      (format s "This bundle was assembled on ~a, not macOS.~%~%~
                 Foreign libraries were NOT copied into Contents/Frameworks or ~
                 relocated, the bundle is NOT code signed, and any PNG icon was ~
                 NOT converted. It is for testing the layout only. Do not ship ~
                 it.~%"
              (or (uiop:operating-system) "a non-Darwin host")))
    (note "assembled off macOS: wrote Contents/~a" *incomplete-build-marker*)
    p))

(defun write-pkginfo (spec)
  (let ((p (uiop:subpathname (contents-dir spec) "PkgInfo")))
    (with-open-file (s p :direction :output :if-exists :supersede)
      (write-string "APPL????" s))
    p))

(defun info-plist-form (spec)
  (let ((base
          `(:dict
            ("CFBundleInfoDictionaryVersion" . "6.0")
            ("CFBundlePackageType"           . "APPL")
            ("CFBundleSignature"             . "????")
            ("CFBundleName"                  . ,(spec-name spec))
            ("CFBundleDisplayName"           . ,(or (spec-display-name spec)
                                                    (spec-name spec)))
            ("CFBundleExecutable"            . ,(spec-executable-name spec))
            ("CFBundleIdentifier"            . ,(or (spec-identifier spec)
                                                    (barf "BUNDLE-IDENTIFIER is required.")))
            ("CFBundleVersion"               . ,(sanitize-version
                                                   (spec-version spec) "Version"))
            ("CFBundleShortVersionString"    . ,(sanitize-version
                                                   (or (spec-short-version spec)
                                                       (spec-version spec))
                                                   "Short version"))
            ("LSMinimumSystemVersion"        . ,(spec-minimum-system-version spec))
            ("NSHighResolutionCapable"       . ,(if (spec-high-resolution-p spec)
                                                    :true :false))
            ,@(when (spec-icon spec)
                `(("CFBundleIconFile" . ,(spec-executable-name spec))))
            ,@(when (spec-agent-p spec) '(("LSUIElement" . :true)))
            ,@(when (spec-category spec)
                `(("LSApplicationCategoryType" . ,(spec-category spec))))
            ,@(when (spec-principal-class spec)
                `(("NSPrincipalClass" . ,(spec-principal-class spec))))
            ,@(when (spec-copyright spec)
                `(("NSHumanReadableCopyright" . ,(spec-copyright spec))))
            ,@(when (spec-url-schemes spec)
                `(("CFBundleURLTypes"
                   . (:array
                      (:dict ("CFBundleURLName" . ,(spec-identifier spec))
                             ("CFBundleURLSchemes"
                              . (:array ,@(spec-url-schemes spec))))))))
            ,@(when (spec-document-types spec)
                `(("CFBundleDocumentTypes"
                   . (:array ,@(spec-document-types spec))))))))
    (plist-merge base (spec-extra-plist spec))))

(defun write-info-plist (spec)
  (lint-plist (write-plist (info-plist-form spec) (info-plist-path spec))))

;;; ------------------------------------------------------------------
;;; icons

(defparameter +icon-sizes+ '(16 32 128 256 512)
  "Base sizes; each is emitted at 1x and 2x.")

(defun png->icns (png output)
  "Build an .icns from a square PNG (1024x1024 recommended) using sips/iconutil."
  (unless (macos-p)
    (note "not on macOS: skipping icon conversion for ~a" png)
    (return-from png->icns nil))
  (require-macos "Converting a PNG icon")
  (let ((iconset (uiop:ensure-directory-pathname
                  (format nil "~a.iconset"
                          (uiop:native-namestring
                           (uiop:subpathname (uiop:temporary-directory)
                                             (format nil "icon-~36r" (random (expt 36 8)))))))))
    (unwind-protect
         (progn
           (ensure-directories-exist iconset)
           (dolist (size +icon-sizes+)
             (dolist (scale '(1 2))
               (let* ((px (* size scale))
                      (file (uiop:subpathname
                             iconset
                             (format nil "icon_~dx~d~@[~a~].png"
                                     size size (when (= scale 2) "@2x")))))
                 (run (list "/usr/bin/sips" "-z" (princ-to-string px)
                            (princ-to-string px)
                            (uiop:native-namestring png)
                            "--out" (uiop:native-namestring file))))))
           (ensure-directories-exist output)
           (run (list "/usr/bin/iconutil" "-c" "icns"
                      (string-right-trim "/" (uiop:native-namestring iconset))
                      "-o" (uiop:native-namestring output)))
           output)
      (ignore-errors (uiop:delete-directory-tree iconset :validate t)))))

(defun symlink-p (path)
  "True if PATH ITSELF is a symbolic link.

lstat, not TRUENAME.  Comparing a path against its truename answers \"is there a
symlink ANYWHERE in this path\", which on macOS is nearly always yes: /var is a
symlink to /private/var, so every file under /tmp or in a temporary directory
resolved to a different string and was reported as a link.  That is a false
positive with teeth -- CHECK-NOT-A-SYMLINK refuses what it flags, so perfectly
ordinary resources under a temporary directory were rejected.

lstat asks about the leaf and nothing above it, which is the question."
  (let ((stat (ignore-errors
               (sb-posix:lstat (uiop:native-namestring
                                (if (uiop:directory-pathname-p path)
                                    (uiop:ensure-directory-pathname path)
                                    path))))))
    (and stat (sb-posix:s-islnk (sb-posix:stat-mode stat)) t)))

(defun check-not-a-symlink (path)
  ;; Copying through a symlink would pull in whatever it points at, which is
  ;; how a resource escapes the bundle. Refuse rather than follow.
  (when (symlink-p path)
    (barf "Resource ~a is a symbolic link. Point :BUNDLE-RESOURCES at the ~
           real file or directory instead." (uiop:native-namestring path)))
  path)

(defun copy-tree-into (source dest)
  "Copy SOURCE, a file or a directory, to DEST. Directories are copied whole.
Symbolic links anywhere in SOURCE are refused, not followed."
  (check-not-a-symlink source)
  (cond
    ((uiop:directory-exists-p source)
     (let ((source (uiop:ensure-directory-pathname source))
           (dest (uiop:ensure-directory-pathname dest)))
       (ensure-directories-exist dest)
       (dolist (f (uiop:directory-files source))
         (uiop:copy-file (check-not-a-symlink f)
                         (uiop:subpathname dest (file-namestring f))))
       (dolist (d (uiop:subdirectories source))
         (copy-tree-into d (uiop:subpathname
                            dest (format nil "~a/"
                                         (car (last (pathname-directory d)))))))))
    ((probe-file source)
     (ensure-directories-exist dest)
     (uiop:copy-file source dest))
    (t (barf "Resource ~a does not exist." source)))
  dest)

(defun existing-ancestor (path)
  "The truename of the deepest directory at or above PATH that exists."
  (let ((dir (uiop:pathname-directory-pathname path)))
    (dotimes (i 64 dir)
      (let ((resolved (ignore-errors (uiop:truename* dir))))
        (when resolved (return resolved)))
      (let ((parent (uiop:pathname-parent-directory-pathname dir)))
        (when (equal parent dir) (return dir))
        (setf dir parent)))))

(defun reserved-resource-names (spec)
  "Names inside Contents/Resources that the build writes itself. A resource
landing on one of these would either be clobbered later or clobber something
the bundle needs."
  (list (format nil "~a.icns" (spec-executable-name spec))
        "entitlements.plist"
        "foreign-libraries.sexp"))

(defun check-resource-destination (spec relative seen)
  "Signal unless RELATIVE names a fresh, unreserved location inside Resources."
  (let* ((resources (uiop:ensure-directory-pathname (resources-dir spec)))
         (dest (uiop:merge-pathnames* (uiop:parse-unix-namestring relative)
                                      resources))
         (native (uiop:native-namestring dest))
         (root (uiop:native-namestring resources)))
    ;; A "../" in the destination would land in Contents/ and could overwrite
    ;; Info.plist or the executable. Comparing the merged strings catches that,
    ;; but not a symlink partway down, so the deepest existing ancestor is
    ;; resolved and checked too.
    (unless (and (uiop:string-prefix-p root native)
                 (uiop:string-prefix-p (uiop:native-namestring
                                        (uiop:truename* resources))
                                       (uiop:native-namestring
                                        (existing-ancestor dest))))
      (barf "Resource destination ~s escapes Contents/Resources." relative))
    (let ((top (first (remove "" (uiop:split-string relative :separator "/")
                              :test #'string=))))
      (when (member top (reserved-resource-names spec) :test #'string-equal)
        (barf "Resource destination ~s collides with ~a, which the build ~
               generates. Choose another name." relative top)))
    (when (gethash native seen)
      (barf "Two resources both install to ~s." relative))
    (setf (gethash native seen) t)
    dest))

(defun install-resources (spec)
  "Copy :BUNDLE-RESOURCES into Contents/Resources. An entry is either a path,
copied under its own name, or (path . \"relative/destination\")."
  (let ((seen (make-hash-table :test #'equal)))
    (loop for entry in (spec-resources spec)
          for source = (if (consp entry) (car entry) entry)
          for relative = (if (consp entry)
                             (cdr entry)
                             (if (uiop:directory-exists-p source)
                                 (format nil "~a/"
                                         (car (last (pathname-directory
                                                     (uiop:ensure-directory-pathname
                                                      source)))))
                                 (file-namestring source)))
          collect (copy-tree-into source
                                  (check-resource-destination spec relative seen)))))

(defun icon-cache-path (spec)
  "Converted icons are cached beside the finished bundle so that rebuilding
does not re-run sips ten times."
  (let ((final (or (spec-final-root spec) (spec-root spec))))
    (make-pathname :name (format nil ".~a" (spec-executable-name spec))
                   :type "icns"
                   :directory (butlast (pathname-directory final))
                   :defaults final)))

(defun install-icon (spec)
  (let ((src (spec-icon spec)))
    (when src
      (unless (probe-file src)
        (barf "Icon ~a does not exist." src))
      (let ((dest (uiop:subpathname (resources-dir spec)
                                    (format nil "~a.icns"
                                            (spec-executable-name spec)))))
        (ensure-directories-exist dest)
        (cond ((string-equal "icns" (pathname-type src))
               (uiop:copy-file src dest))
              ((string-equal "png" (pathname-type src))
               (let ((cache (icon-cache-path spec)))
                 (unless (and (probe-file cache)
                              (> (file-write-date cache) (file-write-date src)))
                   (png->icns src cache))
                 (if (probe-file cache)
                     (uiop:copy-file cache dest)
                     (note "no icon produced for ~a" src))))
              (t (barf "Icon must be .icns or .png, got ~a." src)))
        dest))))
