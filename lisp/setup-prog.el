;;; setup-prog.el --- LSP, linting, docs, syntax -*- lexical-binding: t; -*-

;;; Commentary:
;; See config.org, section "Programming language support" -- including the
;; per-language LSP server install cheat sheet.

;;; Code:

(use-package treesit
  :ensure nil
  :custom (treesit-font-lock-level 4))

(use-package treesit-auto
  :custom (treesit-auto-install 'prompt)
  :config
  (treesit-auto-add-to-auto-mode-alist 'all)
  (global-treesit-auto-mode 1))

(defcustom emacs.d/eglot-auto-modes
  '(python-base-mode  python-ts-mode
    rust-ts-mode
    c-ts-mode         c++-ts-mode
    go-ts-mode
    typescript-ts-mode tsx-ts-mode  js-ts-mode
    sh-mode           bash-ts-mode
    lua-ts-mode
    yaml-ts-mode      json-ts-mode  toml-ts-mode
    dockerfile-ts-mode
    html-mode         css-mode      markdown-mode
    haskell-mode      haskell-ts-mode
    java-mode         java-ts-mode
    kotlin-mode       kotlin-ts-mode
    elixir-mode       elixir-ts-mode
    ruby-mode         ruby-ts-mode
    php-mode          zig-mode      nix-mode
    LaTeX-mode)
  "Major modes for which Eglot should be auto-started.

Eglot only actually attaches when the matching language server is
found on `PATH', so leaving entries here for languages whose server
you have not installed is harmless."
  :type '(repeat symbol)
  :group 'emacs.d)

(use-package eglot
  :ensure nil
  :custom
  (eglot-events-buffer-size 0)
  (eglot-extend-to-xref     t)
  :bind
  (:map eglot-mode-map
        ("C-c l a" . eglot-code-actions)
        ("C-c l r" . eglot-rename)
        ("C-c l f" . eglot-format)
        ("C-c l d" . eldoc))
  :init
  (dolist (mode emacs.d/eglot-auto-modes)
    (let ((hook (intern (format "%s-hook" mode))))
      (add-hook hook #'eglot-ensure))))

(use-package flymake
  :ensure nil
  :hook (prog-mode . flymake-mode)
  :bind
  (:map flymake-mode-map
        ("M-n"     . flymake-goto-next-error)
        ("M-p"     . flymake-goto-prev-error)
        ("C-c ! l" . flymake-show-buffer-diagnostics)
        ("C-c ! L" . flymake-show-project-diagnostics)))

(use-package flymake-shellcheck
  :commands flymake-shellcheck-load
  :hook ((sh-mode      . flymake-shellcheck-load)
         (bash-ts-mode . flymake-shellcheck-load)))

(use-package eldoc
  :ensure nil
  :diminish eldoc-mode
  :custom
  (eldoc-documentation-strategy    'eldoc-documentation-compose-eagerly)
  (eldoc-echo-area-use-multiline-p t))

(defun emacs.d/maybe-enable-smerge ()
  "Enable `smerge-mode' if the visited file contains conflict markers."
  (save-excursion
    (goto-char (point-min))
    (when (re-search-forward "^<<<<<<< " nil t)
      (smerge-mode 1))))

(add-hook 'find-file-hook #'emacs.d/maybe-enable-smerge)

(setq compilation-scroll-output    'first-error
      compilation-ask-about-save   nil)

(use-package ansi-color
  :ensure nil
  :hook (compilation-filter . ansi-color-compilation-filter))

(provide 'setup-prog)
;;; setup-prog.el ends here
