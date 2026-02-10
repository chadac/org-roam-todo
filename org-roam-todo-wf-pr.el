;;; org-roam-todo-wf-pr.el --- Pull request workflow -*- lexical-binding: t; -*-

;; Author: Claude Code
;; Version: 0.1.0
;; Package-Requires: ((emacs "28.1") (org-roam "2.0") (forge "0.4.0"))

;;; Commentary:
;; Defines the `pull-request' workflow for forge-based PR development.
;;
;; This workflow is designed for team development where changes go through
;; code review via Pull Requests on GitHub, GitLab, or other forges.
;; It uses the forge package for all PR operations.
;;
;; Workflow: draft -> active -> ci -> ready -> review -> done
;;
;; - draft: TODO exists, no work started
;; - active: Worktree created, work in progress
;; - ci: Draft PR created, waiting for CI checks to pass
;; - ready: CI passed, PR ready for your own review
;; - review: PR submitted for external/team review
;; - done: PR merged, worktree cleaned up
;;
;; Transitions:
;; - Forward: always allowed
;; - Backward: ci -> active (need more work), ready -> ci (re-run CI)
;; - Rejected: always available to abandon the TODO

;;; Code:

(require 'org-roam-todo-wf)
(require 'org-roam-todo-wf-actions)
(require 'cl-lib)

;; Load forge-client for macros (forge-rest, forge-query, etc.)
;; These are macros that expand at compile/load time, so they must be available
(require 'forge-client)

;; Declare additional forge functions for byte-compilation
(declare-function forge-get-repository "forge-core" (&optional demand))
(declare-function forge-get-pullreq "forge-pullreq" (demand))
(declare-function forge--set-topic-draft "forge-github" (repo topic value))
(declare-function forge--set-topic-review-requests "forge-github" (repo topic reviewers))
(declare-function forge--pull "forge-core" (&optional repo))

;; Optional: magit-forge-ci for CI status checking
(declare-function magit-forge-ci--get-checks-via-gh-cli "magit-forge-ci" (owner repo pr-number))
(declare-function magit-forge-ci--compute-overall-status "magit-forge-ci" (statuses))
(autoload 'forge-rest "forge-core")
(autoload 'forge--set-topic-draft "forge-github")
(autoload 'forge--set-topic-review-requests "forge-github")
(autoload 'forge--glab-post "forge-gitlab")

;;; ============================================================
;;; Customization
;;; ============================================================

(defgroup org-roam-todo-wf-pr nil
  "Pull request workflow settings for org-roam-todo."
  :group 'org-roam-todo)

(defcustom org-roam-todo-wf-pr-create-pr-function nil
  "Custom function to create a pull request.
When set, called instead of built-in forge methods.
Receives: REPO TITLE BODY TARGET HEAD DRAFT-P CALLBACK ERRORBACK.
Set nil to use built-in GitHub/GitLab methods."
  :type '(choice (const :tag "Use built-in forge methods" nil)
                 (function :tag "Custom function"))
  :group 'org-roam-todo-wf-pr)

;;; ============================================================
;;; EIEIO Slot Access Helper
;;; ============================================================

(defun org-roam-todo-wf-pr--slot (object slot)
  "Access SLOT on OBJECT using runtime eieio-oref.
Avoids byte-compile warnings about unknown slots from forge objects."
  (funcall (intern "eieio-oref") object slot))

;;; ============================================================
;;; Forge-Agnostic PR Creation
;;; ============================================================
;; We use cl-defgeneric/cl-defmethod to dispatch based on repository type.
;; This allows forge-specific implementations while remaining extensible.

(cl-defgeneric org-roam-todo-wf-pr--create-pr (repo title body target head draft-p callback errorback)
  "Create a pull request on REPO.
TITLE is the PR title.
BODY is the PR description.
TARGET is the target branch name (e.g., \"main\").
HEAD is the head branch name (the feature branch).
DRAFT-P if non-nil, creates a draft PR.
CALLBACK is called on success.
ERRORBACK is called on failure.

This generic function dispatches to forge-specific implementations.")

(cl-defmethod org-roam-todo-wf-pr--create-pr ((_repo (eql :github))
                                               title body target head draft-p
                                               callback errorback)
  "Create a pull request on GitHub.
TITLE, BODY, TARGET, HEAD, DRAFT-P, CALLBACK, ERRORBACK: see generic."
  (let ((actual-repo (org-roam-todo-wf-pr--current-repo)))
    (forge-rest actual-repo "POST" "/repos/:owner/:repo/pulls"
                ((title title)
                 (body body)
                 (base target)
                 (head head)
                 (draft (if draft-p t :json-false))
                 (maintainer_can_modify t))
                :callback callback
                :errorback errorback)))

(cl-defmethod org-roam-todo-wf-pr--create-pr ((_repo (eql :gitlab))
                                               title body target head draft-p
                                               callback errorback)
  "Create a merge request on GitLab.
TITLE, BODY, TARGET, HEAD, DRAFT-P, CALLBACK, ERRORBACK: see generic."
  (let ((actual-repo (org-roam-todo-wf-pr--current-repo)))
    ;; forge--glab-post is a function (not a macro), so use a regular alist
    (forge--glab-post actual-repo "/projects/:project/merge_requests"
                      `((title . ,(if draft-p
                                      (concat "Draft: " title)
                                    title))
                        (description . ,body)
                        (target_branch . ,target)
                        (source_branch . ,head)
                        (allow_collaboration . t))
                      :callback callback
                      :errorback errorback)))

