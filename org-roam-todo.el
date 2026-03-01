;;; org-roam-todo.el --- Org-roam TODO management with Claude integration -*- lexical-binding: t; -*-

;; Author: chadac <chad@cacrawford.org>
;; Version: 0.2.0
;; Package-Requires: ((emacs "28.1") (org-roam "2.0"))
;; Keywords: org-roam todo ai emacs llm tools
;; URL: https://github.com/chadac/org-roam-todo
;; SPDX-License-Identifier: MIT
;; This file is not part of GNU Emacs.

;;; Commentary:

;; Org-roam based TODO management with optional Claude integration.
;;
;; This file is now a compatibility shim that re-exports functionality
;; from the modular org-roam-todo-* packages:
;;
;; - org-roam-todo-core.el: Core utilities, config, capture, querying
;; - org-roam-todo-wf.el: Hook-based workflow engine
;; - org-roam-todo-wf-actions.el: Built-in workflow actions
;; - org-roam-todo-wf-local.el: Local fast-forward workflow
;; - org-roam-todo-wf-pr.el: GitHub PR workflow
;; - org-roam-todo-list.el: Magit-section based TODO list UI (+ keybindings)
;; - org-roam-todo-theme.el: Shared faces
;;
;; For new code, prefer requiring the specific module you need.
;; This file exists for backward compatibility.

;;; Code:

;; Load all modules - ensures everything is available when package is required
(require 'org-roam-todo-core)    ; Core utilities, config, capture, querying
(require 'org-roam-todo-theme)   ; Shared faces
(require 'org-roam-todo-wf)      ; Workflow engine
;; Workflow definitions - must load after org-roam-todo-wf to avoid circular deps
(require 'org-roam-todo-wf-actions)  ; Shared action hooks
(require 'org-roam-todo-wf-pr)       ; pull-request workflow
(require 'org-roam-todo-wf-local)    ; local-ff workflow
(require 'org-roam-todo-wf-basic)    ; basic workflow
(require 'org-roam-todo-wf-tools)   ; MCP tools for Claude agents
(require 'org-roam-todo-wf-project) ; Per-project validations
(require 'org-roam-todo-wf-watch)   ; Async validation watching
(require 'org-roam-todo-list)       ; Magit-section based TODO list UI
(require 'org-roam-todo-status)     ; Magit-style TODO status buffer (C-x j)

(provide 'org-roam-todo)
;;; org-roam-todo.el ends here
