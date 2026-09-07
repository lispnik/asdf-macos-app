(defsystem "macos-app-test-fixture"
  :defsystem-depends-on ("asdf-macos-app")
  :class :macos-app-system
  :build-operation "macos-app-op"
  :entry-point "macos-app-test-fixture:main"
  :version "3.1.4"
  :bundle-identifier "com.example.fixture"
  :bundle-name "Fixture"
  :bundle-executable "fixture"
  :bundle-short-version "3.1.4-rc2"
  :bundle-resources ("res/" ("extra.txt" . "data/renamed.txt"))
  :bundle-log t
  :bundle-log-max-bytes 512
  ;; Ad-hoc signing needs no certificate, so CI's macOS runner exercises
  ;; sign-bundle and verify-signature against a real SBCL image -- the single
  ;; riskiest thing in this design. Off macOS this is skipped with a note.
  :code-signing-identity "-"
  :depends-on ("macos-app-test-lib")
  :components ((:file "main")))
