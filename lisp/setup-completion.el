;;; setup-completion.el --- Minibuffer + in-buffer completion -*- lexical-binding: t; -*-

;;; Commentary:
;; See config.org, section "Completion".

;;; Code:

(use-package vertico
  :init (vertico-mode 1)
  :custom
  (vertico-cycle  t)
  (vertico-resize t)
  (vertico-count  14)
  :config
  ;; Candidates grow upward above the input line; the prompt stays
  ;; pinned at the bottom of the minibuffer, in your line of sight.
  (require 'vertico-reverse)
  (vertico-reverse-mode 1))

(use-package marginalia
  :after vertico
  :init (marginalia-mode 1))

(use-package orderless
  :custom
  ;; Fall back to `basic' so prefix-driven completion (TRAMP file
  ;; names, in particular) keeps working.
  (completion-styles '(orderless basic))
  (completion-category-overrides
   '((file (styles basic partial-completion)))))

(use-package consult
  :bind
  (("C-x b"   . consult-buffer)
   ("C-x 4 b" . consult-buffer-other-window)
   ("C-x p b" . consult-project-buffer)
   ("M-y"     . consult-yank-pop)
   ("M-g g"   . consult-goto-line)
   ("M-g i"   . consult-imenu)
   ("M-s l"   . consult-line)
   ("M-s r"   . consult-ripgrep)
   ("M-s f"   . consult-find))
  :custom
  (consult-narrow-key  "<")
  (consult-preview-key 'any))

(use-package corfu
  :init (global-corfu-mode 1)
  :custom
  (corfu-auto              t)
  (corfu-auto-prefix       2)
  (corfu-auto-delay        0.1)
  (corfu-cycle             t)
  (corfu-quit-no-match     'separator)
  (corfu-preselect         'prompt)
  (corfu-echo-documentation 0.25))

(use-package cape
  :init
  (add-to-list 'completion-at-point-functions #'cape-dabbrev)
  (add-to-list 'completion-at-point-functions #'cape-file)
  (add-to-list 'completion-at-point-functions #'cape-keyword))

(use-package which-key
  :ensure nil
  :diminish which-key-mode
  :init (setq which-key-idle-delay 0.5
              which-key-popup-type 'minibuffer)
  :config (which-key-mode 1))

(provide 'setup-completion)
;;; setup-completion.el ends here
