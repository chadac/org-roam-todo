;;; org-roam-todo-wf-local.el --- Local fast-forward workflow -*- lexical-binding: t; -*-

;; Author: Claude Code
;; Version: 0.1.0
;; Package-Requires: ((emacs "28.1") (org-roam "2.0"))

;;; Commentary:
;; Defines the `local-ff' workflow for simple local fast-forward merges.
;;
;; This workflow is designed for solo development or trusted environments
;; where you don't need GitHub PRs or CI integration. Changes are merged
;; directly to main via fast-forward merge.
;;
;; Workflow: draft -> active -> review -> done
;;
;; - draft: TODO exists, no work started
;; - active: Worktree created, work in progress
;; - review: Changes ready for local review via magit diff
;; - done: Fast-forward merged to main, pushed to origin, cleaned up
;;
;; Transitions:
;; - Forward: always allowed
;; - Backward: review -> active (allowed if issues found during review)
;; - Rejected: always available to abandon the TODO

;;; Code:

(require 'org-roam-todo-wf)
(require 'org-roam-todo-wf-actions)
(require 'org-roam-todo-wf-tools)

;;; ============================================================
;;; Local Workflow Hooks
;;; ============================================================

(defun org-roam-todo-wf-local--set-needs-review (event)
  "Set NEEDS_REVIEW property to t for local review.
EVENT is the workflow event context."
  (let ((file (plist-get (org-roam-todo-event-todo event) :file)))
    (org-roam-todo-wf-tools--set-property file "NEEDS_REVIEW" "t")))

;; Use shared require-user-approval from org-roam-todo-wf-actions
;; org-roam-todo-wf--require-user-approval is defined there

(defun org-roam-todo-wf-local--open-magit-review (event)
  "Open magit diff to review changes against target branch.
Shows the diff between the rebase target (e.g., main) and the feature branch.
Reads properties fresh from file."
  (let* ((workflow (org-roam-todo-event-workflow event))
         (worktree-path (org-roam-todo-prop event "WORKTREE_PATH"))
         (branch (org-roam-todo-prop event "WORKTREE_BRANCH"))
         (target (org-roam-todo-wf--get-target-branch-from-event event workflow)))
    (when (and worktree-path branch target)
      (let ((default-directory worktree-path))
        ;; Open magit diff showing target..branch
        (when (fboundp 'magit-diff-range)
          (magit-diff-range (format "%s..%s" target branch)))))))

(defun org-roam-todo-wf-local--push-main (event)
  "Push the target branch (main) to origin after merge.
Skips silently if the repository has no 'origin' remote.
Reads properties fresh from file."
  (let* ((workflow (org-roam-todo-event-workflow event))
         (project-root (org-roam-todo-prop event "PROJECT_ROOT"))
         (target (org-roam-todo-wf--get-target-branch-from-event event workflow)))
    (unless target
      (user-error "No rebase target configured for workflow"))
    (unless project-root
      (user-error "No project root configured"))
    ;; Only push if origin remote exists
    (let ((result (org-roam-todo-wf--git-run project-root "remote" "get-url" "origin")))
      (when (car result)
        (org-roam-todo-wf--git-run! project-root "push" "origin" target)))))

;;; ============================================================
;;; Workflow Definition
;;; ============================================================

(org-roam-todo-define-workflow local-ff
  "Simple local fast-forward workflow.

Designed for solo development or trusted environments where you don't need
GitHub PRs or CI integration. Changes are merged directly to main via
fast-forward merge.

Lifecycle:
  draft -> active -> review -> done

- draft: TODO exists, no work started
- active: Worktree created, work in progress
- review: Changes ready for local review (magit diff)
- done: Fast-forward merged to main, pushed, cleaned up

'rejected' is always available to abandon the TODO."

  :statuses '("draft" "active" "review" "done")

  :hooks
  '(;; Validation before active: ensure rebase target exists
    (:validate-active . (org-roam-todo-wf--require-rebase-target-exists))

    ;; When entering active: set up branch and create worktree
    (:on-enter-active . (org-roam-todo-wf--ensure-branch
                         org-roam-todo-wf--ensure-worktree))

    ;; Validation before review: ensure clean state and criteria complete
    (:validate-review . (org-roam-todo-wf--require-acceptance-complete
                         org-roam-todo-wf--require-clean-worktree
                         org-roam-todo-wf--require-rebase-clean))

    ;; When entering review: rebase onto target, set needs-review, open magit
    (:on-enter-review . (org-roam-todo-wf--rebase-onto-target
                         org-roam-todo-wf-local--set-needs-review
                         org-roam-todo-wf-local--open-magit-review))

    ;; Validation before done: user approval and ff-merge requirements
    (:validate-done . (org-roam-todo-wf--require-user-approval
                       org-roam-todo-wf--require-target-clean
                       org-roam-todo-wf--require-ff-possible))

    ;; When entering done: merge, push, and cleanup everything
    (:on-enter-done . (org-roam-todo-wf--ff-merge-to-target
                       org-roam-todo-wf--cleanup-all)))

  :config
  '(:rebase-target "main"
    :push-after-merge t
    :allow-backward (review)          ; Can go back from review->active if issues found

    ;; Watchers for async status monitoring
    :watchers
    (;; When in "review" status, watch for buffer changes (needs more work)
     (:status "review"
      :type buffer-change
      :on-change (:regress "active")))))

;; Alias for backwards compatibility with configs using :merge-workflow local-rebase
(puthash 'local-rebase (gethash 'local-ff org-roam-todo-wf--registry)
         org-roam-todo-wf--registry)

(provide 'org-roam-todo-wf-local)
;;; org-roam-todo-wf-local.el ends here
