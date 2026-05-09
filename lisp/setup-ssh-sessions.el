;;; setup-ssh-sessions.el --- Saved SSH sessions in vterm tabs -*- lexical-binding: t; -*-

;;; Commentary:
;; See config.org, section "SSH sessions".

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'tab-bar)

(defcustom emacs.d/ssh-sessions-file
  (expand-file-name "var/ssh-sessions.el" user-emacs-directory)
  "File where SSH session definitions are persisted."
  :type 'file :group 'emacs.d)

(defvar emacs.d/ssh-sessions nil
  "In-memory list of SSH session plists.")

(defun emacs.d/ssh-sessions--seed-file (file)
  "Write a starter list with one example session to FILE."
  (make-directory (file-name-directory file) t)
  (with-temp-file file
    (insert ";; -*- lexical-binding: t; -*-\n"
            ";; SSH sessions for `setup-ssh-sessions'.\n"
            ";; Each entry is a plist; see config.org for the schema.\n\n"
            "(\n"
            "  (:name \"example-bastion\"\n"
            "   :host \"bastion.example.com\"\n"
            "   :user \"myuser\"\n"
            "   :port 22\n"
            "   :group \"Examples\"\n"
            "   :description \"Sample entry; replace me.\")\n"
            ")\n")))

(defun emacs.d/ssh-sessions-load ()
  "Load `emacs.d/ssh-sessions' from `emacs.d/ssh-sessions-file'."
  (let ((file emacs.d/ssh-sessions-file))
    (unless (file-exists-p file)
      (emacs.d/ssh-sessions--seed-file file))
    (with-temp-buffer
      (insert-file-contents file)
      (goto-char (point-min))
      (setq emacs.d/ssh-sessions (read (current-buffer))))))

(defun emacs.d/ssh-sessions-save ()
  "Write `emacs.d/ssh-sessions' back to disk as pretty-printed Lisp."
  (let ((file emacs.d/ssh-sessions-file))
    (make-directory (file-name-directory file) t)
    (with-temp-file file
      (insert ";; -*- lexical-binding: t; -*-\n"
              ";; SSH sessions for `setup-ssh-sessions'.\n\n")
      (let ((print-length nil) (print-level nil))
        (pp emacs.d/ssh-sessions (current-buffer))))))

(defun emacs.d/ssh-sessions--ensure-loaded ()
  (unless emacs.d/ssh-sessions (emacs.d/ssh-sessions-load)))

