;;;; package.lisp

(defpackage #:asdf-macos-app
  (:use #:cl)
  (:nicknames #:macos-app)
  (:export
   ;; runtime API, available inside the built app
   #:*bundle-root*
   #:bundle-root
   #:bundle-resource
   #:bundle-frameworks
   #:running-in-bundle-p
   ;; build driver
   #:make-app
   #:notarize
   ;; conditions
   #:app-build-error
   ;; knobs
   #:*child-lisp*
   #:*child-lisp-options*
   #:*allow-non-macos-build*
   #:*simulate-non-macos*
   #:*incomplete-build-marker*
   #:incomplete-bundle-p
   #:complete-bundle-p
   #:*replace-complete-bundle*))

(in-package #:asdf-macos-app)

(define-condition app-build-error (simple-error) ())

(defun barf (fmt &rest args)
  (error 'app-build-error :format-control fmt :format-arguments args))

(defun run (argv &key (ignore-error-status nil) input)
  "Run ARGV, returning its stdout as a string. Errors are fatal by default."
  (multiple-value-bind (out err code)
      (uiop:run-program argv
                        :output '(:string :stripped t)
                        :error-output '(:string :stripped t)
                        :input input
                        :ignore-error-status t)
    (when (and (not ignore-error-status) (/= code 0))
      (barf "~a exited ~d:~%~a" (first argv) code err))
    (values out err code)))

(defvar *allow-non-macos-build* nil
  "Bind to T to assemble a bundle on a non-Darwin host. The layout and
Info.plist will be correct, but nothing that needs otool, install_name_tool,
codesign, sips or plutil will run. Useful for CI smoke tests; never for a
shippable artifact.")

(defvar *simulate-non-macos* nil
  "Bind to T to make MACOS-P answer NIL on a Mac.

For the suite, and only for it.  The incomplete-build behaviour -- the marker,
the refusal to replace a complete bundle, the refusal to notarise -- exists for
builds made off macOS, and could previously only be exercised BY building off
macOS.  So those tests passed on Linux and failed on a Mac, which is the worst
of both: the developer sees red on the machine the library is for, and the
behaviour goes untested on the machine most people run it from.")

(defun macos-p ()
  (and (not *simulate-non-macos*) (uiop:os-macosx-p)))

(defun note (format-control &rest args)
  "Say something on the build log. Deliberately not WARN: a build driver may
muffle warnings, and these are things the person running the build must see."
  (format *standard-output* "~&; ~?~%" format-control args)
  (finish-output *standard-output*))

(defparameter +required-tools+
  '("/usr/bin/otool" "/usr/bin/install_name_tool"   ; Xcode command line tools
    "/usr/bin/codesign" "/usr/bin/plutil"           ; base system
    "/usr/bin/sips" "/usr/bin/iconutil"             ; icon conversion
    "/usr/bin/ditto")                               ; notarisation
  "Every command line tool the build shells out to, checked up front by
REQUIRE-MACOS so a missing one is reported before any work happens rather than
from somewhere deep inside RUN. A test asserts this list covers every
/usr/bin/ literal in the sources, because the two drift apart otherwise.")

(defun missing-build-tools (&optional (tools +required-tools+))
  (remove-if #'probe-file tools))

(defun require-macos (what)
  (unless (or (macos-p) *allow-non-macos-build*)
    (barf "~a requires macOS. Bind MACOS-APP:*ALLOW-NON-MACOS-BUILD* to T to ~
           assemble an unsigned, unrelocated bundle anyway." what))
  ;; Being on macOS is not the same as having the tools: a clean install has
  ;; none of these until the Xcode command line tools are present.
  (when (macos-p)
    (let ((missing (missing-build-tools)))
      (when missing
        (barf "~a needs ~{~a~^, ~}, which ~:[is~;are~] not installed. ~
               Run: xcode-select --install"
              what missing (rest missing))))))
