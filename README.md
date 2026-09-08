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
`ASDF_MACOS_APP_BUNDLE` environment variable, and gets an explicit source
registry naming every system in the resolved dependency closure — inheriting
`CL_SOURCE_REGISTRY` is not enough, since the parent may have found systems
through `asdf:*central-registry*` or a search function the child cannot see.
That registry travels inside the bootstrap file rather than the environment,
which has no length limit. The child does *not* get `--no-userinit`, so an
ocicl-style registry set up in your init file still applies on top.

**The core is a resource, not an executable.** `save-lisp-and-die :executable t`
appends the core to the SBCL runtime's Mach-O — *past* the end of `__LINKEDIT`
and past the code signature — and codesign then refuses the file outright:

```
$ codesign --force --sign - some-dumped-image
some-dumped-image: main executable failed strict validation
```

Measured: `__LINKEDIT` and the signature both end at byte 410,952 of a
47,782,952-byte image. That is 47MB of trailing data no signature can cover, and
it holds for a Developer ID as much as for ad hoc, and whether or not the old
signature is stripped first. An executable image cannot be signed, so it cannot
be notarised, so it cannot be shipped.

So the bundle holds three things instead of one:

- `Contents/Resources/sbcl.core` — the dumped core, sealed as an ordinary
  resource. Tampering with it fails `codesign --verify`.
- `Contents/MacOS/<exe>` — a copy of the SBCL runtime, which is a clean Mach-O
  that signs and verifies.
- `Contents/MacOS/sbcl.core` — a relative symlink to the core.

The symlink is what reconciles two constraints that otherwise conflict. With no
`--core` argument and no `SBCL_HOME` — which is exactly what LaunchServices gives
a double-clicked app — the runtime looks for a core of that name *beside its own
executable*. But the core cannot actually live in `MacOS/`: codesign treats every
file there as nested code and refuses the bundle (`code object is not signed at
all / In subcomponent: …/MacOS/sbcl.core`), whatever its permissions. A symlink
is found by the runtime and sealed as a resource by codesign.

No C launcher, and so still no C toolchain in the build.

**The executable is never rewritten.** `install_name_tool` is not run on it. So no
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
  MacOS/editor                a copy of the SBCL runtime
  MacOS/sbcl.core             -> ../Resources/sbcl.core
  Resources/sbcl.core         the dumped core, sealed by the signature
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
must stay inside `Contents/Resources` (checked both as a path and through the
truename of the deepest existing ancestor), must not take a name the build
itself generates (`<exe>.icns`, `entitlements.plist`,
`foreign-libraries.sexp`), and two resources may not install to the same
place. Symbolic links are refused rather than followed, since copying through
one is how a resource escapes the bundle.

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
202 checks, 0 failures
```

CI runs the suite on both Linux and macOS. The Linux leg covers layout,
plists, staging, freshness, the child protocol and the Mach-O parsers; the
macOS leg is the one that actually runs plutil, ad-hoc codesign and
`codesign --verify` against a real SBCL image, which is the riskiest part of
the design. Exactly one test signs, so a signing failure reports as one
failure instead of taking out every build test.

The fixture systems under `tests/fixture` are checked in as `.asd.in` and
renamed when the suite copies them to a scratch directory, so a recursive
source registry over this repository does not register them.

The build tests shell out to a real SBCL and dump images, so the suite takes
around thirty seconds. It works in a scratch directory and redirects the built
app's log with `MACOS_APP_LOG`, so it does not touch your home directory. The
dylib copy-and-rewrite loop in `relocate-foreign-libraries` is the one part
with no coverage: it needs real Mach-O files and `install_name_tool`. Its
parsers are covered against captured `otool` output.

## Known limits and things to check

- **`SBCL_HOME` in the environment loads the wrong core.** The executable is the
  SBCL runtime and finds `sbcl.core` beside itself — *unless* `SBCL_HOME` is
  set, which wins, and the runtime then loads whatever core lives there. The
  application drops into a plain SBCL REPL and never starts. LaunchServices sets
  no `SBCL_HOME`, so a double-clicked app is unaffected; a bundle launched from
  a shell that has one is not, and Homebrew's `sbcl` is a wrapper script that
  exports it. There is no fix without a launcher binary that passes `--core`
  explicitly, which would mean a C toolchain in the build. Launch the bundle
  with `env -u SBCL_HOME` if you need to run it from such a shell.

- **The banner.** A separate core prints SBCL's startup banner unless
  `--noinform` is passed, and LaunchServices passes nothing. It is printed by
  the C runtime before Lisp starts, so no `:toplevel` can suppress it; only an
  embedded executable core does, and that is the thing that cannot be signed.
  For a bundle it goes to the log nobody reads. This is the one thing the old
  layout did better.
- **The hardened runtime needs `disable-library-validation`.** A signed runtime
  refuses to load Homebrew dylibs — `libzstd` for a compression-enabled SBCL —
  on a Team ID mismatch. `:entitlements :sbcl-default` already carries that key;
  a bundle signed without it fails at launch rather than at build.
- **Always launch the signed bundle before shipping it.** `verify-signature`
  catches a file-level failure, not a runtime one.
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
