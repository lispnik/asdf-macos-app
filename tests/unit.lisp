;;;; tests/unit.lisp -- everything that does not need to build an image.

(in-package #:asdf-macos-app-tests)

;;; ------------------------------------------------------------------
;;; plist

(defun plist-string (form)
  (uiop:with-temporary-file (:pathname p :keep nil)
    (app::write-plist form p)
    (uiop:read-file-string p)))

(deftest plist-escapes-markup
  (let ((s (plist-string '(:dict ("K" . "a & b < c > d")))))
    (is (search "a &amp; b &lt; c &gt; d" s))
    (is (not (search "a & b" s)))))

(deftest plist-emits-each-type
  (let ((s (plist-string '(:dict ("s" . "x") ("i" . 42) ("t" . :true)
                           ("f" . :false)
                           ("a" . (:array "p" "q"))
                           ("d" . (:dict ("inner" . "y")))))))
    (is (search "<string>x</string>" s))
    (is (search "<integer>42</integer>" s))
    (is (search "<true/>" s))
    (is (search "<false/>" s))
    (is (search "<key>inner</key>" s))
    (is (search "<!DOCTYPE plist" s))))

(deftest plist-merge-overrides-and-adds
  (let ((m (app::plist-merge '(:dict ("A" . "old") ("B" . "keep"))
                             '(("A" . "new") ("C" . "added")))))
    (is= "new" (cdr (assoc "A" (cdr m) :test #'string=)))
    (is= "keep" (cdr (assoc "B" (cdr m) :test #'string=)))
    (is= "added" (cdr (assoc "C" (cdr m) :test #'string=)))))

;;; ------------------------------------------------------------------
;;; versions

(deftest version-sanitisation
  (flet ((v (x) (with-output-to-string (*standard-output*)
                  (return-from v (app::sanitize-version x)))))
    (is= "1.4.2" (v "1.4.2"))
    (is= "1.4.2" (v "1.4.2-alpha"))
    (is= "0.9"   (v "0.9"))
    (is= "2026.1.3" (v "2026.1.3.7"))
    (is= "1" (v "1"))
    (is= "0" (v "v1.2"))
    (is= "0" (v nil))
    (is= "0" (v ""))))

(defun capture-notes (thunk)
  (with-output-to-string (s)
    (let ((*standard-output* s)) (funcall thunk))))

(deftest version-notes-only-when-changed
  ;; NOTE rather than WARN, so a build driver that muffles warnings still
  ;; shows this
  (is= "" (capture-notes (lambda () (app::sanitize-version "1.2.3" "Version"))))
  (let ((text (capture-notes
               (lambda () (app::sanitize-version "1.2.3-rc1" "Version")))))
    (is (search "not a valid Apple version" text))
    (is (search "1.2.3-rc1" text))))

;;; ------------------------------------------------------------------
;;; otool -L parsing

(defparameter +otool-l-output+
  "/opt/homebrew/lib/libcairo.2.dylib:
	/opt/homebrew/opt/cairo/lib/libcairo.2.dylib (compatibility version 11803.0.0, current version 11803.13.0)
	@rpath/libpixman-1.0.dylib (compatibility version 41.0.0, current version 41.2.0)
	@loader_path/libfontconfig.1.dylib (compatibility version 12.0.0, current version 12.0.0)
	/usr/lib/libSystem.B.dylib (compatibility version 1.0.0, current version 1345.100.2)
")

(deftest otool-dependencies-parsing
  (let ((deps (app::parse-otool-dependencies +otool-l-output+)))
    ;; the header line naming the file itself is dropped
    (is (not (member "/opt/homebrew/lib/libcairo.2.dylib:" deps :test #'string=)))
    (is (member "@rpath/libpixman-1.0.dylib" deps :test #'string=))
    (is (member "@loader_path/libfontconfig.1.dylib" deps :test #'string=))
    (is (member "/usr/lib/libSystem.B.dylib" deps :test #'string=))
    (is= 4 (length deps))))

(deftest system-library-detection
  (is (app::system-library-p "/usr/lib/libSystem.B.dylib"))
  (is (app::system-library-p "/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation"))
  (is (not (app::system-library-p "/opt/homebrew/lib/libpixman-1.0.dylib")))
  (is (not (app::system-library-p "/usr/local/lib/libfoo.dylib"))))

;;; ------------------------------------------------------------------
;;; otool -l LC_RPATH parsing

(defparameter +otool-cap-output+
  "Load command 12
          cmd LC_LOAD_DYLIB
      cmdsize 56
         name /usr/lib/libSystem.B.dylib (offset 24)
Load command 13
          cmd LC_RPATH
      cmdsize 40
         path /opt/homebrew/lib (offset 12)
Load command 14
          cmd LC_RPATH
      cmdsize 48
         path @loader_path/../lib (offset 12)
Load command 15
          cmd LC_RPATH
      cmdsize 56
         path /Users/me/My Libs (offset 12)
Load command 16
          cmd LC_ID_DYLIB
      cmdsize 56
         name @rpath/libcairo.2.dylib (offset 24)
")

(deftest rpath-parsing
  (let ((rpaths (app::parse-otool-rpaths +otool-cap-output+)))
    ;; order matters: dyld searches LC_RPATHs in load-command order
    (is= '("/opt/homebrew/lib" "@loader_path/../lib" "/Users/me/My Libs") rpaths)))

(deftest rpath-parsing-ignores-name-fields
  ;; LC_LOAD_DYLIB and LC_ID_DYLIB use `name`, not `path`; neither is an rpath
  (let ((rpaths (app::parse-otool-rpaths +otool-cap-output+)))
    (is (not (member "/usr/lib/libSystem.B.dylib" rpaths :test #'string=)))
    (is (not (member "@rpath/libcairo.2.dylib" rpaths :test #'string=)))))

(deftest rpath-parsing-empty
  (is= '() (app::parse-otool-rpaths "")))

;;; ------------------------------------------------------------------
;;; install-name resolution against a real directory tree

(defmacro with-fake-libs ((dir &rest relative-names) &body body)
  `(uiop:with-temporary-file (:pathname stamp :keep nil)
     (let ((,dir (uiop:ensure-directory-pathname
                  (format nil "~a.d" (uiop:native-namestring stamp)))))
       (unwind-protect
            (progn
              (dolist (n ',relative-names)
                (let ((f (uiop:subpathname ,dir n)))
                  (ensure-directories-exist f)
                  (with-open-file (s f :direction :output :if-exists :supersede)
                    (write-string "not really a mach-o" s))))
              ,@body)
         (ignore-errors (uiop:delete-directory-tree ,dir :validate t))))))

(deftest resolve-rpath-searches-in-order
  (with-fake-libs (dir "a/origin.dylib" "b/libtarget.dylib" "c/libtarget.dylib")
    (let* ((origin (uiop:native-namestring (uiop:subpathname dir "a/origin.dylib")))
           (app::*rpath-cache* (make-hash-table :test #'equal)))
      ;; b before c: the first match wins, as dyld would do
      (setf (gethash origin app::*rpath-cache*)
            (list (uiop:native-namestring (uiop:subpathname dir "b/"))
                  (uiop:native-namestring (uiop:subpathname dir "c/"))))
      (is= (uiop:native-namestring (truename (uiop:subpathname dir "b/libtarget.dylib")))
           (app::resolve-install-name "@rpath/libtarget.dylib" origin)))))

(deftest resolve-rpath-skips-missing-entries
  (with-fake-libs (dir "a/origin.dylib" "c/libtarget.dylib")
    (let* ((origin (uiop:native-namestring (uiop:subpathname dir "a/origin.dylib")))
           (app::*rpath-cache* (make-hash-table :test #'equal)))
      (setf (gethash origin app::*rpath-cache*)
            (list "/nonexistent/lib"
                  (uiop:native-namestring (uiop:subpathname dir "c/"))))
      (is (app::resolve-install-name "@rpath/libtarget.dylib" origin)))))

(deftest resolve-rpath-expands-loader-path-in-the-rpath-itself
  (with-fake-libs (dir "a/origin.dylib" "lib/libtarget.dylib")
    (let* ((origin (uiop:native-namestring (uiop:subpathname dir "a/origin.dylib")))
           (app::*rpath-cache* (make-hash-table :test #'equal)))
      ;; the rpath entry is itself relative to the referring file
      (setf (gethash origin app::*rpath-cache*) (list "@loader_path/../lib"))
      (is (app::resolve-install-name "@rpath/libtarget.dylib" origin)))))

(deftest resolve-rpath-unresolvable-is-nil
  (with-fake-libs (dir "a/origin.dylib")
    (let* ((origin (uiop:native-namestring (uiop:subpathname dir "a/origin.dylib")))
           (app::*rpath-cache* (make-hash-table :test #'equal)))
      (setf (gethash origin app::*rpath-cache*) (list "/nowhere"))
      (is (null (app::resolve-install-name "@rpath/libtarget.dylib" origin))))))

(deftest resolve-loader-path-and-absolute
  (with-fake-libs (dir "a/origin.dylib" "a/libsibling.dylib")
    (let ((origin (uiop:native-namestring (uiop:subpathname dir "a/origin.dylib")))
          (app::*rpath-cache* (make-hash-table :test #'equal)))
      (is (app::resolve-install-name "@loader_path/libsibling.dylib" origin))
      (is (app::resolve-install-name
           (uiop:native-namestring (uiop:subpathname dir "a/libsibling.dylib"))
           origin))
      (is (null (app::resolve-install-name "/usr/lib/libSystem.B.dylib" origin)))
      (is (null (app::resolve-install-name "@loader_path/absent.dylib" origin))))))

;;; ------------------------------------------------------------------
;;; misc pure functions

(deftest dependency-name-normalisation
  (is= "alexandria" (app::dependency-name "alexandria"))
  (is= "cffi" (app::dependency-name :cffi))
  (is= "cffi" (app::dependency-name '(:version "cffi" "0.24")))
  (is= "cffi" (app::dependency-name '(:feature :darwin "cffi")))
  (is (null (app::dependency-name '(:require :sb-posix)))))

(deftest sibling-directory-naming
  (let ((sib (app::sibling-directory #p"/tmp/build/Editor.app/" ".staging-x")))
    (is= '("build" ".Editor.app.staging-x")
         (last (pathname-directory sib) 2))
    (is= '("tmp" "build") (last (butlast (pathname-directory sib)) 2))))

(deftest info-plist-requires-an-identifier
  (signals app:app-build-error
    (app::info-plist-form (app::make-app-spec :root #p"/tmp/X.app/" :name "X"))))

(deftest info-plist-carries-the-expected-keys
  (let* ((spec (app::make-app-spec :root #p"/tmp/X.app/" :name "X"
                                   :identifier "com.example.x"
                                   :executable-name "x" :version "2.0.1"
                                   :agent-p t :url-schemes '("xproto")
                                   :extra-plist '(("NSFoo" . "bar"))))
         (form (app::info-plist-form spec))
         (entries (cdr form)))
    (flet ((k (name) (cdr (assoc name entries :test #'string=))))
      (is= "com.example.x" (k "CFBundleIdentifier"))
      (is= "x" (k "CFBundleExecutable"))
      (is= "2.0.1" (k "CFBundleVersion"))
      (is= "APPL" (k "CFBundlePackageType"))
      (is= :true (k "LSUIElement"))
      (is= "bar" (k "NSFoo"))
      (is (k "CFBundleURLTypes"))
      ;; no icon was given, so no icon key
      (is (null (k "CFBundleIconFile"))))))

;;; ------------------------------------------------------------------
;;; toolchain check

(deftest missing-build-tools-reports-absent-paths
  (is= '() (app::missing-build-tools '("/bin/sh")))
  (is= '("/nonexistent/tool") (app::missing-build-tools '("/nonexistent/tool")))
  (is= '("/nonexistent/tool")
       (app::missing-build-tools '("/bin/sh" "/nonexistent/tool"))))

(deftest required-tools-are-the-ones-we-actually-shell-out-to
  (dolist (tool app::+required-tools+)
    (is (uiop:string-prefix-p "/usr/bin/" tool))))

;;; ------------------------------------------------------------------
;;; nested code discovery for signing

(defmacro with-scratch-bundle ((spec &rest relative-paths) &body body)
  "Build a fake .app tree. A path ending in / becomes a directory."
  `(uiop:with-temporary-file (:pathname stamp :keep nil)
     (let* ((root (uiop:ensure-directory-pathname
                   (format nil "~a.d/Scratch.app" (uiop:native-namestring stamp))))
            (,spec (app::make-app-spec :root root :final-root root
                                       :name "Scratch" :identifier "com.example.s"
                                       :executable-name "scratch")))
       (unwind-protect
            (progn
              (app::make-skeleton ,spec)
              (dolist (r ',relative-paths)
                (let ((p (uiop:subpathname root r)))
                  (if (uiop:string-suffix-p r "/")
                      (ensure-directories-exist p)
                      (progn (ensure-directories-exist p)
                             (with-open-file (s p :direction :output
                                                  :if-exists :supersede)
                               (write-string "x" s))))))
              ,@body)
         (ignore-errors
          (uiop:delete-directory-tree
           (uiop:pathname-parent-directory-pathname root) :validate t))))))

(defun basenames (paths)
  (mapcar (lambda (p)
            (if (uiop:directory-pathname-p p)
                (car (last (pathname-directory p)))
                (file-namestring p)))
          paths))

(deftest nested-code-includes-more-than-top-level-dylibs
  (with-scratch-bundle (spec
                        "Contents/MacOS/scratch"
                        "Contents/MacOS/helper"
                        "Contents/Frameworks/libfoo.dylib"
                        "Contents/Frameworks/Sparkle.framework/Sparkle"
                        "Contents/Frameworks/nested/libbar.dylib"
                        "Contents/Library/LoginItems/Launcher.app/Contents/MacOS/l")
    (let ((names (basenames (app::nested-code-paths spec))))
      ;; the old implementation found only this one
      (is (member "libfoo.dylib" names :test #'equal))
      ;; a framework is signed as a unit, not as its inner binary
      (is (member "Sparkle.framework" names :test #'equal))
      (is (not (member "Sparkle" names :test #'equal)))
      ;; plain subdirectories are descended into
      (is (member "libbar.dylib" names :test #'equal))
      ;; helper executables beside the main one
      (is (member "helper" names :test #'equal))
      ;; login items
      (is (member "Launcher.app" names :test #'equal))
      ;; but never the main executable: the outer bundle signature covers it
      (is (not (member "scratch" names :test #'equal))))))

(deftest nested-code-is-ordered-innermost-first
  (with-scratch-bundle (spec
                        "Contents/MacOS/scratch"
                        "Contents/Frameworks/libfoo.dylib"
                        "Contents/Frameworks/deep/deeper/libbaz.dylib")
    (let ((depths (mapcar #'app::path-depth (app::nested-code-paths spec))))
      (is (equal depths (sort (copy-list depths) #'>))))))

(deftest code-bundle-directory-detection
  (is (app::code-bundle-directory-p #p"/x/Sparkle.framework/"))
  (is (app::code-bundle-directory-p #p"/x/Service.xpc/"))
  (is (app::code-bundle-directory-p #p"/x/Helper.app/"))
  (is (not (app::code-bundle-directory-p #p"/x/nested/")))
  (is (not (app::code-bundle-directory-p #p"/x/Resources/"))))

;;; ------------------------------------------------------------------
;;; resource destinations

(deftest resource-destinations-must-stay-inside-resources
  (with-scratch-bundle (spec)
    (let ((seen (make-hash-table :test #'equal)))
      (is (app::check-resource-destination spec "data/x.txt" seen))
      (signals app:app-build-error
        (app::check-resource-destination spec "../Info.plist" seen))
      (signals app:app-build-error
        (app::check-resource-destination spec "../MacOS/scratch" seen)))))

(deftest resource-destinations-may-not-take-a-generated-name
  (with-scratch-bundle (spec)
    (let ((seen (make-hash-table :test #'equal)))
      (signals app:app-build-error
        (app::check-resource-destination spec "scratch.icns" seen))
      (signals app:app-build-error
        (app::check-resource-destination spec "foreign-libraries.sexp" seen))
      (signals app:app-build-error
        (app::check-resource-destination spec "entitlements.plist" seen)))))

(deftest two-resources-may-not-collide
  (with-scratch-bundle (spec)
    (let ((seen (make-hash-table :test #'equal)))
      (is (app::check-resource-destination spec "data/x.txt" seen))
      (signals app:app-build-error
        (app::check-resource-destination spec "data/x.txt" seen)))))

;;; ------------------------------------------------------------------
;;; NSPrincipalClass

(deftest principal-class-appears-only-when-asked-for
  (let ((plain (app::make-app-spec :root #p"/tmp/X.app/" :name "X"
                                   :identifier "com.example.x"))
        (cocoa (app::make-app-spec :root #p"/tmp/X.app/" :name "X"
                                   :identifier "com.example.x"
                                   :principal-class "NSApplication")))
    (is (null (cdr (assoc "NSPrincipalClass" (cdr (app::info-plist-form plain))
                          :test #'string=))))
    (is= "NSApplication"
         (cdr (assoc "NSPrincipalClass" (cdr (app::info-plist-form cocoa))
                     :test #'string=)))))

;;; ------------------------------------------------------------------
;;; the stub predicate authorises a delete, so it must be strict

(deftest empty-stub-detection-demands-a-genuinely-empty-tree
  (with-scratch-bundle (spec)
    (is (app::empty-bundle-stub-p (app::spec-root spec))))
  (with-scratch-bundle (spec "Contents/Resources/something.txt")
    (is (not (app::empty-bundle-stub-p (app::spec-root spec))))))

;;; ------------------------------------------------------------------
;;; symlinked resources are refused, not followed

(deftest symlinked-resource-is-refused
  (with-scratch-bundle (spec "outside/secret.txt" "payload/ok.txt")
    (let* ((root (uiop::pathname-parent-directory-pathname (app::spec-root spec)))
           (target (uiop:subpathname root "Scratch.app/outside/secret.txt"))
           (link (uiop:subpathname root "Scratch.app/payload/link.txt")))
      (app::run (list "/bin/ln" "-s" (uiop:native-namestring target)
                      (uiop:native-namestring link)))
      (is (app::symlink-p link))
      (is (not (app::symlink-p target)))
      ;; copying the directory must not silently pull in the link's target
      (signals app:app-build-error
        (app::copy-tree-into (uiop:subpathname root "Scratch.app/payload/")
                             (uiop:subpathname (app::resources-dir spec)
                                               "payload/"))))))

(deftest symlinked-resource-given-directly-is-refused
  (with-scratch-bundle (spec "outside/secret.txt")
    (let* ((root (uiop::pathname-parent-directory-pathname (app::spec-root spec)))
           (target (uiop:subpathname root "Scratch.app/outside/secret.txt"))
           (link (uiop:subpathname root "direct-link.txt")))
      (app::run (list "/bin/ln" "-s" (uiop:native-namestring target)
                      (uiop:native-namestring link)))
      (signals app:app-build-error
        (app::copy-tree-into link (uiop:subpathname (app::resources-dir spec)
                                                    "x.txt"))))))

(deftest existing-ancestor-resolves-the-deepest-real-directory
  (with-scratch-bundle (spec)
    (let ((res (app::resources-dir spec)))
      ;; nothing of "a/b/c" exists, so it resolves back to Resources itself
      (is= (uiop:native-namestring (uiop:truename* res))
           (uiop:native-namestring
            (app::existing-ancestor (uiop:subpathname res "a/b/c.txt")))))))

;;; ------------------------------------------------------------------
;;; the tool list must not drift from the call sites

(deftest every-tool-we-shell-out-to-is-declared
  ;; +REQUIRED-TOOLS+ is what REQUIRE-MACOS checks for. If a new /usr/bin call
  ;; appears in the sources without being added there, a machine missing that
  ;; tool fails deep inside RUN instead of up front.
  (let ((declared app::+required-tools+)
        (found '()))
    (dolist (file (uiop:directory-files
                   (asdf:system-relative-pathname "asdf-macos-app" "src/")))
      (when (equal "lisp" (pathname-type file))
        (let ((text (uiop:read-file-string file)))
        (loop with start = 0
              for at = (search "\"/usr/bin/" text :start2 start)
              while at
              do (let ((end (position #\" text :start (1+ at))))
                   (pushnew (subseq text (1+ at) end) found :test #'string=)
                   (setf start (or end (length text))))))))
    (is found)
    (dolist (tool found)
      ;; xcrun is invoked only by NOTARIZE, which is not part of a build
      (unless (string= tool "/usr/bin/xcrun")
        (is (member tool declared :test #'string=))))))
