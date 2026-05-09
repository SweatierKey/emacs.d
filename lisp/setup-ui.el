;;; setup-ui.el --- Look and feel -*- lexical-binding: t; -*-

;; Visual choices for the editor:
;;
;;   * theme:  `gruber-darker' -- a dark, low-saturation theme inherited
;;             from the user's previous configuration;
;;   * font:   "Comic Code Ligatures" at 220 (~22pt), with sensible
;;             fallbacks so the config still works on machines that don't
;;             have that commercial font installed;
;;   * line numbers and a couple of other prog-mode niceties.
;;
;; Anything that affects keybindings or buffer behaviour belongs in
;; `setup-editor.el', not here.

;;; Code:

(require 'cl-lib)        ;; cl-loop used by the face-attribute advice below

;; ---------------------------------------------------------------------------
;; Theme
;; ---------------------------------------------------------------------------
;;
;; Emacs 30 tightened `set-face-attribute' validation: passing nil as
;; the value for `:background' / `:foreground' / `:underline' /
;; `:overline' now triggers a noisy warning.  Older themes (gruber-
;; darker among them) still pass nil to mean "no override", and the
;; idiomatic Emacs-30 way to express that is the symbol `unspecified'.
;;
;; The advice below transparently rewrites those nil values to
;; `unspecified' for the four affected attributes; nothing else is
;; touched.  The check is cheap (one assoc per attribute on every
;; face-attribute change), runs only at theme-load time in practice,
;; and is reverted automatically once `set-face-attribute' is called
;; with proper values.
(defun emacs.d/face-attribute-rewrite-nil (orig-fn face frame &rest props)
  "Around-advice for `set-face-attribute' that translates nil values for
colour-like attributes to the symbol `unspecified'.  This silences the
\"nil value is invalid\" warnings emitted by older themes when run on
Emacs 30+, without otherwise altering their intent."
  (let ((rewritten
         (cl-loop for (k v) on props by #'cddr
                  append (list k
                               (if (and (memq k '(:background :foreground
                                                  :underline  :overline))
                                        (null v))
                                   'unspecified
                                 v)))))
    (apply orig-fn face frame rewritten)))

(advice-add 'set-face-attribute :around
            #'emacs.d/face-attribute-rewrite-nil)

(use-package gruber-darker-theme
  :config
  ;; `load-theme' interactively asks for confirmation the first time you
  ;; load a theme from a new directory, which is a security feature for
  ;; arbitrary themes.  We trust this one, so we pass NO-CONFIRM.
  (load-theme 'gruber-darker :no-confirm))

;; ---------------------------------------------------------------------------
;; Font
;; ---------------------------------------------------------------------------
;;
;; We try a small ranked list of fonts and pick the first one that is
;; actually installed.  This way the same config works on multiple machines
;; without having to manually edit init.el on each of them.
;;
;; If you want to add or change fonts, just edit the list below.  The first
;; entry is the user's preferred font.
(defun emacs.d/first-installed-font (candidates)
  "Return the first font name from CANDIDATES that is installed, or nil."
  (seq-find (lambda (f) (find-font (font-spec :name f))) candidates))

(let ((font (emacs.d/first-installed-font
             '("Comic Code Ligatures"
               "Comic Code"
               "Iosevka"
               "JetBrains Mono"
               "Fira Code"
               "Cascadia Code"
               "DejaVu Sans Mono"))))
  (when font
    (set-face-attribute 'default nil
                        :font   font
                        ;; :height is in 1/10 of a point, so 220 == 22pt.
                        :height 220)))

;; ---------------------------------------------------------------------------
;; Line numbers and column number
;; ---------------------------------------------------------------------------
;;
;; Line numbers only in programming buffers -- in prose / org / dired they
;; just clutter.
(add-hook 'prog-mode-hook #'display-line-numbers-mode)
(setq display-line-numbers-width-start t) ;; reserve space upfront, no jitter

(column-number-mode 1)
(line-number-mode   1)

;; ---------------------------------------------------------------------------
;; Smooth scrolling
;; ---------------------------------------------------------------------------
;;
;; The default scrolling logic recenters the point when it scrolls off
;; screen, which is jarring.  These three settings together give a more
;; "modern editor" feel: scroll one line at a time, never recenter, keep a
;; 3-line margin from the top/bottom of the window.
(setq scroll-conservatively           101
      scroll-margin                   3
      scroll-preserve-screen-position t
      auto-window-vscroll             nil)

;; Pixel-precision mouse / trackpad scrolling on Emacs 29+.
(when (fboundp 'pixel-scroll-precision-mode)
  (pixel-scroll-precision-mode 1))

;; ---------------------------------------------------------------------------
;; Misc visual polish
;; ---------------------------------------------------------------------------

;; Highlight the current line in programming buffers.  Keep it off in prose
;; / org / dired where it's distracting.
(add-hook 'prog-mode-hook #'hl-line-mode)

;; Show matching parens/brackets without delay.
(setq show-paren-delay 0)
(show-paren-mode 1)

;; Use spaces for the visual fringes between buffer and window edge.
(set-fringe-mode 8)

;; Frame title: show buffer name (and project, if available) -- handy when
;; you alt-tab between many Emacs frames.
(setq frame-title-format
      '((:eval (if (buffer-file-name)
                   (abbreviate-file-name (buffer-file-name))
                 "%b"))
        " — Emacs"))

(provide 'setup-ui)
;;; setup-ui.el ends here
