;;; setup-editor.el --- Core editing behaviour -*- lexical-binding: t; -*-

;; Things every Emacs user wants once they realise the defaults are from
;; another era:
;;
;;   * `y'/`n' instead of `yes'/`no' confirmations,
;;   * remember point position across sessions (`save-place'),
;;   * persistent minibuffer history (`savehist'),
;;   * recent files list (`recentf'),
;;   * automatic reload when a file changes on disk (`auto-revert'),
;;   * sane defaults for tabs vs spaces, backup files, encoding,
;;   * automatic re-tangling of `config.org' on save (so the literate
;;     workflow is frictionless).
;;
;; This module is intentionally non-opinionated about keybindings beyond a
;; handful of universally-expected ones; pick your own elsewhere.

;;; Code:

;; ---------------------------------------------------------------------------
;; Y/N answers
;; ---------------------------------------------------------------------------
;;
;; Old advice was `(fset 'yes-or-no-p 'y-or-n-p)' but Emacs 28 introduced a
;; first-class option that handles a few edge cases properly.
(setq use-short-answers t)

;; ---------------------------------------------------------------------------
;; Encoding -- be unambiguously UTF-8
;; ---------------------------------------------------------------------------
(set-charset-priority 'unicode)
(prefer-coding-system        'utf-8-unix)
(set-default-coding-systems  'utf-8-unix)
(set-terminal-coding-system  'utf-8-unix)
(set-keyboard-coding-system  'utf-8-unix)
(setq locale-coding-system   'utf-8-unix)

;; ---------------------------------------------------------------------------
;; Tabs and indentation
;; ---------------------------------------------------------------------------
(setq-default indent-tabs-mode nil   ;; insert spaces, not literal tabs
              tab-width        4)    ;; but render tabs as 4 cols when present

;; ---------------------------------------------------------------------------
;; Backup and auto-save layout
;; ---------------------------------------------------------------------------
;;
;; By default Emacs litters the whole filesystem with `foo.txt~' files and
;; `#foo.txt#' auto-save files.  We funnel both into subdirectories of
;; `user-emacs-directory' so the rest of the disk stays clean.
(let ((backup-dir    (expand-file-name "var/backups/"   user-emacs-directory))
      (autosave-dir  (expand-file-name "var/auto-save/" user-emacs-directory)))
  (make-directory backup-dir   t)
  (make-directory autosave-dir t)
  (setq backup-directory-alist         `(("." . ,backup-dir))
        auto-save-file-name-transforms `((".*" ,autosave-dir t))
        backup-by-copying              t  ;; don't clobber symlinks
        version-control                t  ;; numbered backups
        delete-old-versions            t
        kept-new-versions              5
        kept-old-versions              2))

;; Lock files (`.#foo.txt') are useful for multi-user setups but mostly
;; just confuse other tools (webpack, vim, file watchers...).  Disable.
(setq create-lockfiles nil)

;; ---------------------------------------------------------------------------
;; Recent files, place, history
;; ---------------------------------------------------------------------------
;;
;; All three are built-in but off by default.

(use-package recentf
  :ensure nil
  :init   (setq recentf-max-saved-items 200
                recentf-max-menu-items 25
                recentf-auto-cleanup 'never)
  :config (recentf-mode 1))

(use-package saveplace
  :ensure nil
  :config (save-place-mode 1))

(use-package savehist
  :ensure nil
  :init   (setq savehist-additional-variables
                '(search-ring regexp-search-ring kill-ring))
  :config (savehist-mode 1))

;; ---------------------------------------------------------------------------
;; Reload changed files
;; ---------------------------------------------------------------------------
;;
;; Quietly refresh buffers when the underlying file changes -- handy when
;; pulling git changes from another window, or when a build tool rewrites
;; a generated file.  Also revert non-file buffers (dired, magit, ...).
(use-package autorevert
  :ensure nil
  :init (setq auto-revert-verbose         nil
              global-auto-revert-non-file-buffers t)
  :config (global-auto-revert-mode 1))

;; ---------------------------------------------------------------------------
;; Pairs and selection
;; ---------------------------------------------------------------------------

;; Type the opening character, get the closing one for free.  Works for
;; (), [], {}, "", ''.
(electric-pair-mode 1)

;; If a region is active and you type, replace the region.  Standard
;; behaviour in basically every other editor.
(delete-selection-mode 1)

;; Visualise selection like other editors do (instead of inverse-video).
(transient-mark-mode 1)

;; ---------------------------------------------------------------------------
;; Whitespace
;; ---------------------------------------------------------------------------

;; Strip trailing whitespace on save, but only in programming buffers --
;; in prose buffers (org, markdown, ...) trailing spaces sometimes have
;; semantic meaning (markdown line break).
(add-hook 'before-save-hook
          (lambda ()
            (when (derived-mode-p 'prog-mode)
              (delete-trailing-whitespace))))

;; Always end files with a single trailing newline (POSIX).
(setq require-final-newline t)

;; ---------------------------------------------------------------------------
;; Built-in conveniences
;; ---------------------------------------------------------------------------

;; Wrap long lines at word boundaries in text buffers.
(add-hook 'text-mode-hook #'visual-line-mode)

;; Highlight the symbol-at-point briefly after navigation -- helps to keep
;; track of where you landed after a jump.
(when (fboundp 'pulse-momentary-highlight-one-line)
  (dolist (cmd '(other-window
                 windmove-up windmove-down windmove-left windmove-right))
    (advice-add cmd :after
                (lambda (&rest _)
                  (pulse-momentary-highlight-one-line (point))))))

;; Disable the bell entirely (early-init also covers this; here it ensures
;; no later mode re-enables it).
(setq ring-bell-function 'ignore)

;; ---------------------------------------------------------------------------
;; Auto-tangle config.org on save
;; ---------------------------------------------------------------------------
;;
;; This makes the literate workflow feel native: open `config.org', edit a
;; src block, hit `C-x C-s', and the corresponding `setup-*.el' file is
;; rewritten in place.  Because the modules are byte-compiled lazily by
;; native-comp, the change shows up the next time Emacs starts (or
;; immediately if you `M-x load-file' the affected module).
(defun emacs.d/auto-tangle-config ()
  "If the current buffer is `config.org', tangle it on save."
  (when (and buffer-file-name
             (string-equal (file-name-nondirectory buffer-file-name)
                           "config.org")
             (file-equal-p (file-name-directory buffer-file-name)
                           user-emacs-directory))
    (let ((org-confirm-babel-evaluate nil))
      (org-babel-tangle))))

(add-hook 'after-save-hook #'emacs.d/auto-tangle-config)

(provide 'setup-editor)
;;; setup-editor.el ends here
