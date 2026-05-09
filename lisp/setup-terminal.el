;;; setup-terminal.el --- vterm + tab-bar with dynamic title -*- lexical-binding: t; -*-

;; The "Emacs as a daily SSH terminal" stack.  This module gives you
;;
;;   * `vterm', a fast NCURSES-compatible terminal that runs full TUIs
;;     (htop, vi, less, tmux, interactive password prompts) without
;;     issues.  We prefer it over the built-in `term'/`ansi-term'/
;;     `eshell' because it's the only one that handles complex remote
;;     sessions transparently;
;;
;;   * `tab-bar-mode' configured so that each remote session lives in its
;;     own tab, and the *tab title is dynamic*: it shows the bastion
;;     name you started from (set when you opened the session) plus the
;;     hostname extracted from the current shell prompt.  When you `ssh'
;;     from the bastion to a target server, the second part of the
;;     title updates automatically the moment a new prompt is rendered.
;;
;; The dynamic title uses two pieces of information:
;;
;;   1. `emacs.d/vterm-bastion-name' (buffer-local, string).  Set when
;;      the session is opened by `setup-ssh-sessions'.  Static for the
;;      lifetime of the session.
;;
;;   2. The hostname extracted from the latest visible shell prompt by
;;      `emacs.d/vterm-extract-prompt-host'.  Updates on every redraw.
;;      Works with the typical Linux PS1 forms:
;;
;;          [user@host pwd]$
;;          user@host:pwd$
;;          user@host pwd>
;;
;;      No remote `.bashrc' modification required -- we just look at
;;      what's already on screen.

;;; Code:

(require 'subr-x)        ;; for `string-trim'

