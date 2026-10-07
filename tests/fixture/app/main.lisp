(defpackage #:macos-app-test-fixture
  (:use #:cl)
  (:export #:main))
(in-package #:macos-app-test-fixture)

(defun main ()
  (format t "FIXTURE-OK ~a ~a~%"
          (macos-app-test-lib:token)
          (or (macos-app:bundle-root) "no-bundle"))
  ;; A contrib nothing in the image needs, so REQUIRE has to find its fasl.
  (format t "~a~%"
          (cond ((member "SB-ROTATE-BYTE" *modules* :test #'string-equal)
                 "CONTRIB-PRELOADED")
                ((ignore-errors (require :sb-rotate-byte) t) "CONTRIB-OK")
                (t "CONTRIB-MISSING")))
  (finish-output))