(cl-defmethod org-roam-todo-wf-pr--create-pr (repo title body target head
                                                   draft-p callback errorback)
  "Fallback method for unsupported forge types.
Checks `org-roam-todo-wf-pr-create-pr-function' for a custom handler,
otherwise signals an error."
  (if org-roam-todo-wf-pr-create-pr-function
      (funcall org-roam-todo-wf-pr-create-pr-function
               repo title body target head draft-p callback errorback)
    (error "Unsupported forge type: %s.  Set `org-roam-todo-wf-pr-create-pr-function' to add support"
           (type-of repo))))

(defvar org-roam-todo-wf-pr--current-repo nil
  "Dynamically bound to the current forge repository during PR creation.")

(defun org-roam-todo-wf-pr--current-repo ()
  "Get the current forge repository.
Must be called within the dynamic scope of PR creation."
  (or org-roam-todo-wf-pr--current-repo
      (error "No current repository - this function must be called during PR creation")))

(defun org-roam-todo-wf-pr--repo-type (repo)
  "Determine the forge type for REPO.
Returns a symbol like :github, :gitlab, or the repo itself for unknown types.
Works with both EIEIO objects and cl-defstruct objects (for testing)."
  (let* ((type-sym (type-of repo))
         (class-name (symbol-name type-sym)))
    (cond
     ((string-match-p "github" class-name) :github)
     ((string-match-p "gitlab" class-name) :gitlab)
     ((string-match-p "gitea" class-name) :gitea)
     ((string-match-p "forgejo" class-name) :forgejo)
     ((string-match-p "gogs" class-name) :gogs)
     (t repo))))  ; Return repo itself for fallback dispatch

;;; ============================================================
;;; PR Workflow Hooks
;;; ============================================================

;;; ------------------------------------------------------------
;;; Helper Functions
;;; ------------------------------------------------------------

(defun org-roam-todo-wf-pr--get-forge-repo (worktree-path)
  "Get the forge repository for WORKTREE-PATH.
Returns the forge repository object or signals an error."
  (let ((default-directory worktree-path))
    (or (forge-get-repository :tracked?)
        (user-error "Repository not tracked by forge.  Run `forge-add-repository' first"))))

(defun org-roam-todo-wf-pr--get-pullreq (worktree-path)
  "Get the pull request for the current branch in WORKTREE-PATH.
Returns the forge-pullreq object or nil if no PR exists."
  (let ((default-directory worktree-path))
    (forge-get-pullreq :branch)))