;; ---------------------------------------------------------------------------
;; vterm
;; ---------------------------------------------------------------------------
;;
;; First boot will compile a small C module against `libvterm'.  The
;; package tries the system `libvterm' first; if `libvterm-dev' (Debian)
;; / `libvterm-devel' (RHEL) headers are missing, it falls back to
;; downloading and building libvterm via cmake's FetchContent.  Either
;; way, you need `cmake', `gcc' and `libtool' installed.
(use-package vterm
  :commands (vterm vterm-other-window)
  :custom
  ;; A few thousand lines of scrollback is plenty for shell sessions and
  ;; keeps memory in check on long-running connections.
  (vterm-max-scrollback 10000)
  ;; Don't kill the buffer when the shell exits -- handy when an SSH
  ;; connection drops, you can read the last error message before the
  ;; buffer goes away.  Use `q' or `kill-buffer' to dismiss it.
  (vterm-kill-buffer-on-exit nil)
  ;; Allow programs running inside vterm to set the buffer title via
  ;; OSC sequences (\033]2;TITLE\007).  We don't *rely* on this for the
  ;; tab title -- our prompt parser works without it -- but if a remote
  ;; tmux config or a colleague's `.bashrc' already emits OSC, we honour
  ;; it.
  (vterm-buffer-name-string "vterm: %s")
  ;; Use the same shell as the user's login shell rather than hard-coding
  ;; one.  TRAMP / SSH sessions ignore this anyway.
  (vterm-shell (or explicit-shell-file-name
                   (getenv "SHELL")
                   "/bin/bash"))
  :bind
  (:map vterm-mode-map
        ;; Make `C-c C-t' toggle copy-mode the same way it does in tmux,
        ;; so muscle memory carries over.  In copy-mode you get normal
        ;; Emacs movement; press the same key again to resume sending
        ;; input to the terminal.
        ("C-c C-t" . vterm-copy-mode)))

;; ---------------------------------------------------------------------------
;; tab-bar-mode
;; ---------------------------------------------------------------------------
;;
;; tab-bar-mode is built in.  We turn it on globally and tweak it so
;; that each tab can have a custom name, and so that the tab bar only
;; shows up when there are at least two tabs (no visual noise during
;; normal editing).
(use-package tab-bar
  :ensure nil
  :init
  (setq tab-bar-show 1                    ;; auto-hide when only one tab
        tab-bar-new-tab-choice "*scratch*" ;; new tabs land on scratch
        tab-bar-close-button-show nil      ;; less clutter
        tab-bar-new-button-show nil)
  :bind
  (("C-x t t" . tab-bar-new-tab)
   ("C-x t k" . tab-bar-close-tab)
   ("C-x t l" . tab-bar-switch-to-next-tab)
   ("C-x t h" . tab-bar-switch-to-prev-tab)
   ("C-x t r" . tab-bar-rename-tab))
  :config
  (tab-bar-mode 1))

;; ---------------------------------------------------------------------------
;; Dynamic tab title for vterm sessions
;; ---------------------------------------------------------------------------
;;
;; The two pieces:
;;
;;   * `emacs.d/vterm-bastion-name'  -- set once when the session is
;;     opened (by `setup-ssh-sessions').  Buffer-local; if nil we fall
;;     back to using only the prompt-derived hostname.
;;
;;   * `emacs.d/vterm-current-host'  -- updated by parsing the visible
;;     prompt.  Buffer-local; recomputed by an after-change hook on
;;     vterm output.
;;
;; The composed title is then shown via the tab-bar's
;; `tab-bar-tab-name-function' so that the active vterm tab always
;; reflects "BASTION: HOST".
;;
;; On non-vterm buffers we fall back to the default tab name behaviour.

(defvar-local emacs.d/vterm-bastion-name nil
  "Name of the bastion / jump host this vterm session was opened against.
Set by `setup-ssh-sessions' when the session is created and not modified
afterwards.  Used as the static prefix of the dynamic tab title.")

(defvar-local emacs.d/vterm-current-host nil
  "Hostname extracted from the most recent visible shell prompt.
Updated by `emacs.d/vterm-update-current-host', which runs from a
vterm output hook.  May be nil while the prompt is still being drawn.")

(defcustom emacs.d/vterm-prompt-host-regexp
  ;; Match the user@host part of common Linux prompts:
  ;;
  ;;   [user@host pwd]$
  ;;    user@host:pwd$
  ;;    user@host pwd>
  ;;    [user@host.fqdn ~]#
  ;;
  ;; We capture the host (group 1).  Hostnames may contain letters,
  ;; digits, dashes, dots, underscores -- the usual DNS label charset
  ;; plus a couple of conveniences.
  "[][:alnum:]_.-]*@\\([[:alnum:]_.-]+\\)[ :]"
  "Regexp used to extract the current hostname from a shell prompt.
Capture group 1 must be the hostname.  Adjust to your `PS1' if it
deviates from the typical Linux defaults.

The regexp is anchored neither to the start nor end of the line because
prompts in the wild are wrapped, decorated with timestamps, etc.  We
just want the last match in the visible buffer."
  :group 'emacs.d
  :type 'regexp)

(defun emacs.d/vterm-extract-prompt-host ()
  "Walk back from `point-max' looking for the most recent prompt-like
match of `emacs.d/vterm-prompt-host-regexp', and return the captured
hostname.  Returns nil if no match is found.

Searches the last 50 lines so we don't pay a full-buffer regex on every
output update -- that's far enough to find a prompt even if the user
just pasted a screenful of output."
  (save-excursion
    (goto-char (point-max))
    (let* ((window-end   (point))
           (window-start (max (point-min)
                              (save-excursion
                                (forward-line -50)
                                (point)))))
      (when (re-search-backward emacs.d/vterm-prompt-host-regexp
                                window-start t)
        (match-string-no-properties 1)))))

(defun emacs.d/vterm-update-current-host (&rest _ignored)
  "Refresh `emacs.d/vterm-current-host' from the visible prompt and
trigger a tab-bar redraw if the value changed."
  (when (derived-mode-p 'vterm-mode)
    (let ((new (emacs.d/vterm-extract-prompt-host)))
      (when (and new (not (equal new emacs.d/vterm-current-host)))
        (setq-local emacs.d/vterm-current-host new)
        (force-mode-line-update)
        (when (fboundp 'tab-bar--update-tab-bar-lines)
          (tab-bar--update-tab-bar-lines))))))

;; vterm doesn't expose a clean "after every redraw" hook, but it does
;; advertise `vterm--filter' as the function it pipes terminal output
;; through.  Adding an :after advice is the most reliable way to react
;; to *any* terminal change, including ones that don't add visible
;; characters (cursor movement, color codes, ...).
(with-eval-after-load 'vterm
  (advice-add 'vterm--filter :after #'emacs.d/vterm-update-current-host))

(defun emacs.d/vterm-tab-name (tab)
  "Return the tab name to display for TAB.

If TAB's underlying buffer is a vterm session we compose the name as
\"BASTION: HOST\" using `emacs.d/vterm-bastion-name' and
`emacs.d/vterm-current-host'.  Either part may be missing -- when both
are nil we fall back to the default `tab-bar-tab-name-current'.

Called by tab-bar through `tab-bar-tab-name-function', so the title
refreshes every time the tab bar repaints."
  (let* ((buf (window-buffer (or (cdr (assq 'wc tab))
                                 (selected-window))))
         (mode    (buffer-local-value 'major-mode buf))
         (bastion (buffer-local-value 'emacs.d/vterm-bastion-name buf))
         (host    (buffer-local-value 'emacs.d/vterm-current-host  buf)))
    (cond
     ((and (eq mode 'vterm-mode) bastion host)
      (format "%s: %s" bastion host))
     ((and (eq mode 'vterm-mode) bastion)
      bastion)
     ((and (eq mode 'vterm-mode) host)
      host)
     (t
      ;; Default behaviour for non-vterm tabs (just the buffer name).
      (buffer-name buf)))))

(setq tab-bar-tab-name-function #'emacs.d/vterm-tab-name)

(provide 'setup-terminal)
;;; setup-terminal.el ends here
