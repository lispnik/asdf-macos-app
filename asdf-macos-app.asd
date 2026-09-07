;;;; asdf-macos-app.asd

(defsystem "asdf-macos-app"
  :description "ASDF extension that builds macOS .app bundles from SBCL images."
  :author "Matthew Kennedy <burnsidemk@gmail.com>"
  :license "MIT"
  :version "0.1.0"
  :depends-on (#+sbcl (:require "sb-posix"))
  :serial t
  :components ((:module "src"
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
  :serial t
  :components ((:module "tests"
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
