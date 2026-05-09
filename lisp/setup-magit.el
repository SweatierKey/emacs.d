;;; setup-magit.el --- Magit -*- lexical-binding: t; -*-

;;; Commentary:
;; See config.org, section "Git via Magit".

;;; Code:

(use-package magit
  :bind
  (("C-x g"   . magit-status)
   ("C-x M-g" . magit-dispatch))
  :custom
  (magit-define-global-key-bindings nil)
  (magit-save-repository-buffers    'dontask)
  (magit-refresh-status-buffer      t)
  (magit-log-section-commit-count   10))

(provide 'setup-magit)
;;; setup-magit.el ends here
