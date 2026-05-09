;;; setup-memory.el --- GC and memory tuning -*- lexical-binding: t; -*-

;; The goal of this module is to make Emacs feel snappy without burning
;; through RAM unnecessarily.  It does three things:
;;
;;   1. installs `gcmh-mode', which raises the GC threshold while you are
;;      *busy* (typing, scrolling, running commands) and lowers it during
;;      idle time -- exactly the opposite of the default behaviour, which
;;      tends to GC right when you press a key;
;;
;;   2. raises `read-process-output-max', the size of the buffer Emacs uses
;;      to slurp data coming back from subprocesses.  The default of 4 KiB
;;      is too small for LSP servers (Eglot, lsp-mode) that exchange
;;      hundreds of KiB of JSON per response and end up doing many tiny
;;      reads, each of which triggers redisplay;
;;
;;   3. tweaks a few built-in limits (history sizes, large-file warning
;;      thresholds, undo limits) for a less stuttery experience on modern
;;      hardware where 100 MiB of RAM is no longer a meaningful concern.

;;; Code:

;; ---------------------------------------------------------------------------
;; gcmh -- "garbage collector magic hack"
;; ---------------------------------------------------------------------------
;;
;; Tiny package (single file) that hooks into idle and busy events so the GC
;; only runs when it won't be felt by the user.  Defaults are sensible; we
;; only nudge the high threshold up a touch (16 MiB instead of the package
;; default 1 GiB which is overkill).
(use-package gcmh
  :diminish gcmh-mode
  :init
  (setq gcmh-idle-delay        'auto         ;; let gcmh figure it out
        gcmh-auto-idle-delay-factor 10
        gcmh-high-cons-threshold (* 16 1024 1024))
  :hook (emacs-startup . gcmh-mode))

;; ---------------------------------------------------------------------------
;; Subprocess I/O buffer
;; ---------------------------------------------------------------------------
;;
;; LSP servers communicate over stdio with potentially large JSON payloads.
;; A larger pipe buffer means fewer round-trips through the redisplay loop
;; and noticeably smoother completion / hover.
;;
;; 1 MiB is the value the LSP-mode and Eglot manuals recommend.  Going
;; higher rarely helps; going lower hurts.
(setq read-process-output-max (* 1024 1024))

;; By default `process-adaptive-read-buffering' adds latency to make slow
;; processes feel "smooth".  For LSP that's the wrong trade-off -- we want
;; the data as fast as possible.
(setq process-adaptive-read-buffering nil)

;; ---------------------------------------------------------------------------
;; History sizes
;; ---------------------------------------------------------------------------
;;
;; Most of these defaults date back to the 1990s and assume RAM is precious.
;; We're more generous: longer histories make `consult-history' and
;; `recentf' actually useful.
(setq history-length            1000
      history-delete-duplicates t
      kill-ring-max             300
      mark-ring-max             50
      global-mark-ring-max      50)

;; ---------------------------------------------------------------------------
;; Undo
;; ---------------------------------------------------------------------------
;;
;; The defaults silently truncate the undo history of files larger than
;; ~150 KiB, which is annoying when editing JSON/log/code-generated files.
;; Bumping the limits costs a few MiB at most.
(setq undo-limit          (* 4 1024 1024)        ;; soft cap before truncating
      undo-strong-limit   (* 6 1024 1024)        ;; hard cap
      undo-outer-limit    (* 64 1024 1024))      ;; per-command outer cap

;; ---------------------------------------------------------------------------
;; Large file warnings
;; ---------------------------------------------------------------------------
;;
;; Default is 10 MiB which trips on perfectly normal log files.  We bump it
;; to 100 MiB; anything larger really *should* prompt before opening because
;; font-lock and undo will choke.
(setq large-file-warning-threshold (* 100 1024 1024))

(provide 'setup-memory)
;;; setup-memory.el ends here
