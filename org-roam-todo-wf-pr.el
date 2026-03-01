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
(declare-function org-roam-todo-wf-pr-feedback--update-pr "org-roam-todo-wf-pr-feedback")
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

(defcustom org-roam-todo-wf-pr-title-function nil
  "Function to generate PR title from TODO.
When set, called with EVENT and should return the PR title string.
When nil, uses the PR Title section or falls back to TODO title."
  :type '(choice (const :tag "Use PR Title section or TODO title" nil)
                 (function :tag "Custom function"))
  :group 'org-roam-todo-wf-pr)

(defcustom org-roam-todo-wf-pr-body-function nil
  "Function to generate PR body/description from TODO.
When set, called with EVENT and should return the PR body string.
When nil, uses the PR Description section or generates a default body."
  :type '(choice (const :tag "Use PR Description section or default" nil)
                 (function :tag "Custom function"))
  :group 'org-roam-todo-wf-pr)

(defcustom org-roam-todo-wf-pr-require-pr-sections t
  "Whether to require PR Title and PR Description sections before PR creation.
When non-nil, the :validate-ci hook will check that these sections exist
and are non-empty in the TODO file."
  :type 'boolean
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
                 (draft (if draft-p t nil))
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
Returns the forge-pullreq object or nil if no PR exists.
Falls back to database lookup if git config is not set."
  (let ((default-directory worktree-path))
    (or
     ;; Try fast lookup via git config (set by forge when creating/checking out PRs)
     (forge-get-pullreq :branch)
     ;; Fallback: search through all PRs for matching head-ref branch
     (when-let* ((repo (forge-get-repository :tracked?))
                 (branch (magit-get-current-branch)))
       (cl-find-if (lambda (pr)
                     (equal (oref pr head-ref) branch))
                   (oref repo pullreqs))))))

