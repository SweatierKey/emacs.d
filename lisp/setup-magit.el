;;; setup-magit.el --- Git porcelain via Magit -*- lexical-binding: t; -*-

;; Magit is the most polished Git interface in any editor, period.  This
;; module installs it and wires up the two universally-expected
;; bindings -- everything else is discoverable from inside Magit itself
;; via `?'.
;;
;; The only customisation here is to keep things quiet:
;;   * we tell Magit not to show the splash buffer the first time you run
;;     it,
;;   * we ask the status buffer to refresh from a hook we control rather
;;     than from a slow `find-file' hook that fires for every visited
;;     file in a Git repo.

;;; Code:

(use-package magit
  ;; If you've never used Magit before: open a buffer inside a Git repo
  ;; and press `C-x g'.  That gets you the status buffer, which is the
  ;; entry point to everything else.  In the status buffer:
  ;;
  ;;     s    stage the section under point
  ;;     u    unstage
  ;;     c c  start a commit
  ;;     P p  push  (push transient)
  ;;     F p  pull
  ;;     l l  log
  ;;     b b  switch branch
  ;;     ?    list every binding
  :bind
  (("C-x g"   . magit-status)
   ("C-x M-g" . magit-dispatch))     ;; "any other Magit transient I forgot"
  :custom
  (magit-define-global-key-bindings nil)   ;; we set our own above
  (magit-save-repository-buffers 'dontask)  ;; auto-save before refreshing
  (magit-refresh-status-buffer t)
  ;; Show recent commits inline in the status buffer; helps you remember
  ;; where you are without running `magit-log' every time.
  (magit-log-section-commit-count 10)
  :config
  ;; Magit binds `<tab>' to `magit-section-toggle' which conflicts with
  ;; nothing, but worth mentioning: hit TAB on any section header (like
  ;; "Untracked files") to fold/unfold it.
  )

(provide 'setup-magit)
;;; setup-magit.el ends here
