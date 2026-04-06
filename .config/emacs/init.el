;;; init.el --- Minimal Evil Emacs -*- lexical-binding: t; -*-

;; Package setup
(require 'package)
(add-to-list 'package-archives '("melpa" . "https://melpa.org/packages/") t)
(package-initialize)

;; Evil
(use-package evil
  :ensure t
  :init
  (setq evil-want-integration t
        evil-want-keybinding nil
        evil-want-C-u-scroll t
        evil-undo-system 'undo-redo
        evil-leader/leader "SPC")
  :config
  (evil-mode 1)

  ;; SPC as leader in normal/visual, unbind SPC first
  (evil-define-key '(normal visual) 'global (kbd "SPC") nil)

  ;; files & buffers -- a bit hand holding but ok
  (evil-define-key 'normal 'global
    (kbd "SPC SPC") 'switch-to-buffer
    (kbd "SPC f f") 'find-file
    (kbd "SPC s f") 'project-find-file
    (kbd "SPC s g") 'project-find-regexp
    (kbd "SPC -")   'dired-jump)
)

(use-package evil-collection
  :ensure t
  :after evil
  :config
  (evil-collection-init))

(use-package evil-commentary
  :ensure t
  :after evil
  :config
  (evil-commentary-mode))

;; Which-key (built-in in 30, need package in 29)
(use-package which-key
  :ensure t
  :config
  (which-key-mode))

;; Built-in: vertical completion
(fido-vertical-mode 1)

;; Built-in: LSP
(use-package eglot
  :hook ((python-mode python-ts-mode
          go-mode go-ts-mode
          js-mode js-ts-mode
          typescript-ts-mode
          rust-ts-mode
          c-mode c-ts-mode
          c++-mode c++-ts-mode) . eglot-ensure))

;; Built-in: tree-sitter mode remapping
(setq major-mode-remap-alist
      '((python-mode    . python-ts-mode)
        (javascript-mode . js-ts-mode)
        (typescript-mode . typescript-ts-mode)
        (json-mode      . json-ts-mode)
        (css-mode       . css-ts-mode)
        (yaml-mode      . yaml-ts-mode)
        (bash-mode      . bash-ts-mode)
        (c-mode         . c-ts-mode)
        (c++-mode       . c++-ts-mode)
        (go-mode        . go-ts-mode)
        (rust-mode      . rust-ts-mode)))

;; Built-in: misc
;;   bright themes: tango, whiteboard, modus-operandi, adwaita
;;   dark themes: deeper-blue, wombat, tango-dark, 
(load-theme 'tango t)
(repeat-mode 1)
(pixel-scroll-precision-mode 1)
(recentf-mode 1)
(savehist-mode 1)
(save-place-mode 1)
(electric-pair-mode 1)

;; UI cleanup
(menu-bar-mode -1)
(tool-bar-mode -1)
(scroll-bar-mode -1)
(setq inhibit-startup-screen t
      ring-bell-function 'ignore
      display-line-numbers-type 'relative)
(global-display-line-numbers-mode 1)
(column-number-mode 1)

;; Sane defaults
(setq make-backup-files nil
      auto-save-default nil
      create-lockfiles nil
      custom-file (expand-file-name "custom.el" user-emacs-directory))
(when (file-exists-p custom-file)
  (load custom-file))

;;; init.el ends here
