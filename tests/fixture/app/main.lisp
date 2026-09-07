(defpackage #:macos-app-test-fixture
  (:use #:cl)
  (:export #:main))
(in-package #:macos-app-test-fixture)

(defun main ()
  (format t "FIXTURE-OK ~a ~a~%"
          (macos-app-test-lib:token)
          (or (macos-app:bundle-root) "no-bundle"))
  (finish-output))
