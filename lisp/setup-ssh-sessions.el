;;; setup-ssh-sessions.el --- Open SSH connections in vterm tabs -*- lexical-binding: t; -*-

;;; Commentary:
;; See config.org, section "SSH sessions".

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'tab-bar)

(defcustom emacs.d/ssh-config-file
  (expand-file-name "~/.ssh/config")
  "OpenSSH client configuration file used as the source of host aliases."
  :type 'file :group 'emacs.d)

(defcustom emacs.d/ssh-host-environments
  '(("\\`lx[a-z]+0[0-9]" . "production")
    ("\\`lx[a-z]+7[0-9]" . "integration")
    ("\\`lx[a-z]+8[0-9]" . "systemtest")
    ("\\`lx[a-z]+9[0-9]" . "preproduction"))
  "Alist mapping host-name regexps to the environment they belong to.
First match wins.  Consumed by `emacs.d/vterm--mode-line-tramp'
to annotate the SSH chain indicator with a tag like `[PROD]' /
`[INTEG]' / `[SYSTEMTEST]' / `[PREPROD]', rendered with a face
that highlights production sessions (red) versus the other
non-prod environments (subdued).  Empty list = no annotations.

Default reflects this user's host-digit convention: the first
digit of the numeric group after the alphabetic prefix encodes
the environment (0 = prod, 7 = integ, 8 = systemtest, 9 = preprod)."
  :type '(alist :key-type regexp :value-type string)
  :group 'emacs.d)

(defun emacs.d/ssh-env-for-host (host)
  "Return the environment name for HOST, or nil if no entry matches.
Looks HOST up in `emacs.d/ssh-host-environments'."
  (when host
    (cdr (cl-find-if (lambda (entry) (string-match-p (car entry) host))
                     emacs.d/ssh-host-environments))))

(defcustom emacs.d/ssh-target-bastions
  '(("\\`lx[a-z]+0[0-9]"     . "lxsag011")
    ("\\`lx[a-z]+[789][0-9]" . "lxsag811"))
  "Alist mapping target-host regexps to the bastion ssh_config alias
to route through.  Each entry is `(REGEX . BASTION-ALIAS)' where
REGEX is matched against the host name (the part after `@' in
`user@host' notation, or the bare host name) given to
`emacs.d/ssh-sessions-open'.  First match wins.

When you open a session for a target matched here, instead of
`ssh -t target' the command is built as

    ssh -t BASTION sudo -i -u SUDO-USER ssh -t TARGET [sudo -i -u USER]

mirroring the manual sequence a sysadmin would type by hand.  The
bastion's per-host settings (sudo-user, tramp-alias) come from
`emacs.d/ssh-host-tramp-config'.  Targets that match no entry use
plain `ssh' as before.

Default value reflects this user's environment: hosts named
`lxXXX0NN' (digit group starting with 0) are routed through
`lxsag011', `lxXXX7NN' / `lxXXX8NN' / `lxXXX9NN' through
`lxsag811'.  Override via `M-x customize-variable' or
`(setq ...)' for other environments."
  :type '(alist :key-type regexp :value-type string)
  :group 'emacs.d)

(defun emacs.d/ssh-sessions--parse-aliases (file)
  "Return concrete host aliases declared in FILE, omitting wildcards.
Patterns containing `*', `?' or `!' are skipped: they are matched by
ssh at connect time but cannot themselves be connected to, so they
must not appear as picker candidates."
  (when (file-readable-p file)
    (let (aliases)
      (with-temp-buffer
        (insert-file-contents file)
        (goto-char (point-min))
        (while (re-search-forward
                "^[ \t]*Host[ \t]+\\(.+?\\)[ \t]*$" nil t)
          (dolist (token (split-string (match-string 1) "[ \t]+" t))
            (unless (string-match-p "[*?!]" token)
              (push token aliases)))))
      (delete-dups (nreverse aliases)))))

(defun emacs.d/ssh-sessions--parse-input (input)
  "Parse INPUT into (USER . HOST), with USER nil if not given."
  (if (string-match "\\`\\([^@]+\\)@\\(.+\\)\\'" input)
      (cons (match-string 1 input) (match-string 2 input))
    (cons nil input)))

(defun emacs.d/ssh-sessions--bastion-for (host)
  "Return the bastion alias to route HOST through, or nil if HOST
doesn't match anything in `emacs.d/ssh-target-bastions'."
  (cdr (cl-find-if (lambda (entry) (string-match-p (car entry) host))
                   emacs.d/ssh-target-bastions)))

(defun emacs.d/ssh-sessions--build-command (user host bastion)
  "Return the shell command to open the session described by USER, HOST
and BASTION (may be nil for direct connections).

When BASTION is nil: a plain `ssh -t [USER@]HOST'.

When BASTION is set, synthesise the multi-step chain a human would
type by hand: ssh to the bastion, sudo -i to the bastion's SUDO-USER
(from `emacs.d/ssh-host-tramp-config'; default `root'), optionally
ssh again to HOST when it is not the bastion itself, and finally
sudo to USER when USER is given and differs from the post-elevation
identity.

