;;; setup-ssh-tunnels.el --- SSH tunnel manager -*- lexical-binding: t; -*-

;;; Commentary:
;; See config.org, section "SSH tunnels".

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'tabulated-list)

(defcustom emacs.d/ssh-tunnels-file
  (expand-file-name "var/ssh-tunnels.el" user-emacs-directory)
  "File where SSH tunnel definitions are persisted."
  :type 'file :group 'emacs.d)

(defvar emacs.d/ssh-tunnels nil
  "In-memory list of SSH tunnel plists.")

(defvar emacs.d/ssh-tunnels--processes (make-hash-table :test 'equal)
  "Map of tunnel-name -> live `process' object for active tunnels.")

(defun emacs.d/ssh-tunnels--seed-file (file)
  "Write a starter list with one example tunnel to FILE."
  (make-directory (file-name-directory file) t)
  (with-temp-file file
    (insert ";; -*- lexical-binding: t; -*-\n"
            ";; SSH tunnels for `setup-ssh-tunnels'.\n"
            ";; Each entry is a plist; see config.org for the schema.\n\n"
            "(\n"
            "  (:name \"example-weblogic-console\"\n"
            "   :type local\n"
            "   :local-port 7001\n"
            "   :remote-host \"weblogic.internal.example.com\"\n"
            "   :remote-port 7001\n"
            "   :via-host \"bastion.example.com\"\n"
            "   :via-user \"myuser\"\n"
            "   :description \"http://localhost:7001/console\")\n"
            ")\n")))

(defun emacs.d/ssh-tunnels-load ()
  "Load `emacs.d/ssh-tunnels' from `emacs.d/ssh-tunnels-file'."
  (let ((file emacs.d/ssh-tunnels-file))
    (unless (file-exists-p file)
      (emacs.d/ssh-tunnels--seed-file file))
    (with-temp-buffer
      (insert-file-contents file)
      (goto-char (point-min))
      (setq emacs.d/ssh-tunnels (read (current-buffer))))))

(defun emacs.d/ssh-tunnels-save ()
  "Write `emacs.d/ssh-tunnels' back to disk as pretty-printed Lisp."
  (let ((file emacs.d/ssh-tunnels-file))
    (make-directory (file-name-directory file) t)
    (with-temp-file file
      (insert ";; -*- lexical-binding: t; -*-\n"
              ";; SSH tunnels for `setup-ssh-tunnels'.\n\n")
      (let ((print-length nil) (print-level nil))
        (pp emacs.d/ssh-tunnels (current-buffer))))))

(defun emacs.d/ssh-tunnels--ensure-loaded ()
  (unless emacs.d/ssh-tunnels (emacs.d/ssh-tunnels-load)))

(defun emacs.d/ssh-tunnels--find (name)
  (cl-find name emacs.d/ssh-tunnels
           :key  (lambda (tunnel) (plist-get tunnel :name))
           :test #'string-equal))

(defun emacs.d/ssh-tunnels--running-p (name)
  (let ((proc (gethash name emacs.d/ssh-tunnels--processes)))
    (and proc (process-live-p proc))))

(defun emacs.d/ssh-tunnels--build-args (tunnel)
  "Return the argv (no program) to launch TUNNEL via ssh."
  (let* ((type   (plist-get tunnel :type))
         (lport  (plist-get tunnel :local-port))
         (rhost  (plist-get tunnel :remote-host))
         (rport  (plist-get tunnel :remote-port))
         (via    (plist-get tunnel :via-host))
         (user   (plist-get tunnel :via-user))
         (target (if user (format "%s@%s" user via) via)))
    (append
     '("-N" "-T")
     ;; Keepalive + fail-fast: helpful behind CyberArk PSMP and other
     ;; corporate firewalls that idle-kill connections silently.
     '("-o" "ServerAliveInterval=30"
       "-o" "ServerAliveCountMax=3"
       "-o" "ExitOnForwardFailure=yes")
     (cl-case type
       (local   (list "-L" (format "%d:%s:%d" lport rhost rport)))
       (remote  (list "-R" (format "%d:%s:%d" lport rhost rport)))
       (dynamic (list "-D" (format "%d" lport)))
       (t       (error "Unknown tunnel type: %S" type)))
     (list target))))

(defun emacs.d/ssh-tunnels--start (tunnel)
  "Spawn the ssh subprocess for TUNNEL and register its sentinel."
  (let* ((name (plist-get tunnel :name))
         (args (emacs.d/ssh-tunnels--build-args tunnel))
         (buf  (get-buffer-create (format "*ssh-tunnel: %s*" name)))
         (proc (apply #'start-process
                      (format "ssh-tunnel-%s" name)
                      buf
                      "ssh" args)))
    (puthash name proc emacs.d/ssh-tunnels--processes)
    (set-process-sentinel
     proc
     (lambda (p _event)
       (unless (process-live-p p)
         (remhash name emacs.d/ssh-tunnels--processes)
         (when (get-buffer "*ssh-tunnels*")
           (with-current-buffer "*ssh-tunnels*" (revert-buffer))))))
    (message "Tunnel %S started (pid %d)" name (process-id proc))))

(defun emacs.d/ssh-tunnels--stop (name)
  "Signal the live ssh process for tunnel NAME to terminate cleanly."
  (when-let ((proc (gethash name emacs.d/ssh-tunnels--processes)))
    (when (process-live-p proc)
      (interrupt-process proc)
      (run-at-time 0.5 nil
                   (lambda ()
                     (when (process-live-p proc)
                       (kill-process proc))))
      (message "Tunnel %S stopped" name))))

(defvar emacs.d/ssh-tunnels-list-mode-map
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map tabulated-list-mode-map)
    (define-key map (kbd "RET") #'emacs.d/ssh-tunnels-toggle)
    (define-key map (kbd "t")   #'emacs.d/ssh-tunnels-toggle)
    (define-key map (kbd "a")   #'emacs.d/ssh-tunnels-add)
    (define-key map (kbd "d")   #'emacs.d/ssh-tunnels-delete-at-point)
    (define-key map (kbd "e")   #'emacs.d/ssh-tunnels-edit)
    (define-key map (kbd "K")   #'emacs.d/ssh-tunnels-stop-all)
    (define-key map (kbd "g")   #'revert-buffer)
    map)
  "Keymap for `emacs.d/ssh-tunnels-list-mode'.")

(define-derived-mode emacs.d/ssh-tunnels-list-mode tabulated-list-mode
  "SSH-Tunnels"
  "Major mode for the SSH tunnels list."
  (setq tabulated-list-format
        [("●"           2  nil)
         ("Name"       24  t)
         ("Type"        8  t)
         ("Spec"       32  t)
         ("Via"        30  t)
         ("Description" 0  t)])
  (setq tabulated-list-padding 1
        tabulated-list-sort-key '("Name" . nil))
  (add-hook 'tabulated-list-revert-hook
            #'emacs.d/ssh-tunnels--refresh-entries nil t)
  (tabulated-list-init-header))

(defun emacs.d/ssh-tunnels--format-spec (tunnel)
  "Render a one-line forwarding spec for TUNNEL."
  (let ((type  (plist-get tunnel :type))
        (lport (plist-get tunnel :local-port))
        (rhost (plist-get tunnel :remote-host))
        (rport (plist-get tunnel :remote-port)))
    (cl-case type
      (local   (format "L %s -> %s:%s" lport rhost rport))
      (remote  (format "R %s -> %s:%s" lport rhost rport))
      (dynamic (format "D %s (SOCKS)"  lport))
      (t       "?"))))

(defun emacs.d/ssh-tunnels--refresh-entries ()
  (emacs.d/ssh-tunnels--ensure-loaded)
  (setq tabulated-list-entries
        (mapcar
         (lambda (tunnel)
           (let* ((name    (plist-get tunnel :name))
                  (type    (plist-get tunnel :type))
                  (via     (plist-get tunnel :via-host))
                  (user    (plist-get tunnel :via-user))
                  (descr   (or (plist-get tunnel :description) ""))
                  (running (emacs.d/ssh-tunnels--running-p name))
                  (dot     (if running
                               (propertize "●" 'face 'success)
                             (propertize "○" 'face 'shadow))))
             (list name
                   (vector dot
                           name
                           (symbol-name type)
                           (emacs.d/ssh-tunnels--format-spec tunnel)
                           (if user (format "%s@%s" user via) (or via ""))
                           descr))))
         emacs.d/ssh-tunnels)))

(defun emacs.d/ssh-tunnels--current-name ()
  (or (tabulated-list-get-id)
      (user-error "No tunnel on this line")))

(defun emacs.d/ssh-tunnels--refresh-list-buffer (&optional delay)
  "Schedule a refresh of the *ssh-tunnels* buffer if it exists."
  (when (get-buffer "*ssh-tunnels*")
    (run-at-time (or delay 0) nil
                 (lambda ()
                   (when (get-buffer "*ssh-tunnels*")
                     (with-current-buffer "*ssh-tunnels*"
                       (revert-buffer)))))))

;;;###autoload
(defun emacs.d/ssh-tunnels-show ()
  "Open the SSH tunnels list buffer."
  (interactive)
  (emacs.d/ssh-tunnels--ensure-loaded)
  (let ((buf (get-buffer-create "*ssh-tunnels*")))
    (with-current-buffer buf
      (emacs.d/ssh-tunnels-list-mode)
      (emacs.d/ssh-tunnels--refresh-entries)
      (tabulated-list-print t))
    (pop-to-buffer buf)))

(defun emacs.d/ssh-tunnels-toggle ()
  "Toggle the tunnel on the current row on/off."
  (interactive)
  (let* ((name   (emacs.d/ssh-tunnels--current-name))
         (tunnel (emacs.d/ssh-tunnels--find name)))
    (unless tunnel (user-error "Tunnel %S not found" name))
    (if (emacs.d/ssh-tunnels--running-p name)
        (emacs.d/ssh-tunnels--stop name)
      (emacs.d/ssh-tunnels--start tunnel))
    (emacs.d/ssh-tunnels--refresh-list-buffer 0.2)))

;;;###autoload
(defun emacs.d/ssh-tunnels-add ()
  "Interactively define a new tunnel and persist it."
  (interactive)
  (emacs.d/ssh-tunnels--ensure-loaded)
  (let ((name (read-string "Tunnel name (unique): ")))
    (when (emacs.d/ssh-tunnels--find name)
      (user-error "A tunnel named %S already exists" name))
    (let* ((type  (intern (completing-read "Type: "
                                           '("local" "remote" "dynamic")
                                           nil t "local")))
           (lport (read-number "Local port: " 8080))
           (rhost (unless (eq type 'dynamic)
                    (read-string "Remote host (as seen from the bastion): ")))
           (rport (unless (eq type 'dynamic)
                    (read-number "Remote port: " 80)))
           (via   (read-string "Via SSH host (the bastion): "))
           (user  (let ((u (read-string "Via SSH user (RET to skip): ")))
                    (and (not (string-empty-p u)) u)))
           (descr (let ((d (read-string "Description (RET to skip): ")))
                    (and (not (string-empty-p d)) d)))
           (tunnel (apply #'list
                          :name name :type type :local-port lport
                          (append
                           (when rhost (list :remote-host rhost))
                           (when rport (list :remote-port rport))
                           (list :via-host via)
                           (when user  (list :via-user user))
                           (when descr (list :description descr))))))
      (setq emacs.d/ssh-tunnels (append emacs.d/ssh-tunnels (list tunnel)))
      (emacs.d/ssh-tunnels-save)
      (emacs.d/ssh-tunnels--refresh-list-buffer)
      (message "Tunnel %S saved." name))))

(defun emacs.d/ssh-tunnels-delete-at-point ()
  "Delete the tunnel on the current row from the saved list."
  (interactive)
  (let ((name (emacs.d/ssh-tunnels--current-name)))
    (when (yes-or-no-p (format "Really delete tunnel %S? " name))
      (emacs.d/ssh-tunnels--stop name)
      (setq emacs.d/ssh-tunnels
            (cl-remove-if (lambda (tunnel)
                            (string-equal name (plist-get tunnel :name)))
                          emacs.d/ssh-tunnels))
      (emacs.d/ssh-tunnels-save)
      (revert-buffer))))

(defun emacs.d/ssh-tunnels-stop-all ()
  "Stop every currently-active tunnel after confirmation."
  (interactive)
  (let ((names (hash-table-keys emacs.d/ssh-tunnels--processes)))
    (when (and names
               (yes-or-no-p
                (format "Stop %d active tunnel(s)? " (length names))))
      (mapc #'emacs.d/ssh-tunnels--stop names))
    (emacs.d/ssh-tunnels--refresh-list-buffer)))

(defun emacs.d/ssh-tunnels--reload-after-save ()
  "Buffer-local `after-save-hook' for the storage file: reload tunnels."
  (when (and buffer-file-name
             (string-equal (expand-file-name buffer-file-name)
                           (expand-file-name emacs.d/ssh-tunnels-file)))
    (emacs.d/ssh-tunnels-load)
    (emacs.d/ssh-tunnels--refresh-list-buffer)
    (message "Tunnels reloaded (%d entries)."
             (length emacs.d/ssh-tunnels))))

;;;###autoload
(defun emacs.d/ssh-tunnels-edit ()
  "Open the tunnel storage file for direct Lisp editing."
  (interactive)
  (emacs.d/ssh-tunnels--ensure-loaded)
  (find-file emacs.d/ssh-tunnels-file)
  (add-hook 'after-save-hook #'emacs.d/ssh-tunnels--reload-after-save nil t))

(global-set-key (kbd "C-c s t") #'emacs.d/ssh-tunnels-show)
(global-set-key (kbd "C-c s T") #'emacs.d/ssh-tunnels-add)

(provide 'setup-ssh-tunnels)
;;; setup-ssh-tunnels.el ends here
