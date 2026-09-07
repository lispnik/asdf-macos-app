# asdf-macos-app

An ASDF extension that builds a macOS `.app` bundle from an SBCL image.

```lisp
(defsystem "editor"
  :defsystem-depends-on ("asdf-macos-app")
  :class :macos-app-system
  :build-operation "macos-app-op"
  :entry-point "editor:main"
  :version "1.4.2"
  :bundle-identifier "com.example.editor"
  :bundle-name "Editor"
  :bundle-icon "res/icon.png"
  :code-signing-identity "Developer ID Application: Jane Doe (ABCDE12345)"
  :depends-on ("cffi" "editor-core")
  :components ((:file "main")))
```

```
$ sbcl --eval '(asdf:make "editor")' --quit
; dumping image: /usr/local/bin/sbcl --dynamic-space-size 8192 ...
; built /path/to/Editor.app/
```

Or from Lisp: `(macos-app:make-app "editor")`.

## Two decisions that shape the design

**The image dump kills the process.** `save-lisp-and-die` never returns, so
nothing that must happen *after* the executable exists — codesigning, dylib
relocation, verification — can run in the same image. `macos-app-op` therefore
creates the bundle skeleton, spawns a child SBCL to perform
`macos-app-image-op` (which dumps straight into `Contents/MacOS/`), and then
finishes the bundle in the parent. The child is told where to write via the
`ASDF_MACOS_APP_BUNDLE` environment variable, and inherits the parent's
`CL_SOURCE_REGISTRY` plus the extension's and the target system's directories.
It does *not* get `--no-userinit`, so an ocicl-style registry set up in your
init file is still visible.

**The executable is never rewritten.** SBCL appends the core image to the
Mach-O file; `install_name_tool` is not guaranteed to leave that intact. So no
`-add_rpath` on the executable. Instead, every dylib is copied into
`Contents/Frameworks`, its *own* dependencies are rewritten to
`@loader_path/<name>`, and at startup the runtime pushes
`Contents/Frameworks/` onto `cffi:*foreign-library-directories*`. CFFI then
resolves libraries to absolute paths inside the bundle.

## Layout produced

```
Editor.app/Contents/
  Info.plist
  PkgInfo                     "APPL????"
  MacOS/editor                the dumped SBCL executable
  Resources/editor.icns
  Resources/entitlements.plist
  Resources/foreign-libraries.sexp   manifest written by the child
  Frameworks/*.dylib
```

## Options

All are `defsystem` keywords on `:macos-app-system`.

| Keyword | Default | Notes |
| --- | --- | --- |
| `:bundle-identifier` | — | required, `CFBundleIdentifier` |
| `:bundle-name` | `:build-pathname`, else capitalized system name | also names the `.app` |
| `:bundle-display-name` | bundle name | |
| `:bundle-executable` | downcased system name | `Contents/MacOS/<this>` |
| `:bundle-short-version` | `:version` | `CFBundleShortVersionString` |
| `:bundle-icon` | none | `.icns` copied; `.png` converted via `sips` + `iconutil` |
| `:bundle-minimum-system-version` | `"11.0"` | |
| `:bundle-agent` | `nil` | `LSUIElement`; menubar apps with no Dock icon |
| `:bundle-high-resolution` | `t` | |
| `:bundle-category` | none | `LSApplicationCategoryType` |
| `:bundle-principal-class` | none | `NSPrincipalClass`; a Cocoa app wants `"NSApplication"` |
| `:bundle-copyright` | none | |
| `:bundle-url-schemes` | none | list of strings |
| `:bundle-document-types` | none | list of plist-DSL dicts |
| `:bundle-info-plist` | none | alist merged over the generated keys |
| `:bundle-resources` | none | files/dirs copied into `Contents/Resources`; an entry is a path or `(path . "relative/destination")` |
| `:bundle-log` | `t` | redirect the app's stdio to a log file at runtime |
| `:bundle-log-max-bytes` | 1 MB | rotate the log past this; `nil` disables |
| `:bundle-foreign-libraries` | none | extra dylibs beyond what CFFI reports |
| `:bundle-output-directory` | system source dir | where the `.app` lands |
| `:code-signing-identity` | `nil` | `nil` = unsigned, `"-"` = ad hoc, else a Developer ID |
| `:entitlements` | `:sbcl-default` | or a pathname, or `nil` |
| `:hardened-runtime` | `t` | |
| `:compression` | `nil` | passed to `uiop:dump-image` (needs zstd-enabled SBCL) |

The plist DSL: strings, integers, reals, `:true`/`:false`,
`(:array v ...)`, `(:dict ("Key" . v) ...)`, `(:data "base64")`,
`(:date "...")`.

