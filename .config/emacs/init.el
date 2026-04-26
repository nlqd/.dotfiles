;;; init.el --- Minimal Evil Emacs -*- lexical-binding: t; -*-

(require 'package)
(add-to-list 'package-archives '("melpa" . "https://melpa.org/packages/") t)
(package-initialize)

(use-package evil
  :ensure t
  :init
  (setq evil-want-integration t
        evil-want-keybinding nil
        evil-want-C-u-scroll t
        evil-want-C-u-delete t
        evil-want-C-w-delete t
        evil-undo-system 'undo-redo)
  :config
  (evil-mode 1))

(use-package evil-collection
  :ensure t
  :after evil
  :config
  (evil-collection-init '(minibuffer dired magit org eglot)))

(use-package evil-commentary
  :ensure t
  :after evil
  :config
  (evil-commentary-mode))

(use-package magit
  :ensure t
  :defer t)

(use-package org-roam
  :ensure t
  :defer t
  :custom
  (org-roam-directory (expand-file-name "~/org/roam"))
  :config
  (org-roam-db-autosync-mode))

(use-package hyperbole
  :ensure t
  :defer t)

(use-package org
  :defer t
  :custom
  (org-confirm-babel-evaluate nil)
  :config
  (org-babel-do-load-languages
   'org-babel-load-languages
   '((emacs-lisp . t)
     (shell      . t)
     (python     . t))))

(use-package eglot
  :defer t
  :hook ((python-ts-mode typescript-ts-mode tsx-ts-mode js-ts-mode go-ts-mode rust-ts-mode c-ts-mode c++-ts-mode) . eglot-ensure)
  :custom
  (eglot-autoshutdown t)
  (eglot-events-buffer-size 0))

;; Tree-sitter grammars pinned to last ABI 14 release
(defvar my/treesit-langs
  '((c          "v0.23.6" :ext "\\.[ch]\\'")
    (cpp        "v0.23.4" :ext "\\.\\(cpp\\|cc\\|cxx\\|hpp\\)\\'" :to c++-ts-mode)
    (go         "v0.23.4" :ext "\\.go\\'")
    (rust       "v0.23.3" :ext "\\.rs\\'")
    (python     "v0.23.6" :ext "\\.py\\'")
    (javascript "v0.23.1" :ext "\\.m?js\\'"  :to js-ts-mode)
    (typescript "v0.23.2" :ext "\\.ts\\'"    :src "typescript/src")
    (tsx        "v0.23.2" :ext "\\.tsx\\'"   :src "tsx/src"
                :url "https://github.com/tree-sitter/tree-sitter-typescript")
    (json       "v0.24.8" :ext "\\.json\\'")
    (css        "v0.23.2" :ext "\\.css\\'")
    (yaml       "v0.7.2"  :ext "\\.ya?ml\\'"
                :url "https://github.com/tree-sitter-grammars/tree-sitter-yaml")
    (gomod      "v1.0.2"  :ext "/go\\.mod\\'" :to go-mod-ts-mode
                :url "https://github.com/camdencheek/tree-sitter-go-mod")))

(require 'treesit)
(pcase-dolist (`(,lang ,tag . ,opts) my/treesit-langs)
  (let ((mode (or (plist-get opts :to) (intern (format "%s-ts-mode" lang))))
        (url  (or (plist-get opts :url)
                  (format "https://github.com/tree-sitter/tree-sitter-%s" lang)))
        (src  (plist-get opts :src)))
    (setf (alist-get lang treesit-language-source-alist)
          (list url tag src))
    (add-to-list 'auto-mode-alist (cons (plist-get opts :ext) mode))))

(setq-default indent-tabs-mode nil
              tab-width 4)

(add-hook 'go-ts-mode-hook
          (lambda () (setq-local indent-tabs-mode t tab-width 4)))

(use-package indent-bars
  :ensure t
  :hook ((python-ts-mode yaml-ts-mode json-ts-mode typescript-ts-mode
          tsx-ts-mode js-ts-mode css-ts-mode c-ts-mode c++-ts-mode
          go-ts-mode rust-ts-mode) . indent-bars-mode)
  :custom
  (indent-bars-treesit-support t))

;; Themes and opts

(load-theme 'modus-operandi t)
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
(global-visual-line-mode 1)
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
