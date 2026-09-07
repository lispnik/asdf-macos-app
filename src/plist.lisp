;;;; plist.lisp -- a small, dependency-free Apple property list writer.
;;;;
;;;; Value DSL:
;;;;   (:dict ("Key" . value) ...)   -> <dict>
;;;;   (:array value ...)            -> <array>
;;;;   (:data "base64")              -> <data>
;;;;   (:date "2026-01-01T00:00:00Z")-> <date>
;;;;   :true / :false                -> <true/> <false/>
;;;;   string                        -> <string>
;;;;   integer                       -> <integer>
;;;;   real                          -> <real>

(in-package #:asdf-macos-app)

(defparameter +plist-header+
  "<?xml version=\"1.0\" encoding=\"UTF-8\"?>
<!DOCTYPE plist PUBLIC \"-//Apple//DTD PLIST 1.0//EN\" \"http://www.apple.com/DTDs/PropertyList-1.0.dtd\">
")

(defun xml-escape (string)
  (with-output-to-string (s)
    (loop for c across (string string)
          do (case c
               (#\& (write-string "&amp;" s))
               (#\< (write-string "&lt;" s))
               (#\> (write-string "&gt;" s))
               (#\" (write-string "&quot;" s))
               (t   (write-char c s))))))

(defun indent (stream depth)
  (dotimes (i depth) (write-char #\Tab stream)))

(defun write-plist-value (value stream &optional (depth 0))
  (flet ((tag (name text)
           (indent stream depth)
           (format stream "<~a>~a</~a>~%" name text name)))
    (etypecase value
      (string  (tag "string" (xml-escape value)))
      (integer (tag "integer" value))
      (real    (tag "real" (float value 1d0)))
      (symbol
       (ecase value
         (:true  (indent stream depth) (format stream "<true/>~%"))
         (:false (indent stream depth) (format stream "<false/>~%"))))
      (cons
       (ecase (car value)
         (:data (tag "data" (cdr (second value))))
         (:date (tag "date" (xml-escape (second value))))
         (:array
          (indent stream depth) (format stream "<array>~%")
          (dolist (v (cdr value)) (write-plist-value v stream (1+ depth)))
          (indent stream depth) (format stream "</array>~%"))
         (:dict
          (indent stream depth) (format stream "<dict>~%")
          (loop for (k . v) in (cdr value)
                do (indent stream (1+ depth))
                   (format stream "<key>~a</key>~%" (xml-escape k))
                   (write-plist-value v stream (1+ depth)))
          (indent stream depth) (format stream "</dict>~%")))))))

(defun write-plist (value pathname)
  (ensure-directories-exist pathname)
  (with-open-file (s pathname :direction :output
                              :if-exists :supersede
                              :external-format :utf-8)
    (write-string +plist-header+ s)
    (format s "<plist version=\"1.0\">~%")
    (write-plist-value value s 0)
    (format s "</plist>~%"))
  pathname)

(defun plist-merge (base extra)
  "Merge EXTRA (an alist of string keys to DSL values) over BASE's dict entries."
  (let ((entries (copy-alist (cdr base))))
    (loop for (k . v) in extra
          do (let ((cell (assoc k entries :test #'string=)))
               (if cell (setf (cdr cell) v) (push (cons k v) entries))))
    (cons :dict (sort entries #'string< :key #'car))))

(defun lint-plist (pathname)
  "Run plutil over PATHNAME so a malformed plist fails the build rather than
the app. A no-op where plutil does not exist."
  (when (macos-p)
    (multiple-value-bind (out err code)
        (run (list "/usr/bin/plutil" "-lint" (uiop:native-namestring pathname))
             :ignore-error-status t)
      (declare (ignore out))
      (unless (zerop code)
        (barf "plutil rejected ~a:~%~a" pathname err))))
  pathname)
