;;; early-init.el --- Pre-init tweaks for a fast and clean boot -*- lexical-binding: t; -*-

;; This file is loaded by Emacs *before* `package.el' is initialised and
;; *before* any UI element is rendered, which makes it the right place to:
;;
;;   1. raise the garbage-collector threshold for the duration of init,
;;   2. neutralise the file-name handler machinery while we load Lisp,
;;   3. turn off the toolbar, menubar and scrollbar early enough that the
;;      user never sees them flash on screen,
;;   4. tell `package.el' that we will activate it ourselves in `init.el'
;;      (so we can use `use-package' deterministically).
;;
;; Everything that is *not* boot-time critical lives in `init.el' or in the
;; literate `config.org' file -- this one stays small on purpose.

;;; Code:

;; ---------------------------------------------------------------------------
;; Garbage collection
;; ---------------------------------------------------------------------------
;;
;; During startup Emacs allocates *a lot* of cons cells while reading and
;; byte-compiling Lisp.  The default threshold (~800 KiB) is so low that the
;; GC fires dozens of times during init, slowing the boot considerably.
;;
;; We push the threshold to `most-positive-fixnum' (effectively "never GC"
;; for the duration of the boot) and raise the percentage of heap growth
;; allowed before a GC.  Once startup is done the `emacs-startup-hook'
;; restores sane runtime values; later on `gcmh-mode' (loaded from
;; `setup-memory.el') will manage the threshold dynamically while Emacs is
;; idle vs. busy.
(setq gc-cons-threshold  most-positive-fixnum
      gc-cons-percentage 0.6)

;; ---------------------------------------------------------------------------
;; File-name handler alist
;; ---------------------------------------------------------------------------
;;
;; Every time Emacs opens a file it walks `file-name-handler-alist' looking
;; for a handler that matches the path (think TRAMP, jka-compr, image-mode,
;; ...).  During init we know we are only loading plain `.el' / `.elc' files
;; from disk, so we can shortcut the lookup by emptying the alist and
;; restoring it once we are done.  Saves a non-trivial amount of time on
;; large configurations.
(defvar emacs.d/file-name-handler-alist--original file-name-handler-alist
  "Backup of `file-name-handler-alist' as it was before early-init clobbered it.")
(setq file-name-handler-alist nil)

(add-hook 'emacs-startup-hook
          (lambda ()
            ;; Put the original handlers back so TRAMP, archive-mode, etc.
            ;; keep working at runtime.
            (setq file-name-handler-alist emacs.d/file-name-handler-alist--original)
            ;; Lower the GC percentage to a more reasonable value; the
            ;; absolute threshold will be tuned at runtime by gcmh.
            (setq gc-cons-percentage 0.1)))

;; ---------------------------------------------------------------------------
;; UI: hide the toolbar, menubar and scrollbar before the first frame paints
;; ---------------------------------------------------------------------------
;;
;; Disabling these in `init.el' technically works, but the user briefly sees
;; them flash on screen before they are removed.  Turning them off here, in
;; early-init, means Emacs never allocates space for them in the first place
;; and the very first frame the user sees is already clean.
;;
;; (In UI-design jargon these elements are sometimes called the "chrome" of
;; the application -- the frame around the actual content.  That's where the
;; Google Chrome browser got its name from: a browser with minimal chrome.)
(menu-bar-mode   -1)
(tool-bar-mode   -1)
(when (fboundp 'scroll-bar-mode)
  (scroll-bar-mode -1))

;; Skip the splash/welcome screen and the chatty *scratch* header so we land
;; on a quiet, focused buffer.
(setq inhibit-startup-screen   t
      inhibit-startup-message  t
      initial-scratch-message  nil
      ;; Replace the audible bell with a no-op.  A visible bell is also an
      ;; option (`(setq visible-bell t)`), but most users find both annoying.
      ring-bell-function       'ignore)

;; Resize frames in pixel increments instead of character cells -- this plays
;; much better with tiling window managers and HiDPI displays -- and don't
;; let internal Emacs operations (like changing the font) implicitly resize
;; the frame, which can cause visible jumps during init.
(setq frame-resize-pixelwise        t
      frame-inhibit-implied-resize  t)

;; ---------------------------------------------------------------------------
;; Package system
;; ---------------------------------------------------------------------------
;;
;; By default Emacs activates installed packages *between* early-init.el and
;; init.el.  We disable that here so we can call `package-initialize'
;; ourselves at the exact point where we want it to happen, after configuring
;; the archive list and any pinning rules.
(setq package-enable-at-startup nil)

;; ---------------------------------------------------------------------------
;; Native compilation (Emacs 28+)
;; ---------------------------------------------------------------------------
;;
;; Emacs will JIT-compile elisp to native code in the background.  Warnings
;; from this process are mostly noise for end users (deprecation notices in
;; third-party packages, etc.), so we silence the popup -- they still go to
;; the *Warnings* buffer, just without stealing the focus.
(setq native-comp-async-report-warnings-errors 'silent)

(provide 'early-init)
;;; early-init.el ends here
