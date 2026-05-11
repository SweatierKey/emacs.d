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
        ("C-c C-t" . vterm-copy-mode)))

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

(defvar-local emacs.d/vterm-pending-chain nil
  "List of shell lines the auto-stepper has yet to type into this buffer.
Seeded by `emacs.d/ssh-sessions-open' for bastion-routed sessions
and consumed by `emacs.d/vterm--advance-pending-chain' one entry
per prompt transition.  Each entry is a single shell line (without
trailing newline); the stepper appends Return when sending it.

Why we type the chain interactively instead of appending it to the
ssh CLI: CyberArk PSMP-fronted bastions reject any extra command
argument on the ssh line with `Invalid session state'.  By driving
the chain *inside* the bastion shell we mimic exactly what a
sysadmin would type by hand -- the one approach PSMP accepts.")

(defvar-local emacs.d/vterm--pending-chain-last-sig nil
  "Last (USER . HOST) signature the auto-stepper has already responded to.
The prompt parser fires after every libvterm screen update, so a
single chain step typically observes many intermediate parser hits
between sending its command and the shell drawing the new prompt.
Comparing against this signature ensures we send each step exactly
once per *real* prompt transition.")

(defcustom emacs.d/vterm-prompt-host-regexp
  (concat "^\\[?"                                ; optional `[' (RHEL/Fedora)
          "\\([[:alnum:]_.-]+\\)"                ; 1: user
          "@"
          "\\([[:alnum:]_.-]+\\)"                ; 2: host
          "\\(?:[: \t]+"                         ; separator: `:' or whitespace
          "\\([^][:space:]\n]+?\\)\\)?"          ; 3: cwd (optional, no `]')
          "\\]?"                                 ; optional closing `]'
          "[ \t]*[$#%>]")                        ; prompt char
  "Regexp used to extract user, host and cwd from the visible shell prompt.
Capture groups in order: USER (group 1), HOST (group 2), CWD
(group 3, optional).  Anchored at column zero.  Handles both the
Debian/Ubuntu shape (`user@host:cwd$') and the RHEL/Fedora
bracketed shape (`[user@host cwd]$').  Customise for prompts that
don't end with `$', `#', `%' or `>' (e.g. starship/powerline arrows)."
  :type 'regexp :group 'emacs.d)

(defcustom emacs.d/vterm-tramp-sudo-user nil
  "Default user TRAMP sudoes into after the ssh hop to the bastion.
Set to a string (e.g. \"root\") only if *every* ssh alias you open
auto-elevates after login; for a mixed environment leave this nil
and use `emacs.d/ssh-host-tramp-config' to opt in per host."
  :type '(choice (const :tag "No sudo by default" nil) string)
  :group 'emacs.d)

(defcustom emacs.d/vterm-tramp-bastion-user "root"
  "Default user the session is expected to be running as after the
bastion sudo.  Compared against the prompt-detected user to decide
whether an *extra* `|sudo:USER' hop is needed (e.g. after `sudo
su - oracle' on the target).  Per-host override via
`emacs.d/ssh-host-tramp-config'."
  :type 'string :group 'emacs.d)

(defcustom emacs.d/ssh-host-tramp-config
  '(("\\`lxsag" :sudo-user "root"))
  "Per-host TRAMP overrides matched against ssh_config aliases.
Alist where each car is a regexp matched (with `string-match-p')
against the alias passed to `emacs.d/ssh-sessions-open', and each
cdr is a plist with these recognised keys:

  :sudo-user STRING    Become this user via sudo right after the
                       ssh hop (e.g. \"root\" for a CyberArk-style
                       bastion that auto-elevates).  nil disables
                       the sudo hop entirely.

  :bastion-user STRING The user the session is expected to be
                       running as after that sudo (default
                       inherited from `emacs.d/vterm-tramp-bastion-user').
                       An *extra* sudo is added if the prompt's
                       user differs (e.g. after `sudo su - oracle').

  :tramp-alias VALUE   Use this ssh_config alias *for the TRAMP
                       path only*, instead of the alias used for
                       the interactive vterm session.  Only needed
                       in legacy setups where the interactive
                       entry must keep `RemoteCommand' /
                       `RequestTTY' for CLI ssh; with the chain
                       built in elisp (see `emacs.d/ssh-target-bastions')
                       a clean ssh_config Host stanza serves both
                       vterm and TRAMP and this key is unused.
                       VALUE may be a string (used verbatim) or a
                       function of one argument (the bastion
                       alias) returning a string.

The first matching entry wins; aliases that match no entry use
the global defaults.  Default value covers `lxsag*' bastions of
this user; override via `M-x customize-variable' or
`(setq ...)' for other environments."
  :type '(alist :key-type regexp :value-type plist)
  :group 'emacs.d)

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

(defun emacs.d/vterm--tramp-host-config (alias)
  "Return the plist of TRAMP overrides for ALIAS, or nil.
Walks `emacs.d/ssh-host-tramp-config' and returns the cdr of the
first entry whose car (a regexp) matches ALIAS."
  (cdr (cl-find-if (lambda (entry)
                     (string-match-p (car entry) alias))
                   emacs.d/ssh-host-tramp-config)))

(defun emacs.d/vterm--tramp-resolved (alias key default)
  "Look up KEY for ALIAS in `emacs.d/ssh-host-tramp-config'.
Falls back to DEFAULT when ALIAS matches no entry, or when the
matched entry does not include KEY."
  (let ((cfg (emacs.d/vterm--tramp-host-config alias)))
    (if (plist-member cfg key)
        (plist-get cfg key)
      default)))

(defun emacs.d/vterm--tramp-resolve-alias (bastion)
  "Return the ssh_config alias TRAMP should use for BASTION.
Honors a `:tramp-alias' entry in `emacs.d/ssh-host-tramp-config'
(string used verbatim, or function called with BASTION); falls
back to BASTION itself."
  (let ((override (emacs.d/vterm--tramp-resolved bastion :tramp-alias nil)))
    (cond
     ((stringp override)   override)
     ((functionp override) (funcall override bastion))
     (t                    bastion))))

(defun emacs.d/vterm--tramp-anchor (str-or-empty)
  "Wrap STR-OR-EMPTY in `\\`...\\''-anchored regexp form.
Returns `\\`\\''  (the empty-string-only matcher) when STR-OR-EMPTY
is nil or empty -- TRAMP treats this as `user not specified',
preventing the proxy entry from matching arbitrary users."
  (if (or (null str-or-empty) (string-empty-p str-or-empty))
      "\\`\\'"
    (concat "\\`" (regexp-quote str-or-empty) "\\'")))

(defun emacs.d/vterm--tramp-chain (bastion tramp-alias host user path
                                           sudo-user bastion-user)
  "Return `(DEEPEST-PATH . PROXY-ENTRIES)' describing the TRAMP setup
matching the prompt-derived session state.  DEEPEST-PATH is the
minimal-form TRAMP path (single or two-method) that
`default-directory' should hold; PROXY-ENTRIES is a list of
`(HOST-RX USER-RX PROXY-STRING)' triples to add to
`tramp-default-proxies-alist' so TRAMP can resolve DEEPEST-PATH
into the full multi-hop chain.

The shape of the chain is chosen from five cases:

  A. plain ssh, on bastion             /ssh:TRAMP-ALIAS:CWD
  B. plain ssh, hopped to a target     /ssh:HOST:CWD
  C. with sudo, on bastion             /sudo:SUDO-USER@TRAMP-ALIAS:CWD
  D. with sudo, on target as SUDO-USER /ssh:HOST:CWD
  E. with sudo, on target as USER      /sudo:USER@HOST:CWD

This split exists because TRAMP's ad-hoc chain parsing
(`tramp-add-hops') generates proxy entries with a nil user-regexp
that matches *any* user and beats the legitimate intermediate
entries -- producing the `Host name X does not match Y' error
when the chain has more than 3 hops.  By building the proxy list
ourselves with anchored user regexes the ordering bug is avoided."
  (let* ((on-bastion (string-equal host bastion))
         (path/      (file-name-as-directory (or path "~")))
         deepest entries)
    (cond
     ((and (not sudo-user) on-bastion)                     ; A
      (setq deepest (format "/ssh:%s:%s" tramp-alias path/)))
     ((not sudo-user)                                       ; B
      (setq deepest (format "/ssh:%s:%s" host path/))
      (push (list (emacs.d/vterm--tramp-anchor host)
                  "\\`\\'"
                  (format "/ssh:%s:" tramp-alias))
            entries))
     (on-bastion                                            ; C
      (setq deepest (format "/sudo:%s@%s:%s"
                            sudo-user tramp-alias path/))
      (push (list (emacs.d/vterm--tramp-anchor tramp-alias)
                  (emacs.d/vterm--tramp-anchor sudo-user)
                  (format "/ssh:%s:" tramp-alias))
            entries))
     ((string-equal user bastion-user)                      ; D
      (setq deepest (format "/ssh:%s:%s" host path/))
      (push (list (emacs.d/vterm--tramp-anchor host)
                  "\\`\\'"
                  (format "/sudo:%s@%s:" sudo-user tramp-alias))
            entries)
      (push (list (emacs.d/vterm--tramp-anchor tramp-alias)
                  (emacs.d/vterm--tramp-anchor sudo-user)
                  (format "/ssh:%s:" tramp-alias))
            entries))
     (t                                                     ; E
      (setq deepest (format "/sudo:%s@%s:%s" user host path/))
      (push (list (emacs.d/vterm--tramp-anchor host)
                  (emacs.d/vterm--tramp-anchor user)
                  (format "/ssh:%s:" host))
            entries)
      (push (list (emacs.d/vterm--tramp-anchor host)
                  "\\`\\'"
                  (format "/sudo:%s@%s:" sudo-user tramp-alias))
            entries)
      (push (list (emacs.d/vterm--tramp-anchor tramp-alias)
                  (emacs.d/vterm--tramp-anchor sudo-user)
                  (format "/ssh:%s:" tramp-alias))
            entries)))
    (cons deepest entries)))