Every ssh hop in the bastion chain carries `-o RemoteCommand=none':
because this function orchestrates elevation explicitly, any
`RemoteCommand sudo -i' inherited from the user's ssh_config (a
CyberArk PSMP convention) would collide with the command we append --
OpenSSH refuses with `Cannot execute command-line and remote command'.
The override is inert when no `RemoteCommand' is set, so it is safe to
apply unconditionally on the bastion path.  The direct (no-bastion)
branch leaves `RemoteCommand' untouched: that branch issues no extra
command, so any `RemoteCommand' in the user's config is free to fire
as part of the host's interactive setup."
  (if (not bastion)
      (cond
       (user (format "ssh -t %s@%s" user host))
       (t    (format "ssh -t %s" host)))
    (let* ((sudo-user    (emacs.d/vterm--tramp-resolved
                          bastion :sudo-user
                          (bound-and-true-p emacs.d/vterm-tramp-sudo-user)))
           (bastion-user (emacs.d/vterm--tramp-resolved
                          bastion :bastion-user
                          (or (bound-and-true-p emacs.d/vterm-tramp-bastion-user)
                              "root")))
           (ssh-opts "-t -o RemoteCommand=none")
           (parts (list (format "ssh %s %s" ssh-opts bastion))))
      (when sudo-user
        (setq parts (append parts (list (format "sudo -i -u %s" sudo-user)))))
      (unless (string-equal host bastion)
        (setq parts (append parts (list (format "ssh %s %s" ssh-opts host)))))
      (when (and user
                 (not (string-equal user (or sudo-user bastion-user))))
        (setq parts (append parts (list (format "sudo -i -u %s" user)))))
      (mapconcat #'identity parts " "))))

;;;###autoload
(defun emacs.d/ssh-sessions-open (input)
  "Open an SSH session in a fresh vterm tab.

INPUT is read from the minibuffer and may take two shapes:

- a bare alias        => direct `ssh -t ALIAS'.  Candidates come
                         from `emacs.d/ssh-config-file' (free text
                         accepted too, so a brand-new alias / IP
                         connects without ceremony).

- `user@host'         => if HOST matches `emacs.d/ssh-target-bastions',
                         the connection is routed through the bastion
                         (with auto sudo elevation declared in
                         `emacs.d/ssh-host-tramp-config') and ends as
                         USER on HOST.  Otherwise: plain `ssh -t user@host'.

Buffer-local state is primed so the TRAMP `default-directory'
auto-sync (in setup-terminal) finds the right bastion as soon as
the prompt parser yields a host."
  (interactive
   (let ((aliases (emacs.d/ssh-sessions--parse-aliases
                   emacs.d/ssh-config-file)))
     (list (completing-read "SSH host (or user@host): " aliases nil nil))))
  (when (string-empty-p input)
    (user-error "No host given"))
  (pcase-let* ((`(,user . ,host) (emacs.d/ssh-sessions--parse-input input))
               (bastion          (emacs.d/ssh-sessions--bastion-for host))
               (cmd     (emacs.d/ssh-sessions--build-command user host bastion))
               (label   input)
               (buf-name (format "*ssh: %s*" label)))
    (tab-bar-new-tab)
    (tab-bar-rename-tab label)

    (require 'vterm)
    (let ((vterm-shell       cmd)
          (vterm-buffer-name buf-name))
      (vterm vterm-buffer-name))

    (with-current-buffer (current-buffer)
      ;; Pre-seed buffer-local state so TRAMP `default-directory'
      ;; auto-sync (in setup-terminal) lands on the right hop chain
      ;; even before the prompt parser has caught the first prompt.
      ;; Stop vterm from renaming the buffer on OSC title escapes:
      ;; setup-terminal already does it from the prompt regex, and
      ;; two competing renamers would race.
      (setq-local emacs.d/vterm-bastion-name (or bastion host)
                  emacs.d/vterm-tab-name     label
                  vterm-buffer-name-string   nil)
      (add-hook 'kill-buffer-hook
                #'emacs.d/vterm-close-tab-on-kill nil t))

    (force-mode-line-update t)))

;;;###autoload
(defun emacs.d/ssh-sessions-edit ()
  "Open `emacs.d/ssh-config-file' for direct editing."
  (interactive)
  (find-file emacs.d/ssh-config-file))

;;;###autoload
(defun emacs.d/ssh-sessions-add ()
  "Append a `Host' template at the end of `emacs.d/ssh-config-file'.
Point lands right after `Host ', ready for the alias name.  The
template lines are pre-inserted but mostly commented out -- save to
keep, kill the buffer without saving to discard the scaffold entirely."
  (interactive)
  (find-file emacs.d/ssh-config-file)
  (goto-char (point-max))
  (unless (bolp) (insert "\n"))
  (let ((stanza-start (point)))
    (insert "\nHost \n"
            "    HostName \n"
            "    User \n"
            "    # Port 22\n"
            "    # IdentityFile ~/.ssh/id_rsa\n"
            "    # ProxyJump some-bastion\n")
    (goto-char stanza-start)
    (forward-line 1)
    (end-of-line)))

(global-set-key (kbd "C-c s s") #'emacs.d/ssh-sessions-open)
(global-set-key (kbd "C-c s a") #'emacs.d/ssh-sessions-add)
(global-set-key (kbd "C-c s e") #'emacs.d/ssh-sessions-edit)

(provide 'setup-ssh-sessions)
;;; setup-ssh-sessions.el ends here
