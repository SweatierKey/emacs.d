;;; setup-ssh-tunnels.el --- Saved SSH tunnels with toggle on/off -*- lexical-binding: t; -*-

;; A small manager for SSH port-forwarding tunnels.  Think of it as
;; "MobaXterm's tunnel list", but living in an Emacs buffer.
;;
;; The model:
;;
;;   * A tunnel is an Emacs plist:
;;
;;       (:name        "weblogic-prod-console"     ; required, unique
;;        :type        local                       ; local | remote | dynamic
;;        :local-port  7001                        ; required for local/dynamic
;;        :remote-host "weblogic.internal.acme"    ; required for local/remote
;;        :remote-port 7001                        ; required for local/remote
;;        :via-host    "bastion.acme.com"          ; required, the SSH host
;;        :via-user    "myuser"                    ; optional
;;        :description "Open http://localhost:7001/console")
;;
;;     For `:type local'   we run  `ssh -N -L LP:RH:RP user@VIA'.
;;     For `:type remote'  we run  `ssh -N -R LP:RH:RP user@VIA'.
;;     For `:type dynamic' we run  `ssh -N -D LP user@VIA'  (SOCKS proxy).
;;
;;   * Tunnels are stored in `emacs.d/ssh-tunnels-file' (default
;;     `var/ssh-tunnels.el').  Git-ignored.
;;
;;   * `M-x emacs.d/ssh-tunnels-show' (bound to `C-c s t') opens a
;;     tabulated list of tunnels.  Press `RET' on any row to toggle the
;;     tunnel on/off; `a' to add; `d' to delete; `e' to edit the
;;     storage file; `g' to refresh; `K' to kill ALL active tunnels.
;;
;;   * Tunnels run as Emacs processes (no shell), so they die cleanly
;;     when Emacs exits and you can see their stderr in
;;     `*ssh-tunnel: NAME*' buffers if anything goes wrong.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'tabulated-list)

;; ---------------------------------------------------------------------------
;; Storage
;; ---------------------------------------------------------------------------

(defcustom emacs.d/ssh-tunnels-file
  (expand-file-name "var/ssh-tunnels.el" user-emacs-directory)
  "File where SSH tunnel definitions are persisted.
A single Lisp form: a list of plists.  See the header of
`setup-ssh-tunnels.el' for the schema."
  :group 'emacs.d
  :type 'file)

(defvar emacs.d/ssh-tunnels nil
  "In-memory list of tunnel plists.  Loaded on first access.")

