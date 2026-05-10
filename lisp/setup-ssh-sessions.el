;;; setup-ssh-sessions.el --- Open SSH connections in vterm tabs -*- lexical-binding: t; -*-

;;; Commentary:
;; See config.org, section "SSH sessions".

;;; Code:

(require 'subr-x)
(require 'tab-bar)

(defcustom emacs.d/ssh-config-file
  (expand-file-name "~/.ssh/config")
  "OpenSSH client configuration file used as the source of host aliases."
  :type 'file :group 'emacs.d)

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

;;;###autoload
(defun emacs.d/ssh-sessions-open (host)
  "Open an SSH session to HOST in a fresh tab running vterm.
Candidates come from `emacs.d/ssh-config-file' but any string is
accepted, so a brand-new alias (or a literal hostname/IP) connects
straight away through whatever defaults `~/.ssh/config' provides."
  (interactive
   (let ((aliases (emacs.d/ssh-sessions--parse-aliases
                   emacs.d/ssh-config-file)))
     (list (completing-read "SSH host: " aliases nil nil))))
  (when (string-empty-p host)
    (user-error "No host given"))
  (let ((cmd      (format "ssh -t %s" host))
        (buf-name (format "*ssh: %s*" host)))
    (tab-bar-new-tab)
    (tab-bar-rename-tab host)

    (require 'vterm)
    (let ((vterm-shell       cmd)
          (vterm-buffer-name buf-name))
      (vterm vterm-buffer-name))

    (with-current-buffer (current-buffer)
      ;; Stop vterm from renaming the buffer on OSC title escapes:
      ;; setup-terminal already does it from the prompt regex, and
      ;; two competing renamers would race.
      (setq-local emacs.d/vterm-bastion-name host
                  emacs.d/vterm-tab-name     host
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
            "    # ProxyJump some-bastion\n"
            "    # RemoteCommand sudo su -\n"
            "    # RequestTTY force\n")
    (goto-char stanza-start)
    (forward-line 1)
    (end-of-line)))

(global-set-key (kbd "C-c s s") #'emacs.d/ssh-sessions-open)
(global-set-key (kbd "C-c s a") #'emacs.d/ssh-sessions-add)
(global-set-key (kbd "C-c s e") #'emacs.d/ssh-sessions-edit)

(provide 'setup-ssh-sessions)
;;; setup-ssh-sessions.el ends here
