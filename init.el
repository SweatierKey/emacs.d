;;; init.el --- Bootstrap -*- lexical-binding: t; -*-

;;; Commentary:
;; Bootstrap entry point.  See config.org for the full literate
;; configuration; this file only wires up the package system and
;; loads each `setup-*.el' module from `lisp/'.

;;; Code:

(when (version< emacs-version "29.1")
  (error "This configuration requires Emacs 29.1 or newer; you are running %s"
         emacs-version))

(defconst emacs.d/lisp-dir
  (expand-file-name "lisp" user-emacs-directory)
  "Directory holding the per-area `setup-*.el' modules.")

(unless (file-directory-p emacs.d/lisp-dir)
  (make-directory emacs.d/lisp-dir t))

(add-to-list 'load-path emacs.d/lisp-dir)

(setq custom-file (expand-file-name "custom.el" user-emacs-directory))
(when (file-exists-p custom-file)
  (load custom-file :no-error :no-message))

(require 'package)

(setq package-archives
      '(("gnu"    . "https://elpa.gnu.org/packages/")
        ("nongnu" . "https://elpa.nongnu.org/nongnu/")
        ("melpa"  . "https://melpa.org/packages/"))
      package-archive-priorities
      '(("gnu" . 10) ("nongnu" . 9) ("melpa" . 5)))

(package-initialize)

;; Emacs 30 ships a stub `compat.el' that registers the package as
;; built-in; this prevents `package.el' from installing the real GNU
;; ELPA compat that modern transient/magit need.  See config.org,
;; section "Init bootstrap".
(setq package--builtins         (assq-delete-all 'compat package--builtins)
      package--builtin-versions (assq-delete-all 'compat package--builtin-versions))

(defcustom emacs.d/package-refresh-stale-days 7
  "Days the local package archive cache may age before auto-refresh."
  :type 'integer :group 'emacs.d)

(defun emacs.d/package-refresh-if-stale ()
  "Refresh `package-archive-contents' if the cache is missing or stale."
  (let* ((archive-dir (expand-file-name "archives" package-user-dir))
         (witness     (expand-file-name "gnu/archive-contents" archive-dir)))
    (when (or (not (file-exists-p witness))
              (time-less-p
               (file-attribute-modification-time (file-attributes witness))
               (time-subtract (current-time)
                              (days-to-time emacs.d/package-refresh-stale-days))))
      (message "Package archives are stale; refreshing...")
      (package-refresh-contents))))

(emacs.d/package-refresh-if-stale)

(require 'use-package)
(setq use-package-always-ensure   t
      use-package-always-defer    nil
      use-package-expand-minimally t
      use-package-verbose         nil)

(defun emacs.d/maybe-tangle-config ()
  "Re-tangle `config.org' when newer than any `lisp/setup-*.el' module."
  (let* ((org-file (expand-file-name "config.org" user-emacs-directory))
         (modules  (and (file-directory-p emacs.d/lisp-dir)
                        (directory-files emacs.d/lisp-dir t "\\`setup-.*\\.el\\'"))))
    (when (and (file-exists-p org-file) modules)
      (let ((org-mtime (file-attribute-modification-time
                        (file-attributes org-file))))
        (when (seq-some
               (lambda (el)
                 (time-less-p (file-attribute-modification-time
                               (file-attributes el))
                              org-mtime))
               modules)
          (require 'org)
          (require 'ob-tangle)
          (message "config.org changed -- re-tangling...")
          (org-babel-tangle-file org-file))))))

(emacs.d/maybe-tangle-config)

(require 'setup-memory)
(require 'setup-ui)
(require 'setup-editor)
(require 'setup-completion)
(require 'setup-prog)
(require 'setup-magit)

;;; init.el ends here
