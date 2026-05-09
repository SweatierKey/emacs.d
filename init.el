;;; init.el --- Personal Emacs configuration entry point -*- lexical-binding: t; -*-

;; Author: Matteo  (https://github.com/SweatierKey)
;;
;; This is the *bootstrap* file.  Its job is intentionally tiny:
;;
;;   1. set up the package archives and `use-package',
;;   2. make sure the literate `config.org' file is in sync with the
;;      pre-tangled Lisp modules under `lisp/' (re-tangling on demand),
;;   3. `require' those modules in the right order.
;;
;; The actual configuration -- with prose explanations -- lives in
;; `config.org'.  Each top-level section of that file tangles to a small
;; `setup-*.el' module under `lisp/'.  This way:
;;
;;   * `git clone' + `emacs' "just works" out of the box, because the
;;     tangled `.el' files are committed alongside `config.org' and we never
;;     depend on Org being available at boot time;
;;   * editing `config.org' in Emacs and saving regenerates the relevant
;;     module automatically (see the auto-tangle hook in `setup-editor.el');
;;   * if you only want to read the config you open `config.org' and read
;;     it like a book.
;;
;; This file is meant to be readable -- comments are intentionally verbose.

;;; Code:

;; ---------------------------------------------------------------------------
;; Sanity check: refuse to run on ancient Emacs versions
;; ---------------------------------------------------------------------------
;;
;; The configuration leans on features that only exist in Emacs 29+ (Eglot
;; built in, `use-package' built in, tree-sitter, `which-key' built in,
;; etc.).  Failing fast with a clear message is friendlier than letting the
;; user debug obscure errors later on.
(when (version< emacs-version "29.1")
  (error "This configuration requires Emacs 29.1 or newer; you are running %s"
         emacs-version))

;; ---------------------------------------------------------------------------
;; Load path
;; ---------------------------------------------------------------------------
;;
;; All modular files live in `<user-emacs-directory>/lisp'.  We add that
;; directory to `load-path' so we can `require' them by short name.
(defconst emacs.d/lisp-dir
  (expand-file-name "lisp" user-emacs-directory)
  "Directory holding the per-area `setup-*.el' modules.")

(unless (file-directory-p emacs.d/lisp-dir)
  (make-directory emacs.d/lisp-dir t))

(add-to-list 'load-path emacs.d/lisp-dir)

;; ---------------------------------------------------------------------------
;; Custom file
;; ---------------------------------------------------------------------------
;;
;; By default `customize-*' commands write their output at the bottom of
;; `init.el', which is messy in a version-controlled config.  We redirect
;; them to a separate file that we *do not* track in git -- see
;; `.gitignore'.
(setq custom-file (expand-file-name "custom.el" user-emacs-directory))
(when (file-exists-p custom-file)
  (load custom-file :no-error :no-message))

;; ---------------------------------------------------------------------------
;; Package archives + use-package
;; ---------------------------------------------------------------------------
;;
;; We use:
;;   - GNU ELPA (built in, ships with Emacs)
;;   - NonGNU ELPA (built in since Emacs 28, packages with non-FSF copyright
;;     assignment such as `magit')
;;   - MELPA (community, the bulk of third-party packages)
(require 'package)

(setq package-archives
      '(("gnu"    . "https://elpa.gnu.org/packages/")
        ("nongnu" . "https://elpa.nongnu.org/nongnu/")
        ("melpa"  . "https://melpa.org/packages/")))

;; Pin a couple of important packages to GNU/NonGNU ELPA when they are also
;; on MELPA, to avoid surprise breakages from MELPA's "always latest" policy.
(setq package-archive-priorities
      '(("gnu"    . 10)
        ("nongnu" . 9)
        ("melpa"  . 5)))

(package-initialize)

;; First-run bootstrap: refresh the archive list if we have never done so.
;; We *don't* refresh on every boot -- it's slow and unnecessary.  Run
;; `M-x package-refresh-contents' manually when you want fresh metadata.
(unless package-archive-contents
  (package-refresh-contents))

;; `use-package' is bundled with Emacs 29+, so we just require it.  The
;; helper variables below make the rest of the config more concise.
(require 'use-package)
(setq use-package-always-ensure  t   ;; auto-install missing packages
      use-package-always-defer   nil ;; default; flip to t per package as needed
      use-package-expand-minimally t ;; smaller macroexpansion -> faster boot
      use-package-verbose        nil)

;; ---------------------------------------------------------------------------
;; Literate config: keep `lisp/*.el' in sync with `config.org'
;; ---------------------------------------------------------------------------
;;
;; If the user edited `config.org' more recently than the tangled modules
;; we re-tangle automatically.  This costs ~100ms once per edit, and zero
;; on a normal boot where nothing changed.
(defun emacs.d/maybe-tangle-config ()
  "Re-tangle `config.org' if it is newer than any `lisp/setup-*.el' file."
  (let* ((org-file  (expand-file-name "config.org" user-emacs-directory))
         (any-stale (and (file-exists-p org-file)
                         (let ((org-mtime (file-attribute-modification-time
                                           (file-attributes org-file))))
                           (seq-some
                            (lambda (el)
                              (time-less-p
                               (file-attribute-modification-time
                                (file-attributes el))
                               org-mtime))
                            (directory-files emacs.d/lisp-dir t "\\`setup-.*\\.el\\'"))))))
    (when any-stale
      (require 'org)
      (require 'ob-tangle)
      (message "config.org changed -- re-tangling...")
      (org-babel-tangle-file org-file))))

(emacs.d/maybe-tangle-config)

;; ---------------------------------------------------------------------------
;; Load the modules
;; ---------------------------------------------------------------------------
;;
;; Order matters in a few places:
;;   * `setup-memory'       -- enable gcmh ASAP so it tunes the GC during the
;;                             rest of the load,
;;   * `setup-ui'           -- theme + font, so we look right while later
;;                             modules load,
;;   * `setup-editor'       -- core editing behaviour and built-in tweaks,
;;   * `setup-completion'   -- vertico/marginalia/orderless/consult/corfu,
;;   * `setup-prog'         -- eglot, flymake, eldoc, treesit,
;;   * `setup-magit'        -- git porcelain,
;;   * `setup-tramp'        -- remote editing tweaks,
;;   * `setup-terminal'     -- vterm + tab-bar + dynamic tab title,
;;   * `setup-ssh-sessions' -- saved SSH sessions opened in vterm tabs,
;;   * `setup-ssh-tunnels'  -- tunnel manager with toggle on/off.
(require 'setup-memory)
(require 'setup-ui)
(require 'setup-editor)
(require 'setup-completion)
(require 'setup-prog)
(require 'setup-magit)
(require 'setup-tramp)
(require 'setup-terminal)
(require 'setup-ssh-sessions)
(require 'setup-ssh-tunnels)

;;; init.el ends here
