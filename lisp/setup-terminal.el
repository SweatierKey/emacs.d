;;; setup-terminal.el --- vterm + tab-bar -*- lexical-binding: t; -*-

;;; Commentary:
;; See config.org, section "Terminal: vterm + tab-bar".

;;; Code:

(require 'cl-lib)

(use-package vterm
  :commands (vterm vterm-other-window)
  :custom
  (vterm-max-scrollback     10000)
  (vterm-kill-buffer-on-exit nil)
  (vterm-buffer-name-string "vterm: %s")
  (vterm-shell (or explicit-shell-file-name (getenv "SHELL") "/bin/bash"))
  :bind
  (("C-c v" . vterm)
   :map vterm-mode-map
        ("C-c C-t" . vterm-copy-mode)
        ("C-c f"   . emacs.d/vterm-find-file-remote)))

(use-package tab-bar
  :ensure nil
  :init (setq tab-bar-show               1
              tab-bar-new-tab-choice     "*scratch*"
              tab-bar-close-button-show  nil
              tab-bar-new-button-show    nil)
  :bind
  (("C-x t t" . tab-bar-new-tab)
   ("C-x t k" . tab-bar-close-tab)
   ("C-x t l" . tab-bar-switch-to-next-tab)
   ("C-x t h" . tab-bar-switch-to-prev-tab)
   ("C-x t r" . tab-bar-rename-tab))
  :config (tab-bar-mode 1))

(defvar-local emacs.d/vterm-bastion-name nil
  "Bastion / jump host this vterm session was opened against.
Set by `setup-ssh-sessions' at session creation; static thereafter.")

(defvar-local emacs.d/vterm-current-host nil
  "Hostname extracted from the most recent visible shell prompt.")

(defvar-local emacs.d/vterm-current-user nil
  "User name extracted from the most recent visible shell prompt.
Lets the TRAMP path chain an extra `|sudo:USER' hop when the
session has elevated/deescalated via `sudo su -' on the target.")

(defvar-local emacs.d/vterm-current-path nil
  "Working directory extracted from the most recent visible shell prompt.
Nil when PS1 does not expose a cwd, or before the first prompt has
been drawn.")

(defvar-local emacs.d/vterm-tab-name nil
  "Last tab title applied for this vterm buffer.
Used to find the right tab to rename when the prompt host changes.")

(defcustom emacs.d/vterm-prompt-host-regexp
  "^\\([[:alnum:]_.-]+\\)@\\([[:alnum:]_.-]+\\)\\(?::\\([^[:space:]\n]+?\\)\\)?[ \t]*[$#%>]"
  "Regexp used to extract user, host and cwd from the visible shell prompt.
Capture groups in order: USER (group 1), HOST (group 2), CWD
(group 3, optional).  The regexp is anchored at column zero, so a
non-standard PS1 that indents the prompt will not match -- customise
this if your environment is unusual."
  :type 'regexp :group 'emacs.d)

(defcustom emacs.d/vterm-tramp-sudo-user "root"
  "User TRAMP must sudo into immediately after the ssh hop to the bastion.
Mirrors the `RemoteCommand sudo -i' that the interactive ssh_config
typically runs on a CyberArk-style bastion: the interactive shell is
already root, but TRAMP's own ssh invocation needs the equivalent
step expressed as a hop.  Set to nil to disable."
  :type '(choice (const :tag "No sudo on bastion" nil) string)
  :group 'emacs.d)

(defcustom emacs.d/vterm-tramp-bastion-user "root"
  "User the session is expected to be running as after the bastion sudo.
Used to decide whether an *extra* `|sudo:USER' hop is needed on
top of the basic chain: if the prompt's user differs from this
(typically because of `sudo su - oracle' on the target host) the
chain grows by one final sudo hop to reach that user."
  :type 'string :group 'emacs.d)

(defcustom emacs.d/vterm-tramp-auto-sync t
  "When non-nil, continuously sync `default-directory' of session vterms
to a TRAMP path matching the prompt-derived remote location.  This
makes `C-x C-f', dired, magit, `compile' and `M-!' from the vterm
buffer all target the remote machine.  Set to nil to leave
`default-directory' alone and cross to the remote only on demand,
through `emacs.d/vterm-find-file-remote' (bound to `C-c f' in
vterm-mode)."
  :type 'boolean :group 'emacs.d)

(defun emacs.d/vterm-extract-prompt-context ()
  "Return (USER HOST PATH) from the most recent prompt, or nil.
Each element may be nil if its capture group did not match.  Scans
back at most 50 lines from `point-max'."
  (save-excursion
    (goto-char (point-max))
    (let ((window-start (max (point-min)
                             (save-excursion (forward-line -50) (point)))))
      (when (re-search-backward emacs.d/vterm-prompt-host-regexp
                                window-start t)
        (list (match-string-no-properties 1)
              (match-string-no-properties 2)
              (and (match-beginning 3) (match-string-no-properties 3)))))))

(defun emacs.d/vterm--tramp-default-directory ()
  "Compose the TRAMP path matching the current session prompt, or nil.
Builds `/ssh:BASTION[|sudo:U1][|ssh:TARGET][|sudo:U2]:CWD/' from
the buffer-local state.  Returns nil when bastion, host or cwd are
still unknown (so callers can skip the sync gracefully)."
  (let ((bastion emacs.d/vterm-bastion-name)
        (host    emacs.d/vterm-current-host)
        (user    emacs.d/vterm-current-user)
        (path    emacs.d/vterm-current-path))
    (when (and bastion host path)
      (let* ((sudo-on-bastion
              (and emacs.d/vterm-tramp-sudo-user
                   (format "|sudo:%s" emacs.d/vterm-tramp-sudo-user)))
             (extra-ssh
              (and (not (string-equal host bastion))
                   (format "|ssh:%s" host)))
             (extra-sudo
              ;; Add another sudo only when the prompt's user is not
              ;; the post-bastion default -- typically because of a
              ;; `sudo su - oracle' on the target.  Only meaningful
              ;; once we have hopped past the bastion.
              (and user
                   extra-ssh
                   (not (string-equal
                         user emacs.d/vterm-tramp-bastion-user))
                   (format "|sudo:%s" user))))
        (format "/ssh:%s%s%s%s:%s"
                bastion
                (or sudo-on-bastion "")
                (or extra-ssh        "")
                (or extra-sudo       "")
                (file-name-as-directory path))))))

(defun emacs.d/tab-bar-rename-tab-by-name (old-name new-name)
  "Rename the tab named OLD-NAME to NEW-NAME on the selected frame.
Returns non-nil on success, nil if no tab has OLD-NAME."
  (let* ((tabs (funcall tab-bar-tabs-function))
         (idx  (cl-position old-name tabs
                            :key  (lambda (tab) (alist-get 'name tab))
                            :test #'string-equal)))
    (when idx
      ;; tab-bar-rename-tab is 1-based; passing the index is required so
      ;; we do not accidentally rename whichever tab is currently selected.
      (tab-bar-rename-tab new-name (1+ idx))
      t)))

(defun emacs.d/vterm--compose-buffer-name (tab-name path)
  "Return the buffer name to install for TAB-NAME (and optional PATH).
Format: `*ssh: TAB-NAME[ — PATH]*'."
  (if path
      (format "*ssh: %s — %s*" tab-name path)
    (format "*ssh: %s*" tab-name)))

(defun emacs.d/vterm-update-current-host (&rest _ignored)
  "Refresh user/host/path from the prompt and rename tab + buffer, then
optionally sync `default-directory' to the matching TRAMP path.
The tab name only tracks the *host* (stable identity of the SSH
session), the buffer name additionally reflects the *cwd*, and the
TRAMP-derived `default-directory' also tracks the current *user* --
in increasing order of volatility.  Hooked as `:after' advice on
`vterm--filter'."
  (when (derived-mode-p 'vterm-mode)
    (let* ((ctx      (emacs.d/vterm-extract-prompt-context))
           (new-user (nth 0 ctx))
           (new-host (nth 1 ctx))
           (new-path (nth 2 ctx)))
      (when new-host
        (let ((host-changed (not (equal new-host emacs.d/vterm-current-host)))
              (user-changed (not (equal new-user emacs.d/vterm-current-user)))
              (path-changed (not (equal new-path emacs.d/vterm-current-path))))
          (when host-changed (setq-local emacs.d/vterm-current-host new-host))
          (when user-changed (setq-local emacs.d/vterm-current-user new-user))
          (when path-changed (setq-local emacs.d/vterm-current-path new-path))
          (when (and emacs.d/vterm-tab-name
                     (or host-changed user-changed path-changed))
            (let* ((bastion      emacs.d/vterm-bastion-name)
                   (new-tab-name (if bastion
                                     (format "%s: %s" bastion new-host)
                                   new-host))
                   (new-buf-name (emacs.d/vterm--compose-buffer-name
                                  new-tab-name new-path)))
              (when (and (bound-and-true-p tab-bar-mode)
                         (not (string-equal new-tab-name
                                            emacs.d/vterm-tab-name))
                         (emacs.d/tab-bar-rename-tab-by-name
                          emacs.d/vterm-tab-name new-tab-name))
                (setq-local emacs.d/vterm-tab-name new-tab-name))
              (unless (string-equal new-buf-name (buffer-name))
                ;; `t' makes the new name unique on collision (e.g. two
                ;; sessions land on the same alias + cwd at once).
                (rename-buffer new-buf-name t))
              (when emacs.d/vterm-tramp-auto-sync
                (when-let ((td (emacs.d/vterm--tramp-default-directory)))
                  (unless (string-equal td default-directory)
                    (setq-local default-directory td)))))))))))

;;;###autoload
(defun emacs.d/vterm-find-file-remote ()
  "Open `find-file' with `default-directory' bound to this session's
TRAMP path.  Use when `emacs.d/vterm-tramp-auto-sync' is nil, or
to cross to the remote just for this one command from a buffer
whose `default-directory' is still local."
  (interactive)
  (let ((td (emacs.d/vterm--tramp-default-directory)))
    (unless td
      (user-error
       "Cannot derive a TRAMP path: missing bastion/host/cwd for this session"))
    (let ((default-directory td))
      (call-interactively #'find-file))))

(with-eval-after-load 'vterm
  (advice-add 'vterm--filter :after #'emacs.d/vterm-update-current-host))

(defun emacs.d/vterm-handle-exit (buf _event)
  "Make `q' kill BUF and mark its mode line `[exited]' once vterm dies."
  (when (buffer-live-p buf)
    (with-current-buffer buf
      (let ((map (make-sparse-keymap)))
        (set-keymap-parent map (current-local-map))
        (define-key map (kbd "q") #'kill-current-buffer)
        (use-local-map map))
      (setq-local mode-line-process
                  (propertize " [exited]" 'face 'shadow))
      (force-mode-line-update))))

(with-eval-after-load 'vterm
  (add-hook 'vterm-exit-functions #'emacs.d/vterm-handle-exit))

(defun emacs.d/vterm-close-tab-on-kill ()
  "Close the tab hosting this buffer when it is killed.
Installed buffer-locally by `setup-ssh-sessions' on session vterms.
Refuses to close the last surviving tab."
  (when (and (bound-and-true-p tab-bar-mode)
             emacs.d/vterm-tab-name)
    (let* ((tabs (funcall tab-bar-tabs-function))
           (idx  (cl-position emacs.d/vterm-tab-name tabs
                              :key  (lambda (tab) (alist-get 'name tab))
                              :test #'string-equal)))
      (when (and idx (> (length tabs) 1))
        ;; Defer the close: doing it from inside `kill-buffer-hook'
        ;; can leave the buffer-list traversal in an inconsistent state.
        (run-at-time 0 nil #'tab-bar-close-tab (1+ idx))))))

(provide 'setup-terminal)
;;; setup-terminal.el ends here
