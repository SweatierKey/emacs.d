;;; setup-prog.el --- Programming: LSP, linting, docs, syntax -*- lexical-binding: t; -*-

;; This module wires up the modern Emacs programming experience using
;; what already ships in Emacs 29+, plus a couple of small helpers from
;; ELPA.  Nothing exotic, nothing magic.
;;
;;   * `eglot'             -- Language Server Protocol (LSP) client.
;;                            Zero config for most languages: install the
;;                            language server somewhere on `PATH', open a
;;                            file, and you get completion, go-to-def,
;;                            find-references, rename, hover docs, format,
;;                            code actions -- the lot.
;;   * `flymake'           -- on-the-fly syntax/semantic checking.  Eglot
;;                            forwards LSP diagnostics through it.
;;   * `flymake-shellcheck'-- standalone Flymake backend for ShellCheck;
;;                            useful for `sh-mode' even when no LSP server
;;                            is running.
;;   * `eldoc'             -- documentation in the echo area for the
;;                            symbol at point.  Eglot drives this too.
;;   * `treesit'           -- tree-sitter integration.  Better syntax
;;                            highlighting and structural navigation than
;;                            the legacy regex-based `font-lock'.
;;   * `treesit-auto'      -- helper that downloads grammars on demand
;;                            and remaps `foo-mode' to `foo-ts-mode' when
;;                            a grammar is available.
;;
;; ---------------------------------------------------------------------------
;; How language servers get installed
;; ---------------------------------------------------------------------------
;;
;; Eglot does *not* install language servers for you (unlike `lsp-mode',
;; which ships `lsp-install-server', or `mason.nvim' on the Neovim side).
;; You install the server through whatever package manager makes sense,
;; and Eglot picks it up from `PATH'.  Three reasonable strategies:
;;
;;   1. System-wide: distro packages.  Quick, but requires `sudo' and
;;      pins you to whatever version your distro shipped.
;;        Debian/Ubuntu:  `sudo apt install clangd gopls'
;;        Fedora:         `sudo dnf install clang-tools-extra gopls'
;;        Arch:           `sudo pacman -S clang gopls'
;;
;;   2. Per-user (recommended): no `sudo', easy to upgrade, isolates from
;;      system Python/Node:
;;        Python:    `pip install --user python-lsp-server'  (or `pyright')
;;        Rust:      `rustup component add rust-analyzer'
;;        Go:        `go install golang.org/x/tools/gopls@latest'
;;        Node CLI:  `npm i -g typescript-language-server typescript'
;;        Brew/mac:  `brew install <server>'
;;
;;   3. Per-project (most reproducible): `nix develop', `mise', `asdf',
;;      a devcontainer, or just a project-local virtualenv.  Each project
;;      brings its own pinned version, no global state to drift.
;;
;; ---------------------------------------------------------------------------
;; Cheat-sheet of useful language servers
;; ---------------------------------------------------------------------------
;;
;; Pick what you actually use; you don't need them all.  The install
;; command is the most popular one as of 2026; replace with your package
;; manager of choice.
;;
;;   Language        | Server                     | Install (one option)
;;   ----------------+----------------------------+--------------------------------------------------
;;   Python          | python-lsp-server (pylsp)  | pip install --user 'python-lsp-server[all]'
;;                   | pyright                    | npm i -g pyright
;;                   | ruff (linter+fmt as LSP)   | pip install --user ruff-lsp
;;   Rust            | rust-analyzer              | rustup component add rust-analyzer
;;   C / C++ / Obj-C | clangd                     | apt install clangd  /  brew install llvm
;;   Go              | gopls                      | go install golang.org/x/tools/gopls@latest
;;   TypeScript / JS | typescript-language-server | npm i -g typescript-language-server typescript
;;   Bash            | bash-language-server (*)   | npm i -g bash-language-server
;;   HTML/CSS/JSON   | vscode-langservers-extracted | npm i -g vscode-langservers-extracted
;;   YAML            | yaml-language-server       | npm i -g yaml-language-server
;;   TOML            | taplo                      | cargo install taplo-cli --features lsp
;;   Markdown        | marksman                   | brew install marksman  (or release binary)
;;   Lua             | lua-language-server        | brew install lua-language-server
;;   Dockerfile      | dockerfile-language-server | npm i -g dockerfile-language-server-nodejs
;;   Terraform       | terraform-ls               | brew install hashicorp/tap/terraform-ls
;;   Nix             | nil                        | nix profile install nixpkgs#nil
;;   Zig             | zls                        | https://zigtools.org/zls/install/
;;   Haskell         | haskell-language-server    | ghcup install hls
;;   OCaml           | ocaml-lsp-server           | opam install ocaml-lsp-server
;;   Java            | eclipse.jdt.ls (jdtls)     | brew install jdtls
;;   Kotlin          | kotlin-language-server     | brew install kotlin-language-server
;;   Elixir          | elixir-ls                  | brew install elixir-ls
;;   Ruby            | solargraph                 | gem install --user-install solargraph
;;   PHP             | intelephense               | npm i -g intelephense
;;   LaTeX           | texlab                     | cargo install --git https://github.com/latex-lsp/texlab
;;   Vue             | vue-language-server (volar)| npm i -g @vue/language-server
;;   Svelte          | svelte-language-server     | npm i -g svelte-language-server
;;
;; (*) `bash-language-server' ships shellcheck integration internally, so
;;     you get the same warnings as the standalone `shellcheck' CLI plus
;;     LSP features (rename, go-to-def for functions, ...).

