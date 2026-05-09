;;; setup-tramp.el --- Remote editing over SSH -*- lexical-binding: t; -*-

;;; Commentary:
;; See config.org, section "TRAMP".

;;; Code:

(defun emacs.d/save-place-skip-remote (orig-fn &rest args)
  "Around-advice that skips `save-place' bookkeeping for remote files."
  (unless (and buffer-file-name (file-remote-p buffer-file-name))
    (apply orig-fn args)))

(use-package tramp
  :ensure nil
  :defer t
  :custom
  (tramp-default-method                       "ssh")
  (tramp-verbose                              1)
  (tramp-persistency-file-name
   (expand-file-name "var/tramp" user-emacs-directory))
  (vc-handled-backends                        '(Git))
  (tramp-completion-reread-directory-timeout  nil)
  :config
  (with-eval-after-load 'recentf
    (add-to-list 'recentf-exclude (lambda (f) (file-remote-p f))))
  (with-eval-after-load 'saveplace
    (advice-add 'save-place-to-alist :around
                #'emacs.d/save-place-skip-remote))
  (setq tramp-archive-enabled                  nil
        remote-file-name-inhibit-auto-save-visited t)
  (add-to-list 'tramp-remote-path 'tramp-own-remote-path))

(provide 'setup-tramp)
;;; setup-tramp.el ends here