(defun org-roam-todo-wf-pr--get-target-branch-name (todo workflow)
  "Get the target branch name (without remote prefix) from TODO and WORKFLOW.
DEPRECATED: Use `org-roam-todo-wf-pr--get-target-branch-name-from-event' instead."
  (let ((target (or (plist-get todo :target-branch)
                    (plist-get (org-roam-todo-workflow-config workflow) :rebase-target))))
    ;; Strip remote prefix (e.g., "origin/main" -> "main")
    (if (and target (string-match "^[^/]+/\\(.+\\)$" target))
        (match-string 1 target)
      (or target "main"))))

(defun org-roam-todo-wf-pr--get-target-branch-name-from-event (event workflow)
  "Get the target branch name (without remote prefix) from EVENT.
Reads TARGET_BRANCH fresh from file."
  (let ((target (org-roam-todo-wf--get-target-branch-from-event event workflow)))
    ;; Strip remote prefix (e.g., "origin/main" -> "main")
    (if (and target (string-match "^[^/]+/\\(.+\\)$" target))
        (match-string 1 target)
      (or target "main"))))

;;; ------------------------------------------------------------
;;; PR Workflow Hooks
;;; ------------------------------------------------------------

(defun org-roam-todo-wf-pr--create-draft-pr (event)
  "Create a draft PR for the TODO.
EVENT is the workflow event context.
Uses forge to create a draft PR targeting the rebase-target branch.
Dispatches to the appropriate forge backend (GitHub, GitLab, etc.).
Reads properties fresh from file."
  (let* ((workflow (org-roam-todo-event-workflow event))
         (worktree-path (org-roam-todo-prop event "WORKTREE_PATH"))
         (branch (org-roam-todo-prop event "WORKTREE_BRANCH"))
         (title (org-roam-todo-prop event "TITLE"))
         (description (org-roam-todo-prop event "DESCRIPTION"))
         (body (format "## TODO\n\n%s\n\n---\n_Managed by org-roam-todo_"
                       (or description title)))
         (target (org-roam-todo-wf-pr--get-target-branch-name-from-event event workflow))
         (default-directory worktree-path)
         (repo (org-roam-todo-wf-pr--get-forge-repo worktree-path))
         (repo-type (org-roam-todo-wf-pr--repo-type repo)))
    ;; Dynamically bind the repo for the method to access
    (let ((org-roam-todo-wf-pr--current-repo repo))
      (org-roam-todo-wf-pr--create-pr
       repo-type
       title body target branch
       t  ; draft-p
       (lambda (&rest _)
         (message "Draft PR created for %s" title)
         (forge--pull repo))
       (lambda (&rest args)
         (message "Failed to create PR: %S" args))))))

(defun org-roam-todo-wf-pr--mark-pr-ready (event)
  "Mark the draft PR as ready for review.
Converts the PR from draft status to ready-for-review using forge.
Reads WORKTREE_PATH fresh from file."
  (let* ((worktree-path (org-roam-todo-prop event "WORKTREE_PATH"))
         (default-directory worktree-path)
         (repo (org-roam-todo-wf-pr--get-forge-repo worktree-path))
         (pullreq (org-roam-todo-wf-pr--get-pullreq worktree-path)))
    (unless pullreq
      (user-error "No pull request found for current branch"))
    ;; Use forge's generic method to unset draft status
    (forge--set-topic-draft repo pullreq nil)))

(defun org-roam-todo-wf-pr--get-pr-state (worktree-path)
  "Get the PR state for the current branch in WORKTREE-PATH.
Returns one of: merged, rejected (closed), open, or nil if no PR exists."
  (let ((default-directory worktree-path))
    (when-let ((pullreq (org-roam-todo-wf-pr--get-pullreq worktree-path)))
      (condition-case nil
          (funcall (intern "eieio-oref") pullreq 'state)
        (error nil)))))

;;; ============================================================
;;; Watcher Poll Functions (for org-roam-todo-wf-watch)
;;; ============================================================

(defun org-roam-todo-wf-pr--check-ci-status (todo)
  "Check CI status for TODO's PR.
Returns \\='success, \\='failure, or \\='pending.
Used by watchers to poll CI status and trigger auto-advancement."
  (let ((worktree-path (plist-get todo :worktree-path)))
    (if (and worktree-path
             (featurep 'magit-forge-ci)
             (fboundp 'magit-forge-ci--get-checks-via-gh-cli)
             (fboundp 'magit-forge-ci--compute-overall-status))
        (condition-case nil
            (let* ((default-directory worktree-path)
                   (repo (org-roam-todo-wf-pr--get-forge-repo worktree-path))
                   (pullreq (org-roam-todo-wf-pr--get-pullreq worktree-path)))
              (if pullreq
                  (let* ((owner (org-roam-todo-wf-pr--slot repo 'owner))
                         (name (org-roam-todo-wf-pr--slot repo 'name))
                         (pr-number (org-roam-todo-wf-pr--slot pullreq 'number))
                         (checks (magit-forge-ci--get-checks-via-gh-cli owner name pr-number))
                         (status (magit-forge-ci--compute-overall-status checks)))
                    (pcase status
                      ("success" 'success)
                      ("failure" 'failure)
                      (_ 'pending)))
                ;; No PR yet - still pending
                'pending))
          (error 'pending))
      ;; No CI integration available - assume pending (manual check needed)
      'pending)))

(defun org-roam-todo-wf-pr--check-pr-merged (todo)
  "Check if TODO's PR has been merged.
Returns \\='success if merged, \\='failure if closed without merge, \\='pending if open.
Used by watchers to poll merge status and trigger auto-advancement."
  (let ((worktree-path (plist-get todo :worktree-path)))
    (if worktree-path
        (condition-case nil
            (let ((state (org-roam-todo-wf-pr--get-pr-state worktree-path)))
              (pcase state
                ('merged 'success)
                ('rejected 'failure)
                (_ 'pending)))
          (error 'pending))
      'pending)))

(defun org-roam-todo-wf-pr--require-ci-pass (event)
  "Validate: CI checks have passed for the PR.
EVENT is the workflow event context.
Uses `magit-forge-ci' if available to check CI status.
Otherwise, always passes (user must verify CI manually).
Reads WORKTREE_PATH fresh from file."
  (let ((worktree-path (org-roam-todo-prop event "WORKTREE_PATH")))
    ;; Check if magit-forge-ci is available
    (if (and worktree-path
             (featurep 'magit-forge-ci)
             (fboundp 'magit-forge-ci--get-checks-via-gh-cli)
             (fboundp 'magit-forge-ci--compute-overall-status))
        ;; Use magit-forge-ci to check CI status
        (let* ((default-directory worktree-path)
               (repo (org-roam-todo-wf-pr--get-forge-repo worktree-path))
               (pullreq (org-roam-todo-wf-pr--get-pullreq worktree-path)))
          (if pullreq
              (let* ((owner (org-roam-todo-wf-pr--slot repo 'owner))
                     (name (org-roam-todo-wf-pr--slot repo 'name))
                     (pr-number (org-roam-todo-wf-pr--slot pullreq 'number))
                     (checks (magit-forge-ci--get-checks-via-gh-cli owner name pr-number))
                     (status (magit-forge-ci--compute-overall-status checks)))
                (pcase status
                  ("success" nil)  ; validation passes
                  ("pending" (user-error "CI checks are still running"))
                  ("failure" (user-error "CI checks have failed"))
                  (_ (user-error "CI status unknown: %s" status))))
            ;; No PR yet - can't check CI
            (user-error "No PR found - cannot check CI status")))
      ;; magit-forge-ci not available - always pass
      nil)))

(defun org-roam-todo-wf-pr--require-user-approval (event)
  "Validate: user has approved the PR for external review.
EVENT is the workflow event context.
Checks for APPROVED property in the TODO.  This is a local approval
indicating you've reviewed your own changes before requesting external review.
Reads APPROVED fresh from file."
  (let ((approved (org-roam-todo-prop event "APPROVED")))
    (unless approved
      (user-error "Not approved for review.  Set :APPROVED: t in the TODO after reviewing your changes"))))

(defun org-roam-todo-wf-pr--require-pr-merged (event)
  "Validate: PR has been merged.
EVENT is the workflow event context.
Checks forge PR state to confirm the PR is merged.
Reads WORKTREE_PATH fresh from file."
  (let* ((worktree-path (org-roam-todo-prop event "WORKTREE_PATH"))
         (state (when worktree-path (org-roam-todo-wf-pr--get-pr-state worktree-path))))
    (pcase state
      (`merged nil)  ; validation passes
      (`rejected (user-error "PR was closed without merging"))
      (`open (user-error "PR is still open.  Wait for it to be merged"))
      (_ (user-error "Could not determine PR state.  Is the PR tracked by forge?")))))

(defun org-roam-todo-wf-pr--request-reviewers (event)
  "Request reviewers for the PR.
Uses the :reviewers config from the workflow to add reviewers via forge.
Reads WORKTREE_PATH fresh from file."
  (let* ((workflow (org-roam-todo-event-workflow event))
         (config (org-roam-todo-workflow-config workflow))
         (worktree-path (org-roam-todo-prop event "WORKTREE_PATH"))
         (reviewers (plist-get config :reviewers))
         (default-directory worktree-path))
    (when (and reviewers worktree-path)
      (let ((repo (org-roam-todo-wf-pr--get-forge-repo worktree-path))
            (pullreq (org-roam-todo-wf-pr--get-pullreq worktree-path)))
        (unless pullreq
          (user-error "No pull request found for current branch"))
        (forge--set-topic-review-requests repo pullreq reviewers)))))

(defun org-roam-todo-wf-pr--on-enter-ci (event)
  "Actions when entering CI status.
Rebases onto target, pushes the branch, and creates a draft PR."
  ;; First rebase onto target
  (org-roam-todo-wf--rebase-onto-target event)
  ;; Push the branch
  (org-roam-todo-wf--push-branch event)
  ;; Create the draft PR
  (org-roam-todo-wf-pr--create-draft-pr event))

(defun org-roam-todo-wf-pr--on-enter-review (event)
  "Actions when entering review status.
Requests configured reviewers."
  (org-roam-todo-wf-pr--request-reviewers event))

;;; ============================================================
;;; Workflow Definition
;;; ============================================================

(org-roam-todo-define-workflow pull-request
  "Pull Request workflow with forge integration.

Designed for team development where changes go through code review
via Pull Requests.  Uses the forge package to interact with GitHub,
GitLab, and other supported forges.

Lifecycle:
  draft -> active -> ci -> ready -> review -> done

- draft: TODO exists, no work started
- active: Worktree created, work in progress
- ci: Draft PR created, waiting for CI checks
- ready: CI passed, ready for your review
- review: PR submitted for external review
- done: PR merged, cleaned up

'rejected' is always available to abandon the TODO.

Requirements:
- The repository must be tracked by forge (run `forge-add-repository')
- The forge package must be configured with API access"

  :statuses '("draft" "active" "ci" "ready" "review" "done")

  :hooks
  '(;; When entering active: set up branch and create worktree
    (:on-enter-active . (org-roam-todo-wf--ensure-branch
                         org-roam-todo-wf--ensure-worktree))

    ;; Validation before CI: ensure clean state with commits on branch
    (:validate-ci . (org-roam-todo-wf--require-clean-worktree
                     org-roam-todo-wf--require-branch-has-commits))

    ;; When entering CI: rebase, push, create draft PR
    (:on-enter-ci . (org-roam-todo-wf-pr--on-enter-ci))

    ;; Validation before ready: CI passes and all criteria complete
    (:validate-ready . (org-roam-todo-wf--require-acceptance-complete
                        org-roam-todo-wf-pr--require-ci-pass))

    ;; When entering ready: mark PR ready for review
    (:on-enter-ready . (org-roam-todo-wf-pr--mark-pr-ready))

    ;; Validation before review: user must approve their own changes
    ;; Also: only AI agents (CI automation) can advance to review
    (:validate-review . (org-roam-todo-wf-pr--require-user-approval
                         org-roam-todo-wf--only-ai))

    ;; When entering review: request reviewers
    (:on-enter-review . (org-roam-todo-wf-pr--on-enter-review))

    ;; Validation before done: PR must be merged, and only humans can approve
    (:validate-done . (org-roam-todo-wf-pr--require-pr-merged
                       org-roam-todo-wf--only-human))

    ;; When entering done: cleanup everything (agent, buffers, worktree)
    (:on-enter-done . (org-roam-todo-wf--cleanup-all)))

  :config
  '(:rebase-target "origin/main"
    :draft-pr t
    :reviewers nil                   ; set per-project
    :labels nil                      ; set per-project
    :allow-backward (ci ready)       ; can regress for fixes

    ;; Watchers for async status monitoring
    :watchers
    (;; When in "ci" status, poll for CI completion
     (:status "ci"
      :poll-fn org-roam-todo-wf-pr--check-ci-status
      :interval 60                    ; check every minute
      :on-success (:advance "ready")  ; auto-advance when CI passes
      :on-failure (:regress "active") ; regress on failure for fixes
      :timeout 3600)                  ; stop polling after 1 hour

     ;; When in "ci" status, watch for buffer changes (needs more work)
     (:status "ci"
      :type buffer-change
      :on-change (:regress "active")) ; regress if files are modified

     ;; When in "review" status, poll for PR merge
     (:status "review"
      :poll-fn org-roam-todo-wf-pr--check-pr-merged
      :interval 120                   ; check every 2 minutes
      :on-success (:advance "done")   ; auto-advance when merged
      :timeout 86400))))

(provide 'org-roam-todo-wf-pr)
;;; org-roam-todo-wf-pr.el ends here
