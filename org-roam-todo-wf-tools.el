;;; org-roam-todo-wf-tools.el --- Workflow MCP tools for org-roam-todo -*- lexical-binding: t; -*-

;; Author: Claude Code
;; Version: 0.1.0
;; Package-Requires: ((emacs "28.1") (org-roam "2.0"))

;;; Commentary:
;; Human-centric MCP tools for the org-roam-todo workflow system.
;; These tools provide the interface for managing TODOs through their lifecycle:
;;
;; - todo-start: Create worktree and advance draft -> active
;; - todo-stage-changes: Stage and commit changes per workflow's commit-strategy
;; - todo-advance: Move to next status (+1)
;; - todo-regress: Move to previous status (-1, if allowed)
;; - todo-reject: Abandon TODO
;; - todo-delegate: Spawn agent in worktree
;;
;; These tools work with any workflow (local-ff, pull-request, etc.) and
;; respect the workflow's transition rules and validation hooks.

;;; Code:

(require 'cl-lib)
(require 'org-roam-todo-wf)
(require 'org-roam-todo-wf-actions)

;; Forward declarations for functions from org-roam-todo.el
(declare-function org-roam-todo--query-todos "org-roam-todo" (&optional project-filter))
(declare-function org-roam-todo-mcp-add-progress "org-roam-todo" (message &optional todo-id))

;;; ============================================================
;;; TODO Resolution
;;; ============================================================

(defun org-roam-todo-wf-tools--get-todo (todo-id)
  "Resolve TODO-ID to a TODO plist.
If TODO-ID is nil, tries to find the current TODO from the worktree.
If TODO-ID is a file path that exists, parses and returns it.
Otherwise searches by title or ID."
  (cond
   ;; No ID - try to infer from current worktree
   ((null todo-id)
    (org-roam-todo-wf-tools--get-todo-from-worktree))
   ;; File path that exists
   ((and (stringp todo-id) (file-exists-p todo-id))
    (org-roam-todo-wf-tools--parse-todo-file todo-id))
   ;; Search by title or ID
   (t
    (let ((todos (org-roam-todo--query-todos)))
      (cl-find-if (lambda (todo)
                    (or (string= (plist-get todo :title) todo-id)
                        (string= (plist-get todo :id) todo-id)))
                  todos)))))

(defun org-roam-todo-wf-tools--get-todo-from-worktree ()
  "Find TODO associated with the current worktree directory."
  (let* ((cwd (directory-file-name (expand-file-name default-directory)))
         (todos (org-roam-todo--query-todos)))
    (cl-find-if
     (lambda (todo)
       (let ((wpath (plist-get todo :worktree-path)))
         (and wpath
              (string= (directory-file-name (expand-file-name wpath)) cwd))))
     todos)))

(defun org-roam-todo-wf-tools--parse-todo-file (file)
  "Parse TODO properties from FILE and return as plist."
  (with-temp-buffer
    (insert-file-contents file)
    (let ((props '())
          (content (buffer-string)))
      ;; Extract properties
      (when (string-match ":ID:\\s-*\\(.+\\)" content)
        (setq props (plist-put props :id (match-string 1 content))))
      (when (string-match ":PROJECT_NAME:\\s-*\\(.+\\)" content)
        (setq props (plist-put props :project-name (match-string 1 content))))
      (when (string-match ":PROJECT_ROOT:\\s-*\\(.+\\)" content)
        (setq props (plist-put props :project-root (match-string 1 content))))
      (when (string-match ":STATUS:\\s-*\\(.+\\)" content)
        (setq props (plist-put props :status (match-string 1 content))))
      (when (string-match ":WORKTREE_PATH:\\s-*\\(.+\\)" content)
        (setq props (plist-put props :worktree-path (match-string 1 content))))
      (when (string-match ":WORKTREE_BRANCH:\\s-*\\(.+\\)" content)
        (setq props (plist-put props :worktree-branch (match-string 1 content))))
      (when (string-match "#\\+title:\\s-*\\(.+\\)" content)
        (setq props (plist-put props :title (match-string 1 content))))
      (setq props (plist-put props :file file))
      props)))

;;; ============================================================
;;; MCP Tools
;;; ============================================================

(defun org-roam-todo-wf-tools-start (&optional todo-id)
  "Start working on a TODO - advance from draft to active.
TODO-ID can be a file path, title, or ID. Defaults to current TODO.
Creates the worktree via :on-enter-active hook."
  (let ((todo (org-roam-todo-wf-tools--get-todo todo-id)))
    (unless todo
      (user-error "TODO not found: %s" (or todo-id "current")))
    (let ((status (plist-get todo :status)))
      (unless (string= status "draft")
        (user-error "Can only start TODOs in draft status (current: %s)" status))
      (org-roam-todo-wf--change-status todo "active" 'ai)
      (format "Started TODO: %s" (plist-get todo :title)))))

(defun org-roam-todo-wf-tools-stage (description &optional todo-id)
  "Commit staged changes according to workflow's commit-strategy.
DESCRIPTION is a description of the changes made.
TODO-ID can be a file path, title, or ID.  Defaults to current TODO.

The agent must explicitly stage changes before calling this tool.
If there are unstaged changes, this tool will error - the agent should
either stage them, add them to .gitignore, or use `git update-index
--assume-unchanged` to exclude them.

Commit strategies (from workflow :commit-strategy config):
- :single-commit (default): Creates one commit, amends if branch has commits
- :many-commit: Creates a new commit for each stage call
- :managed-commit: Does nothing - agent must commit manually

All automated commits use --no-gpg-sign."
  (let ((todo (org-roam-todo-wf-tools--get-todo todo-id)))
    (unless todo
      (user-error "TODO not found: %s" (or todo-id "current")))
    (let* ((worktree-path (plist-get todo :worktree-path))
           (workflow (org-roam-todo-wf--get-workflow todo))
           (config (org-roam-todo-workflow-config workflow))
           (strategy (or (plist-get config :commit-strategy) :single-commit)))
      (unless worktree-path
        (user-error "No worktree exists - call todo-start first"))
      (let ((default-directory worktree-path))
        ;; Check for unstaged changes
        (org-roam-todo-wf-tools--require-no-unstaged)
        ;; Check for staged changes (unless managed-commit)
        (unless (eq strategy :managed-commit)
          (org-roam-todo-wf-tools--require-staged-changes))
        ;; Commit according to strategy
        (pcase strategy
          (:single-commit
           (org-roam-todo-wf-tools--commit-single description todo))
          (:many-commit
           (org-roam-todo-wf-tools--commit-new description))
          (:managed-commit
           "Commit strategy is :managed-commit - commit manually when ready.")
          (_
           (user-error "Unknown commit strategy: %s" strategy)))))))

(defun org-roam-todo-wf-tools--require-no-unstaged ()
  "Error if there are unstaged changes in the working tree.
Unstaged changes should be explicitly staged, added to .gitignore,
or excluded with `git update-index --assume-unchanged`."
  (let ((output (with-output-to-string
                  (with-current-buffer standard-output
                    (call-process "git" nil t nil
                                  "diff" "--name-only")))))
    (when (and output (not (string-empty-p (string-trim output))))
      (user-error "Unstaged changes detected: %s\nStage them, add to .gitignore, or exclude with `git update-index --assume-unchanged`"
                  (string-trim output)))))

(defun org-roam-todo-wf-tools--require-staged-changes ()
  "Error if there are no staged changes to commit."
  (let ((output (with-output-to-string
                  (with-current-buffer standard-output
                    (call-process "git" nil t nil
                                  "diff" "--cached" "--name-only")))))
    (when (or (null output) (string-empty-p (string-trim output)))
      (user-error "No staged changes to commit.  Stage your changes first with `git add` or `magit_stage`"))))

(defun org-roam-todo-wf-tools--ref-exists-p (ref)
  "Return non-nil if git REF exists."
  (= 0 (call-process "git" nil nil nil "rev-parse" "--verify" "--quiet" ref)))

(defun org-roam-todo-wf-tools--branch-has-commits-p (todo)
  "Return non-nil if the current branch has commits ahead of the target.
Uses generic `org-roam-todo-wf--get-target-branch' for target resolution.
Falls back to 'main' if the configured target doesn't exist."
  (let* ((workflow (org-roam-todo-wf--get-workflow todo))
         ;; Use the generic function for target branch resolution
         (configured-target (or (org-roam-todo-wf--get-target-branch todo workflow)
                                "main"))
         ;; Use configured target if it exists, otherwise try 'main'
         (target (cond
                  ((org-roam-todo-wf-tools--ref-exists-p configured-target) configured-target)
                  ((org-roam-todo-wf-tools--ref-exists-p "main") "main")
                  (t nil))))
    (when target
      (let ((output (with-output-to-string
                      (with-current-buffer standard-output
                        (call-process "git" nil t nil
                                      "rev-list" "--count" (format "%s..HEAD" target))))))
        (and output
             (string-match "^\\([0-9]+\\)" output)
             (> (string-to-number (match-string 1 output)) 0))))))

(defun org-roam-todo-wf-tools--commit-single (description todo)
  "Commit with DESCRIPTION, amending if branch already has commits.
TODO is used to determine the target branch from workflow config."
  (if (org-roam-todo-wf-tools--branch-has-commits-p todo)
      ;; Amend existing commit
      (let ((result (call-process "git" nil nil nil
                                  "commit" "--amend" "--no-gpg-sign"
                                  "-m" description)))
        (if (= result 0)
            (format "Amended commit: %s" description)
          (user-error "Failed to amend commit")))
    ;; Create new commit
    (org-roam-todo-wf-tools--commit-new description)))

(defun org-roam-todo-wf-tools--commit-new (description)
  "Create a new commit with DESCRIPTION."
  (let ((result (call-process "git" nil nil nil
                              "commit" "--no-gpg-sign" "-m" description)))
    (if (= result 0)
        (format "Created commit: %s" description)
      (user-error "Failed to create commit"))))

(defun org-roam-todo-wf-tools-advance (&optional todo-id)
  "Advance TODO to next status in workflow (+1).
TODO-ID can be a file path, title, or ID. Defaults to current TODO."
  (let ((todo (org-roam-todo-wf-tools--get-todo todo-id)))
    (unless todo
      (user-error "TODO not found: %s" (or todo-id "current")))
    (let* ((workflow (org-roam-todo-wf--get-workflow todo))
           (statuses (org-roam-todo-workflow-statuses workflow))
           (current (plist-get todo :status))
           (idx (cl-position current statuses :test #'string=)))
      ;; Check we're not at the end
      (unless (and idx (< idx (1- (length statuses))))
        (user-error "Cannot advance from '%s' - already at terminal status" current))
      (let ((next (nth (1+ idx) statuses)))
        (org-roam-todo-wf--change-status todo next 'ai)
        (format "Advanced: %s -> %s" current next)))))

(defun org-roam-todo-wf-tools-regress (&optional todo-id)
  "Regress TODO to previous status (-1, if workflow allows).
TODO-ID can be a file path, title, or ID. Defaults to current TODO."
  (let ((todo (org-roam-todo-wf-tools--get-todo todo-id)))
    (unless todo
      (user-error "TODO not found: %s" (or todo-id "current")))
    (let* ((workflow (org-roam-todo-wf--get-workflow todo))
           (statuses (org-roam-todo-workflow-statuses workflow))
           (config (org-roam-todo-workflow-config workflow))
           (allow-backward (plist-get config :allow-backward))
           (current (plist-get todo :status))
           (idx (cl-position current statuses :test #'string=)))
      ;; Check we're not at the first status
      (unless (and idx (> idx 0))
        (user-error "Cannot regress from '%s' - already at first status" current))
      ;; Check if regress is allowed for this status
      (unless (member (intern current) allow-backward)
        (user-error "Cannot regress from '%s' - not allowed by workflow" current))
      (let ((prev (nth (1- idx) statuses)))
        (org-roam-todo-wf--change-status todo prev 'ai)
        (format "Regressed: %s -> %s" current prev)))))

(defun org-roam-todo-wf-tools-reject (reason &optional todo-id)
  "Reject/abandon a TODO.  Move to rejected status.
REASON is the explanation for rejection.
TODO-ID can be a file path, title, or ID.  Defaults to current TODO."
  (let ((todo (org-roam-todo-wf-tools--get-todo todo-id)))
    (unless todo
      (user-error "TODO not found: %s" (or todo-id "current")))
    ;; Log the rejection reason
    (org-roam-todo-mcp-add-progress
     (format "REJECTED: %s" reason)
     (plist-get todo :file))
    ;; Change status to rejected
    (org-roam-todo-wf--change-status todo "rejected" 'ai)
    (format "Rejected TODO: %s\nReason: %s" (plist-get todo :title) reason)))

(defun org-roam-todo-wf-tools-delegate (&optional todo-id)
  "Delegate a TODO to a Claude agent.
Spawns an agent in the worktree.  The TODO must be in active status
with a worktree created.  The agent can then call todo-advance when done.
TODO-ID can be a file path, title, or ID.  Defaults to current TODO."
  (let ((todo (org-roam-todo-wf-tools--get-todo todo-id)))
    (unless todo
      (user-error "TODO not found: %s" (or todo-id "current")))
    (let ((status (plist-get todo :status))
          (worktree-path (plist-get todo :worktree-path)))
      ;; Validate status
      (unless (string= status "active")
        (user-error "Can only delegate from 'active' status (current: %s)" status))
      ;; Validate worktree
      (unless worktree-path
        (user-error "No worktree exists - call todo-start first"))
      ;; Spawn the agent
      (let ((buffer-name (org-roam-todo-wf-tools--spawn-agent worktree-path todo)))
        (format "Delegated to agent: %s\nWorktree: %s" buffer-name worktree-path)))))

;;; ============================================================
;;; Agent Spawning
;;; ============================================================

(defun org-roam-todo-wf-tools--spawn-agent (worktree-path todo)
  "Spawn a Claude agent in WORKTREE-PATH for TODO.
Returns the agent buffer name."
  (require 'claude-agent nil t)
  (if (fboundp 'claude-agent-run)
      (let* ((file (plist-get todo :file))
             (model (or (plist-get todo :worktree-model) "sonnet"))
             (buf (claude-agent-run worktree-path nil nil nil model))
             (buffer-name (buffer-name buf)))
        ;; Store agent buffer reference in TODO
        (org-roam-todo-wf-tools--set-property file "AGENT_BUFFER" buffer-name)
        ;; Send task to agent
        (org-roam-todo-wf-tools--send-task-to-agent buf todo)
        buffer-name)
    (user-error "claude-agent not available - cannot delegate")))

(defun org-roam-todo-wf-tools--send-task-to-agent (buffer todo)
  "Send TODO task to agent BUFFER."
  (let ((title (plist-get todo :title))
        (description (or (plist-get todo :description) ""))
        (worktree-path (plist-get todo :worktree-path)))
    (with-current-buffer buffer
      (let ((msg (format "[WORKTREE TASK]

## Task
%s

%s

## Worktree
%s

## Instructions
1. Implement the task
2. Stage your changes with `magit_stage`
3. Call `org-roam-todo-wf-tools-submit` with a commit message when ready

The workflow will handle pushing and PR creation automatically."
                         title description worktree-path)))
        (when (boundp 'claude-agent--message-queue)
          (push msg claude-agent--message-queue))))))

(defun org-roam-todo-wf-tools--set-property (file property value)
  "Set PROPERTY to VALUE in TODO FILE."
  (with-current-buffer (find-file-noselect file)
    (save-excursion
      (goto-char (point-min))
      (let ((prop-regex (format "^:%s:.*$" property)))
        (if (re-search-forward prop-regex nil t)
            (replace-match (format ":%s: %s" property value))
          ;; Add property after existing properties
          (when (re-search-forward "^:PROPERTIES:" nil t)
            (forward-line 1)
            (insert (format ":%s: %s\n" property value)))))
      (save-buffer))))

;;; ============================================================
;;; MCP Tool Registration
;;; ============================================================

;; Require the MCP registry for tool registration
;; Tools are registered at runtime only if claude-mcp-registry is available
(with-eval-after-load 'claude-mcp-registry
  (when (fboundp 'claude-mcp-deftool)
    (eval
     '(progn
        (claude-mcp-deftool todo-start
          "Start working on a TODO - advance from draft to active.
Creates a git worktree and sets up the branch for development.
TODO-ID can be a file path, title, or ID.  Defaults to current TODO."
          :function #'org-roam-todo-wf-tools-start
          :args ((todo-id string "Optional: TODO file path, title, or ID")))

        (claude-mcp-deftool todo-stage-changes
          "Commit staged changes according to workflow's commit strategy.
You must explicitly stage changes first (via `git add` or `magit_stage`).
Errors if there are unstaged changes - stage them, add to .gitignore,
or exclude with `git update-index --assume-unchanged`.
Commit strategies:
- :single-commit (default): Creates one commit, amends if branch has commits
- :many-commit: Creates a new commit for each stage call
- :managed-commit: Validates only - agent must commit manually
All automated commits use --no-gpg-sign."
          :function #'org-roam-todo-wf-tools-stage
          :args ((description string :required "Description of all changes made")
                 (todo-id string "Optional: TODO file path, title, or ID")))

        (claude-mcp-deftool todo-advance
          "Advance TODO to the next status in workflow.
Moves the TODO forward through its workflow stages.
Respects workflow validation hooks."
          :function #'org-roam-todo-wf-tools-advance
          :args ((todo-id string "Optional: TODO file path, title, or ID")))

        (claude-mcp-deftool todo-regress
          "Regress TODO to previous status (if workflow allows).
Moves the TODO back one stage.
Only works if the workflow allows regression from the current status."
          :function #'org-roam-todo-wf-tools-regress
          :args ((todo-id string "Optional: TODO file path, title, or ID")))

        (claude-mcp-deftool todo-reject
          "Reject/abandon a TODO.  Move to rejected status.
Use this when a TODO should be abandoned without completion.
Records the rejection reason in the TODO progress log."
          :function #'org-roam-todo-wf-tools-reject
          :args ((reason string :required "Explanation for rejection")
                 (todo-id string "Optional: TODO file path, title, or ID")))

        (claude-mcp-deftool todo-delegate
          "Delegate a TODO to a Claude agent.
Spawns an agent in the worktree to work on the TODO autonomously.
The TODO must be in active status with a worktree created.
The agent can call todo-advance when done."
          :function #'org-roam-todo-wf-tools-delegate
          :args ((todo-id string "Optional: TODO file path, title, or ID")))))))

(provide 'org-roam-todo-wf-tools)
;;; org-roam-todo-wf-tools.el ends here