;;; Code:

;; ---------------------------------------------------------------------------
;; tree-sitter
;; ---------------------------------------------------------------------------
(use-package treesit
  :ensure nil                     ;; built in
  :custom
  ;; Maximum tree-sitter highlighting detail.  The default 3 hides some
  ;; useful faces (e.g. variable definitions vs. usages).
  (treesit-font-lock-level 4))

(use-package treesit-auto
  :custom (treesit-auto-install 'prompt)   ;; ask before downloading grammars
  :config
  (treesit-auto-add-to-auto-mode-alist 'all)
  (global-treesit-auto-mode 1))

;; ---------------------------------------------------------------------------
;; Eglot -- LSP client
;; ---------------------------------------------------------------------------
(use-package eglot
  :ensure nil
  :custom
  ;; Don't log every JSON message to a buffer -- it's slow and noisy.
  ;; Re-enable temporarily when debugging a server issue.
  (eglot-events-buffer-size 0)
  ;; Some servers report a confidence-or-detail level for every keystroke.
  ;; Trim the noise down to the diagnostics we actually act on.
  (eglot-extend-to-xref t)
  :bind
  (:map eglot-mode-map
        ("C-c l a" . eglot-code-actions)
        ("C-c l r" . eglot-rename)
        ("C-c l f" . eglot-format)
        ("C-c l d" . eldoc))
  :hook
  ;; Auto-start Eglot for these modes.  Add (or remove) entries as your
  ;; language palette grows.  Modes are listed in their tree-sitter form
  ;; where one exists; Eglot is happy with either.  Eglot only starts if
  ;; the matching server is found on `PATH', so it's safe to leave entries
  ;; here for languages whose servers you haven't installed yet -- you
  ;; just won't get LSP features for those until you install the server.
  ((python-base-mode  . eglot-ensure)
   (python-ts-mode    . eglot-ensure)
   (rust-ts-mode      . eglot-ensure)
   (c-ts-mode         . eglot-ensure)
   (c++-ts-mode       . eglot-ensure)
   (go-ts-mode        . eglot-ensure)
   (typescript-ts-mode . eglot-ensure)
   (tsx-ts-mode       . eglot-ensure)
   (js-ts-mode        . eglot-ensure)
   (sh-mode           . eglot-ensure)
   (bash-ts-mode      . eglot-ensure)
   (lua-ts-mode       . eglot-ensure)
   (yaml-ts-mode      . eglot-ensure)
   (json-ts-mode      . eglot-ensure)
   (toml-ts-mode      . eglot-ensure)
   (dockerfile-ts-mode . eglot-ensure)
   (html-mode         . eglot-ensure)
   (css-mode          . eglot-ensure)
   (markdown-mode     . eglot-ensure)
   (haskell-mode      . eglot-ensure)
   (haskell-ts-mode   . eglot-ensure)
   (java-mode         . eglot-ensure)
   (java-ts-mode      . eglot-ensure)
   (kotlin-mode       . eglot-ensure)
   (kotlin-ts-mode    . eglot-ensure)
   (elixir-mode       . eglot-ensure)
   (elixir-ts-mode    . eglot-ensure)
   (ruby-mode         . eglot-ensure)
   (ruby-ts-mode      . eglot-ensure)
   (php-mode          . eglot-ensure)
   (zig-mode          . eglot-ensure)
   (nix-mode          . eglot-ensure)
   (LaTeX-mode        . eglot-ensure)))

;; ---------------------------------------------------------------------------
;; Flymake -- on-the-fly diagnostics
;; ---------------------------------------------------------------------------
(use-package flymake
  :ensure nil
  :hook (prog-mode . flymake-mode)
  :bind
  (:map flymake-mode-map
        ("M-n" . flymake-goto-next-error)
        ("M-p" . flymake-goto-prev-error)
        ("C-c ! l" . flymake-show-buffer-diagnostics)
        ("C-c ! L" . flymake-show-project-diagnostics)))

;; ---------------------------------------------------------------------------
;; ShellCheck for shell scripts
;; ---------------------------------------------------------------------------
;;
;; If you have `bash-language-server' installed, Eglot will already give
;; you ShellCheck diagnostics through LSP.  This package is the lightweight
;; fallback for the (very common) case where the LSP server is missing:
;; it shells out to the standalone `shellcheck' binary and feeds the
;; results into Flymake.  Both can coexist -- the LSP entries simply take
;; priority when present.
;;
;; Install ShellCheck itself with your package manager:
;;     apt install shellcheck   /   brew install shellcheck   /   dnf install ShellCheck
;;
;; For best results in Bash specifically, the file should declare its
;; dialect via a shebang or via `# shellcheck shell=bash'.
(use-package flymake-shellcheck
  :commands flymake-shellcheck-load
  :hook ((sh-mode      . flymake-shellcheck-load)
         (bash-ts-mode . flymake-shellcheck-load)))

;; ---------------------------------------------------------------------------
;; Eldoc -- documentation in the echo area / dedicated buffer
;; ---------------------------------------------------------------------------
(use-package eldoc
  :ensure nil
  :diminish eldoc-mode
  :custom
  ;; If Eldoc has more than one source of documentation, compose them all
  ;; instead of showing only the first one.
  (eldoc-documentation-strategy 'eldoc-documentation-compose-eagerly)
  ;; Don't truncate the docstring -- spill into a dedicated *eldoc* buffer
  ;; if it doesn't fit in the echo area.
  (eldoc-echo-area-use-multiline-p t))

;; ---------------------------------------------------------------------------
;; Misc programming niceties
;; ---------------------------------------------------------------------------

;; Smerge resolves merge conflict markers semi-automatically; turn it on
;; whenever a file with conflict markers is visited.
(add-hook 'find-file-hook
          (lambda ()
            (save-excursion
              (goto-char (point-min))
              (when (re-search-forward "^<<<<<<< " nil t)
                (smerge-mode 1)))))

;; Compilation buffers should respect ANSI color escapes (build tools love
;; them) and scroll to follow the output.
(setq compilation-scroll-output 'first-error
      compilation-ask-about-save nil)

(use-package ansi-color
  :ensure nil
  :hook (compilation-filter . ansi-color-compilation-filter))

(provide 'setup-prog)
;;; setup-prog.el ends here
