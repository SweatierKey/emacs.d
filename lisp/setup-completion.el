;;; setup-completion.el --- Minibuffer + in-buffer completion -*- lexical-binding: t; -*-

;; The "modern" Emacs completion stack, kept small and modular.  Each
;; package does one thing well and they compose freely:
;;
;;   * `vertico'     -- vertical completion UI in the minibuffer
;;                      (replaces the default horizontal list);
;;   * `marginalia'  -- adds annotations next to each candidate
;;                      (file size, command keybinding, docstring snippet);
;;   * `orderless'   -- a fuzzy-ish completion style that lets you type
;;                      space-separated tokens in any order ("buf rev" matches
;;                      `revert-buffer'); much nicer than substring or
;;                      flex matching alone;
;;   * `consult'     -- a big collection of "search and pick" commands
;;                      (buffers, lines, ripgrep, imenu, ...) that all use
;;                      the same minibuffer UI;
;;   * `corfu'       -- popup completion *inside* a buffer (think
;;                      VSCode-style autocomplete);
;;   * `cape'        -- extra completion-at-point backends for `corfu'
;;                      (file paths, dabbrev, keywords);
;;   * `which-key'   -- pops up a hint of available key bindings after a
;;                      prefix.  Built into Emacs 30, no install needed.

;;; Code:

;; ---------------------------------------------------------------------------
;; vertico -- minibuffer UI
;; ---------------------------------------------------------------------------
(use-package vertico
  :init (vertico-mode 1)
  :custom
  (vertico-cycle t)            ;; wrap around at the top/bottom of the list
  (vertico-resize t)           ;; let the minibuffer grow/shrink with results
  (vertico-count 14))          ;; show this many candidates by default

;; ---------------------------------------------------------------------------
;; marginalia -- annotations
;; ---------------------------------------------------------------------------
(use-package marginalia
  :after vertico
  :init (marginalia-mode 1))

;; ---------------------------------------------------------------------------
;; orderless -- token-based fuzzy matching
;; ---------------------------------------------------------------------------
(use-package orderless
  :custom
  ;; Use orderless globally, but fall back to the built-in `basic' style
  ;; when nothing else matches -- this is necessary for things like TRAMP
  ;; remote file completion, which depend on prefix matching to work.
  (completion-styles '(orderless basic))
  (completion-category-overrides
   '((file (styles basic partial-completion)))))

;; ---------------------------------------------------------------------------
;; consult -- search and navigate everything
;; ---------------------------------------------------------------------------
;;
;; The bindings below replace a few stock commands with their consult-
;; powered equivalents.  `M-y' for kill-ring browsing and `C-s' (isearch)
;; -> `consult-line' are the two that most people fall in love with first.
(use-package consult
  :bind
  (("C-x b"   . consult-buffer)        ;; switch buffer with live preview
   ("C-x 4 b" . consult-buffer-other-window)
   ("C-x p b" . consult-project-buffer)
   ("M-y"     . consult-yank-pop)      ;; browse kill ring
   ("M-g g"   . consult-goto-line)
   ("M-g i"   . consult-imenu)         ;; jump to symbols in the current file
   ("M-s l"   . consult-line)          ;; "I-search but better"
   ("M-s r"   . consult-ripgrep)       ;; project-wide grep, requires `rg'
   ("M-s f"   . consult-find))         ;; file finder, requires `find'/`fd'
  :custom
  (consult-narrow-key "<")             ;; press `<' to narrow to a category
  (consult-preview-key 'any))          ;; preview as soon as you focus a candidate

;; ---------------------------------------------------------------------------
;; corfu -- in-buffer popup completion
;; ---------------------------------------------------------------------------
(use-package corfu
  :init (global-corfu-mode 1)
  :custom
  (corfu-auto t)                ;; pop up automatically as you type
  (corfu-auto-prefix 2)         ;; ...after this many characters
  (corfu-auto-delay 0.1)        ;; ...with this much idle delay
  (corfu-cycle t)               ;; wrap around the candidate list
  (corfu-quit-no-match 'separator)
  (corfu-preselect 'prompt)
  ;; Show docstring of the highlighted candidate in the echo area.
  (corfu-echo-documentation 0.25))

;; ---------------------------------------------------------------------------
;; cape -- extra completion-at-point backends
;; ---------------------------------------------------------------------------
;;
;; Eglot already provides language-aware completion via
;; `completion-at-point-functions'.  `cape' adds general-purpose ones --
;; file paths, words from open buffers, keywords -- so completion still
;; works in buffers with no LSP backend.
(use-package cape
  :init
  (add-to-list 'completion-at-point-functions #'cape-dabbrev)
  (add-to-list 'completion-at-point-functions #'cape-file)
  (add-to-list 'completion-at-point-functions #'cape-keyword))

;; ---------------------------------------------------------------------------
;; which-key (built-in on Emacs 30+)
;; ---------------------------------------------------------------------------
;;
;; Type a prefix like `C-x' and wait half a second; a popup at the bottom
;; of the screen lists every key bound under that prefix.  Invaluable
;; while learning Emacs and still useful as a power user.
(use-package which-key
  :ensure nil                ;; bundled with Emacs 30
  :diminish which-key-mode
  :init
  (setq which-key-idle-delay 0.5
        which-key-popup-type 'minibuffer)
  :config
  (which-key-mode 1))

(provide 'setup-completion)
;;; setup-completion.el ends here
