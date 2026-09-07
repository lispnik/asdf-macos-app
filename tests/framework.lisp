;;;; tests/framework.lisp -- just enough to avoid a dependency.

(defpackage #:asdf-macos-app-tests
  (:use #:cl)
  (:local-nicknames (#:app #:asdf-macos-app))
  (:export #:run-all))

(in-package #:asdf-macos-app-tests)

(defvar *tests* '())
(defvar *failures* 0)
(defvar *checks* 0)
(defvar *current* nil)

(defmacro deftest (name &body body)
  `(progn
     (defun ,name () ,@body)
     (setf *tests* (append (remove ',name *tests*) (list ',name)))
     ',name))

(defun report-failure (form got)
  (incf *failures*)
  (format t "~&  FAIL ~a~%       ~s~%       => ~s~%" *current* form got))

(defun check (form value)
  (incf *checks*)
  (if value t (progn (report-failure form value) nil)))

(defmacro is (form)
  `(check ',form ,form))

(defmacro is= (expected form &key (test '#'equal))
  (let ((e (gensym)) (a (gensym)))
    `(let ((,e ,expected) (,a ,form))
       (incf *checks*)
       (or (funcall ,test ,e ,a)
           (progn (report-failure '(= ,expected ,form) ,a)
                  (format t "       expected ~s~%" ,e)
                  nil)))))

(defmacro signals (condition &body body)
  `(progn
     (incf *checks*)
     (handler-case (progn ,@body
                          (report-failure '(signals ,condition ,@body) :no-error)
                          nil)
       (,condition () t)
       (error (e) (report-failure '(signals ,condition ,@body) e) nil))))

(defun run-all (&key (verbose t))
  (let ((*failures* 0) (*checks* 0))
    (dolist (name *tests*)
      (let ((*current* name))
        (when verbose (format t "~&; ~a~%" name))
        (handler-case (funcall name)
          (error (e)
            (incf *failures*)
            (format t "~&  ERROR in ~a: ~a~%" name e)))))
    (format t "~&~%~d check~:p, ~d failure~:p~%" *checks* *failures*)
    (finish-output)
    *failures*))
