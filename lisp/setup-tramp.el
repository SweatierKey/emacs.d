;;; setup-tramp.el --- Remote editing over SSH -*- lexical-binding: t; -*-

;; TRAMP lets you edit remote files transparently.  You type
;;
;;     C-x C-f /ssh:user@host:/etc/nginx/nginx.conf
;;
;; and Emacs opens the remote file as if it were local.  Magit, dired,
;; eshell, projects -- all of them work over TRAMP without changes.
;;
;; The defaults are conservative: TRAMP is paranoid about staleness, runs
;; small probes for every operation, and re-establishes the SSH connection
;; more often than a human would.  This module trades a bit of paranoia
;; for a *much* faster experience over SSH, while keeping the security
;; properties of plain `ssh' (we never disable host key checking).
;;
;; Pre-requisites on your local machine:
;;
;;   * a working `ssh' on `PATH' (Emacs uses your system SSH client),
;;   * an `~/.ssh/config' with `ControlMaster auto' and `ControlPersist'
;;     for the hosts you visit often.  Example block:
;;
;;         Host *
;;             ControlMaster auto
;;             ControlPath   ~/.ssh/cm-%r@%h:%p
;;             ControlPersist 10m
;;             ServerAliveInterval 60
;;
;; With ControlMaster set up, every TRAMP operation reuses the same SSH
;; connection, which is the single biggest speed win.

;;; Code:

(use-package tramp
  :ensure nil               ;; built in
  :defer t                  ;; only load when you actually open a remote file
  :custom

  ;; -----------------------------------------------------------------------
  ;; Default method
  ;; -----------------------------------------------------------------------
  ;;
  ;; `ssh' is fast, plain, and uses your system OpenSSH (so all your
  ;; `~/.ssh/config' tweaks Just Work).  `scp' is slightly faster for
  ;; one-off file fetches but doesn't share the SSH ControlMaster, so
  ;; `ssh' is the better default.
  (tramp-default-method "ssh")

  ;; -----------------------------------------------------------------------
  ;; Don't print "Connecting to host..." spam
  ;; -----------------------------------------------------------------------
  (tramp-verbose 1)         ;; default is 3; 1 silences most progress noise.
                            ;; Bump back to 6 when debugging a connection.

  ;; -----------------------------------------------------------------------
  ;; Persistent connection state
  ;; -----------------------------------------------------------------------
  ;;
  ;; TRAMP caches "remote process environment" facts to a file so that
  ;; reconnecting to a host after restart is fast.
  (tramp-persistency-file-name
   (expand-file-name "var/tramp" user-emacs-directory))

  ;; -----------------------------------------------------------------------
  ;; Don't keep version-control info for remote files
  ;; -----------------------------------------------------------------------
  ;;
  ;; The built-in vc.el probes every visited file for VCS metadata, which
  ;; over a slow network turns into many small SSH calls.  Magit operates
  ;; through a single SSH connection and is much faster, so we just turn
  ;; the per-file VC probing off for remote files.
  (vc-handled-backends '(Git))            ;; only Git, no CVS/RCS/SVN/...

  ;; -----------------------------------------------------------------------
  ;; Faster directory listings
  ;; -----------------------------------------------------------------------
  ;;
  ;; TRAMP uses a series of probes to discover what `ls' on the remote
  ;; understands.  Caching the result avoids redoing the probes on every
  ;; reconnection.
  (tramp-completion-reread-directory-timeout nil)

  :config

  ;; -----------------------------------------------------------------------
  ;; Don't track remote files in the recent-files / save-place lists
  ;; -----------------------------------------------------------------------
  ;;
  ;; They tend to expire (host changes IP, name changes), and probing them
  ;; on startup is slow.  Keep the recent-files list local-only.
  (with-eval-after-load 'recentf
    (add-to-list 'recentf-exclude
                 (lambda (f) (file-remote-p f))))

  (with-eval-after-load 'saveplace
    (defun emacs.d/save-place-skip-remote (orig-fn &rest args)
      "Skip `save-place' bookkeeping for remote files."
      (unless (and buffer-file-name (file-remote-p buffer-file-name))
        (apply orig-fn args)))
    (advice-add 'save-place-to-alist :around #'emacs.d/save-place-skip-remote))

  ;; -----------------------------------------------------------------------
  ;; Disable file-name handlers TRAMP doesn't need on remote paths
  ;; -----------------------------------------------------------------------
  ;;
  ;; The built-in `tramp-archive' handler matches archive members
  ;; (foo.tar.gz inside a remote dir) but is rarely useful and slows down
  ;; every remote `find-file'.  Loading is deferred so this is safe even
  ;; if you do want it later -- just `M-x tramp-archive-cleanup' first.
  (setq tramp-archive-enabled nil)

  ;; -----------------------------------------------------------------------
  ;; Use the remote `PATH'
  ;; -----------------------------------------------------------------------
  ;;
  ;; By default TRAMP uses a sanitised PATH that often misses tools the
  ;; remote shell would find (homebrew, asdf, mise, ...).  Append the
  ;; remote login shell's PATH so commands like `git' or `node' resolve.
  (add-to-list 'tramp-remote-path 'tramp-own-remote-path)

  ;; -----------------------------------------------------------------------
  ;; Don't auto-save remote files locally
  ;; -----------------------------------------------------------------------
  ;;
  ;; Auto-saving over SSH is slow and the local copy of an auto-save
  ;; defeats the point of editing remotely.  We disable it -- you still
  ;; have full undo, and `C-x C-s' to save explicitly.
  (setq remote-file-name-inhibit-auto-save-visited t))

(provide 'setup-tramp)
;;; setup-tramp.el ends here
