;;; org-roam-todo-theme.el --- Shared faces for org-roam-todo -*- lexical-binding: t; -*-

;; Author: Claude Code
;; Version: 0.1.0
;; Package-Requires: ((emacs "28.1"))

;;; Commentary:
;; Provides shared face definitions for org-roam-todo status indicators.
;; These faces are used across different views (list, agenda, etc.) to
;; ensure consistent visual representation of TODO statuses.
;;
;; The standard workflow statuses are:
;; - draft: Initial state, work not yet started
;; - active: Work in progress
;; - review: Awaiting review (CI, code review, etc.)
;; - done: Completed successfully
;; - rejected: Abandoned or closed without completion
;;
;; Custom workflows may define additional statuses, which will use
;; the default face unless explicitly configured.

;;; Code:

(require 'cl-lib)

;;; ============================================================
;;; Customization Group
;;; ============================================================

(defgroup org-roam-todo-theme nil
  "Face customization for org-roam-todo status indicators."
  :group 'org-roam-todo
  :group 'faces)

;;; ============================================================
;;; Core Status Faces
;;; ============================================================

(defface org-roam-todo-status-draft
  '((((class color) (background dark)) :foreground "#888888" :slant italic)
    (((class color) (background light)) :foreground "#666666" :slant italic)
    (t :inherit font-lock-comment-face))
  "Face for draft status.
Used when a TODO exists but work has not yet started."
  :group 'org-roam-todo-theme)

(defface org-roam-todo-status-active
  '((((class color) (background dark)) :foreground "#61afef" :weight bold)
    (((class color) (background light)) :foreground "#0070cc" :weight bold)
    (t :inherit font-lock-function-name-face :weight bold))
  "Face for active status.
Used when work is in progress on a TODO."
  :group 'org-roam-todo-theme)

(defface org-roam-todo-status-review
  '((((class color) (background dark)) :foreground "#e5c07b" :weight bold)
    (((class color) (background light)) :foreground "#b08000" :weight bold)
    (t :inherit font-lock-warning-face))
  "Face for review status.
Used when a TODO is awaiting review (CI, code review, etc.)."
  :group 'org-roam-todo-theme)

(defface org-roam-todo-status-done
  '((((class color) (background dark)) :foreground "#98c379" :weight bold)
    (((class color) (background light)) :foreground "#28a428" :weight bold)
    (t :inherit success))
  "Face for done status.
Used when a TODO has been completed successfully."
  :group 'org-roam-todo-theme)

(defface org-roam-todo-status-rejected
  '((((class color) (background dark)) :foreground "#e06c75" :strike-through t)
    (((class color) (background light)) :foreground "#cc0000" :strike-through t)
    (t :inherit error :strike-through t))
  "Face for rejected status.
Used when a TODO has been abandoned or closed without completion."
  :group 'org-roam-todo-theme)

;;; ============================================================
;;; Extended Workflow Status Faces
;;; ============================================================

;; These faces are used by specific workflows (e.g., pull-request workflow)

(defface org-roam-todo-status-ci
  '((((class color) (background dark)) :foreground "#c678dd" :weight bold)
    (((class color) (background light)) :foreground "#9030a0" :weight bold)
    (t :inherit font-lock-preprocessor-face :weight bold))
  "Face for CI status.
Used in pull-request workflow when waiting for CI checks."
  :group 'org-roam-todo-theme)

(defface org-roam-todo-status-ready
  '((((class color) (background dark)) :foreground "#56b6c2" :weight bold)
    (((class color) (background light)) :foreground "#007090" :weight bold)
    (t :inherit font-lock-type-face :weight bold))
  "Face for ready status.
Used when CI has passed and TODO is ready for human review."
  :group 'org-roam-todo-theme)

;;; ============================================================
;;; UI Element Faces
;;; ============================================================

(defface org-roam-todo-project
  '((t :inherit font-lock-keyword-face :weight bold))
  "Face for project names."
  :group 'org-roam-todo-theme)

(defface org-roam-todo-worktree-active
  '((((class color) (background dark)) :foreground "#98c379")
    (((class color) (background light)) :foreground "#28a428")
    (t :inherit success))
  "Face for active worktree indicator."
  :group 'org-roam-todo-theme)

(defface org-roam-todo-agent-running
  '((((class color) (background dark)) :foreground "#61afef" :weight bold)
    (((class color) (background light)) :foreground "#0070cc" :weight bold)
    (t :inherit font-lock-constant-face :weight bold))
  "Face for running agent indicator."
  :group 'org-roam-todo-theme)

(defface org-roam-todo-subtask
  '((t :inherit font-lock-doc-face))
  "Face for subtask text."
  :group 'org-roam-todo-theme)

(defface org-roam-todo-subtask-done
  '((((class color) (background dark)) :foreground "#98c379")
    (((class color) (background light)) :foreground "#28a428")
    (t :inherit success))
  "Face for completed subtask checkboxes."
  :group 'org-roam-todo-theme)

(defface org-roam-todo-tree
  '((t :inherit font-lock-comment-face))
  "Face for tree drawing characters."
  :group 'org-roam-todo-theme)

;;; ============================================================
;;; Status Face Registry
;;; ============================================================

(defvar org-roam-todo-theme--status-faces
  '(("draft"    . org-roam-todo-status-draft)
    ("active"   . org-roam-todo-status-active)
    ("review"   . org-roam-todo-status-review)
    ("done"     . org-roam-todo-status-done)
    ("rejected" . org-roam-todo-status-rejected)
    ("ci"       . org-roam-todo-status-ci)
    ("ready"    . org-roam-todo-status-ready))
  "Alist mapping status strings to their faces.
Add entries here to support custom workflow statuses.")

(defun org-roam-todo-theme-status-face (status)
  "Get the face for STATUS.
Returns the appropriate face from `org-roam-todo-theme--status-faces',
or `default' if STATUS is not registered."
  (or (alist-get status org-roam-todo-theme--status-faces nil nil #'string=)
      'default))

(defun org-roam-todo-theme-register-status (status face)
  "Register FACE for STATUS in the theme registry.
This allows custom workflows to define faces for their statuses."
  (setf (alist-get status org-roam-todo-theme--status-faces nil nil #'string=)
        face))

(provide 'org-roam-todo-theme)
;;; org-roam-todo-theme.el ends here
