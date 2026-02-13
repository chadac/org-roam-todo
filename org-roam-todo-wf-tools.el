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

;;; NOTE: Review functionality has been moved to org-roam-todo-status.el
;;; The review flow now uses the status buffer directly:
;;; - "Awaiting Review" notice shows when NEEDS_REVIEW is set
;;; - v a: approve and advance
;;; - v r: reject and regress  
;;; - a (advance): auto-approves if review is pending

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
;;; Async Status Watching
;;; ============================================================

(defvar org-roam-todo-wf-tools--watch-tasks (make-hash-table :test 'equal)
  "Hash table tracking active watch tasks.
Key: task-id, Value: plist with :todo-id :start-time :iteration :timer")

(defun org-roam-todo-wf-tools--watch-poll (task-id)
  "Poll TODO status for TASK-ID and apply auto-upgrade if ready.
This function is called periodically by a timer."
  (let* ((state (gethash task-id org-roam-todo-wf-tools--watch-tasks))
         (todo-id (plist-get state :todo-id))
         (start-time (plist-get state :start-time))
         (timeout-secs (plist-get state :timeout))
         (iteration (1+ (or (plist-get state :iteration) 0)))
         (elapsed (- (float-time) start-time)))

    ;; Update iteration count
    (plist-put state :iteration iteration)

    ;; Check timeout
    (when (> elapsed timeout-secs)
      (when (plist-get state :timer)
        (cancel-timer (plist-get state :timer)))
      (remhash task-id org-roam-todo-wf-tools--watch-tasks)
      (claude-mcp-async-complete task-id
                                 (format "Watch timeout after %d seconds. TODO did not auto-upgrade."
                                         timeout-secs))
      (cl-return-from org-roam-todo-wf-tools--watch-poll))

    ;; Try to resolve the TODO
    (condition-case err
        (let ((todo (org-roam-todo-wf-tools--get-todo todo-id)))
          (unless todo
            (when (plist-get state :timer)
              (cancel-timer (plist-get state :timer)))
            (remhash task-id org-roam-todo-wf-tools--watch-tasks)
            (claude-mcp-async-error task-id
                                    (format "TODO not found: %s" todo-id))
            (cl-return-from org-roam-todo-wf-tools--watch-poll))

          (let* ((todo-file (plist-get todo :file))
                 (current-status (plist-get todo :status))
                 (initial-status (plist-get state :initial-status)))

            ;; Check if status changed (someone manually changed it, or auto-upgrade happened)
            (when (not (string= current-status initial-status))
              (when (plist-get state :timer)
                (cancel-timer (plist-get state :timer)))
              (remhash task-id org-roam-todo-wf-tools--watch-tasks)
              (claude-mcp-async-complete 
               task-id
               (format "TODO status changed: %s -> %s\nElapsed: %.0fs"
                       initial-status current-status elapsed))
              (cl-return-from org-roam-todo-wf-tools--watch-poll))

            ;; Check if auto-upgrade is ready
            (let* ((check-result (org-roam-todo-wf-check-auto-upgrade todo-file current-status))
                   (result-state (plist-get check-result :state)))
              (if (plist-get check-result :can-upgrade)
                  ;; Apply the upgrade
                  (let ((apply-result (org-roam-todo-wf-apply-auto-upgrade todo-file)))
                    (when (plist-get state :timer)
                      (cancel-timer (plist-get state :timer)))
                    (remhash task-id org-roam-todo-wf-tools--watch-tasks)
                    (if (plist-get apply-result :applied)
                        (claude-mcp-async-complete 
                         task-id
                         (format "Auto-upgrade applied: %s -> %s\n\nAction: %s\nState: %s\nElapsed: %.0fs\n\n%s"
                                 current-status
                                 (plist-get check-result :target-status)
                                 (plist-get check-result :action)
                                 (plist-get check-result :state)
                                 elapsed
                                 (or (plist-get check-result :message) "")))
                      (claude-mcp-async-error 
                       task-id
                       (format "Auto-upgrade check succeeded but apply failed: %s"
                               (or (plist-get apply-result :message) "unknown error")))))
                ;; Check for terminal states that should stop polling
                (cond
                 ;; Failed validation with no on-fail configured - terminal state
                 ((and (eq result-state :fail)
                       (not (plist-get check-result :can-upgrade)))
                  (when (plist-get state :timer)
                    (cancel-timer (plist-get state :timer)))
                  (remhash task-id org-roam-todo-wf-tools--watch-tasks)
                  (claude-mcp-async-complete
                   task-id
                   (format "Validation failed (no auto-downgrade configured)\n\nState: %s\nElapsed: %.0fs\n\n%s"
                           result-state
                           elapsed
                           (or (plist-get check-result :message) ""))))
                 ;; Feedback required - terminal state
                 ((eq result-state :feedback)
                  (when (plist-get state :timer)
                    (cancel-timer (plist-get state :timer)))
                  (remhash task-id org-roam-todo-wf-tools--watch-tasks)
                  (claude-mcp-async-complete
                   task-id
                   (format "User feedback required\n\nState: %s\nElapsed: %.0fs\n\n%s"
                           result-state
                           elapsed
                           (or (plist-get check-result :message) ""))))
                 ;; Still pending - continue polling
                 (t
                  (message "[%d] TODO watch: status=%s state=%s (%.0fs elapsed)"
                           iteration current-status result-state elapsed)))))))
      (error
       (when (plist-get state :timer)
         (cancel-timer (plist-get state :timer)))
       (remhash task-id org-roam-todo-wf-tools--watch-tasks)
       (claude-mcp-async-error task-id
                               (format "Error checking TODO status: %s"
                                       (error-message-string err)))))))

(defun org-roam-todo-wf-tools--watch-status (task-id server-port todo-id 
                                                     &optional poll-interval timeout)
  "Watch TODO-ID's status until auto-upgrade completes or times out (async).
TASK-ID and SERVER-PORT are provided by the MCP async framework.
POLL-INTERVAL defaults to 30 seconds.
TIMEOUT defaults to 3600 seconds (1 hour).

Returns :async-started immediately and polls in the background."
  (let* ((todo (org-roam-todo-wf-tools--get-todo todo-id))
         (timeout-secs (or timeout 3600))
         (poll-secs (or poll-interval 30)))
    
    (unless todo
      (claude-mcp-async-error task-id (format "TODO not found: %s" todo-id))
      (cl-return-from org-roam-todo-wf-tools--watch-status :async-started))

    (let* ((current-status (plist-get todo :status))
           (state (list :todo-id todo-id
                       :initial-status current-status
                       :start-time (float-time)
                       :timeout timeout-secs
                       :poll-interval poll-secs
                       :iteration 0
                       :timer nil)))

      ;; Store state
      (puthash task-id state org-roam-todo-wf-tools--watch-tasks)

      ;; Set up timer for polling (starts with immediate poll at 0.1s)
      (let ((timer (run-with-timer 0.1 poll-secs
                                   (lambda () (org-roam-todo-wf-tools--watch-poll task-id)))))
        (plist-put state :timer timer)

        ;; Register with MCP framework
        (claude-mcp-async-register task-id
                                   :port server-port
                                   :timer timer
                                   :timeout timeout-secs))

      ;; Return immediately - result will come via claude-mcp-async-complete
      :async-started)))

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

        (claude-mcp-deftool todo-advance
          "Advance TODO to the next status in workflow.
Moves the TODO forward through its workflow stages.
Respects workflow validation hooks."
          :function #'org-roam-todo-wf-tools-advance
          :safe t
          :args ((todo-id string "Optional: TODO file path, title, or ID")))

        (claude-mcp-deftool todo-regress
          "Regress TODO to previous status (if workflow allows).
Moves the TODO back one stage.
Only works if the workflow allows regression from the current status."
          :function #'org-roam-todo-wf-tools-regress
          :safe t
          :args ((todo-id string "Optional: TODO file path, title, or ID")))

        (claude-mcp-deftool todo-reject
          "Reject/abandon a TODO.  Move to rejected status.
Use this when a TODO should be abandoned without completion.
Records the rejection reason in the TODO progress log."
          :function #'org-roam-todo-wf-tools-reject
          :safe t
          :args ((reason string :required "Explanation for rejection")
                 (todo-id string "Optional: TODO file path, title, or ID")))

        (claude-mcp-deftool todo-delegate
          "Delegate a TODO to a Claude agent.
Spawns an agent in the worktree to work on the TODO autonomously.
The TODO must be in active status with a worktree created.
The agent can call todo-advance when done."
          :function #'org-roam-todo-wf-tools-delegate
          :args ((todo-id string "Optional: TODO file path, title, or ID")))


        (claude-mcp-deftool todo-watch-status
          "Watch a TODO's status until auto-upgrade completes or times out.
Polls validations and applies auto-upgrade when ready.
Returns when the TODO advances/regresses or timeout is reached.

This is useful for monitoring async validations like CI checks.
The tool will automatically apply transitions when validation state changes."
          :async t
          :timeout 3600
          :function #'org-roam-todo-wf-tools--watch-status
          :safe t
          :args ((todo-id string :required "TODO file path, title, or ID")
                 (poll-interval integer "Seconds between checks (default: 30)")
                 (timeout integer "Maximum seconds to wait (default: 3600)")))))))

(provide 'org-roam-todo-wf-tools)
;;; org-roam-todo-wf-tools.el ends here
