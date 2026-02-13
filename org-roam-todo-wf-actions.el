;;; org-roam-todo-wf-actions.el --- Built-in action library for workflows -*- lexical-binding: t; -*-

;; Author: Claude Code
;; Version: 0.1.0
;; Package-Requires: ((emacs "28.1") (org-roam "2.0"))

;;; Commentary:
;; Built-in action library for org-roam-todo workflows.
;; Provides composable actions that workflows can mix and match:
;;
;; Validation Hooks (for :validate-STATUS):
;;   - org-roam-todo-wf--require-clean-worktree
;;   - org-roam-todo-wf--require-staged-changes
;;   - org-roam-todo-wf--require-rebase-clean
;;   - org-roam-todo-wf--require-pre-commit-pass
;;   - org-roam-todo-wf--require-target-clean
;;   - org-roam-todo-wf--require-ff-possible
;;   - org-roam-todo-wf--require-acceptance-complete
;;
;; Action Hooks (for :on-enter-STATUS, :on-exit-STATUS):
;;   - org-roam-todo-wf--ensure-branch (creates branch, fetches upstream)
;;   - org-roam-todo-wf--ensure-worktree (creates worktree for branch)
;;   - org-roam-todo-wf--cleanup-worktree
;;   - org-roam-todo-wf--cleanup-project-buffers
;;   - org-roam-todo-wf--cleanup-todo-buffer
;;   - org-roam-todo-wf--cleanup-claude-agent
;;   - org-roam-todo-wf--cleanup-all (recommended for :on-enter-done)
;;   - org-roam-todo-wf--rebase-onto-target
;;   - org-roam-todo-wf--ff-merge-to-target
;;   - org-roam-todo-wf--push-branch
;;
;; Git Helpers:
;;   - org-roam-todo-wf--git-run
;;   - org-roam-todo-wf--git-run!
;;
;; See CLAUDE.md for design details.

;;; Code:

