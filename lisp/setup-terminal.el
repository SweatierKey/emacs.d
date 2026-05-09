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

(defvar-local emacs.d/vterm-tab-name nil
  "Last tab title applied for this vterm buffer.
Used to find the right tab to rename when the prompt host changes.")

(defcustom emacs.d/vterm-prompt-host-regexp
  "[][:alnum:]_.-]*@\\([[:alnum:]_.-]+\\)[ :]"
  "Regexp used to extract the current hostname from a shell prompt.
Capture group 1 must be the hostname."
  :type 'regexp :group 'emacs.d)

(defun emacs.d/vterm-extract-prompt-host ()
  "Return the hostname captured by the most recent prompt-like match."
  (save-excursion
    (goto-char (point-max))
    (let ((window-start (max (point-min)
                             (save-excursion (forward-line -50) (point)))))
      (when (re-search-backward emacs.d/vterm-prompt-host-regexp
                                window-start t)
        (match-string-no-properties 1)))))

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

(defun emacs.d/vterm-update-current-host (&rest _ignored)
  "Refresh the host derived from the prompt and rename the tab if needed.
Hooked as `:after' advice on `vterm--filter'."
  (when (derived-mode-p 'vterm-mode)
    (let ((new-host (emacs.d/vterm-extract-prompt-host)))
      (when (and new-host
                 (not (equal new-host emacs.d/vterm-current-host)))
        (setq-local emacs.d/vterm-current-host new-host)
        (let* ((bastion      emacs.d/vterm-bastion-name)
               (new-tab-name (if bastion
                                 (format "%s: %s" bastion new-host)
                               new-host)))
          (when (and (bound-and-true-p tab-bar-mode)
                     emacs.d/vterm-tab-name
                     (not (string-equal new-tab-name
                                        emacs.d/vterm-tab-name)))
            (when (emacs.d/tab-bar-rename-tab-by-name
                   emacs.d/vterm-tab-name new-tab-name)
              (setq-local emacs.d/vterm-tab-name new-tab-name))))))))

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
