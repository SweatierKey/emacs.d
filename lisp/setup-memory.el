;;; setup-memory.el --- GC and memory tuning -*- lexical-binding: t; -*-

;;; Commentary:
;; See config.org, section "Memory and GC".

;;; Code:

(use-package gcmh
  :diminish gcmh-mode
  :init
  (setq gcmh-idle-delay              'auto
        gcmh-auto-idle-delay-factor  10
        gcmh-high-cons-threshold     (* 16 1024 1024))
  :hook (emacs-startup . gcmh-mode))

(setq read-process-output-max         (* 1024 1024)
      process-adaptive-read-buffering nil)

(setq history-length            1000
      history-delete-duplicates t
      kill-ring-max             300
      mark-ring-max             50
      global-mark-ring-max      50)

(setq undo-limit          (* 4  1024 1024)
      undo-strong-limit   (* 6  1024 1024)
      undo-outer-limit    (* 64 1024 1024))

(setq large-file-warning-threshold (* 100 1024 1024))

(provide 'setup-memory)
;;; setup-memory.el ends here