## Runtime API

Available inside the built app:

- `macos-app:running-in-bundle-p`
- `macos-app:bundle-root` — the `.app` pathname, found by walking up from `argv0`
- `macos-app:bundle-resource` — `Contents/Resources`, optionally joined with a relative path
- `macos-app:bundle-frameworks`

The generated toplevel wraps your `:entry-point`: it locates the bundle, sets
`*default-pathname-defaults*` to the home directory (Finder launches with
`cwd` = `/`), registers the Frameworks directory with CFFI, strips legacy
`-psn_*` arguments, and redirects output to `~/Library/Logs/<name>.log`, since
a Finder-launched process has nowhere else to write. Set `MACOS_APP_LOG` in the
environment to send that somewhere else, or bind `macos-app:*log-to-file*` to
`nil` to keep stdio as-is.

## Signing

`:entitlements :sbcl-default` writes the three keys an SBCL image needs under
the hardened runtime:

- `com.apple.security.cs.allow-unsigned-executable-memory`
- `com.apple.security.cs.allow-jit`
- `com.apple.security.cs.disable-library-validation`

Nested code is signed innermost first, then the bundle — `--deep` is deprecated
by Apple. "Nested code" is not just `Frameworks/*.dylib`: it covers dylibs in
subdirectories, `.framework` and `.xpc` bundles signed as units rather than
walked into, helper executables sitting beside the main one in
`Contents/MacOS`, and login items under `Contents/Library`. The build then runs
`codesign --verify --deep --strict` and fails loudly if that does not pass.

`:bundle-resources` destinations are checked before anything is copied: they
must stay inside `Contents/Resources`, must not take a name the build itself
generates (`<exe>.icns`, `entitlements.plist`, `foreign-libraries.sexp`), and
two resources may not install to the same place.

Notarization is a separate step, since it needs credentials and network:

```lisp
(macos-app:notarize "Editor.app" :keychain-profile "notary")
```

after `xcrun notarytool store-credentials notary`.

## Building off macOS

`macos-app:*allow-non-macos-build*` assembles the layout and Info.plist on any
host, skipping everything that needs otool, install_name_tool, codesign, sips
or plutil. The result is not shippable, and says so: a file called
`Contents/INCOMPLETE-BUILD` explains what was left out. That marker is acted
on rather than merely advisory — such a build refuses to replace a complete
bundle at the same path (bind `macos-app:*replace-complete-bundle*` to
override), and `notarize` refuses it outright. `macos-app:complete-bundle-p`
answers the question directly. The test suite uses this mode; nothing else
should.

On macOS the build additionally checks the tools are actually installed, since
a clean system has none of them until `xcode-select --install` has been run.

## Tests

```
$ sbcl --eval '(asdf:test-system "asdf-macos-app")' --quit
179 checks, 0 failures
```

CI runs the suite on both Linux and macOS. The Linux leg covers layout,
plists, staging, freshness, the child protocol and the Mach-O parsers; the
macOS leg is the one that actually runs plutil, ad-hoc codesign and
`codesign --verify` against a real SBCL image, which is the riskiest part of
the design.

The build tests shell out to a real SBCL and dump images, so the suite takes
around thirty seconds. It works in a scratch directory and redirects the built
app's log with `MACOS_APP_LOG`, so it does not touch your home directory. The
dylib copy-and-rewrite loop in `relocate-foreign-libraries` is the one part
with no coverage: it needs real Mach-O files and `install_name_tool`. Its
parsers are covered against captured `otool` output.

## Known limits and things to check

- **SBCL core plus code signature.** Signing appends to the Mach-O after the
  core has already been appended by `save-lisp-and-die`. This works on current
  SBCL and macOS, but it is the most fragile part of the pipeline. Always
  launch the signed bundle before shipping it; `verify-signature` catches the
  file-level failure but not a runtime one. If it ever breaks, the escape hatch
  is a small C launcher in `Contents/MacOS` that `exec`s the SBCL runtime with
  `--core Contents/Resources/app.core`.
- **Universal binaries.** Not supported. `lipo` cannot merge two SBCL cores.
  Build arm64 and x86_64 bundles separately.
- **Non-CFFI foreign libraries.** Only CFFI's `list-foreign-libraries` is
  consulted automatically. Anything loaded through `sb-alien` directly must be
  listed in `:bundle-foreign-libraries`.
- **Two dylibs with the same basename** will collide in `Frameworks/`; the
  build errors rather than silently picking one.
- SBCL only. The child-process invocation and `sb-ext:posix-environ` are
  SBCL-specific; `macos-app:*child-lisp*` and `*child-lisp-options*` let you
  point at a different runtime.
