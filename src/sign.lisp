;;;; sign.lisp -- codesign, entitlements, notarization.

(in-package #:asdf-macos-app)

(defparameter +sbcl-entitlements+
  '(:dict
    ;; SBCL allocates writable-executable memory for compiled code.
    ("com.apple.security.cs.allow-unsigned-executable-memory" . :true)
    ("com.apple.security.cs.allow-jit"                        . :true)
    ;; Needed to dlopen dylibs we bundled ourselves.
    ("com.apple.security.cs.disable-library-validation"       . :true))
  "The minimum a hardened-runtime SBCL image needs in order to start.")

(defun entitlements-file (spec)
  (let ((e (spec-entitlements spec)))
    (etypecase e
      (null nil)
      (pathname e)
      (string (pathname e))
      (symbol
       (assert (eq e :sbcl-default))
       (let ((p (uiop:subpathname (resources-dir spec) "entitlements.plist")))
         (lint-plist (write-plist +sbcl-entitlements+ p))
         p)))))

(defun codesign (path identity &key entitlements hardened (timestamp t))
  (run (append (list "/usr/bin/codesign" "--force" "--sign" identity)
               (when hardened '("--options" "runtime"))
               ;; ad-hoc signatures cannot be timestamped
               (when (and timestamp (not (string= identity "-"))) '("--timestamp"))
               (when entitlements
                 (list "--entitlements" (uiop:native-namestring entitlements)))
               (list (string-right-trim "/" (uiop:native-namestring path))))))

(defparameter +code-bundle-types+ '("framework" "xpc" "app" "appex" "bundle")
  "Directory extensions that codesign treats as a unit rather than walking.")

(defun code-bundle-directory-p (directory)
  (let ((name (car (last (pathname-directory
                          (uiop:ensure-directory-pathname directory))))))
    (and (stringp name)
         (member (pathname-type (pathname name)) +code-bundle-types+
                 :test #'equal))))

(defun path-depth (path)
  (length (pathname-directory (uiop:ensure-directory-pathname path))))

(defun collect-nested-code (directory)
  "Signable items under DIRECTORY. A .framework or .xpc is one item; anything
else is descended into."
  (let ((directory (uiop:ensure-directory-pathname directory)))
    (when (uiop:directory-exists-p directory)
      (append (uiop:directory-files directory)
              (loop for d in (uiop:subdirectories directory)
                    append (if (code-bundle-directory-p d)
                               (list d)
                               (collect-nested-code d)))))))

(defun nested-code-paths (spec)
  "Everything inside the bundle that must be signed before the bundle itself.
Globbing Frameworks/*.dylib is not enough: .framework and .xpc bundles, helper
executables beside the main one, and login items all count as nested code."
  (let* ((main (executable-path spec))
         (main-name (file-namestring main))
         (paths (append (collect-nested-code (frameworks-dir spec))
                        (remove main-name (uiop:directory-files (macos-dir spec))
                                :key #'file-namestring :test #'equal)
                        (collect-nested-code
                         (uiop:subpathname (contents-dir spec) "Library/")))))
    ;; deepest first, so an enclosing bundle is signed after its contents
    (sort (remove-duplicates paths :test #'equal) #'> :key #'path-depth)))

(defun sign-bundle (spec)
  "Sign nested code first, then the bundle. Apple deprecated --deep; do it by hand."
  (let ((identity (spec-signing-identity spec)))
    (when (and identity (not (macos-p)))
      (note "not on macOS: bundle left unsigned")
      (return-from sign-bundle nil))
    (when identity
      (let* ((adhoc (string= identity "-"))
             (hardened (and (spec-hardened-runtime-p spec) (not adhoc)))
             (ent (entitlements-file spec)))
        ;; nested code: no entitlements, signed innermost first
        (dolist (path (nested-code-paths spec))
          (codesign path identity :hardened hardened))
        ;; the bundle itself signs Contents/MacOS/<exe>
        (codesign (spec-root spec) identity
                  :entitlements ent
                  :hardened (or hardened (spec-hardened-runtime-p spec)))
        (verify-signature spec)))))

(defun verify-signature (spec)
  (multiple-value-bind (out err code)
      (run (list "/usr/bin/codesign" "--verify" "--deep" "--strict" "--verbose=2"
                 (string-right-trim "/" (uiop:native-namestring (spec-root spec))))
           :ignore-error-status t)
    (declare (ignore out))
    (unless (zerop code)
      (barf "codesign --verify failed:~%~a~%~
             Signature details:~%~a~%~
             If the failure mentions the main executable, the appended SBCL ~
             core may have been disturbed."
            err (signature-details spec)))
    t))

(defun signature-details (spec)
  "codesign -dvvv output, for the error message. Writes to stderr."
  (multiple-value-bind (out err)
      (run (list "/usr/bin/codesign" "-dvvv" "--entitlements" ":-"
                 (string-right-trim "/" (uiop:native-namestring (spec-root spec))))
           :ignore-error-status t)
    (if (plusp (length err)) err out)))

(defun notarize (app &key keychain-profile (staple t))
  "Submit APP to Apple's notary service and staple the ticket.
KEYCHAIN-PROFILE is a profile previously stored with
  xcrun notarytool store-credentials"
  (let ((app (uiop:ensure-directory-pathname app)))
    (when (incomplete-bundle-p app)
      (barf "~a was assembled without the macOS toolchain (Contents/~a is ~
             present). There is nothing here worth notarising."
            (uiop:native-namestring app) *incomplete-build-marker*))
    (let ((zip (make-pathname :type "zip"
                              :name (car (last (pathname-directory app)))
                              :directory (butlast (pathname-directory app)))))
      (run (list "/usr/bin/ditto" "-c" "-k" "--keepParent"
                 (string-right-trim "/" (uiop:native-namestring app))
                 (uiop:native-namestring zip)))
      (run (list "/usr/bin/xcrun" "notarytool" "submit"
                 (uiop:native-namestring zip)
                 "--keychain-profile" keychain-profile
                 "--wait"))
      (when staple
        (run (list "/usr/bin/xcrun" "stapler" "staple"
                   (string-right-trim "/" (uiop:native-namestring app)))))
      app)))