;;; ------------------------------------------------------------
;;; PR Info via gh CLI (fallback when forge doesn't know about PR)
;;; ------------------------------------------------------------

(defun org-roam-todo-wf-pr--get-pr-number-from-props (event)
  "Get PR number from TODO properties.
Reads :PR: or :PR_NUMBER: property from the TODO file.
Returns the PR number as a string, or nil if not set."
  (or (org-roam-todo-prop event "PR")
      (org-roam-todo-prop event "PR_NUMBER")))

(defun org-roam-todo-wf-pr--get-pr-number-via-gh (worktree-path branch)
  "Get PR number for BRANCH using gh CLI.
WORKTREE-PATH is the directory to run the command in.
BRANCH is the head branch name to search for.
Returns the PR number as a string, or nil if no PR found."
  (when (and worktree-path branch)
    (let* ((default-directory worktree-path)
           (output (string-trim
                    (shell-command-to-string
                     (format "gh pr list --head %s --json number -q '.[0].number' 2>/dev/null"
                             (shell-quote-argument branch))))))
      (when (and output
                 (not (string-empty-p output))
                 (string-match-p "^[0-9]+$" output))
        output))))

(defun org-roam-todo-wf-pr--get-repo-info-via-gh (worktree-path)
  "Get repository owner and name using gh CLI.
WORKTREE-PATH is the directory to run the command in.
Returns a cons cell (owner . name), or nil if not available."
  (when worktree-path
    (let* ((default-directory worktree-path)
           (owner (string-trim
                   (shell-command-to-string
                    "gh repo view --json owner -q .owner.login 2>/dev/null")))
           (name (string-trim
                  (shell-command-to-string
                   "gh repo view --json name -q .name 2>/dev/null"))))
      (when (and owner name
                 (not (string-empty-p owner))
                 (not (string-empty-p name)))
        (cons owner name)))))

(defun org-roam-todo-wf-pr--get-pr-info (event worktree-path)
  "Get PR info for the TODO, using multiple fallback strategies.
EVENT is the workflow event context.
WORKTREE-PATH is the directory containing the worktree.

Tries in order:
1. Forge pullreq object (if forge knows about the PR)
2. TODO :PR_NUMBER: property (if manually set)
3. gh CLI lookup by branch name

Returns a plist (:pr-number N :owner \"owner\" :name \"repo\" :source SOURCE)
where SOURCE is \\='forge, \\='property, or \\='gh-cli.
Returns nil if no PR can be found."
  (let ((default-directory worktree-path))
    ;; Strategy 1: Try forge first (fastest if available)
    (if-let ((pullreq (org-roam-todo-wf-pr--get-pullreq worktree-path)))
        (let ((repo (org-roam-todo-wf-pr--get-forge-repo worktree-path)))
          (list :pr-number (org-roam-todo-wf-pr--slot pullreq 'number)
                :owner (org-roam-todo-wf-pr--slot repo 'owner)
                :name (org-roam-todo-wf-pr--slot repo 'name)
                :source 'forge))
      ;; Strategy 2: Check TODO properties
      (if-let ((pr-number-str (org-roam-todo-wf-pr--get-pr-number-from-props event)))
          (let* ((pr-number (string-to-number pr-number-str))
                 (repo-info (org-roam-todo-wf-pr--get-repo-info-via-gh worktree-path)))
            (when (and (> pr-number 0) repo-info)
              (list :pr-number pr-number
                    :owner (car repo-info)
                    :name (cdr repo-info)
                    :source 'property)))
        ;; Strategy 3: Use gh CLI to find PR by branch name
        (let ((branch (or (org-roam-todo-prop event "WORKTREE_BRANCH")
                          (magit-get-current-branch))))
          (when-let ((pr-number-str (org-roam-todo-wf-pr--get-pr-number-via-gh
                                     worktree-path branch)))
            (let ((repo-info (org-roam-todo-wf-pr--get-repo-info-via-gh worktree-path)))
              (when repo-info
                (list :pr-number (string-to-number pr-number-str)
                      :owner (car repo-info)
                      :name (cdr repo-info)
                      :source 'gh-cli)))))))))

;; Target branch functions are in org-roam-todo-wf-actions.el:
;; - org-roam-todo-wf--get-target-branch (from plist)
;; - org-roam-todo-wf--get-target-branch-from-event (reads fresh from file)

(defun org-roam-todo-wf-pr--strip-remote-prefix (branch)
  "Strip remote prefix from BRANCH name for PR API calls.
E.g., \"origin/main\" -> \"main\", \"main\" -> \"main\".
GitHub/GitLab APIs expect branch names without remote prefixes."
  (if (and branch (string-match "^[^/]+/\\(.+\\)$" branch))
      (match-string 1 branch)
    branch))

(defun org-roam-todo-wf-pr--get-pr-file (todo-file)
  "Get the PR file path for TODO-FILE.
The PR file is a separate file (todo-name-pr.org) that stores PR content."
  (when todo-file
    (let* ((dir (file-name-directory todo-file))
           (base (file-name-base todo-file)))
      (expand-file-name (concat base "-pr.org") dir))))

(defun org-roam-todo-wf-pr--read-pr-file (pr-file)
  "Read PR content from PR-FILE.
Returns a plist with :title and :body, or nil if file doesn\='t exist.
Strips \='Pull Request: \=' prefix from title if present.
Handles both old format (just #+title:) and new format (with :PROPERTIES:)."
  (when (and pr-file (file-exists-p pr-file))
    (with-temp-buffer
      (insert-file-contents pr-file)
      (goto-char (point-min))
      (let ((title nil)
            (body nil))
        ;; Skip properties drawer if present
        (when (looking-at ":PROPERTIES:")
          (re-search-forward "^:END:" nil t)
          (forward-line 1))
        ;; Find title, stripping "Pull Request: " prefix if present
        (when (re-search-forward "^#\\+title:\\s-*\\(Pull Request:\\s-*\\)?\\(.+\\)$" nil t)
          (setq title (string-trim (or (match-string 2) (match-string 1)))))
        (forward-line 1)
        ;; Skip blank lines and parent link
        (while (and (not (eobp))
                    (or (looking-at "^$")
                        (looking-at "^Parent TODO:")))
          (forward-line 1))
        (setq body (string-trim (buffer-substring-no-properties (point) (point-max))))
        (when (string-empty-p body) (setq body nil))
        (list :title title :body body)))))

(defun org-roam-todo-wf-pr--get-pr-node (file)
  "Get PR info for TODO FILE.
First checks for a separate PR file (todo-name-pr.org).
Falls back to heading with :ROAM_TYPE: pr property in the TODO file.
Returns a plist with :title and :body, or nil if not found."
  (when (and file (file-exists-p file))
    ;; First try separate PR file
    (let ((pr-file (org-roam-todo-wf-pr--get-pr-file file)))
      (or (org-roam-todo-wf-pr--read-pr-file pr-file)
          ;; Fall back to inline PR node in TODO file
          (with-temp-buffer
            (insert-file-contents file)
            (goto-char (point-min))
            ;; Find a heading with ROAM_TYPE: pr property
            (let ((found nil)
                  (case-fold-search t))
              (while (and (not found)
                          (re-search-forward "^\\(\\*+\\)\\s-+\\(.+\\)$" nil t))
                (let ((level (length (match-string 1)))
                      (heading-title (match-string 2)))
                  ;; Check if this heading has ROAM_TYPE: pr
                  (save-excursion
                    (forward-line 1)
                    (when (looking-at "\\s-*:PROPERTIES:")
                      (let ((props-start (point)))
                        (when (re-search-forward "^\\s-*:END:" nil t)
                          (let ((props-text (buffer-substring-no-properties props-start (point))))
                            (when (string-match ":ROAM_TYPE:\\s-*pr" props-text)
                              ;; Found the PR node - extract body
                              (forward-line 1)
                              (let* ((body-start (point))
                                     ;; Find end: next heading of same level or higher, or end of file
                                     (body-end (if (re-search-forward
                                                    (format "^\\*\\{1,%d\\}\\s-" level) nil t)
                                                   (match-beginning 0)
                                                 (point-max)))
                                     (body (string-trim
                                            (buffer-substring-no-properties body-start body-end))))
                                (setq found (list :title (string-trim heading-title)
                                                  :body (if (string-empty-p body) nil body))))))))))))
              found))))))

(defun org-roam-todo-wf-pr--get-pr-title (event)
  "Get the PR title for EVENT.
Resolution order:
1. Custom function from `org-roam-todo-wf-pr-title-function'
2. PR node heading (heading with :ROAM_TYPE: pr)
3. TODO title as fallback"
  (or (when org-roam-todo-wf-pr-title-function
        (funcall org-roam-todo-wf-pr-title-function event))
      (let ((file (org-roam-todo--resolve-file event)))
        (when file
          (let ((pr-node (org-roam-todo-wf-pr--get-pr-node file)))
            (when pr-node
              (plist-get pr-node :title)))))
      (org-roam-todo-prop event "TITLE")))

(defun org-roam-todo-wf-pr--get-pr-body (event)
  "Get the PR body/description for EVENT.
Resolution order:
1. Custom function from `org-roam-todo-wf-pr-body-function'
2. PR node content (heading with :ROAM_TYPE: pr)
3. Default body with TODO title/description"
  (or (when org-roam-todo-wf-pr-body-function
        (funcall org-roam-todo-wf-pr-body-function event))
      (let ((file (org-roam-todo--resolve-file event)))
        (when file
          (let ((pr-node (org-roam-todo-wf-pr--get-pr-node file)))
            (when pr-node
              (plist-get pr-node :body)))))
      ;; Default fallback
      (let ((title (org-roam-todo-prop event "TITLE"))
            (description (org-roam-todo-prop event "DESCRIPTION")))
        (format "## TODO\n\n%s\n\n---\n_Managed by org-roam-todo_"
                (or description title)))))

(defun org-roam-todo-wf-pr--require-pr-sections (event)
  "Validate: PR node exists with title and description.
EVENT is the workflow event context.
Only validates if `org-roam-todo-wf-pr-require-pr-sections' is non-nil.
Requires a PR node (heading with :ROAM_TYPE: pr property) containing
both a title (the heading text) and body (content under the heading)."
  (when org-roam-todo-wf-pr-require-pr-sections
    (let* ((file (org-roam-todo--resolve-file event))
           (pr-node (when file (org-roam-todo-wf-pr--get-pr-node file))))
      (unless pr-node
        (user-error "Missing PR node. Use mcp__emacs__todo_pr_update to create PR title and description"))
      (unless (plist-get pr-node :title)
        (user-error "PR node has no title. Use mcp__emacs__todo_pr_update to set PR title"))
      (unless (plist-get pr-node :body)
        (user-error "PR node has no description. Use mcp__emacs__todo_pr_update to set PR description")))))

;;; ------------------------------------------------------------
;;; PR Workflow Hooks
;;; ------------------------------------------------------------

(defun org-roam-todo-wf-pr--create-draft-pr (event)
  "Create a draft PR for the TODO, or update existing PR.
EVENT is the workflow event context.
Uses forge to create a draft PR targeting the rebase-target branch.
Dispatches to the appropriate forge backend (GitHub, GitLab, etc.).
Saves the PR number to the TODO's PR property for status tracking.
If a PR already exists (detected via :PR: property or gh CLI), skips creation.
Reads properties fresh from file."
  (let* ((workflow (org-roam-todo-event-workflow event))
         (todo-file (org-roam-todo--resolve-file event))
         (worktree-path (org-roam-todo-prop event "WORKTREE_PATH"))
         (branch (org-roam-todo-prop event "WORKTREE_BRANCH"))
         ;; Check if PR already exists
         (existing-pr (org-roam-todo-wf-pr--get-pr-info event worktree-path)))
    
    (if existing-pr
        ;; PR already exists - just update title/body instead of creating new
        (let* ((pr-number (plist-get existing-pr :pr-number))
               (title (org-roam-todo-wf-pr--get-pr-title event))
               (body (org-roam-todo-wf-pr--get-pr-body event)))
          (message "PR #%s already exists, updating title and description..." pr-number)
          ;; Update the PR via org-roam-todo-wf-pr-feedback functions
          (org-roam-todo-wf-pr-feedback--update-pr worktree-path title body)
          ;; Ensure PR property is set
          (when todo-file
            (org-roam-todo-set-file-property todo-file "PR" (number-to-string pr-number)))
          (message "Updated PR #%s: %s" pr-number title))
      
      ;; No existing PR - create new draft PR
      (let* ((title (org-roam-todo-wf-pr--get-pr-title event))
             (body (org-roam-todo-wf-pr--get-pr-body event))
             (target-raw (org-roam-todo-wf--get-target-branch-from-event event workflow))
             (target (or (org-roam-todo-wf-pr--strip-remote-prefix target-raw) "main"))
             (default-directory worktree-path)
             (repo (org-roam-todo-wf-pr--get-forge-repo worktree-path))
             (repo-type (org-roam-todo-wf-pr--repo-type repo)))
        ;; Dynamically bind the repo for the method to access
        (let ((org-roam-todo-wf-pr--current-repo repo))
          (org-roam-todo-wf-pr--create-pr
           repo-type
           title body target branch
           t  ; draft-p
           (lambda (data &rest _)
             ;; Extract PR number from response and save to TODO
             (let ((pr-number (or (alist-get 'number data)
                                  (alist-get 'iid data))))  ; GitLab uses 'iid'
               (when (and pr-number todo-file)
                 (org-roam-todo-set-file-property todo-file "PR" (number-to-string pr-number))
                 (message "Draft PR #%s created for %s" pr-number title)))
             (forge--pull repo))
           (lambda (&rest args)
             (message "Failed to create PR: %S" args))))))))
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

(defun org-roam-todo-wf-pr--mark-pr-ready-via-gh (worktree-path &optional pr-number)
  "Mark a draft PR as ready for review using gh CLI.
WORKTREE-PATH is the directory to run the command in.
PR-NUMBER is optional - if not provided, uses current branch's PR."
  (when worktree-path
    (let* ((default-directory worktree-path)
           (cmd (if pr-number
                    (format "gh pr ready %s 2>&1" pr-number)
                  "gh pr ready 2>&1"))
           (result (shell-command-to-string cmd)))
      (if (string-match-p "marked as ready" result)
          (message "PR marked as ready for review")
        (message "gh pr ready: %s" (string-trim result))))))
(defun org-roam-todo-wf-pr--get-pr-state-via-gh (worktree-path &optional pr-number)
  "Get PR state using gh CLI.
WORKTREE-PATH is the directory to run the command in.
PR-NUMBER is optional - if not provided, uses current branch's PR.
Returns one of: merged, closed, open, or nil."
  (when worktree-path
    (let* ((default-directory worktree-path)
           (cmd (if pr-number
                    (format "gh pr view %s --json state -q .state 2>/dev/null" pr-number)
                  "gh pr view --json state -q .state 2>/dev/null"))
           (result (string-trim (shell-command-to-string cmd))))
      (pcase result
        ("MERGED" 'merged)
        ("CLOSED" 'closed)
        ("OPEN" 'open)
        (_ nil)))))

(defun org-roam-todo-wf-pr--get-pr-state (worktree-path &optional event)
  "Get the PR state for the current branch in WORKTREE-PATH.
EVENT is optional workflow event for reading :PR: property.
Returns one of: merged, closed, open, or nil if no PR exists.
Tries forge first, then falls back to gh CLI with :PR: property."
  (let ((default-directory worktree-path))
    ;; Strategy 1: Try forge
    (or (when-let ((pullreq (org-roam-todo-wf-pr--get-pullreq worktree-path)))
          (condition-case nil
              (funcall (intern "eieio-oref") pullreq 'state)
            (error nil)))
        ;; Strategy 2: Try gh CLI with PR number from property
        (when event
          (when-let ((pr-number (org-roam-todo-wf-pr--get-pr-number-from-props event)))
            (org-roam-todo-wf-pr--get-pr-state-via-gh worktree-path pr-number)))
        ;; Strategy 3: Try gh CLI with current branch
        (org-roam-todo-wf-pr--get-pr-state-via-gh worktree-path))))

;;; ============================================================
;;; Watcher Poll Functions (for org-roam-todo-wf-watch)
;;; ============================================================

(defun org-roam-todo-wf-pr--check-ci-status (todo)
  "Check CI status for TODO's PR.
Returns \\='success, \\='failure, or \\='pending.
Used by watchers to poll CI status and trigger auto-advancement.
Falls back to gh CLI for PR detection when forge doesn't know about the PR."
  (let ((worktree-path (plist-get todo :worktree-path)))
    (if (and worktree-path
             (featurep 'magit-forge-ci)
             (fboundp 'magit-forge-ci--get-checks-via-gh-cli)
             (fboundp 'magit-forge-ci--compute-overall-status))
        (condition-case nil
            (let* ((default-directory worktree-path)
                   ;; Create a minimal event for get-pr-info
                   ;; It needs the :file property to read TODO properties
                   (event (make-org-roam-todo-event :todo todo))
                   (pr-info (org-roam-todo-wf-pr--get-pr-info event worktree-path)))
              (if pr-info
                  (let* ((owner (plist-get pr-info :owner))
                         (name (plist-get pr-info :name))
                         (pr-number (plist-get pr-info :pr-number))
                         (checks (magit-forge-ci--get-checks-via-gh-cli owner name pr-number))
                         (status (magit-forge-ci--compute-overall-status checks)))
                    (pcase status
                      ("success" 'success)
                      ("failure" 'failure)
                      (_ 'pending)))
                ;; No PR found via any method - still pending
                'pending))
          (error 'pending))
      ;; No CI integration available - assume pending (manual check needed)
      'pending)))

(defun org-roam-todo-wf-pr--check-pr-merged (todo)
  "Check if TODO's PR has been merged.
Returns \\='success if merged, \\='failure if closed without merge, \\='pending if open.
Used by watchers to poll merge status and trigger auto-advancement.
Uses :pr property from TODO if forge can't find the PR."
  (let ((worktree-path (plist-get todo :worktree-path))
        (pr-number (plist-get todo :pr)))
    (if worktree-path
        (condition-case nil
            (let ((state (or (org-roam-todo-wf-pr--get-pr-state worktree-path)
                             ;; Fallback to gh CLI with PR number
                             (when pr-number
                               (org-roam-todo-wf-pr--get-pr-state-via-gh
                                worktree-path (if (stringp pr-number) pr-number
                                                (number-to-string pr-number)))))))
              (pcase state
                ('merged 'success)
                ('closed 'failure)
                (_ 'pending)))
          (error 'pending))
      'pending)))

(defun org-roam-todo-wf-pr--require-ci-pass (event)
  "Validate: CI checks have passed for the PR.
EVENT is the workflow event context.
Returns:
  nil (or :pass) - CI checks passed
  (:pending \"message\") - CI checks still running
  (:fail \"message\") - CI checks failed or PR not found

Uses `magit-forge-ci' if available to check CI status.
Falls back to gh CLI for PR detection when forge doesn't know about the PR.
Otherwise, always passes (user must verify CI manually).
Reads WORKTREE_PATH fresh from file."
  (let ((worktree-path (org-roam-todo-prop event "WORKTREE_PATH")))
    ;; Check if magit-forge-ci is available
    (if (and worktree-path
             (featurep 'magit-forge-ci)
             (fboundp 'magit-forge-ci--get-checks-via-gh-cli)
             (fboundp 'magit-forge-ci--compute-overall-status))
        ;; Use magit-forge-ci to check CI status
        ;; Use the new get-pr-info which falls back to gh CLI
        (let* ((default-directory worktree-path)
               (pr-info (org-roam-todo-wf-pr--get-pr-info event worktree-path)))
          (if pr-info
              (let* ((owner (plist-get pr-info :owner))
                     (name (plist-get pr-info :name))
                     (pr-number (plist-get pr-info :pr-number))
                     (checks (magit-forge-ci--get-checks-via-gh-cli owner name pr-number))
                     (status (magit-forge-ci--compute-overall-status checks)))
                (pcase status
                  ("success" nil)  ; pass - CI succeeded
                  ("pending" (list :pending "CI checks are still running.

The workflow will automatically advance when CI completes.
You can also check CI status manually:
  - Bash: gh pr checks
  - Web: Check the PR page on GitHub/GitLab"))
                  ("failure" (list :fail (format "CI checks have failed.

HOW TO FIX:
1. Check which CI jobs failed:
   - Bash: gh pr checks
   - Bash: gh run list --branch <branch>
   - Web: Check the PR page for failed checks

2. View CI logs:
   - Bash: gh run view <run-id> --log-failed
   - Web: Click on the failed check in the PR

3. Fix the failing tests/checks in your code

4. Commit and push your fixes:
   - MCP: mcp__emacs__git_stage, mcp__emacs__git_commit
   - Bash: git add . && git commit -m \"fix: CI failures\"
   - Bash: git push

5. The workflow will re-check CI automatically, or regress to 'active':
   - MCP: mcp__emacs__todo_regress to go back and fix issues")))
                  (_ (list :fail (format "CI status unknown: %s

HOW TO FIX:
1. Check CI status manually:
   - Bash: gh pr checks
   - Web: Check the PR page on GitHub/GitLab

2. If CI hasn't started, it may need a push or manual trigger:
   - Bash: git commit --allow-empty -m \"trigger CI\" && git push

3. Ensure CI is configured for this repository:
   - Check .github/workflows/ or .gitlab-ci.yml" status)))))
            ;; No PR found via any method (tried forge, TODO properties, and gh CLI)
            (list :fail "No PR found - cannot check CI status.

Tried: forge, TODO :PR_NUMBER: property, and gh CLI lookup by branch.

HOW TO FIX:
1. Ensure a PR was created:
   - Bash: gh pr list --head <branch-name>
   - Bash: gh pr view

2. If no PR exists, create one:
   - Bash: gh pr create --draft --title \"<title>\"

3. If the PR exists but wasn't detected:
   - Add :PR_NUMBER: property to your TODO file
   - Or run: M-x forge-pull to sync forge database")))
      ;; magit-forge-ci not available - always pass
      nil)))

;; Use shared require-user-approval from org-roam-todo-wf-actions
;; org-roam-todo-wf--require-user-approval is defined there

(defun org-roam-todo-wf-pr--require-pr-merged (event)
  "Validate: PR has been merged.
EVENT is the workflow event context.
Checks forge PR state to confirm the PR is merged.
Falls back to gh CLI if forge can't find the PR.
Reads WORKTREE_PATH fresh from file."
  (let* ((worktree-path (org-roam-todo-prop event "WORKTREE_PATH"))
         (state (when worktree-path (org-roam-todo-wf-pr--get-pr-state worktree-path event))))
    (pcase state
      ('merged nil)  ; validation passes
      ('closed (user-error "PR was closed without merging.

The pull request was closed by a reviewer or maintainer without being merged.

HOW TO FIX:
1. Check why the PR was closed:
   - Bash: gh pr view
   - Web: Check the PR comments/history

2. If the work is still needed:
   - MCP: mcp__emacs__todo_regress to go back to 'active'
   - Address the feedback
   - Create a new PR or reopen the existing one

3. If the work is no longer needed:
   - MCP: mcp__emacs__todo_reject with reason explaining why"))
      ('open (user-error "PR is still open and awaiting merge.

The pull request has not been merged yet.

WHAT TO DO:
1. Wait for reviewers to approve and merge the PR
   - The workflow will automatically advance when the PR is merged
   - MCP: mcp__emacs__todo_watch_status to monitor

2. If you have merge permissions:
   - Bash: gh pr merge --auto
   - Web: Click 'Merge pull request' on the PR page

3. If reviews are needed:
   - Check review status: gh pr checks
   - Request reviews: gh pr edit --add-reviewer <username>

4. If there are merge conflicts:
   - MCP: mcp__emacs__todo_regress to go back and rebase
   - Bash: git fetch && git rebase origin/main
   - Push and the PR will update"))
      (_ (user-error "Could not determine PR state.

The forge package cannot find or read the PR status.

HOW TO FIX:
1. Ensure the PR exists:
   - Bash: gh pr view
   - Bash: gh pr list --head <branch-name>

2. Refresh forge data:
   - Run: M-x forge-pull
   - Bash: (forge-pull) in Emacs

3. Ensure the repository is tracked by forge:
   - Run: M-x forge-add-repository

4. Check forge configuration:
   - Ensure GitHub/GitLab token is configured
   - See forge documentation for auth setup")))))

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
  "Actions when entering review status (legacy).
Requests configured reviewers."
  (org-roam-todo-wf-pr--request-reviewers event))

(defun org-roam-todo-wf-pr--on-enter-review-full (event)
  "Full actions when entering review status in simplified workflow.
Performs rebase, push, create PR (ready), and request reviewers."
  ;; First rebase onto target
  (org-roam-todo-wf--rebase-onto-target event)
  ;; Push the branch
  (org-roam-todo-wf--push-branch event)
  ;; Create a ready PR (not draft) since we've already done our validations
  (org-roam-todo-wf-pr--create-ready-pr event)
  ;; Request reviewers
  (org-roam-todo-wf-pr--request-reviewers event))

(defun org-roam-todo-wf-pr--create-ready-pr (event)
  "Create a ready (non-draft) PR for the TODO, or update existing PR.
EVENT is the workflow event context.
If a PR already exists (detected via :PR: property or gh CLI), updates it
and marks it as ready for review instead of creating a new one."
  (let* ((workflow (org-roam-todo-event-workflow event))
         (todo-file (org-roam-todo--resolve-file event))
         (worktree-path (org-roam-todo-prop event "WORKTREE_PATH"))
         (branch (org-roam-todo-prop event "WORKTREE_BRANCH"))
         ;; Check if PR already exists
         (existing-pr (org-roam-todo-wf-pr--get-pr-info event worktree-path)))

    (if existing-pr
        ;; PR already exists - update title/body and mark ready
        (let* ((pr-number (plist-get existing-pr :pr-number))
               (title (org-roam-todo-wf-pr--get-pr-title event))
               (body (org-roam-todo-wf-pr--get-pr-body event)))
          (message "PR #%s already exists, updating and marking ready for review..." pr-number)
          ;; Update the PR title/body
          (org-roam-todo-wf-pr-feedback--update-pr worktree-path title body)
          ;; Mark PR as ready for review (not draft)
          (org-roam-todo-wf-pr--mark-pr-ready-via-gh worktree-path pr-number)
          ;; Ensure PR property is set
          (when todo-file
            (org-roam-todo-set-file-property todo-file "PR" (number-to-string pr-number)))
          (message "Updated PR #%s and marked ready: %s" pr-number title))

      ;; No existing PR - create new ready PR
      (let* ((title (org-roam-todo-wf-pr--get-pr-title event))
             (body (org-roam-todo-wf-pr--get-pr-body event))
             (target-raw (org-roam-todo-wf--get-target-branch-from-event event workflow))
             (target (or (org-roam-todo-wf-pr--strip-remote-prefix target-raw) "main"))
             (default-directory worktree-path)
             (repo (org-roam-todo-wf-pr--get-forge-repo worktree-path))
             (repo-type (org-roam-todo-wf-pr--repo-type repo)))
        (let ((org-roam-todo-wf-pr--current-repo repo))
          (org-roam-todo-wf-pr--create-pr
           repo-type
           title body target branch
           nil  ; draft-p = nil for ready PR
           (lambda (data &rest _)
             (let ((pr-number (or (alist-get 'number data)
                                  (alist-get 'iid data))))
               (when (and pr-number todo-file)
                 (org-roam-todo-set-file-property todo-file "PR" (number-to-string pr-number))
                 (message "PR #%s created for %s" pr-number title)))
             (forge--pull repo))
           (lambda (&rest args)
             (message "Failed to create PR: %S" args))))))))

(defun org-roam-todo-wf-pr--check-review-status (todo)
  "Check overall review status for TODO.
Returns \\='success if PR is merged, \\='failure if CI failed or PR closed,
\\='pending otherwise.
Used by watchers to poll status and trigger auto-advancement.
Uses :pr property from TODO if forge can't find the PR."
  (let ((worktree-path (plist-get todo :worktree-path))
        (pr-number (plist-get todo :pr)))
    (if worktree-path
        (condition-case nil
            (let* ((pr-state (or (org-roam-todo-wf-pr--get-pr-state worktree-path)
                                 ;; Fallback to gh CLI with PR number
                                 (when pr-number
                                   (org-roam-todo-wf-pr--get-pr-state-via-gh
                                    worktree-path (if (stringp pr-number) pr-number
                                                    (number-to-string pr-number))))))
                   (ci-status (org-roam-todo-wf-pr--check-ci-status todo)))
              (cond
               ;; PR merged = success
               ((eq pr-state 'merged) 'success)
               ;; PR closed without merge = failure
               ((eq pr-state 'closed) 'failure)
               ;; CI failed = failure (regress to fix)
               ((eq ci-status 'failure) 'failure)
               ;; Otherwise still pending
               (t 'pending)))
          (error 'pending))
      'pending)))

;;; ============================================================
;;; Workflow Definition
;;; ============================================================

(org-roam-todo-define-workflow pull-request
  "Pull Request workflow with forge integration.

Designed for team development where changes go through code review
via Pull Requests.  Uses the forge package to interact with GitHub,
GitLab, and other supported forges.

Lifecycle:
  draft -> active -> review -> done

- draft: TODO exists, no work started
- active: Worktree created, work in progress
- review: PR created, awaiting CI and/or reviewer feedback
  - Automatically regresses to active if ANY changes are made
- done: PR merged, cleaned up

'rejected' is always available to abandon the TODO.

Requirements:
- The repository must be tracked by forge (run `forge-add-repository')
- The forge package must be configured with API access"

  :statuses '("draft" "active" "review" "done")

  :hooks
  '(;; Validation before active: ensure rebase target exists
    (:validate-active . ((10 . org-roam-todo-wf--require-rebase-target-exists)))

    ;; When entering active: set up branch and create worktree
    (:on-enter-active . (org-roam-todo-wf--ensure-branch
                         org-roam-todo-wf--ensure-worktree))

    ;; Validation before review: all the important checks
    ;; Priority: lower numbers run first (fast/important checks first)
    (:validate-review . (;; Fast checks first (priority 10-19)
                         (10 . org-roam-todo-wf--require-clean-worktree)
                         (11 . org-roam-todo-wf--require-branch-has-commits)
                         (12 . org-roam-todo-wf-pr--require-pr-sections)
                         ;; Medium priority (20-29)
                         (20 . org-roam-todo-wf--require-acceptance-complete)
                         ;; Slow/external checks (30-39)
                         (30 . org-roam-todo-wf-pr--require-ci-pass)
                         ;; User approval last (40+)
                         (40 . org-roam-todo-wf--require-user-approval)))

    ;; When entering review: rebase, push, create PR, mark ready, request reviewers
    (:on-enter-review . (org-roam-todo-wf-pr--on-enter-review-full))

    ;; Validation before done: PR must be merged, and only humans can approve
    (:validate-done . ((10 . org-roam-todo-wf-pr--require-pr-merged)
                       (20 . org-roam-todo-wf--only-human)))

    ;; When entering done: cleanup everything (agent, buffers, worktree)
    (:on-enter-done . (org-roam-todo-wf--cleanup-all)))

  :config
  '(:rebase-target "origin/main"
    :draft-pr nil                    ; create ready PR directly now
    :reviewers nil                   ; set per-project
    :labels nil                      ; set per-project
    :allow-backward (review)         ; can regress from review for fixes

    ;; Auto-upgrade configuration for async validation monitoring
    :auto-upgrade
    (("review" . (:on-pass "done"    ; advance when PR merged
                  :on-fail "active"   ; regress if PR closed or changes made
                  :poll-interval 60   ; check every 60 seconds
                  :timeout 86400      ; stop after 24 hours
                  :feedback t)))      ; capture feedback from PR review

    ;; Watchers for async status monitoring
    :watchers
    (;; When in "review" status, watch for buffer changes (needs more work)
     (:status "review"
      :type buffer-change
      :on-change (:regress "active")) ; regress if files are modified

     ;; When in "review" status, poll for CI completion and PR merge
     (:status "review"
      :poll-fn org-roam-todo-wf-pr--check-review-status
      :interval 60                    ; check every minute
      :on-success (:advance "done")   ; auto-advance when merged
      :on-failure (:regress "active") ; regress on CI failure
      :timeout 86400))))              ; stop polling after 24 hours

(provide 'org-roam-todo-wf-pr)
;;; org-roam-todo-wf-pr.el ends here
