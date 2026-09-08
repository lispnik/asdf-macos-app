;;;; tests/build.lisp -- end to end, against a real fixture system.
;;;;
;;;; These actually dump images, so they are slow (a couple of seconds each).
;;;; Off macOS they run with APP:*ALLOW-NON-MACOS-BUILD* bound, which exercises
;;;; the layout, plist, staging, freshness and entry-point paths but skips
;;;; signing and dylib relocation.

(in-package #:asdf-macos-app-tests)

(defparameter +fixture-files+
  ;; The .asd files are checked in as .asd.in and renamed on copy. Otherwise a
  ;; recursive source registry over this repository -- CI's, or a developer's
  ;; own -- would register the fixture systems globally, and the suite would be
  ;; quietly relying on asdf:*central-registry* being searched first.
  '(("app/macos-app-test-fixture.asd.in" . "app/macos-app-test-fixture.asd")
    ("app/main.lisp" . "app/main.lisp")
    ("app/extra.txt" . "app/extra.txt")
    ("app/res/note.txt" . "app/res/note.txt")
    ("app/res/sub/nested.txt" . "app/res/sub/nested.txt")
    ("lib/macos-app-test-lib.asd.in" . "lib/macos-app-test-lib.asd")
    ("lib/lib.lisp" . "lib/lib.lisp")))

(defun fixture-source-directory ()
  (asdf:system-relative-pathname "asdf-macos-app/tests" "tests/fixture/"))

(defun app-dir (dir) (uiop:subpathname dir "app/"))
(defun lib-dir (dir) (uiop:subpathname dir "lib/"))
(defun fixture-asd (dir) (uiop:subpathname dir "app/macos-app-test-fixture.asd"))
(defun fixture-main (dir) (uiop:subpathname dir "app/main.lisp"))

