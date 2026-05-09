;;; early-init.el --- Pre-init tweaks -*- lexical-binding: t; -*-

;;; Commentary:
;; See config.org, section "early-init.el" for the rationale behind every
;; setting in this file.

;;; Code:

(setq gc-cons-threshold  most-positive-fixnum
      gc-cons-percentage 0.6)

(defvar emacs.d/file-name-handler-alist--original file-name-handler-alist
  "Backup of `file-name-handler-alist' before early-init clobbered it.")
(setq file-name-handler-alist nil)

(add-hook 'emacs-startup-hook
          (lambda ()
            (setq file-name-handler-alist emacs.d/file-name-handler-alist--original
                  gc-cons-percentage      0.1)))

(menu-bar-mode -1)
(tool-bar-mode -1)
(when (fboundp 'scroll-bar-mode)
  (scroll-bar-mode -1))

(setq inhibit-startup-screen   t
      inhibit-startup-message  t
      initial-scratch-message  nil
      ring-bell-function       'ignore
      frame-resize-pixelwise        t
      frame-inhibit-implied-resize  t
      package-enable-at-startup     nil
      native-comp-async-report-warnings-errors 'silent)

(provide 'early-init)
;;; early-init.el ends here
