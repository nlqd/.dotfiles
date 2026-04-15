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
  (evil-mode 1))

(use-package evil-collection
  :ensure t
  :after evil
  :config
  (evil-collection-init '(dired magit org eglot)))

(use-package evil-commentary
  :ensure t
  :after evil
  :config
  (evil-commentary-mode))

;; Git
(use-package magit
  :ensure t
  :defer t)

(use-package hyperbole
  :ensure t
  :defer t)

;; Research
(use-package org-roam
  :ensure t
  :defer t
  :custom
  (org-roam-directory (expand-file-name "~/org/roam"))
  :config
  (org-roam-db-autosync-mode))


;; version mismatch often
(setq major-mode-remap-alist
      '((python-mode     . python-ts-mode)
        (javascript-mode . js-ts-mode)
        (typescript-mode . typescript-ts-mode)
        (json-mode       . json-ts-mode)
        (css-mode        . css-ts-mode)
        (yaml-mode       . yaml-ts-mode)
        (bash-mode       . bash-ts-mode)
        (c-mode          . c-ts-mode)
        (c++-mode        . c++-ts-mode)
        (go-mode         . go-ts-mode)
        (rust-mode       . rust-ts-mode)))

(load-theme 'tango t)
(cond ((find-font (font-spec :name "Iosevka Nerd Font"))
       (set-frame-font "Iosevka Nerd Font-12"))
      ((find-font (font-spec :name "Berkeley Mono"))
       (set-frame-font "Berkeley Mono-11")))
(setq-default line-spacing 0.2)

(fido-vertical-mode 1)
(recentf-mode 1)
(savehist-mode 1)
(save-place-mode 1)
(electric-pair-mode 1)
(menu-bar-mode -1)
(tool-bar-mode -1)
(scroll-bar-mode -1)
(column-number-mode 1)
(global-display-line-numbers-mode 1)
(winner-mode 1)

(setq inhibit-startup-screen t
      display-line-numbers-type 'relative
      bidi-display-reordering nil
      read-process-output-max (* 4 1024 1024)
      make-backup-files nil
      auto-save-default nil
      create-lockfiles nil
      save-interprogram-paste-before-kill t
      kill-do-not-save-duplicates t
      set-mark-command-repeat-pop t
      help-window-select t
      custom-file (expand-file-name "custom.el" user-emacs-directory))

(when (file-exists-p custom-file)
  (load custom-file))

;;; init.el ends here
