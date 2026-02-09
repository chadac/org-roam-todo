;;; org-roam-todo-wf-basic.el --- Basic approval workflow -*- lexical-binding: t; -*-

;; Author: Claude Code
;; Version: 0.1.0
;; Package-Requires: ((emacs "28.1") (org-roam "2.0"))

;;; Commentary:
;; Defines the `basic' workflow for simple task tracking without worktrees.
;;
;; This workflow is designed for tasks that don't need their own git worktree.
;; Instead, they inherit the working directory from a parent task, or use the
;; project root directly if there's no parent.
;;
;; Workflow: draft -> active -> done
;;
;; - draft: TODO exists, not yet started
;; - active: Work in progress
;; - done: Completed (requires approval)
;;
;; Transitions:
;; - Forward: always allowed (done requires approval)
;; - Backward: active -> draft (allowed to un-start)
;; - Rejected: always available to abandon the TODO

;;; Code:

(require 'org-roam-todo-wf)
(require 'org-roam-todo-core)

;;; ============================================================
;;; Basic Workflow Hooks
;;; ============================================================

(defun org-roam-todo-wf-basic--require-approved (event)
  "Validate: TODO must be approved before marking done.
EVENT is the workflow event context.
Reads APPROVED property fresh from file."
  (let ((approved (org-roam-todo-prop event "APPROVED")))
    (unless approved
      (user-error "TODO must be approved before marking done.  Set :APPROVED: t in properties"))))

(defun org-roam-todo-wf-basic--set-working-directory (event)
  "Set the effective working directory for the TODO.
EVENT is the workflow event context.
Stores the resolved directory in the TODO's EFFECTIVE_DIR property.
Reads properties fresh from file."
  (let* ((file (org-roam-todo--resolve-file event))
         (worktree-path (org-roam-todo-prop event "WORKTREE_PATH"))
         (parent-todo (org-roam-todo-prop event "PARENT_TODO"))
         (project-root (org-roam-todo-prop event "PROJECT_ROOT"))
         ;; Resolve effective directory
         (effective-dir (or
                         ;; Own worktree
                         (when (and worktree-path (file-directory-p worktree-path))
                           worktree-path)
                         ;; Parent's worktree
                         (when (and parent-todo (file-exists-p parent-todo))
                           (org-roam-todo-get-file-property parent-todo "WORKTREE_PATH"))
                         ;; Project root fallback
                         project-root)))
    (when (and file effective-dir)
      (org-roam-todo-set-file-property file "EFFECTIVE_DIR" effective-dir))))

;;; ============================================================
;;; Workflow Definition
;;; ============================================================

(org-roam-todo-define-workflow basic
  "Simple approval-based workflow without worktrees.

Designed for tasks that don't need their own git worktree. The working
directory is inherited from a parent task's worktree, or defaults to
the project root if there's no parent.

Lifecycle:
  draft -> active -> done

- draft: TODO exists, not yet started
- active: Work in progress
- done: Completed (requires approval)

'rejected' is always available to abandon the TODO."

  :statuses '("draft" "active" "done")

  :hooks
  '(;; When entering active: resolve and set working directory
    (:on-enter-active . (org-roam-todo-wf-basic--set-working-directory))

    ;; Validation before done: criteria complete and must be approved
    (:validate-done . (org-roam-todo-wf--require-acceptance-complete
                       org-roam-todo-wf-basic--require-approved)))

  :config
  '(:uses-worktree nil
    :allow-backward (active)))  ; Can go back from active->draft

(provide 'org-roam-todo-wf-basic)
;;; org-roam-todo-wf-basic.el ends here
