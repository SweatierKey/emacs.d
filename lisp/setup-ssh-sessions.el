;;; setup-ssh-sessions.el --- Saved SSH sessions, opened in vterm tabs -*- lexical-binding: t; -*-

;; A small "session manager" inspired by what tools like MobaXterm,
;; Termius, or PuTTY's saved sessions provide -- but built natively on
;; top of `vterm' and `tab-bar-mode'.
;;
;; The model:
;;
;;   * A session is an Emacs plist with a few fields:
;;
;;       (:name        "prod-bastion-1"      ; required, unique
;;        :host        "bastion1.acme.com"   ; required
;;        :user        "myuser"              ; optional, defaults to local user
;;        :port        22                    ; optional
;;        :command     "ssh ..."             ; optional, full command override
;;        :group       "Production"          ; optional, used for grouping/filter
;;        :description "CyberArk PSMP entry to prod tier")
;;
;;   * Sessions are stored in `emacs.d/ssh-sessions-file' (defaults to
;;     `var/ssh-sessions.el' under `user-emacs-directory').  The file is
;;     git-ignored, since it usually contains hostnames internal to your
;;     org.
;;
;;   * `emacs.d/ssh-sessions-open' (bound to `C-c s s' by default) prompts
;;     for a session via `completing-read' (which uses Vertico if the
;;     completion module is loaded), then opens it in a fresh tab whose
;;     title is the session name.  As soon as the remote prompt is
;;     visible, `setup-terminal' will append the current hostname to the
;;     title (e.g. "prod-bastion-1: db04").
;;
;;   * `emacs.d/ssh-sessions-add' (`C-c s a') interactively defines a
;;     new session and persists it.
;;
;;   * `emacs.d/ssh-sessions-edit' (`C-c s e') jumps to the storage
;;     file so you can edit it as a plain Lisp value.
;;
;; Connection method:
;;
;;   We use `vterm' running plain `ssh' rather than TRAMP because the
;;   real-life flow involves CyberArk PSMP and other interactive prompts
;;   (MFA, password change, banner acks) that don't fit TRAMP's model.
;;   You'll just type your password as you do today; the saving is in
;;   never having to remember the host, the user, or the right port.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'tab-bar)

;; ---------------------------------------------------------------------------
;; Storage
;; ---------------------------------------------------------------------------

(defcustom emacs.d/ssh-sessions-file
  (expand-file-name "var/ssh-sessions.el" user-emacs-directory)
  "File where SSH session definitions are persisted.
The file should contain a single Lisp form: a list of plists.  See the
header of `setup-ssh-sessions.el' for the expected fields.

The default location is under `var/' which is git-ignored, so personal
hostnames don't accidentally end up in a public repo."
  :group 'emacs.d
  :type 'file)

(defvar emacs.d/ssh-sessions nil
  "In-memory list of SSH session plists.
Loaded from `emacs.d/ssh-sessions-file' on first access via
`emacs.d/ssh-sessions-load'.")

(defun emacs.d/ssh-sessions-load ()
  "Read `emacs.d/ssh-sessions-file' into `emacs.d/ssh-sessions'.
Returns the list of sessions.  Creates an empty file if it doesn't
exist yet so you can edit it without an extra step."
  (let ((file emacs.d/ssh-sessions-file))
    (unless (file-exists-p file)
      (make-directory (file-name-directory file) t)
      (with-temp-file file
        (insert ";; -*- lexical-binding: t; -*-\n")
        (insert ";; SSH sessions for `setup-ssh-sessions'.\n")
        (insert ";; Each entry is a plist with at least :name and :host.\n")
        (insert ";; See ~/.emacs.d/lisp/setup-ssh-sessions.el for the full schema.\n\n")
        (insert "(\n")
        (insert "  ;; Example -- delete or replace with your real sessions.\n")
        (insert "  (:name \"example-bastion\"\n")
        (insert "   :host \"bastion.example.com\"\n")
        (insert "   :user \"myuser\"\n")
        (insert "   :port 22\n")
        (insert "   :group \"Examples\"\n")
        (insert "   :description \"Sample entry; replace me.\")\n")
        (insert ")\n")))
    (with-temp-buffer
      (insert-file-contents file)
      (goto-char (point-min))
      (setq emacs.d/ssh-sessions (read (current-buffer))))))

(defun emacs.d/ssh-sessions-save ()
  "Write `emacs.d/ssh-sessions' back to `emacs.d/ssh-sessions-file' as
a pretty-printed Lisp form.  Existing comments at the top of the file
are *not* preserved -- the file is rewritten in full -- so prefer
editing the file directly with `emacs.d/ssh-sessions-edit' if you want
to keep prose around."
  (let ((file emacs.d/ssh-sessions-file))
    (make-directory (file-name-directory file) t)
    (with-temp-file file
      (insert ";; -*- lexical-binding: t; -*-\n")
      (insert ";; SSH sessions for `setup-ssh-sessions'.\n\n")
      (let ((print-length nil)
            (print-level  nil))
        (pp emacs.d/ssh-sessions (current-buffer))))))