(defun emacs.d/ssh-sessions--find (name)
  (cl-find name emacs.d/ssh-sessions
           :key  (lambda (s) (plist-get s :name))
           :test #'string-equal))

(defun emacs.d/ssh-sessions--build-command (session)
  "Return the shell command string used to launch SESSION.
If SESSION provides a `:command' field it wins verbatim, otherwise we
synthesise a plain `ssh [-p PORT] [USER@]HOST' invocation."
  (or (plist-get session :command)
      (let ((host (plist-get session :host))
            (user (plist-get session :user))
            (port (plist-get session :port))
            (parts '("ssh")))
        (when port
          (setq parts (append parts (list "-p" (format "%s" port)))))
        (setq parts (append parts (list (if user
                                            (format "%s@%s" user host)
                                          host))))
        (mapconcat #'identity parts " "))))

(defun emacs.d/ssh-sessions--annotation (cand)
  "Annotation function passed to `completing-read'."
  (when-let ((session (emacs.d/ssh-sessions--find cand)))
    (let ((host  (plist-get session :host))
          (group (plist-get session :group))
          (descr (plist-get session :description)))
      (concat
       (when host  (format "  %s" host))
       (when group (format "  [%s]" group))
       (when descr (format "  -- %s" descr))))))

(defun emacs.d/ssh-sessions--read-optional (prompt)
  "Read a string for PROMPT and return it, or nil if empty."
  (let ((s (read-string prompt)))
    (and (not (string-empty-p s)) s)))

(defun emacs.d/ssh-sessions--reload-after-save ()
  "Buffer-local `after-save-hook' for the storage file: reload sessions."
  (when (and buffer-file-name
             (string-equal (expand-file-name buffer-file-name)
                           (expand-file-name emacs.d/ssh-sessions-file)))
    (emacs.d/ssh-sessions-load)
    (message "SSH sessions reloaded (%d entries)."
             (length emacs.d/ssh-sessions))))

;;;###autoload
(defun emacs.d/ssh-sessions-open (name)
  "Open the saved SSH session NAME in a new tab running vterm."
  (interactive
   (progn
     (emacs.d/ssh-sessions--ensure-loaded)
     (unless emacs.d/ssh-sessions
       (user-error "No SSH sessions defined; use M-x emacs.d/ssh-sessions-add"))
     (let* ((completion-extra-properties
             '(:annotation-function emacs.d/ssh-sessions--annotation))
            (names (mapcar (lambda (s) (plist-get s :name))
                           emacs.d/ssh-sessions)))
       (list (completing-read "SSH session: " names nil t)))))
  (emacs.d/ssh-sessions--ensure-loaded)
  (let* ((session (emacs.d/ssh-sessions--find name))
         (cmd     (and session (emacs.d/ssh-sessions--build-command session)))
         (buf-name (format "*ssh: %s*" name)))
    (unless session (user-error "Session %S not found" name))

    (tab-bar-new-tab)
    (tab-bar-rename-tab name)

    (require 'vterm)
    (let ((vterm-shell        cmd)
          (vterm-buffer-name  buf-name))
      (vterm vterm-buffer-name))

    (with-current-buffer (current-buffer)
      (setq-local emacs.d/vterm-bastion-name name
                  emacs.d/vterm-tab-name     name)
      (add-hook 'kill-buffer-hook
                #'emacs.d/vterm-close-tab-on-kill nil t))

    (force-mode-line-update t)))

;;;###autoload
(defun emacs.d/ssh-sessions-add ()
  "Interactively define a new SSH session and persist it."
  (interactive)
  (emacs.d/ssh-sessions--ensure-loaded)
  (let* ((name (read-string "Session name (unique): ")))
    (when (emacs.d/ssh-sessions--find name)
      (user-error "A session named %S already exists" name))
    (let* ((host  (read-string "Host: "))
           (user  (emacs.d/ssh-sessions--read-optional "User (RET to skip): "))
           (port  (let ((p (read-string "Port (RET for default 22): ")))
                    (and (not (string-empty-p p)) (string-to-number p))))
           (group (emacs.d/ssh-sessions--read-optional "Group (RET to skip): "))
           (descr (emacs.d/ssh-sessions--read-optional
                   "Description (RET to skip): "))
           (session (apply #'list
                           :name name :host host
                           (append
                            (when user  (list :user user))
                            (when port  (list :port port))
                            (when group (list :group group))
                            (when descr (list :description descr))))))
      (setq emacs.d/ssh-sessions (append emacs.d/ssh-sessions (list session)))
      (emacs.d/ssh-sessions-save)
      (message "Session %S saved.  M-x emacs.d/ssh-sessions-open to launch."
               name))))

;;;###autoload
(defun emacs.d/ssh-sessions-edit ()
  "Open the session storage file for direct Lisp editing."
  (interactive)
  (emacs.d/ssh-sessions--ensure-loaded)
  (find-file emacs.d/ssh-sessions-file)
  (add-hook 'after-save-hook #'emacs.d/ssh-sessions--reload-after-save nil t))

(global-set-key (kbd "C-c s s") #'emacs.d/ssh-sessions-open)
(global-set-key (kbd "C-c s a") #'emacs.d/ssh-sessions-add)
(global-set-key (kbd "C-c s e") #'emacs.d/ssh-sessions-edit)

(provide 'setup-ssh-sessions)
;;; setup-ssh-sessions.el ends here
