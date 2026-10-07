;;;; asdf-macos-app.asd

(defsystem "asdf-macos-app"
  :description "ASDF extension that builds macOS .app bundles from SBCL images."
  :author "Matthew Kennedy <burnsidemk@gmail.com>"
  :license "MIT"
  :version "0.2.0"
  :depends-on (#+sbcl (:require "sb-posix"))
  ;; On the module, not here: :SERIAL T on the system orders only its direct
  ;; components -- the one module -- and left the files inside unordered, so a
  ;; change to a structure in bundle.lisp did not recompile sign.lisp.
  :components ((:module "src"
                :serial t
                :components ((:file "package")
                             (:file "plist")
                             (:file "runtime")
                             (:file "bundle")
                             (:file "foreign")
                             (:file "sign")
                             (:file "op"))))
  :in-order-to ((test-op (test-op "asdf-macos-app/tests"))))

(defsystem "asdf-macos-app/tests"
  :description "Test suite for asdf-macos-app."
  :depends-on ("asdf-macos-app")
  :components ((:module "tests"
                :serial t
                :components ((:file "framework")
                             (:file "unit")
                             (:file "build")
                             (:module "fixture"
                              :components ((:static-file "macos-app-test-fixture.asd")
                                           (:static-file "main.lisp"))))))
  :perform (test-op (o c)
             (let ((failures (uiop:symbol-call :asdf-macos-app-tests '#:run-all)))
               (unless (zerop failures)
                 (error "~d test failure~:p." failures)))))