(defun emacs.d/vterm--tramp-default-directory ()
  "Side-effecting wrapper around `emacs.d/vterm--tramp-chain'.
Returns the deepest TRAMP path matching the current session
prompt, and installs the proxy entries it needs in
`tramp-default-proxies-alist' (idempotently, no removal on
session close -- entries are tiny and mutually exclusive).
Returns nil when bastion or host are still unknown."
  (let ((bastion emacs.d/vterm-bastion-name)
        (host    emacs.d/vterm-current-host)
        (user    emacs.d/vterm-current-user)
        (path    emacs.d/vterm-current-path))
    (when (and bastion host)
      (require 'tramp)
      (let* ((tramp-alias    (emacs.d/vterm--tramp-resolve-alias bastion))
             (sudo-user-name (emacs.d/vterm--tramp-resolved
                              bastion :sudo-user
                              emacs.d/vterm-tramp-sudo-user))
             (bastion-user   (emacs.d/vterm--tramp-resolved
                              bastion :bastion-user
                              emacs.d/vterm-tramp-bastion-user))
             (chain (emacs.d/vterm--tramp-chain
                     bastion tramp-alias host user path
                     sudo-user-name bastion-user)))
        (dolist (e (cdr chain))
          (add-to-list 'tramp-default-proxies-alist e))
        (car chain)))))

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

(defun emacs.d/vterm--advance-pending-chain ()
  "Type the next pending chain step into this vterm, if any.
Pops one entry from `emacs.d/vterm-pending-chain' the *first* time
the prompt signature (USER . HOST) is observed in its new value,
sends it followed by Return, and records the signature in
`emacs.d/vterm--pending-chain-last-sig' so further prompt-parser
firings on the same prompt are ignored.  No-op when the chain is
empty, when user/host are still unknown, or when the signature is
identical to the last responded one (e.g. command echo before the
shell has rendered the new prompt)."
  (when (and emacs.d/vterm-pending-chain
             emacs.d/vterm-current-host
             emacs.d/vterm-current-user)
    (let ((sig (cons emacs.d/vterm-current-user
                     emacs.d/vterm-current-host)))
      (unless (equal sig emacs.d/vterm--pending-chain-last-sig)
        (setq-local emacs.d/vterm--pending-chain-last-sig sig)
        (let ((next (pop emacs.d/vterm-pending-chain)))
          (vterm-send-string next)
          (vterm-send-return))))))

(defun emacs.d/vterm-update-current-host (&rest _ignored)
  "Refresh user/host/path from the prompt and rename tab + buffer, then
optionally sync `default-directory' to the matching TRAMP path.
The tab name only tracks the *host* (stable identity of the SSH
session), the buffer name additionally reflects the *cwd*, and the
TRAMP-derived `default-directory' also tracks the current *user* --
in increasing order of volatility.  Hooked as `:after' advice on
`vterm--filter'.  After updating the state, advances the
pending-chain auto-stepper so PSMP-style sessions can type their
sudo/ssh hops one at a time."
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
          (when (or host-changed user-changed)
            (emacs.d/vterm--advance-pending-chain))
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

(defun emacs.d/vterm--cross-to-remote (command)
  "Run COMMAND interactively with `default-directory' bound to the
session's TRAMP path when known.  Falls back to the buffer's
existing `default-directory' (local on plain vterms, already the
TRAMP path on session vterms with auto-sync enabled).  Reports in
the echo area when the fallback kicks in."
  (let* ((td (emacs.d/vterm--tramp-default-directory))
         (default-directory (or td default-directory)))
    (unless td
      (message "vterm: no remote target -- %s rooted at %s"
               command default-directory))
    (call-interactively command)))

;;;###autoload
(defun emacs.d/vterm-find-file-remote ()
  "Open `find-file' rooted at the session's TRAMP path when known."
  (interactive)
  (emacs.d/vterm--cross-to-remote #'find-file))

;;;###autoload
(defun emacs.d/vterm-dired-remote ()
  "Open `dired' rooted at the session's TRAMP path when known."
  (interactive)
  (emacs.d/vterm--cross-to-remote #'dired))

(defface emacs.d/vterm-environment-production-face
  '((t :inherit error :weight bold))
  "Mode-line face for production-environment session indicator.
Inherits from `error' so the tag stands out under any theme."
  :group 'emacs.d)

(defface emacs.d/vterm-environment-other-face
  '((t :inherit shadow))
  "Mode-line face for non-production session indicators (preproduction,
systemtest, integration, ...).  Inherits from `shadow' for a
subdued look."
  :group 'emacs.d)

(defun emacs.d/vterm--mode-line-tramp ()
  "Mode-line segment showing the current SSH chain (and environment).
Format: ` ⇄BASTION[→HOST] [ENV]'.  Returns nil (so the segment is
invisible) outside vterm buffers or when the buffer's
`default-directory' is not a TRAMP path.  The environment tag is
omitted when the host doesn't match anything in
`emacs.d/ssh-host-environments'; otherwise it is rendered in
`emacs.d/vterm-environment-production-face' for `production',
`emacs.d/vterm-environment-other-face' for everything else."
  (when (and (derived-mode-p 'vterm-mode)
             emacs.d/vterm-bastion-name
             (file-remote-p default-directory))
    (let* ((bastion emacs.d/vterm-bastion-name)
           (host    emacs.d/vterm-current-host)
           (env     (and (fboundp 'emacs.d/ssh-env-for-host)
                         (emacs.d/ssh-env-for-host host)))
           (chain   (propertize
                     (if (and host (not (string-equal host bastion)))
                         (concat " ⇄" bastion "→" host)
                       (concat " ⇄" bastion))
                     'face 'shadow))
           (env-tag (when env
                      (propertize
                       (format " [%s]" (upcase env))
                       'face (if (string-equal env "production")
                                  'emacs.d/vterm-environment-production-face
                                'emacs.d/vterm-environment-other-face)))))
      (propertize (concat chain (or env-tag ""))
                  'help-echo (concat "TRAMP target: " default-directory
                                     (when env
                                       (format "\nEnvironment: %s" env)))))))

(defvar emacs.d/vterm--pixel-scroll-passthrough-map
  (let ((m (make-sparse-keymap)))
    (define-key m [next]  #'vterm--self-insert)
    (define-key m [prior] #'vterm--self-insert)
    m)
  "Override map that re-routes `<prior>'/`<next>' to vterm.
`pixel-scroll-precision-mode' is a *minor* mode and its keymap
shadows `vterm-mode-map' (Emacs gives minor-mode keymaps a higher
lookup precedence than major-mode keymaps).  Without this override
PageUp/PageDown would scroll the Emacs buffer instead of being sent
to the terminal -- programs like `less' or `man' would never see
them.  We attach this map via `minor-mode-overriding-map-alist' in
vterm buffers, which restores major-mode-like priority for these
two keys *only* while pixel-scroll is enabled, leaving wheel-scroll
behaviour unchanged.")

(defun emacs.d/vterm--install-pixel-scroll-passthrough ()
  "Send PageUp/PageDown to the terminal even with `pixel-scroll-precision-mode' on.
Hooked on `vterm-mode-hook' so it runs once per vterm buffer.
The override is keyed on `pixel-scroll-precision-mode' so it only
takes effect when that minor mode is active; if you ever turn pixel
scroll off, the entry becomes inert and ordinary `vterm-mode-map'
bindings (which already route both keys to `vterm--self-insert')
take over again."
  (setq-local minor-mode-overriding-map-alist
              (cons (cons 'pixel-scroll-precision-mode
                          emacs.d/vterm--pixel-scroll-passthrough-map)
                    (assq-delete-all 'pixel-scroll-precision-mode
                                     minor-mode-overriding-map-alist))))

(with-eval-after-load 'vterm
  (advice-add 'vterm--filter :after #'emacs.d/vterm-update-current-host)
  ;; Bind cross-to-remote commands directly on the keymap rather than
  ;; via use-package's :bind, which can silently no-op when the module
  ;; is reloaded after vterm has already been set up.
  (define-key vterm-mode-map (kbd "C-c f") #'emacs.d/vterm-find-file-remote)
  (define-key vterm-mode-map (kbd "C-c d") #'emacs.d/vterm-dired-remote)
  ;; Restore PageUp/PageDown passthrough in every new vterm buffer
  ;; (see `emacs.d/vterm--install-pixel-scroll-passthrough' for the why).
  ;; Also retro-apply to vterm buffers that already exist when this
  ;; module is reloaded, so the user does not have to re-open them.
  (add-hook 'vterm-mode-hook
            #'emacs.d/vterm--install-pixel-scroll-passthrough)
  (dolist (buf (buffer-list))
    (with-current-buffer buf
      (when (derived-mode-p 'vterm-mode)
        (emacs.d/vterm--install-pixel-scroll-passthrough))))
  ;; Add the chain indicator to every mode line (the function returns
  ;; nil outside vterm buffers, so it's invisible elsewhere).  Avoid
  ;; double-registration on reload.
  (let ((segment '(:eval (emacs.d/vterm--mode-line-tramp))))
    (unless (member segment mode-line-misc-info)
      (setq mode-line-misc-info (append mode-line-misc-info (list segment))))))

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
