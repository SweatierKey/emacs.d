;;; setup-editor.el --- Core editing behaviour -*- lexical-binding: t; -*-

;;; Commentary:
;; See config.org, section "Editor basics".

;;; Code:

(setq use-short-answers t)

(set-charset-priority 'unicode)
(prefer-coding-system        'utf-8-unix)
(set-default-coding-systems  'utf-8-unix)
(set-terminal-coding-system  'utf-8-unix)
(set-keyboard-coding-system  'utf-8-unix)
(setq locale-coding-system   'utf-8-unix)

(setq-default indent-tabs-mode nil
              tab-width        4)

(let ((backup-dir   (expand-file-name "var/backups/"   user-emacs-directory))
      (autosave-dir (expand-file-name "var/auto-save/" user-emacs-directory)))
  (make-directory backup-dir   t)
  (make-directory autosave-dir t)
  (setq backup-directory-alist         `(("." . ,backup-dir))
        auto-save-file-name-transforms `((".*" ,autosave-dir t))
        backup-by-copying              t
        version-control                t
        delete-old-versions            t
        kept-new-versions              5
        kept-old-versions              2))

(setq create-lockfiles      nil
      require-final-newline t
      ring-bell-function    'ignore)

(use-package recentf
  :ensure nil
  :init   (setq recentf-max-saved-items 200
                recentf-max-menu-items  25
                recentf-auto-cleanup    'never)
  :config (recentf-mode 1))

(use-package saveplace
  :ensure nil
  :config (save-place-mode 1))

(use-package savehist
  :ensure nil
  :init   (setq savehist-additional-variables
                '(search-ring regexp-search-ring kill-ring))
  :config (savehist-mode 1))

(use-package autorevert
  :ensure nil
  :init (setq auto-revert-verbose                nil
              global-auto-revert-non-file-buffers t)
  :config (global-auto-revert-mode 1))

(electric-pair-mode    1)
(delete-selection-mode 1)
(transient-mark-mode   1)

(defun emacs.d/strip-trailing-whitespace-prog ()
  "Strip trailing whitespace in `prog-mode' buffers only."
  (when (derived-mode-p 'prog-mode)
    (delete-trailing-whitespace)))

(add-hook 'before-save-hook #'emacs.d/strip-trailing-whitespace-prog)

(add-hook 'text-mode-hook #'visual-line-mode)

(when (fboundp 'pulse-momentary-highlight-one-line)
  (defun emacs.d/pulse-line (&rest _) (pulse-momentary-highlight-one-line (point)))
  (dolist (cmd '(other-window
                 windmove-up windmove-down windmove-left windmove-right))
    (advice-add cmd :after #'emacs.d/pulse-line)))

(defun emacs.d/auto-tangle-config ()
  "Tangle `config.org' on save when the current buffer is that file."
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
