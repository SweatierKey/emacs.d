;;; setup-ui.el --- Theme, font, scrolling, line numbers -*- lexical-binding: t; -*-

;;; Commentary:
;; See config.org, section "Look and feel".

;;; Code:

(require 'cl-lib)

(defun emacs.d/face-attribute-rewrite-nil (orig-fn face frame &rest props)
  "Translate nil to `unspecified' for colour-like face attributes.

Older themes still pass nil to mean \"no override\"; Emacs 30 emits a
warning in that case.  Used as `:around' advice on
`set-face-attribute'."
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
  :config (load-theme 'gruber-darker :no-confirm))

(defcustom emacs.d/font-candidates
  '("Comic Code Ligatures"
    "Comic Code"
    "Iosevka"
    "JetBrains Mono"
    "Fira Code"
    "Cascadia Code"
    "DejaVu Sans Mono")
  "Ranked list of fixed-pitch fonts to try, first installed wins."
  :type '(repeat string)
  :group 'emacs.d)

(defcustom emacs.d/font-height 220
  "Height (1/10 of a point) for the default face."
  :type 'integer :group 'emacs.d)

(defun emacs.d/first-installed-font (candidates)
  "Return the first font in CANDIDATES that is installed, or nil."
  (seq-find (lambda (f) (find-font (font-spec :name f))) candidates))

(when-let ((font (emacs.d/first-installed-font emacs.d/font-candidates)))
  (set-face-attribute 'default nil :font font :height emacs.d/font-height))

(add-hook 'prog-mode-hook #'display-line-numbers-mode)
(add-hook 'prog-mode-hook #'hl-line-mode)
(setq display-line-numbers-width-start t)
(column-number-mode 1)
(line-number-mode   1)

(setq scroll-conservatively           101
      scroll-margin                   3
      scroll-preserve-screen-position t
      auto-window-vscroll             nil)

(when (fboundp 'pixel-scroll-precision-mode)
  (pixel-scroll-precision-mode 1))

(setq show-paren-delay 0)
(show-paren-mode 1)

(set-fringe-mode 8)

(setq frame-title-format
      '((:eval (if (buffer-file-name)
                   (abbreviate-file-name (buffer-file-name))
                 "%b"))
        " — Emacs"))

(provide 'setup-ui)
;;; setup-ui.el ends here