(defvar emacs.d/ssh-tunnels--processes (make-hash-table :test 'equal)
  "Map of tunnel-name -> live `process' object for currently active tunnels.")

(defun emacs.d/ssh-tunnels-load ()
  "Read `emacs.d/ssh-tunnels-file' into `emacs.d/ssh-tunnels'."
  (let ((file emacs.d/ssh-tunnels-file))
    (unless (file-exists-p file)
      (make-directory (file-name-directory file) t)
      (with-temp-file file
        (insert ";; -*- lexical-binding: t; -*-\n")
        (insert ";; SSH tunnels for `setup-ssh-tunnels'.\n")
        (insert ";; Each entry is a plist; see lisp/setup-ssh-tunnels.el for the schema.\n\n")
        (insert "(\n")
        (insert "  ;; Example -- delete or replace.\n")
        (insert "  (:name \"example-weblogic-console\"\n")
        (insert "   :type local\n")
        (insert "   :local-port 7001\n")
        (insert "   :remote-host \"weblogic.internal.example.com\"\n")
        (insert "   :remote-port 7001\n")
        (insert "   :via-host \"bastion.example.com\"\n")
        (insert "   :via-user \"myuser\"\n")
        (insert "   :description \"http://localhost:7001/console\")\n")
        (insert ")\n")))
    (with-temp-buffer
      (insert-file-contents file)
      (goto-char (point-min))
      (setq emacs.d/ssh-tunnels (read (current-buffer))))))

(defun emacs.d/ssh-tunnels-save ()
  "Write `emacs.d/ssh-tunnels' back to `emacs.d/ssh-tunnels-file'."
  (let ((file emacs.d/ssh-tunnels-file))
    (make-directory (file-name-directory file) t)
    (with-temp-file file
      (insert ";; -*- lexical-binding: t; -*-\n")
      (insert ";; SSH tunnels for `setup-ssh-tunnels'.\n\n")
      (let ((print-length nil) (print-level nil))
        (pp emacs.d/ssh-tunnels (current-buffer))))))

(defun emacs.d/ssh-tunnels--ensure-loaded ()
  (unless emacs.d/ssh-tunnels (emacs.d/ssh-tunnels-load)))

;; ---------------------------------------------------------------------------
;; Process management
;; ---------------------------------------------------------------------------

(defun emacs.d/ssh-tunnels--build-args (tunnel)
  "Return the argv list (excluding the program name) to run TUNNEL.
The program is always `ssh'.  We pass `-N' so SSH does not allocate a
remote shell, and `-T' to suppress pseudo-tty allocation -- both
appropriate for a forwarding-only session."
  (let* ((type   (plist-get tunnel :type))
         (lport  (plist-get tunnel :local-port))
         (rhost  (plist-get tunnel :remote-host))
         (rport  (plist-get tunnel :remote-port))
         (via    (plist-get tunnel :via-host))
         (user   (plist-get tunnel :via-user))
         (target (if user (format "%s@%s" user via) via)))
    (append
     '("-N" "-T")
     ;; ServerAliveInterval helps detect dropped tunnels through
     ;; CyberArk / corporate firewalls that idle-kill connections.
     '("-o" "ServerAliveInterval=30"
       "-o" "ServerAliveCountMax=3"
       "-o" "ExitOnForwardFailure=yes")
     (cl-case type
       (local   (list "-L" (format "%d:%s:%d" lport rhost rport)))
       (remote  (list "-R" (format "%d:%s:%d" lport rhost rport)))
       (dynamic (list "-D" (format "%d" lport)))
       (t       (error "Unknown tunnel type: %S" type)))
     (list target))))

(defun emacs.d/ssh-tunnels--running-p (name)
  (let ((proc (gethash name emacs.d/ssh-tunnels--processes)))
    (and proc (process-live-p proc))))

(defun emacs.d/ssh-tunnels--start (tunnel)
  "Start TUNNEL.  Errors if already running or if SSH fails immediately."
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
         ;; When the SSH process dies (network drop, ExitOnForwardFailure,
         ;; Ctrl-C from the user...) drop it from the live map and refresh
         ;; the list buffer if it's open.
         (remhash name emacs.d/ssh-tunnels--processes)
         (when (get-buffer "*ssh-tunnels*")
           (with-current-buffer "*ssh-tunnels*"
             (revert-buffer))))))
    (message "Tunnel %S started (pid %d)" name (process-id proc))))

(defun emacs.d/ssh-tunnels--stop (name)
  "Stop the tunnel named NAME if it is running."
  (let ((proc (gethash name emacs.d/ssh-tunnels--processes)))
    (when (and proc (process-live-p proc))
      (interrupt-process proc)
      ;; Give SSH ~0.5s to disconnect cleanly; if it's still alive, kill.
      (run-at-time 0.5 nil
                   (lambda ()
                     (when (process-live-p proc)
                       (kill-process proc))))
      (message "Tunnel %S stopped" name))))

;; ---------------------------------------------------------------------------
;; Tabulated list mode
;; ---------------------------------------------------------------------------

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
  "Major mode for the SSH tunnels list.

Bindings:
  RET / t   toggle tunnel on point on/off
  a         add a new tunnel
  d         delete tunnel on point
  e         edit the tunnels file directly
  K         stop ALL active tunnels
  g         refresh the list"
  (setq tabulated-list-format
        [("●"        2  nil)              ;; running indicator
         ("Name"     24 t)
         ("Type"     8  t)
         ("Spec"     32 t)
         ("Via"      30 t)
         ("Description" 0 t)])
  (setq tabulated-list-padding 1)
  (setq tabulated-list-sort-key '("Name" . nil))
  (add-hook 'tabulated-list-revert-hook
            #'emacs.d/ssh-tunnels--refresh-entries nil t)
  (tabulated-list-init-header))

(defun emacs.d/ssh-tunnels--format-spec (tunnel)
  "Render a one-line forwarding spec for TUNNEL, e.g. \"L 7001 -> rh:7001\"."
  (let ((type   (plist-get tunnel :type))
        (lport  (plist-get tunnel :local-port))
        (rhost  (plist-get tunnel :remote-host))
        (rport  (plist-get tunnel :remote-port)))
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
           (let* ((name (plist-get tunnel :name))
                  (type (plist-get tunnel :type))
                  (via  (plist-get tunnel :via-host))
                  (user (plist-get tunnel :via-user))
                  (descr (or (plist-get tunnel :description) ""))
                  (running (emacs.d/ssh-tunnels--running-p name))
                  (dot (if running
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

(defun emacs.d/ssh-tunnels--current-name ()
  "Return the tunnel name on the current row, or signal an error."
  (or (tabulated-list-get-id)
      (user-error "No tunnel on this line")))

(defun emacs.d/ssh-tunnels--find (name)
  (cl-find name emacs.d/ssh-tunnels
           :key (lambda (t-) (plist-get t- :name))
           :test #'string-equal))

(defun emacs.d/ssh-tunnels-toggle ()
  "Toggle the tunnel on the current row on/off."
  (interactive)
  (let* ((name   (emacs.d/ssh-tunnels--current-name))
         (tunnel (emacs.d/ssh-tunnels--find name)))
    (unless tunnel (user-error "Tunnel %S not found" name))
    (if (emacs.d/ssh-tunnels--running-p name)
        (emacs.d/ssh-tunnels--stop name)
      (emacs.d/ssh-tunnels--start tunnel))
    ;; Give the sentinel a moment to settle before redrawing.
    (run-at-time 0.2 nil
                 (lambda ()
                   (when (get-buffer "*ssh-tunnels*")
                     (with-current-buffer "*ssh-tunnels*"
                       (revert-buffer)))))))

;;;###autoload
(defun emacs.d/ssh-tunnels-add ()
  "Interactively define a new tunnel and persist it."
  (interactive)
  (emacs.d/ssh-tunnels--ensure-loaded)
  (let* ((name   (read-string "Tunnel name (unique): "))
         (_      (when (emacs.d/ssh-tunnels--find name)
                   (user-error "A tunnel named %S already exists" name)))
         (type   (intern (completing-read "Type: " '("local" "remote" "dynamic") nil t "local")))
         (lport  (read-number "Local port: " 8080))
         (rhost  (unless (eq type 'dynamic)
                   (read-string "Remote host (as seen from the bastion): ")))
         (rport  (unless (eq type 'dynamic)
                   (read-number "Remote port: " 80)))
         (via    (read-string "Via SSH host (the bastion): "))
         (user   (let ((u (read-string "Via SSH user (RET to skip): ")))
                   (and (not (string-empty-p u)) u)))
         (descr  (let ((d (read-string "Description (RET to skip): ")))
                   (and (not (string-empty-p d)) d)))
         (tunnel (delq nil
                       (list :name name :type type
                             :local-port lport
                             (when rhost :remote-host) (when rhost rhost)
                             (when rport :remote-port) (when rport rport)
                             :via-host via
                             (when user :via-user) (when user user)
                             (when descr :description) (when descr descr)))))
    (setq emacs.d/ssh-tunnels (append emacs.d/ssh-tunnels (list tunnel)))
    (emacs.d/ssh-tunnels-save)
    (when (get-buffer "*ssh-tunnels*")
      (with-current-buffer "*ssh-tunnels*" (revert-buffer)))
    (message "Tunnel %S saved." name)))

(defun emacs.d/ssh-tunnels-delete-at-point ()
  "Delete the tunnel on the current row from the saved list.
Stops it first if it is running."
  (interactive)
  (let* ((name (emacs.d/ssh-tunnels--current-name)))
    (when (yes-or-no-p (format "Really delete tunnel %S? " name))
      (emacs.d/ssh-tunnels--stop name)
      (setq emacs.d/ssh-tunnels
            (cl-remove-if (lambda (t-) (string-equal name (plist-get t- :name)))
                          emacs.d/ssh-tunnels))
      (emacs.d/ssh-tunnels-save)
      (revert-buffer))))

(defun emacs.d/ssh-tunnels-stop-all ()
  "Stop every currently-active tunnel.  Asks for confirmation."
  (interactive)
  (let ((names (hash-table-keys emacs.d/ssh-tunnels--processes)))
    (when (and names
               (yes-or-no-p (format "Stop %d active tunnel(s)? " (length names))))
      (mapc #'emacs.d/ssh-tunnels--stop names))
    (when (get-buffer "*ssh-tunnels*")
      (with-current-buffer "*ssh-tunnels*" (revert-buffer)))))

;;;###autoload
(defun emacs.d/ssh-tunnels-edit ()
  "Open the tunnel storage file for direct editing as Lisp."
  (interactive)
  (emacs.d/ssh-tunnels--ensure-loaded)
  (find-file emacs.d/ssh-tunnels-file)
  (add-hook 'after-save-hook
            (lambda ()
              (when (string-equal (buffer-file-name)
                                  (expand-file-name emacs.d/ssh-tunnels-file))
                (emacs.d/ssh-tunnels-load)
                (when (get-buffer "*ssh-tunnels*")
                  (with-current-buffer "*ssh-tunnels*" (revert-buffer)))
                (message "Tunnels reloaded (%d entries)."
                         (length emacs.d/ssh-tunnels))))
            nil t))

;; ---------------------------------------------------------------------------
;; Default keybindings
;; ---------------------------------------------------------------------------

(global-set-key (kbd "C-c s t") #'emacs.d/ssh-tunnels-show)
(global-set-key (kbd "C-c s T") #'emacs.d/ssh-tunnels-add)

(provide 'setup-ssh-tunnels)
;;; setup-ssh-tunnels.el ends here