(defun emacs.d/ssh-sessions--ensure-loaded ()
  "Load sessions from disk if `emacs.d/ssh-sessions' is still nil."
  (unless emacs.d/ssh-sessions
    (emacs.d/ssh-sessions-load)))

;; ---------------------------------------------------------------------------
;; Building the SSH command
;; ---------------------------------------------------------------------------

(defun emacs.d/ssh-sessions--build-command (session)
  "Return the shell command string to launch SESSION.

If SESSION provides an explicit `:command' string we use that verbatim
-- handy for sessions that go through a wrapper (CyberArk PSMP, a
ProxyJump chain, a kerberized `ssh' wrapper, ...).  Otherwise we
synthesise a plain `ssh -p PORT USER@HOST' command from the fields."
  (or (plist-get session :command)
      (let* ((host (plist-get session :host))
             (user (plist-get session :user))
             (port (plist-get session :port))
             (parts (list "ssh")))
        (when port (setq parts (append parts (list "-p" (format "%s" port)))))
        (setq parts (append parts (list (if user (format "%s@%s" user host) host))))
        (mapconcat #'identity parts " "))))

;; ---------------------------------------------------------------------------
;; Commands
;; ---------------------------------------------------------------------------

(defun emacs.d/ssh-sessions--annotation (cand)
  "Annotation function for `completing-read': show host (and group, if
set) next to the session name."
  (let* ((session (cl-find cand emacs.d/ssh-sessions
                           :key (lambda (s) (plist-get s :name))
                           :test #'string-equal))
         (host    (plist-get session :host))
         (group   (plist-get session :group))
         (descr   (plist-get session :description)))
    (concat
     (when host  (format "  %s" host))
     (when group (format "  [%s]" group))
     (when descr (format "  -- %s" descr)))))

;;;###autoload
(defun emacs.d/ssh-sessions-open (name)
  "Open the saved SSH session NAME in a new tab running vterm.

When called interactively, prompt with completion over the names in
`emacs.d/ssh-sessions'.  Annotations show the host, group and
description -- so you can search by any of them with Orderless."
  (interactive
   (progn
     (emacs.d/ssh-sessions--ensure-loaded)
     (unless emacs.d/ssh-sessions
       (user-error "No SSH sessions defined.  Use M-x emacs.d/ssh-sessions-add"))
     (let* ((completion-extra-properties
             '(:annotation-function emacs.d/ssh-sessions--annotation))
            (names (mapcar (lambda (s) (plist-get s :name))
                           emacs.d/ssh-sessions)))
       (list (completing-read "SSH session: " names nil t)))))
  (emacs.d/ssh-sessions--ensure-loaded)
  (let* ((session (cl-find name emacs.d/ssh-sessions
                           :key (lambda (s) (plist-get s :name))
                           :test #'string-equal))
         (cmd     (emacs.d/ssh-sessions--build-command session))
         (buf     (generate-new-buffer (format "*ssh: %s*" name))))
    (unless session
      (user-error "Session %S not found" name))

    ;; Open in a fresh tab so each session is visually separated; the
    ;; tab title is "BASTION: HOST" -- BASTION being NAME (set below as
    ;; a buffer-local) and HOST extracted from the prompt by
    ;; `setup-terminal' once the connection is up.
    (tab-bar-new-tab)

    ;; Now spin up vterm in the freshly-created tab.  We set the shell
    ;; for this single buffer to our SSH command via a let-binding of
    ;; `vterm-shell' -- vterm reads it at buffer creation time.
    (require 'vterm)
    (let ((vterm-shell        cmd)
          (vterm-buffer-name  (buffer-name buf)))
      (kill-buffer buf)        ;; placeholder, let vterm create its own
      (vterm vterm-buffer-name))

    ;; Mark the freshly-created vterm buffer with the bastion name so
    ;; the dynamic tab title can pick it up.
    (with-current-buffer (current-buffer)
      (setq-local emacs.d/vterm-bastion-name name))

    (force-mode-line-update t)))

;;;###autoload
(defun emacs.d/ssh-sessions-add ()
  "Interactively define a new SSH session and persist it.
Prompts for name, host, user (optional), port (optional) and a free-form
description.  More advanced fields (`:command', `:group') are easier to
add by editing the storage file directly via
`emacs.d/ssh-sessions-edit'."
  (interactive)
  (emacs.d/ssh-sessions--ensure-loaded)
  (let* ((name (read-string "Session name (unique): "))
         (_    (when (cl-find name emacs.d/ssh-sessions
                              :key (lambda (s) (plist-get s :name))
                              :test #'string-equal)
                 (user-error "A session named %S already exists" name)))
         (host (read-string "Host: "))
         (user (let ((u (read-string "User (RET to skip): ")))
                 (and (not (string-empty-p u)) u)))
         (port (let ((p (read-string "Port (RET for default 22): ")))
                 (and (not (string-empty-p p)) (string-to-number p))))
         (group (let ((g (read-string "Group (RET to skip): ")))
                  (and (not (string-empty-p g)) g)))
         (descr (let ((d (read-string "Description (RET to skip): ")))
                  (and (not (string-empty-p d)) d)))
         (session (delq nil
                        (list :name name
                              :host host
                              (when user  :user)  (when user user)
                              (when port  :port)  (when port port)
                              (when group :group) (when group group)
                              (when descr :description) (when descr descr)))))
    (setq emacs.d/ssh-sessions
          (append emacs.d/ssh-sessions (list session)))
    (emacs.d/ssh-sessions-save)
    (message "Session %S saved.  M-x emacs.d/ssh-sessions-open to launch." name)))

;;;###autoload
(defun emacs.d/ssh-sessions-edit ()
  "Open the session storage file for direct editing as Lisp."
  (interactive)
  (emacs.d/ssh-sessions--ensure-loaded)
  (find-file emacs.d/ssh-sessions-file)
  ;; After saving, re-load into memory so subsequent `-open' calls see
  ;; the new contents without restarting Emacs.
  (add-hook 'after-save-hook
            (lambda ()
              (when (string-equal (buffer-file-name)
                                  (expand-file-name emacs.d/ssh-sessions-file))
                (emacs.d/ssh-sessions-load)
                (message "SSH sessions reloaded (%d entries)."
                         (length emacs.d/ssh-sessions))))
            nil t))

;; ---------------------------------------------------------------------------
;; Default keybindings under C-c s
;; ---------------------------------------------------------------------------
;;
;; `C-c s' is in the user reserved range, so we know we're not stepping
;; on any major mode bindings.  The mnemonic prefix is "s" for "ssh /
;; sessions".

(global-set-key (kbd "C-c s s") #'emacs.d/ssh-sessions-open)
(global-set-key (kbd "C-c s a") #'emacs.d/ssh-sessions-add)
(global-set-key (kbd "C-c s e") #'emacs.d/ssh-sessions-edit)

(provide 'setup-ssh-sessions)
;;; setup-ssh-sessions.el ends here