(defmacro with-fixture ((dir) &body body)
  "Copy the fixture into a scratch directory and register it, so that tests may
edit its sources without touching the repository."
  `(let ((,dir (uiop:ensure-directory-pathname
                (format nil "~afixture-~36r"
                        (uiop:native-namestring (uiop:temporary-directory))
                        (random (expt 36 8) (make-random-state t))))))
     (unwind-protect
          (progn
            (ensure-directories-exist ,dir)
            (loop for (from . to) in +fixture-files+
                  for target = (uiop:subpathname ,dir to)
                  do (ensure-directories-exist target)
                     (uiop:copy-file (uiop:subpathname (fixture-source-directory)
                                                       from)
                                     target))
            ;; Registered here and nowhere else: no config file, no environment
            ;; variable. If the child cannot see these, item 8 has regressed.
            (let ((asdf:*central-registry*
                    (list* (app-dir ,dir) (lib-dir ,dir) asdf:*central-registry*)))
              (clear-fixture-systems)
              ,@body))
       (ignore-errors (uiop:delete-directory-tree ,dir :validate t))
       (clear-fixture-systems))))

(defun clear-fixture-systems ()
  (asdf:clear-system "macos-app-test-fixture")
  (asdf:clear-system "macos-app-test-lib"))

(defun build-fixture (&rest keys)
  "Build and return (values bundle-pathname build-output-string)."
  (let* ((app::*allow-non-macos-build* t)
         (out (make-string-output-stream))
         (bundle (let ((*standard-output* (make-broadcast-stream
                                           out *standard-output*)))
                   (apply #'app:make-app "macos-app-test-fixture" keys))))
    (values bundle (get-output-stream-string out))))

(defun replace-in-file (path from to)
  "Substitute FROM with TO in PATH, erroring if FROM is not present -- a test
that silently edits nothing is worse than no test."
  (let* ((text (uiop:read-file-string path))
         (at (search from text)))
    (unless at (error "~s not found in ~a" from path))
    (with-open-file (s path :direction :output :if-exists :supersede)
      (write-string (concatenate 'string (subseq text 0 at) to
                                 (subseq text (+ at (length from))))
                    s))
    path))

(defun staging-leftovers (dir)
  (remove-if-not (lambda (p)
                   (search ".staging-" (uiop:native-namestring p)))
                 (append (uiop:subdirectories dir) (uiop:directory-files dir))))

(defun run-bundle (bundle dir &key (fresh t))
  "Run the app's executable and return whatever it printed. Inside a bundle the
generated toplevel redirects to a log file; MACOS_APP_LOG points that at the
scratch directory so the suite never touches the real ~/Library/Logs.

SBCL_HOME IS STRIPPED, and that is not tidiness. The bundled executable is the
SBCL runtime, which finds its core beside itself -- unless SBCL_HOME is set, in
which case that wins and the runtime loads whatever core lives there instead.
Homebrew's `sbcl' is a shell wrapper that exports SBCL_HOME, so a suite run from
one hands the child a variable that makes the application load a DIFFERENT core
and drop into a plain REPL. The tests then see no output and fail on macOS while
passing on Linux, which is exactly what happened.

Stripping it is also the honest test: LaunchServices sets no SBCL_HOME, so a
double-clicked application never has one. See the note in the README about
launching from a shell that does."
  (let* ((exe (uiop:subpathname bundle "Contents/MacOS/fixture"))
         (log (uiop:subpathname dir "fixture.log"))
         (var (concatenate 'string app::+log-override-variable+ "=")))
    (when fresh (ignore-errors (delete-file log)))
    (uiop:run-program (list (uiop:native-namestring exe))
                      :environment
                      (cons (concatenate 'string var (uiop:native-namestring log))
                            (remove-if (lambda (e)
                                         (or (uiop:string-prefix-p var e)
                                             (uiop:string-prefix-p "SBCL_HOME=" e)))
                                       #+sbcl (sb-ext:posix-environ) #-sbcl nil))
                      :output :interactive :error-output :interactive)
    (if (probe-file log) (uiop:read-file-string log) "")))

;;; ------------------------------------------------------------------

(deftest build-produces-the-expected-layout
  (with-fixture (dir)
    (let ((bundle (build-fixture)))
      (is (probe-file bundle))
      (dolist (f '("Contents/Info.plist" "Contents/PkgInfo"
                   "Contents/MacOS/fixture"
                   "Contents/Resources/foreign-libraries.sexp"))
        (is (probe-file (uiop:subpathname bundle f))))
      (is (probe-file (uiop:subpathname bundle "Contents/Frameworks/")))
      (is (null (staging-leftovers dir))))))

(deftest the-core-is-a-resource-and-the-executable-is-the-runtime
  "The layout that makes a bundle signable.

An executable image cannot be codesigned: SAVE-LISP-AND-DIE :EXECUTABLE T
appends the core past the end of the Mach-O and past the code signature, and
codesign refuses the file with `main executable failed strict validation'.  So
the core is a sealed resource, the executable is a copy of the SBCL runtime --
an ordinary signable binary -- and a symlink in MacOS/ is what lets the runtime
find its core with no arguments.

All three are asserted, because each is load-bearing and any one alone looks
arbitrary."
  (with-fixture (dir)
    (let* ((bundle (build-fixture))
           (core (uiop:subpathname bundle "Contents/Resources/sbcl.core"))
           (link (uiop:subpathname bundle "Contents/MacOS/sbcl.core"))
           (exe (uiop:subpathname bundle "Contents/MacOS/fixture")))
      (is (probe-file core))
      (is (asdf-macos-app::symlink-p link))
      ;; RELATIVE.  An absolute link points into the staging directory, which is
      ;; deleted the moment the bundle is committed.
      (is (string= "../Resources/sbcl.core"
                   (sb-posix:readlink (uiop:native-namestring link))))
      (is (probe-file exe))
      ;; The executable is the runtime, not an image: a fraction of the core's
      ;; size rather than a shade larger than it.
      (let ((exe-size (with-open-file (in exe :element-type '(unsigned-byte 8))
                        (file-length in)))
            (core-size (with-open-file (in core :element-type '(unsigned-byte 8))
                         (file-length in))))
        (is (< exe-size (floor core-size 10)))))))

(deftest built-plist-is-well-formed
  (with-fixture (dir)
    (let* ((bundle (build-fixture))
           (text (uiop:read-file-string
                  (uiop:subpathname bundle "Contents/Info.plist"))))
      (is (search "<string>com.example.fixture</string>" text))
      (is (search "<string>fixture</string>" text))
      (is (search "<string>3.1.4</string>" text))
      ;; :bundle-short-version was "3.1.4-rc2" and must have been sanitised
      (is (not (search "rc2" text))))))

(deftest built-app-runs-and-finds-its-bundle
  (with-fixture (dir)
    (let* ((bundle (build-fixture))
           (output (run-bundle bundle dir)))
      (is (search "FIXTURE-OK" output))
      ;; the runtime located the .app by walking up from argv0
      (is (not (search "no-bundle" output)))
      (is (search ".app" output))
      ;; and the child found a dependency the parent knew only via
      ;; asdf:*central-registry*
      (is (search "LIB-LINKED" output)))))

(deftest second-build-reuses-the-image
  (with-fixture (dir)
    (build-fixture)
    (multiple-value-bind (bundle output) (build-fixture)
      (declare (ignore bundle))
      (is (search "reusing" output))
      (is (not (search "dumping image" output))))))

(deftest touching-a-source-forces-a-new-image
  (with-fixture (dir)
    (build-fixture)
    (sleep 1.1)                         ; file-write-date is second-granular
    (let ((main (fixture-main dir)))
      (with-open-file (s main :direction :output :if-exists :append)
        (format s "~&;; touched~%")))
    (clear-fixture-systems)
    (multiple-value-bind (bundle output) (build-fixture)
      (declare (ignore bundle))
      (is (search "dumping image" output))
      (is (not (search "reusing" output))))))

(deftest force-image-overrides-freshness
  (with-fixture (dir)
    (build-fixture)
    (multiple-value-bind (bundle output) (build-fixture :force-image t)
      (declare (ignore bundle))
      (is (search "dumping image" output)))))

(deftest bad-entry-point-fails-the-build
  (with-fixture (dir)
    (let ((bundle (build-fixture)))
      (is (probe-file bundle))
      ;; break the entry point and force a re-dump
      (sleep 1.1)
      (replace-in-file (fixture-asd dir)
                       "macos-app-test-fixture:main"
                       "macos-app-test-fixture:absent")
      (clear-fixture-systems)
      (signals app:app-build-error (build-fixture))
      ;; the previous bundle survived and nothing was left half-written
      (is (probe-file (uiop:subpathname bundle "Contents/MacOS/fixture")))
      (is (search "FIXTURE-OK" (run-bundle bundle dir)))
      (is (null (staging-leftovers dir))))))

(deftest failed-build-leaves-nothing-at-the-destination
  ;; ASDF creates Foo.app/Contents from OUTPUT-FILES before PERFORM runs, so a
  ;; failed first build would otherwise leave a stray bundle directory.
  (with-fixture (dir)
    (replace-in-file (fixture-asd dir)
                     "macos-app-test-fixture:main" "macos-app-test-fixture:absent")
    (clear-fixture-systems)
    (is (failed-build-message dir))
    (is (null (probe-file (uiop:subpathname (app-dir dir) "Fixture.app/"))))
    (is (null (staging-leftovers (app-dir dir))))))

(deftest complete-bundle-p-ignores-an-empty-stub
  (with-fixture (dir)
    (let ((stub (uiop:subpathname (app-dir dir) "Stub.app/")))
      (ensure-directories-exist (uiop:subpathname stub "Contents/MacOS/"))
      (is (app::empty-bundle-stub-p stub))
      (is (not (app:complete-bundle-p stub)))
      (let ((bundle (build-fixture)))
        (is (not (app::empty-bundle-stub-p bundle)))
        ;; built off macOS, so present but not complete
        (is (app:incomplete-bundle-p bundle))
        (is (not (app:complete-bundle-p bundle)))))))

(deftest missing-identifier-fails-before-anything-is-written
  (with-fixture (dir)
    (replace-in-file (fixture-asd dir)
                     ":bundle-identifier \"com.example.fixture\"" "")
    (clear-fixture-systems)
    (signals app:app-build-error (build-fixture))
    (is (null (staging-leftovers dir)))))

;;; ------------------------------------------------------------------
;;; child registry propagation

(defun registry-directories (form)
  (loop for e in (rest form) when (consp e) collect (second e)))

(deftest child-registry-lists-the-whole-closure
  (with-fixture (dir)
    (let* ((system (asdf:find-system "macos-app-test-fixture"))
           (form (app::child-source-registry-form system))
           (dirs (registry-directories form)))
      (is (eq :source-registry (first form)))
      (is (member (uiop:native-namestring (app-dir dir)) dirs :test #'equal))
      ;; the dependency, reachable only through *central-registry*
      (is (member (uiop:native-namestring (lib-dir dir)) dirs :test #'equal))
      ;; the extension itself, so the child can read :defsystem-depends-on
      (is (member (uiop:native-namestring
                   (asdf:system-source-directory
                    (asdf:find-system "asdf-macos-app")))
                  dirs :test #'equal))
      (is (eq :inherit-configuration (car (last form)))))))

(deftest child-registry-is-well-formed
  (with-fixture (dir)
    (is (probe-file (lib-dir dir)))
    (let ((form (app::child-source-registry-form
                 (asdf:find-system "macos-app-test-fixture"))))
      (is (every (lambda (e) (or (keywordp e)
                                 (and (consp e) (eq :directory (first e))
                                      (stringp (second e)))))
                 (rest form))))))

(deftest central-registry-entries-are-not-evaluated
  (let* ((canary nil)
         (asdf:*central-registry*
           (list #p"/tmp/plain/"
                 '*default-pathname-defaults*
                 ;; ASDF would evaluate this; we must not
                 '(progn (setf canary t) #p"/tmp/evaluated/"))))
    (declare (ignorable canary))
    (let ((dirs (mapcar #'uiop:native-namestring
                        (app::central-registry-directories))))
      (is (member "/tmp/plain/" dirs :test #'equal))
      ;; a bound special is read for its value, which is the common idiom
      (is (member (uiop:native-namestring
                   (uiop:ensure-directory-pathname *default-pathname-defaults*))
                  dirs :test #'equal))
      (is (not (member "/tmp/evaluated/" dirs :test #'equal))))))

(deftest bootstrap-mentions-no-package-of-ours
  ;; The child reads the bootstrap before this extension exists there, so a
  ;; symbol interned in our package is a read error rather than a warning.
  (with-fixture (dir)
    (is (probe-file (app-dir dir)))
    (let* ((system (asdf:find-system "macos-app-test-fixture"))
           (text (with-output-to-string (s)
                   (app::write-child-bootstrap
                    s (app::child-bootstrap-forms
                       (asdf:system-source-file system) "x" #p"/tmp/s.sexp"
                       (app::child-source-registry-form system))))))
      (is (not (search "ASDF-MACOS-APP::" text)))
      (is (not (search "ASDF-MACOS-APP-TESTS::" text)))
      (is (search "(REQUIRE :ASDF)" text)))))

;;; ------------------------------------------------------------------
;;; child failure diagnosis

(defun failed-build-message (dir)
  "Build, expecting failure, and return the error text."
  (declare (ignorable dir))
  (handler-case (progn (build-fixture) nil)
    (app:app-build-error (e) (princ-to-string e))))

(deftest failure-while-loading-names-that-phase
  (with-fixture (dir)
    ;; a form that reads fine but will not compile
    (with-open-file (s (fixture-main dir) :direction :output :if-exists :append)
      (format s "~&(defun broken () (this-function-does-not-exist 1 2 3) (car))~%"))
    (clear-fixture-systems)
    (let ((msg (failed-build-message dir)))
      (is msg)
      (is (search "compiling and loading the system" msg))
      (is (not (search "dumping the executable" msg))))))

(deftest failure-while-dumping-names-that-phase
  (with-fixture (dir)
    (replace-in-file (fixture-asd dir)
                     "macos-app-test-fixture:main" "macos-app-test-fixture:absent")
    (clear-fixture-systems)
    (let ((msg (failed-build-message dir)))
      (is msg)
      (is (search "dumping the executable" msg))
      ;; the child's own condition is quoted verbatim, not just an exit code
      (is (search "ABSENT" (string-upcase msg))))))

(deftest failure-while-reading-the-asd-names-that-phase
  (with-fixture (dir)
    (replace-in-file (fixture-asd dir)
                     ":depends-on (\"macos-app-test-lib\")"
                     ":depends-on (\"no-such-system-anywhere\")")
    (clear-fixture-systems)
    (let ((msg (failed-build-message dir)))
      (is msg)
      (is (or (search "reading the .asd" msg)
              (search "compiling and loading the system" msg)))
      (is (search "NO-SUCH-SYSTEM-ANYWHERE" (string-upcase msg))))))

(deftest failure-message-carries-a-backtrace
  (with-fixture (dir)
    (replace-in-file (fixture-asd dir)
                     "macos-app-test-fixture:main" "macos-app-test-fixture:absent")
    (clear-fixture-systems)
    (let ((msg (failed-build-message dir)))
      (is msg)
      (is (search "ASDF" (string-upcase msg))))))

;;; ------------------------------------------------------------------
;;; off-macOS builds are marked as such

(deftest incomplete-build-is-labelled
  (with-fixture (dir)
    (multiple-value-bind (bundle output) (build-fixture)
      (let ((marker (uiop:subpathname
                     bundle (format nil "Contents/~a" app:*incomplete-build-marker*))))
        (if (app::macos-p)
            (is (null (probe-file marker)))
            (progn
              (is (probe-file marker))
              (is (search "Do not ship" (uiop:read-file-string marker)))
              (is (search app:*incomplete-build-marker* output))
              (is (probe-file (app-dir dir)))))))))

(deftest log-override-keeps-the-suite-out-of-the-home-directory
  (with-fixture (dir)
    (let ((bundle (build-fixture))
          (real-log (merge-pathnames "Library/Logs/Fixture.log"
                                     (user-homedir-pathname))))
      (ignore-errors (delete-file real-log))
      (is (search "FIXTURE-OK" (run-bundle bundle dir)))
      (is (probe-file (uiop:subpathname dir "fixture.log")))
      (is (null (probe-file real-log))))))

;;; ------------------------------------------------------------------
;;; :bundle-resources

(deftest resources-are-copied-into-the-bundle
  (with-fixture (dir)
    (let ((bundle (build-fixture)))
      ;; a directory entry keeps its own name and its nesting
      (is (search "RESOURCE-FILE"
                  (uiop:read-file-string
                   (uiop:subpathname bundle "Contents/Resources/res/note.txt"))))
      (is (search "NESTED-RESOURCE"
                  (uiop:read-file-string
                   (uiop:subpathname bundle
                                     "Contents/Resources/res/sub/nested.txt"))))
      ;; a (source . destination) entry is renamed and may create directories
      (is (search "RENAMED-RESOURCE"
                  (uiop:read-file-string
                   (uiop:subpathname bundle
                                     "Contents/Resources/data/renamed.txt"))))
      (is (probe-file (app-dir dir))))))

(deftest missing-resource-fails-the-build
  (with-fixture (dir)
    (replace-in-file (fixture-asd dir) ":bundle-resources (\"res/\""
                     ":bundle-resources (\"no-such-directory/\"")
    (clear-fixture-systems)
    (let ((msg (failed-build-message dir)))
      (is msg)
      (is (search "does not exist" msg)))))

;;; ------------------------------------------------------------------
;;; logging options

(deftest log-rotates-past-the-configured-size
  (with-fixture (dir)
    (let* ((bundle (build-fixture))
           (log (uiop:subpathname dir "fixture.log"))
           (rotated (make-pathname :type "log.1" :defaults log)))
      ;; the fixture sets :bundle-log-max-bytes to 512
      (with-open-file (s log :direction :output :if-exists :supersede
                             :if-does-not-exist :create)
        (dotimes (i 200) (format s "padding padding padding~%")))
      (is (> (with-open-file (s log) (file-length s)) 512))
      (run-bundle bundle dir :fresh nil)
      (is (probe-file rotated))
      (is (search "FIXTURE-OK" (uiop:read-file-string log)))
      (is (< (with-open-file (s log) (file-length s)) 512)))))

(deftest log-can-be-turned-off
  (with-fixture (dir)
    (replace-in-file (fixture-asd dir) ":bundle-log t" ":bundle-log nil")
    (clear-fixture-systems)
    (let ((bundle (build-fixture)))
      ;; nothing is written to the log file; output goes to stdout instead
      (run-bundle bundle dir)
      (is (null (probe-file (uiop:subpathname dir "fixture.log")))))))

;;; ------------------------------------------------------------------
;;; the marker is load-bearing

(deftest incomplete-build-will-not-replace-a-complete-one
  (with-fixture (dir)
    (let ((bundle (build-fixture)))
      ;; pretend the committed bundle was built properly on a Mac
      (delete-file (uiop:subpathname
                    bundle (format nil "Contents/~a"
                                   app:*incomplete-build-marker*)))
      (is (app:complete-bundle-p bundle))
      (sleep 1.1)
      (clear-fixture-systems)
      (let ((msg (failed-build-message dir)))
        (is msg)
        (is (search "Refusing to replace" msg)))
      ;; and the good bundle is still there
      (is (not (app:incomplete-bundle-p bundle)))
      (is (probe-file (uiop:subpathname bundle "Contents/MacOS/fixture")))
      (is (null (staging-leftovers dir))))))

(deftest incomplete-build-may-replace-another-incomplete-one
  (with-fixture (dir)
    (let ((bundle (build-fixture)))
      (is (app:incomplete-bundle-p bundle))
      (sleep 1.1)
      (clear-fixture-systems)
      (is (build-fixture :force-image t)))))

(deftest override-allows-replacing-a-complete-bundle
  (with-fixture (dir)
    (let ((bundle (build-fixture)))
      (delete-file (uiop:subpathname
                    bundle (format nil "Contents/~a"
                                   app:*incomplete-build-marker*)))
      (sleep 1.1)
      (clear-fixture-systems)
      (let ((app::*replace-complete-bundle* t))
        (is (build-fixture :force-image t)))
      (is (app:incomplete-bundle-p bundle)))))

(deftest notarising-an-incomplete-bundle-is-refused
  (with-fixture (dir)
    (let ((bundle (build-fixture)))
      (is (probe-file (app-dir dir)))
      (is (app:incomplete-bundle-p bundle))
      ;; must refuse before shelling out to ditto, which is not present here
      (signals app:app-build-error
        (app:notarize bundle :keychain-profile "nonexistent")))))

(deftest unsigned-is-the-default
  (with-fixture (dir)
    (let ((bundle (build-fixture)))
      (is (probe-file (app-dir dir)))
      (is (null (probe-file
                 (uiop:subpathname bundle
                                   "Contents/Resources/entitlements.plist")))))))

(deftest ad-hoc-signing-round-trip
  ;; Deliberately the only test that signs. Ad-hoc signing needs no
  ;; certificate, so CI's macOS runner exercises sign-bundle and
  ;; verify-signature against a real SBCL image -- the riskiest thing in this
  ;; design, and the one an appended core could break. Isolating it here means
  ;; a signing failure reports as one failure rather than taking out every
  ;; build test and hiding whatever else went wrong.
  (with-fixture (dir)
    (replace-in-file (fixture-asd dir)
                     ":bundle-log-max-bytes 512"
                     ":bundle-log-max-bytes 512
  :code-signing-identity \"-\"")
    (clear-fixture-systems)
    (multiple-value-bind (bundle output) (build-fixture)
      (if (app::macos-p)
          ;; sign-bundle ran verify-signature itself; reaching here means it
          ;; passed. entitlements.plist is the observable side effect.
          (is (probe-file (uiop:subpathname
                           bundle "Contents/Resources/entitlements.plist")))
          (progn
            (is (search "left unsigned" output))
            (is (null (probe-file
                       (uiop:subpathname
                        bundle "Contents/Resources/entitlements.plist")))))))))