(require 'cl-lib)
(require 'org-roam-todo-wf)
(require 'org-roam-todo-core)

;;; ============================================================
;;; Git Helper Functions
;;; ============================================================

(defun org-roam-todo-wf--git-run (directory &rest args)
  "Run git with ARGS in DIRECTORY, returning (exit-code . output)."
  (let ((default-directory directory))
    (with-temp-buffer
      (let ((exit-code (apply #'call-process "git" nil t nil args)))
        (cons exit-code (buffer-string))))))

(defun org-roam-todo-wf--git-run! (directory &rest args)
  "Run git with ARGS in DIRECTORY.  Signal error on failure.
Return output string on success."
  (let ((result (apply #'org-roam-todo-wf--git-run directory args)))
    (unless (= 0 (car result))
      (error "git %s failed (exit %d): %s"
             (string-join args " ") (car result) (cdr result)))
    (cdr result)))

;;; ============================================================
;;; Branch Setup Actions
;;; ============================================================

(defun org-roam-todo-wf--ensure-branch (event)
  "Ensure branch exists for TODO in EVENT.
This hook should run before `org-roam-todo-wf--ensure-worktree'.

Steps:
1. Generate branch name from TODO title if not already set
2. Fetch from upstream if `:fetch-before-create' is configured
3. Create branch from the base ref (e.g., origin/main)
4. Store the branch name in the TODO's WORKTREE_BRANCH property

The base ref is determined by:
- TODO's TARGET_BRANCH property
- Workflow's :rebase-target config
- Project's :base-branch config
- Global `org-roam-todo-worktree-base-branch'
- Defaults to HEAD

Reads all TODO properties fresh from file via `org-roam-todo-prop'."
  (let* ((workflow (org-roam-todo-event-workflow event))
         ;; Read fresh from file
         (project-root (org-roam-todo-prop event "PROJECT_ROOT"))
         (project-name (org-roam-todo-prop event "PROJECT_NAME"))
         (title (org-roam-todo-prop event "TITLE"))
         (file (org-roam-todo--resolve-file event))
         ;; Get existing branch or generate new one
         (existing-branch (org-roam-todo-prop event "WORKTREE_BRANCH"))
         (branch-name (or existing-branch
                          (org-roam-todo-default-branch-name title project-name)))
         ;; Get target/base branch (used as-is for git operations)
         (target (org-roam-todo-wf--get-target-branch-from-event event workflow))
         (base-branch (or target
                          (org-roam-todo-project-config-get
                           project-name :base-branch
                           org-roam-todo-worktree-base-branch)))
         ;; Check if we should fetch
         (should-fetch (org-roam-todo-project-config-get
                        project-name :fetch-before-create
                        org-roam-todo-worktree-fetch-before-create)))
    ;; Only proceed if we have project root
    (when project-root
      ;; 1. Fetch if configured
      (when should-fetch
        (org-roam-todo-wf--git-run project-root "fetch"))

      ;; 2. Create branch if it doesn't exist
      (unless (org-roam-todo-branch-exists-p project-root branch-name)
        (org-roam-todo-wf--git-run! project-root
                                    "branch" branch-name (or base-branch "HEAD")))

      ;; 3. Store branch name in TODO file if not already set
      (when (and file (not existing-branch))
        (org-roam-todo-wf--set-todo-property file "WORKTREE_BRANCH" branch-name))

      ;; 4. Also set worktree path if not already set
      (unless (org-roam-todo-prop event "WORKTREE_PATH")
        (let ((worktree-path (org-roam-todo-calc-worktree-path
                              project-root branch-name)))
          (when file
            (org-roam-todo-wf--set-todo-property file "WORKTREE_PATH" worktree-path)))))))

(defun org-roam-todo-wf--set-todo-property (file property value)
  "Set PROPERTY to VALUE in TODO FILE's property drawer."
  (with-current-buffer (find-file-noselect file)
    (save-excursion
      (goto-char (point-min))
      (let ((prop-re (format "^:%s:.*$" (regexp-quote property))))
        (if (re-search-forward prop-re nil t)
            (replace-match (format ":%s: %s" property value))
          ;; Property doesn't exist, add it after :PROPERTIES:
          (when (re-search-forward "^:PROPERTIES:" nil t)
            (forward-line 1)
            (insert (format ":%s: %s\n" property value))))))
    (save-buffer)))

;;; ============================================================
;;; Helper Functions
;;; ============================================================

(defun org-roam-todo-wf--get-target-branch (todo workflow)
  "Get the effective target branch from TODO plist and WORKFLOW.
Priority: TODO :target-branch > project config :rebase-target > workflow :rebase-target."
  (let ((project-name (plist-get todo :project-name)))
    (or (plist-get todo :target-branch)
        (when project-name
          (org-roam-todo-project-config-get project-name :rebase-target))
        (plist-get (org-roam-todo-workflow-config workflow) :rebase-target))))

(defun org-roam-todo-wf--get-target-branch-from-event (event workflow)
  "Get the effective target branch from EVENT, reading fresh from file.
Priority: TODO TARGET_BRANCH > project config :rebase-target > workflow :rebase-target.
Reads properties fresh from file via `org-roam-todo-prop'."
  (let ((project-name (org-roam-todo-prop event "PROJECT_NAME")))
    (or (org-roam-todo-prop event "TARGET_BRANCH")
        (when project-name
          (org-roam-todo-project-config-get project-name :rebase-target))
        (plist-get (org-roam-todo-workflow-config workflow) :rebase-target))))

(defun org-roam-todo-wf--has-staged-changes-p (worktree-path)
  "Return non-nil if WORKTREE-PATH has staged changes."
  (not (string-empty-p
        (cdr (org-roam-todo-wf--git-run worktree-path
                                        "diff" "--cached" "--name-only")))))
;;; ============================================================
;;; Validation Hooks
;;; ============================================================

(defun org-roam-todo-wf--require-rebase-target-exists (event)
  "Validate: rebase-target branch/ref exists.
EVENT is the workflow event context.
This ensures the target we'll create the branch from actually exists.
Reads properties fresh from file via `org-roam-todo-prop'."
  (let* ((workflow (org-roam-todo-event-workflow event))
         (project-root (org-roam-todo-prop event "PROJECT_ROOT"))
         (target (org-roam-todo-wf--get-target-branch-from-event event workflow)))
    (when (and project-root target)
      ;; Check if the ref exists with git rev-parse
      (let ((result (org-roam-todo-wf--git-run
                     project-root "rev-parse" "--verify" target)))
        (unless (= 0 (car result))
          (user-error "Rebase target '%s' does not exist.  Fetch or correct the target branch"
                      target))))))

(defun org-roam-todo-wf--require-clean-worktree (event)
  "Validate: worktree has no uncommitted changes.
EVENT is the workflow event context.
Reads WORKTREE_PATH fresh from file."
  (let ((worktree-path (org-roam-todo-prop event "WORKTREE_PATH")))
    (when worktree-path
      (let ((result (org-roam-todo-wf--git-run worktree-path "status" "--porcelain")))
        (unless (string-empty-p (cdr result))
          (user-error "Worktree has uncommitted changes.  Commit or stash before proceeding"))))))

(defun org-roam-todo-wf--require-staged-changes (event)
  "Validate: there are staged changes to commit.
EVENT is the workflow event context.
Reads WORKTREE_PATH fresh from file."
  (let ((worktree-path (org-roam-todo-prop event "WORKTREE_PATH")))
    (when worktree-path
      (unless (org-roam-todo-wf--has-staged-changes-p worktree-path)
        (user-error "No staged changes.  Stage your changes before submitting")))))

(defun org-roam-todo-wf--require-branch-has-commits (event)
  "Validate: the feature branch has commits ahead of the target.
EVENT is the workflow event context.
This validates that work has been done and committed on the branch."
  (let* ((workflow (org-roam-todo-event-workflow event))
         (worktree-path (org-roam-todo-prop event "WORKTREE_PATH"))
         (target (org-roam-todo-wf--get-target-branch-from-event event workflow)))
    (when (and worktree-path target)
      (let ((result (org-roam-todo-wf--git-run worktree-path
                                                "rev-list" "--count"
                                                (format "%s..HEAD" target))))
        (when (or (not (car result))
                  (string-empty-p (string-trim (cdr result)))
                  (= 0 (string-to-number (string-trim (cdr result)))))
          (user-error "No commits on branch.  Make and commit changes before advancing"))))))

(defun org-roam-todo-wf--require-rebase-clean (event)
  "Validate: branch rebases cleanly onto target.
EVENT is the workflow event context.
Reads properties fresh from file."
  (let* ((workflow (org-roam-todo-event-workflow event))
         (target (org-roam-todo-wf--get-target-branch-from-event event workflow))
         (worktree-path (org-roam-todo-prop event "WORKTREE_PATH")))
    (when (and target worktree-path)
      ;; Fetch latest
      (org-roam-todo-wf--git-run worktree-path "fetch")
      ;; Try rebase (abort on conflict)
      (let ((result (org-roam-todo-wf--git-run worktree-path "rebase" target)))
        (unless (= 0 (car result))
          (org-roam-todo-wf--git-run worktree-path "rebase" "--abort")
          (user-error "Rebase conflict with %s.  Resolve manually before proceeding" target))))))

(defun org-roam-todo-wf--require-pre-commit-pass (event)
  "Validate: git pre-commit hook passes on staged changes.
Runs the actual .git/hooks/pre-commit script if it exists.
EVENT is the workflow event context.
Reads WORKTREE_PATH fresh from file."
  (let* ((worktree-path (org-roam-todo-prop event "WORKTREE_PATH"))
         (git-dir (when worktree-path (expand-file-name ".git" worktree-path)))
         (hook-path (when git-dir (expand-file-name "hooks/pre-commit" git-dir))))
    ;; Run the pre-commit hook if it exists and is executable
    (when (and hook-path
               (file-exists-p hook-path)
               (file-executable-p hook-path))
      (let ((default-directory worktree-path))
        (unless (= 0 (call-process hook-path nil nil nil))
          (user-error "Pre-commit hook failed.  Fix issues before proceeding"))))))

(defun org-roam-todo-wf--require-target-clean (event)
  "Validate: target branch repo has no uncommitted changes.
EVENT is the workflow event context.
This ensures the project-root (where we'll do the ff-merge) is clean.
Ignores untracked files - only checks for staged/unstaged modifications.
Reads PROJECT_ROOT fresh from file."
  (let ((project-root (org-roam-todo-prop event "PROJECT_ROOT")))
    (when project-root
      ;; Use -uno to ignore untracked files
      (let ((result (org-roam-todo-wf--git-run project-root "status" "--porcelain" "-uno")))
        (unless (string-empty-p (string-trim (cdr result)))
          (user-error "Target repository has uncommitted changes.  Clean up before merging"))))))

(defun org-roam-todo-wf--require-ff-possible (event)
  "Validate: fast-forward merge to target branch is possible.
EVENT is the workflow event context.
Checks that the feature branch is a direct descendant of the target branch,
meaning there's no divergence and ff-merge will succeed.
Reads properties fresh from file."
  (let* ((workflow (org-roam-todo-event-workflow event))
         (project-root (org-roam-todo-prop event "PROJECT_ROOT"))
         (branch-name (org-roam-todo-prop event "WORKTREE_BRANCH"))
         (target (org-roam-todo-wf--get-target-branch-from-event event workflow)))
    (when (and project-root branch-name target)
      ;; Check if target is an ancestor of branch (ff-merge possible)
      ;; git merge-base --is-ancestor <target> <branch>
      ;; Returns 0 if target IS an ancestor (ff possible), non-zero otherwise
      (let ((result (org-roam-todo-wf--git-run
                     project-root "merge-base" "--is-ancestor" target branch-name)))
        (unless (= 0 (car result))
          (user-error "Cannot fast-forward: %s has diverged from %s.  Rebase first"
                      target branch-name))))))

(defun org-roam-todo-wf--require-acceptance-complete (event)
  "Validate: all acceptance criteria must be complete.
EVENT is the workflow event context.
Uses `org-roam-todo-all-criteria-complete-p' to check the TODO file."
  (let ((file (org-roam-todo--resolve-file event)))
    (unless (org-roam-todo-all-criteria-complete-p file)
      (let ((incomplete (org-roam-todo-get-incomplete-criteria file)))
        (user-error "Incomplete acceptance criteria (%d remaining):\n%s"
                    (length incomplete)
                    (mapconcat (lambda (c)
                                 (format "  %d. %s"
                                         (plist-get c :index)
                                         (plist-get c :text)))
                               incomplete
                               "\n"))))))

;;; ============================================================
;;; Git Worktree Actions
;;; ============================================================

(defun org-roam-todo-wf--generate-dir-locals (worktree-path project-root)
  "Generate .dir-locals.el in WORKTREE-PATH to configure agent permissions.
Uses the rule-based permission system to:
- Auto-allow Read for both worktree and project root (safe read-only access)
- Auto-allow Edit/Write/lock/locks/edit/edits for the worktree
- Auto-deny Edit/Write/lock/locks/edit/edits for the project root"
  (let* ((dir-locals-file (expand-file-name ".dir-locals.el" worktree-path))
         (worktree-normalized (file-name-as-directory
                               (expand-file-name worktree-path)))
         (project-root-normalized (file-name-as-directory
                                   (expand-file-name project-root)))
         (reject-message (format "You are in a worktree. Edit files here (%s), not in the main project."
                                 worktree-path))
         (system-prompt (format "You are working in a git worktree at %s. Only edit files within this worktree directory. The main project at %s is off-limits for editing."
                                worktree-path project-root-normalized))
         ;; Permission rules evaluated in order - first match wins
         (permission-rules
          `(;; Rule 1: Auto-allow Read/read_file for anywhere (safe read-only)
            (:match (:tool-regex "^Read$\\|^mcp__emacs__read_file$")
             :action :allow
             :scope :session)
            ;; Rule 2: Auto-allow editing tools for worktree path
            (:match (:and (:tool-regex "^Edit$\\|^Write$\\|^mcp__emacs__lock$\\|^mcp__emacs__locks$\\|^mcp__emacs__edit$\\|^mcp__emacs__edits$")
                          (:path-prefix ,worktree-normalized))
             :action :allow
             :scope :session)
            ;; Rule 3: Auto-deny editing tools for project root
            (:match (:and (:tool-regex "^Edit$\\|^Write$\\|^mcp__emacs__lock$\\|^mcp__emacs__locks$\\|^mcp__emacs__edit$\\|^mcp__emacs__edits$")
                          (:path-prefix ,project-root-normalized))
             :action :deny
             :message ,reject-message)))
         (dir-locals-content
          `((nil . ((claude-agent-permission-policy . :rules)
                    (claude-agent-permission-rules-local . ,permission-rules)
                    (claude-agent-extra-system-prompt . ,system-prompt))))))
    (with-temp-file dir-locals-file
      (insert ";;; Directory Local Variables for worktree agent\n")
      (insert ";;; For more information see (info \"(emacs) Directory Variables\")\n\n")
      (pp dir-locals-content (current-buffer)))))

(defun org-roam-todo-wf--ensure-worktree (event)
  "Ensure worktree exists for TODO in EVENT.
Creates the worktree for an existing branch.  The branch should already
exist (created by `org-roam-todo-wf--ensure-branch').

If the branch doesn't exist, falls back to creating it with the worktree.
Also generates a .dir-locals.el to configure agent permissions.
Reads properties fresh from file via `org-roam-todo-prop'."
  (let* ((workflow (org-roam-todo-event-workflow event))
         ;; Read fresh from file
         (project-root (org-roam-todo-prop event "PROJECT_ROOT"))
         (branch-name (org-roam-todo-prop event "WORKTREE_BRANCH"))
         (worktree-path (org-roam-todo-prop event "WORKTREE_PATH"))
         (target (org-roam-todo-wf--get-target-branch-from-event event workflow)))
    (when (and worktree-path branch-name project-root
               (not (file-directory-p worktree-path)))
      (if (org-roam-todo-branch-exists-p project-root branch-name)
          ;; Branch exists - just add worktree for it
          (org-roam-todo-wf--git-run! project-root
                                      "worktree" "add"
                                      worktree-path
                                      branch-name)
        ;; Branch doesn't exist - create it with the worktree (fallback)
        (org-roam-todo-wf--git-run! project-root
                                    "worktree" "add"
                                    "-b" branch-name
                                    worktree-path
                                    (or target "HEAD"))))
    ;; Generate .dir-locals.el for agent permissions (if worktree exists)
    (when (and worktree-path project-root (file-directory-p worktree-path))
      (org-roam-todo-wf--generate-dir-locals worktree-path project-root))))

(defun org-roam-todo-wf--cleanup-worktree (event)
  "Clean up git worktree and branch for TODO in EVENT.
Remove the worktree directory and force-delete the branch.
Reads properties fresh from file."
  (let* ((project-root (org-roam-todo-prop event "PROJECT_ROOT"))
         (worktree-path (org-roam-todo-prop event "WORKTREE_PATH"))
         (branch-name (org-roam-todo-prop event "WORKTREE_BRANCH")))
    ;; Remove worktree if it exists
    (when (and worktree-path project-root)
      (org-roam-todo-wf--git-run! project-root
                                  "worktree" "remove" "--force" worktree-path))
    ;; Delete branch if it exists
    (when (and branch-name project-root)
      (org-roam-todo-wf--git-run! project-root
                                  "branch" "-D" branch-name))))

(defun org-roam-todo-wf--cleanup-project-buffers (event)
  "Close all buffers associated with the worktree project in EVENT.
Uses projectile to find and kill buffers belonging to the worktree.
Safely handles the case where projectile is not available.
Reads WORKTREE_PATH fresh from file."
  (let ((worktree-path (org-roam-todo-prop event "WORKTREE_PATH")))
    (when (and worktree-path (file-directory-p worktree-path))
      (if (fboundp 'projectile-project-buffers)
          ;; Use projectile if available
          (let ((project-buffers (projectile-project-buffers worktree-path)))
            (dolist (buf project-buffers)
              (when (buffer-live-p buf)
                (kill-buffer buf))))
        ;; Fallback: kill buffers whose file is under worktree-path
        (dolist (buf (buffer-list))
          (when-let* ((file (buffer-file-name buf))
                      (_ (string-prefix-p (file-truename worktree-path)
                                          (file-truename file))))
            (kill-buffer buf)))))))

(defun org-roam-todo-wf--cleanup-todo-buffer (event)
  "Close the TODO org-roam buffer for EVENT.
Finds and kills the buffer visiting the TODO file."
  (let ((todo-file (org-roam-todo--resolve-file event)))
    (when todo-file
      (when-let ((buf (find-buffer-visiting todo-file)))
        (kill-buffer buf)))))

(defun org-roam-todo-wf--cleanup-claude-agent (event)
  "Stop the Claude agent associated with the worktree in EVENT.
Looks for a claude buffer matching the worktree path and kills it.
Reads WORKTREE_PATH fresh from file."
  (let ((worktree-path (org-roam-todo-prop event "WORKTREE_PATH")))
    (when worktree-path
      ;; Claude agent buffers are named *claude:/path/to/worktree* or
      ;; *claude:/path/to/worktree:agent-name*
      (let ((pattern (format "\\*claude:%s" (regexp-quote worktree-path))))
        (dolist (buf (buffer-list))
          (when (string-match-p pattern (buffer-name buf))
            (kill-buffer buf)))))))

(defun org-roam-todo-wf--cleanup-all (event)
  "Perform complete cleanup for a finished TODO in EVENT.
This is the recommended cleanup action for :on-enter-done hooks.
Cleans up in order:
1. Claude agent buffers (to stop any running agents)
2. Project buffers (to close all files from the worktree)
3. TODO buffer (to close the task file)
4. Git worktree and branch (to remove the working directory)"
  ;; Kill Claude agent first - it might be using project files
  (org-roam-todo-wf--cleanup-claude-agent event)
  ;; Kill project buffers before removing the worktree
  (org-roam-todo-wf--cleanup-project-buffers event)
  ;; Close the TODO buffer
  (org-roam-todo-wf--cleanup-todo-buffer event)
  ;; Finally remove the git worktree and branch
  (org-roam-todo-wf--cleanup-worktree event))

(defun org-roam-todo-wf--rebase-onto-target (event)
  "Rebase worktree branch onto target branch.
Fetches first, then rebases.  Aborts and signals error on conflict.
Reads properties fresh from file."
  (let* ((workflow (org-roam-todo-event-workflow event))
         (target (org-roam-todo-wf--get-target-branch-from-event event workflow))
         (worktree-path (org-roam-todo-prop event "WORKTREE_PATH")))
    (when (and target worktree-path)
      ;; Fetch latest
      (org-roam-todo-wf--git-run worktree-path "fetch")
      ;; Try rebase
      (let ((result (org-roam-todo-wf--git-run worktree-path "rebase" target)))
        (unless (= 0 (car result))
          ;; Abort on failure
          (org-roam-todo-wf--git-run worktree-path "rebase" "--abort")
          (user-error "Rebase conflict with %s.  Resolve manually: %s"
                      target (cdr result)))))))

(defun org-roam-todo-wf--push-branch (event)
  "Push worktree branch to origin with force-with-lease.
Signals error if no branch is configured.
Reads properties fresh from file."
  (let* ((worktree-path (org-roam-todo-prop event "WORKTREE_PATH"))
         (branch-name (org-roam-todo-prop event "WORKTREE_BRANCH")))
    (unless branch-name
      (user-error "No worktree branch configured for push"))
    (unless worktree-path
      (user-error "No worktree path configured for push"))
    (org-roam-todo-wf--git-run! worktree-path
                                "push" "--force-with-lease" "origin" branch-name)))

(defun org-roam-todo-wf--ff-merge-to-target (event)
  "Fast-forward merge worktree branch into target branch.
Must be run from project-root (not worktree).
Signals error if merge fails or if target/branch not configured.
Reads properties fresh from file."
  (let* ((workflow (org-roam-todo-event-workflow event))
         (project-root (org-roam-todo-prop event "PROJECT_ROOT"))
         (branch-name (org-roam-todo-prop event "WORKTREE_BRANCH"))
         (target (org-roam-todo-wf--get-target-branch-from-event event workflow)))
    (unless target
      (user-error "No target branch configured for merge"))
    (unless branch-name
      (user-error "No worktree branch configured for merge"))
    (unless project-root
      (user-error "No project root configured for merge"))
    (org-roam-todo-wf--git-run! project-root
                                "merge" "--ff-only" branch-name)))

(provide 'org-roam-todo-wf-actions)
;;; org-roam-todo-wf-actions.el ends here
