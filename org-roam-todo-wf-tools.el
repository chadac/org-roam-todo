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
(declare-function org-roam-todo-mcp-add-progress "org-roam-todo-core" (message &optional todo-id))

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


(defun org-roam-todo-wf-tools-create (title project-root &optional description acceptance-criteria model)
  "Create a new TODO programmatically.
TITLE is the TODO title (required).
PROJECT-ROOT is the path to the project (required).
DESCRIPTION is an optional task description.
ACCEPTANCE-CRITERIA is an optional list of criteria strings.
MODEL is the Claude model to use for the worktree agent (default: opus).

Returns the path to the created TODO file."
  (require 'org-roam-todo-core)
  (unless title (user-error "title is required"))
  (unless project-root (user-error "project_root is required"))
  
  (let* ((resolved-root (org-roam-todo-resolve-project-root
                         (expand-file-name project-root)))
         (project-name (org-roam-todo-project-name resolved-root))
         (project-dir (expand-file-name (concat "projects/" project-name) org-roam-directory))
         (id-timestamp (format "%s%04x" (format-time-string "%Y%m%dT%H%M%S") (random 65536)))
         (date-stamp (format-time-string "%Y-%m-%d"))
         (slug (org-roam-todo-slugify title))
         (file-path (expand-file-name (format "todo-%s.org" slug) project-dir))
         (model-str (or model "opus"))
         (description-text (or description ""))
         (criteria-text (if acceptance-criteria
                            (mapconcat (lambda (c) (format "- [ ] %s" c))
                                       (if (listp acceptance-criteria)
                                           acceptance-criteria
                                         (list acceptance-criteria))
                                       "\n")
                          "- [ ]")))
    
    ;; Ensure project directory exists
    (unless (file-directory-p project-dir)
      (make-directory project-dir t))
    
    ;; Check if file already exists
    (when (file-exists-p file-path)
      (user-error "A TODO with slug '%s' already exists: %s" slug file-path))
    
    ;; Create the TODO file
    (with-temp-file file-path
      (insert (format ":PROPERTIES:
:ID: %s
:PROJECT_NAME: %s
:PROJECT_ROOT: %s
:STATUS: draft
:WORKTREE_MODEL: %s
:CREATED: %s
:END:
#+title: %s
#+filetags: :todo:%s:

** Task Description

%s

** Acceptance Criteria
%s

** Progress Log

"
                      id-timestamp
                      project-name
                      resolved-root
                      model-str
                      date-stamp
                      title
                      project-name
                      description-text
                      criteria-text)))
    
    ;; Sync with org-roam if available
    (when (fboundp 'org-roam-db-update-file)
      (org-roam-db-update-file file-path))
    
    (format "Created TODO: %s\nFile: %s\nProject: %s\nStatus: draft"
            title file-path project-name)))

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
;;; Agent State Tracking
;;; ============================================================

(defvar-local org-roam-todo-wf-tools--agent-waiting nil
  "When non-nil, the agent is waiting for user input.
Contains a plist with :reason and :since keys.")

(defvar-local org-roam-todo-wf-tools--todo-file nil
  "The TODO file associated with this agent buffer.")

(defun org-roam-todo-wf-tools--get-agent-waiting-state (worktree-path)
  "Get the waiting state for the agent in WORKTREE-PATH.
Returns nil if no agent or not waiting, otherwise the waiting plist."
  (let ((expanded-path (file-name-as-directory (expand-file-name worktree-path))))
    (cl-loop for buffer in (buffer-list)
             for name = (buffer-name buffer)
             when (string-match-p "^\\*claude:" name)
             do (with-current-buffer buffer
                  (let ((buf-dir (file-name-as-directory
                                  (expand-file-name default-directory))))
                    (when (string= buf-dir expanded-path)
                      (cl-return org-roam-todo-wf-tools--agent-waiting)))))))

;;; ============================================================
;;; Agent Wait-for-User Tool
;;; ============================================================

(defun org-roam-todo-wf-tools-wait-for-user (reason)
  "Signal that the agent is waiting for user input.
REASON explains what the agent is waiting for.
This sets a waiting state that:
1. Shows in the TODO status UI
2. Prevents auto-advance prompts
3. Notifies the user that input is needed

The waiting state is cleared when:
- The user sends a message to the agent
- The agent calls todo-advance or todo-reject
- The agent explicitly clears it by calling this with empty reason"
  (if (or (null reason) (string-empty-p reason))
      ;; Clear waiting state
      (progn
        (setq org-roam-todo-wf-tools--agent-waiting nil)
        "Waiting state cleared. Resuming normal operation.")
    ;; Set waiting state
    (setq org-roam-todo-wf-tools--agent-waiting
          (list :reason reason
                :since (current-time)))
    ;; Update TODO property if we know which TODO this is
    (when org-roam-todo-wf-tools--todo-file
      (org-roam-todo-wf-tools--set-property 
       org-roam-todo-wf-tools--todo-file
       "AGENT_WAITING" reason))
    ;; Request user attention
    (when (fboundp 'claude-mcp-request-attention)
      (claude-mcp-request-attention 
       (format "Agent waiting: %s" reason)
       'normal))
    (format "Waiting for user input: %s\n\nThe user has been notified. You will receive a message when they respond." reason)))

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
             (allowed-tools (org-roam-todo-effective-agent-allowed-tools))
             (buf (claude-agent-run worktree-path nil nil nil model allowed-tools))
             (buffer-name (buffer-name buf)))
        ;; Store agent buffer reference in TODO
        (org-roam-todo-wf-tools--set-property file "AGENT_BUFFER" buffer-name)
        ;; Set up agent hooks and state
        (with-current-buffer buf
          (setq org-roam-todo-wf-tools--todo-file file)
          ;; Add hook to clear waiting state when user sends message
          (add-hook 'claude-agent-before-send-message-hook
                    #'org-roam-todo-wf-tools--on-user-message nil t)
          ;; Add hook to prompt for advance when agent becomes ready
          (add-hook 'claude-agent-ready-hook
                    #'org-roam-todo-wf-tools--on-agent-ready nil t))
        ;; Send task to agent
        (org-roam-todo-wf-tools--send-task-to-agent buf todo)
        buffer-name)
    (user-error "claude-agent not available - cannot delegate")))

(defun org-roam-todo-wf-tools--on-user-message ()
  "Hook called when user sends a message to the agent.
Clears the waiting state since user has responded."
  (when org-roam-todo-wf-tools--agent-waiting
    (setq org-roam-todo-wf-tools--agent-waiting nil)
    ;; Clear the TODO property
    (when org-roam-todo-wf-tools--todo-file
      (org-roam-todo-wf-tools--set-property
       org-roam-todo-wf-tools--todo-file
       "AGENT_WAITING" ""))))

(defvar org-roam-todo-wf-tools--ready-prompt-delay 2.0
  "Seconds to wait after agent becomes ready before prompting.
This avoids prompting during brief pauses in multi-step operations.")

(defvar-local org-roam-todo-wf-tools--ready-timer nil
  "Timer for delayed ready-state prompting.")

(defun org-roam-todo-wf-tools--on-agent-ready (buffer)
  "Hook called when agent becomes ready (idle).
BUFFER is the agent buffer.
After a delay, prompts the agent to advance the TODO if appropriate."
  (with-current-buffer buffer
    ;; Cancel any existing timer
    (when org-roam-todo-wf-tools--ready-timer
      (cancel-timer org-roam-todo-wf-tools--ready-timer))
    ;; Don't prompt if agent is waiting for user
    (unless org-roam-todo-wf-tools--agent-waiting
      ;; Set up delayed prompt
      (setq org-roam-todo-wf-tools--ready-timer
            (run-with-timer
             org-roam-todo-wf-tools--ready-prompt-delay nil
             #'org-roam-todo-wf-tools--maybe-prompt-advance
             buffer)))))

(defun org-roam-todo-wf-tools--maybe-prompt-advance (buffer)
  "Prompt agent in BUFFER to consider advancing the TODO.
Only prompts if agent is still ready and not waiting for user."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (setq org-roam-todo-wf-tools--ready-timer nil)
      ;; Check conditions for prompting
      (when (and org-roam-todo-wf-tools--todo-file
                 (not org-roam-todo-wf-tools--agent-waiting)
                 ;; Check agent is still ready
                 (boundp 'claude-agent--thinking-status)
                 (not claude-agent--thinking-status))
        ;; Send system message reminder
        (when (fboundp 'claude-agent--send-system-message)
          (claude-agent--send-system-message
           "WORKFLOW REMINDER: If you have completed the task, please call `mcp__emacs__todo_advance` to advance the TODO to the next workflow status. If you need user input to continue, call `mcp__emacs__todo_wait_for_user` with a description of what you need."))))))

(defun org-roam-todo-wf-tools--send-task-to-agent (buffer todo)
  "Send TODO task to agent BUFFER."
  (let* ((title (plist-get todo :title))
         (file (plist-get todo :file))
         (worktree-path (plist-get todo :worktree-path))
         ;; Read full task description from the TODO file
         (task-content (org-roam-todo-wf-tools--read-todo-content file)))
    (with-current-buffer buffer
      (let ((msg (format "I'm delegating the following task to you:

* %s

TODO file: %s

%s

** Workflow Tools

You have access to =mcp__emacs__todo_*= tools for managing this task:

- =mcp__emacs__todo_advance= - Advance the TODO to the next workflow status
- =mcp__emacs__todo_reject= - If the task cannot be completed, reject it with a reason

Please review the task and acceptance criteria, then begin working on it."
                         title file task-content)))
        (when (boundp 'claude-agent--message-queue)
          (push msg claude-agent--message-queue))))))

(defun org-roam-todo-wf-tools--read-todo-content (file)
  "Read the task description and acceptance criteria from TODO FILE."
  (when (and file (file-exists-p file))
    (with-temp-buffer
      (insert-file-contents file)
      (let ((content (buffer-string))
            (sections '()))
        ;; Extract Task Description section
        (when (string-match "\\*\\* Task Description\\s-*\n\\(\\(?:.*\n\\)*?\\)\\(?:\\*\\* \\|\\'" content)
          (push (format "** Task Description\n\n%s" 
                        (string-trim (match-string 1 content)))
                sections))
        ;; Extract Acceptance Criteria section
        (when (string-match "\\*\\* Acceptance Criteria\\s-*\n\\(\\(?:.*\n\\)*?\\)\\(?:\\*\\* \\|\\'" content)
          (push (format "** Acceptance Criteria\n%s"
                        (string-trim (match-string 1 content)))
                sections))
        (string-join (nreverse sections) "\n\n")))))

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
;;; PR Feedback Functions
;;; ============================================================

(declare-function org-roam-todo-wf-pr-feedback-fetch "org-roam-todo-wf-pr-feedback")
(declare-function org-roam-todo-wf-pr-feedback-summary "org-roam-todo-wf-pr-feedback")
(declare-function org-roam-todo-wf-pr-feedback-invalidate-cache "org-roam-todo-wf-pr-feedback")

(defun org-roam-todo-wf-tools-pr-feedback (&optional todo-id force-refresh)
  "Get PR feedback summary for TODO-ID.
If FORCE-REFRESH is non-nil, invalidate cache first.
Returns a structured summary of CI checks, reviews, and comments."
  (let* ((todo (org-roam-todo-wf-tools--get-todo todo-id))
         (worktree-path (and todo (plist-get todo :worktree-path))))
    (unless todo
      (user-error "TODO not found: %s" (or todo-id "current directory")))
    (unless worktree-path
      (user-error "TODO has no worktree"))
    (unless (file-directory-p worktree-path)
      (user-error "Worktree directory not found: %s" worktree-path))
    
    (require 'org-roam-todo-wf-pr-feedback)
    
    ;; Invalidate cache if requested
    (when force-refresh
      (org-roam-todo-wf-pr-feedback-invalidate-cache worktree-path))
    
    ;; Fetch feedback and generate summary
    (let* ((feedback (org-roam-todo-wf-pr-feedback-fetch worktree-path))
           (summary (and feedback (org-roam-todo-wf-pr-feedback-summary feedback))))
      (if feedback
          (format "PR Feedback for %s:

PR: %s #%d (%s)
URL: %s

CI Status: %s
  - Failed: %d
  - Pending: %d
  - Passed: %d
  - Total: %d

Reviews: %s
  - Review count: %d

Comments:
  - Total comments: %d
  - Unresolved: %d

%s"
                  (plist-get todo :title)
                  (if (eq (plist-get feedback :forge) :gitlab) "MR" "PR")
                  (plist-get feedback :pr-number)
                  (plist-get feedback :pr-state)
                  (or (plist-get feedback :pr-url) "N/A")
                  (plist-get summary :ci-status)
                  (plist-get summary :ci-failed-count)
                  (plist-get summary :ci-pending-count)
                  (plist-get summary :ci-success-count)
                  (plist-get summary :ci-total-count)
                  (plist-get summary :review-state)
                  (plist-get summary :review-count)
                  (plist-get summary :comment-count)
                  (plist-get summary :unresolved-count)
                  (if (> (plist-get summary :ci-failed-count) 0)
                      "Use todo-pr-ci-logs to view failed CI check details."
                    ""))
        "No PR/MR found for this branch."))))

(defun org-roam-todo-wf-tools-pr-comments (&optional todo-id include-resolved)
  "Get PR comments for TODO-ID.
If INCLUDE-RESOLVED is non-nil, include resolved comments too.
Returns formatted list of comments with file locations."
  (let* ((todo (org-roam-todo-wf-tools--get-todo todo-id))
         (worktree-path (and todo (plist-get todo :worktree-path))))
    (unless todo
      (user-error "TODO not found: %s" (or todo-id "current directory")))
    (unless worktree-path
      (user-error "TODO has no worktree"))
    
    (require 'org-roam-todo-wf-pr-feedback)
    
    (let* ((feedback (org-roam-todo-wf-pr-feedback-fetch worktree-path))
           (review-comments (or (plist-get feedback :review-comments)
                                (plist-get feedback :discussions)))
           (comments (plist-get feedback :comments))
           (all-comments (append review-comments comments))
           (filtered (if include-resolved
                         all-comments
                       (cl-remove-if (lambda (c) (eq (plist-get c :state) 'resolved))
                                     all-comments)))
           (result '()))
      (if (null filtered)
          "No comments found."
        (dolist (comment filtered)
          (let* ((author (plist-get comment :author))
                 (body (plist-get comment :body))
                 (path (plist-get comment :path))
                 (line (plist-get comment :line))
                 (state (plist-get comment :state))
                 (location (if path
                               (format "%s%s" path (if line (format ":%d" line) ""))
                             "general")))
            (push (format "--- %s [%s] at %s ---\n%s\n"
                          author
                          (or state "comment")
                          location
                          (or body "(no body)"))
                  result)))
        (mapconcat #'identity (nreverse result) "\n")))))

(defun org-roam-todo-wf-tools-pr-ci-logs (&optional todo-id check-name)
  "Get CI check details for TODO-ID.
If CHECK-NAME is provided, return logs for that specific check.
Otherwise, return summary of all failed checks with log tails."
  (let* ((todo (org-roam-todo-wf-tools--get-todo todo-id))
         (worktree-path (and todo (plist-get todo :worktree-path))))
    (unless todo
      (user-error "TODO not found: %s" (or todo-id "current directory")))
    (unless worktree-path
      (user-error "TODO has no worktree"))
    
    (require 'org-roam-todo-wf-pr-feedback)
    
    (let* ((feedback (org-roam-todo-wf-pr-feedback-fetch worktree-path))
           (ci-checks (plist-get feedback :ci-checks))
           (failed-checks (cl-remove-if-not 
                           (lambda (c) (eq (plist-get c :status) 'failure))
                           ci-checks)))
      (cond
       ;; Specific check requested
       (check-name
        (let ((check (cl-find check-name ci-checks 
                              :key (lambda (c) (plist-get c :name))
                              :test #'string=)))
          (if check
              (format "=== CI Check: %s ===
Status: %s
URL: %s

Log tail:
%s"
                      (plist-get check :name)
                      (plist-get check :status)
                      (or (plist-get check :url) "N/A")
                      (or (plist-get check :log-tail) "(no logs available)"))
            (format "Check '%s' not found. Available checks: %s"
                    check-name
                    (mapconcat (lambda (c) (plist-get c :name)) ci-checks ", ")))))
       ;; No failed checks
       ((null failed-checks)
        (format "No failed CI checks. Total checks: %d, all passing or pending."
                (length ci-checks)))
       ;; Show all failed checks
       (t
        (let ((result '()))
          (dolist (check failed-checks)
            (push (format "=== %s (FAILED) ===
URL: %s

Log tail:
%s
"
                          (plist-get check :name)
                          (or (plist-get check :url) "N/A")
                          (or (plist-get check :log-tail) "(no logs available)"))
                  result))
          (concat (format "Found %d failed CI checks:\n\n" (length failed-checks))
                  (mapconcat #'identity (nreverse result) "\n"))))))))

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

        (claude-mcp-deftool todo-create
          "Create a new TODO for a project programmatically.
Creates a TODO file in the org-roam projects directory with the specified
title, description, and acceptance criteria. The TODO starts in 'draft' status.

Use this when you need to:
- Create a TODO for a task you've identified
- Break down a larger task into sub-TODOs
- Document work that needs to be done

After creating, use todo-start to begin working on it (creates worktree)."
          :function #'org-roam-todo-wf-tools-create
          :safe t
          :args ((title string :required "Title for the TODO")
                 (project-root string :required "Path to the project root directory")
                 (description string "Task description explaining what needs to be done")
                 (acceptance-criteria array "List of acceptance criteria strings")
                 (model string "Claude model for worktree agent: opus, sonnet (default: opus)")))

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
                 (timeout integer "Maximum seconds to wait (default: 3600)")))

        (claude-mcp-deftool todo-wait-for-user
          "Signal that you are waiting for user input before continuing.
Call this when you need clarification, approval, or other input from the user.

This tool:
1. Shows a 'waiting for user' indicator in the TODO status UI
2. Notifies the user that you need their attention
3. Prevents workflow reminder prompts while waiting

The waiting state is automatically cleared when:
- The user sends you a message
- You call todo-advance or todo-reject

To explicitly clear the waiting state, call with an empty reason."
          :function #'org-roam-todo-wf-tools-wait-for-user
          :safe t
          :needs-session-cwd t
          :args ((reason string :required "What you are waiting for from the user")))

        ;; PR Feedback tools
        (claude-mcp-deftool todo-pr-feedback
          "Get PR/MR feedback summary for the current TODO.
Returns a summary of CI checks, reviews, and comments for the PR/MR
associated with this TODO's worktree branch.

Supports both GitHub (gh CLI) and GitLab (glab CLI).

Use this to:
- Check CI status before advancing
- See if there are pending reviews
- Get an overview of feedback on your PR"
          :function #'org-roam-todo-wf-tools-pr-feedback
          :safe t
          :needs-session-cwd t
          :args ((todo-id string "Optional: TODO file path, title, or ID")
                 (force-refresh boolean "If true, bypass cache and fetch fresh data")))

        (claude-mcp-deftool todo-pr-comments
          "Get PR/MR comments for the current TODO.
Returns a formatted list of review comments and discussions with:
- Author name
- File path and line number (for inline comments)
- Comment body
- Resolution status

By default only shows unresolved comments. Set include-resolved to true
to see all comments."
          :function #'org-roam-todo-wf-tools-pr-comments
          :safe t
          :needs-session-cwd t
          :args ((todo-id string "Optional: TODO file path, title, or ID")
                 (include-resolved boolean "If true, include resolved comments")))

        (claude-mcp-deftool todo-pr-ci-logs
          "Get CI check logs for the current TODO.
If check-name is provided, returns logs for that specific check.
Otherwise, returns log tails for all failed checks.

Use this to:
- Diagnose CI failures
- Understand what went wrong in a build
- Get error messages and stack traces from failed tests"
          :function #'org-roam-todo-wf-tools-pr-ci-logs
          :safe t
          :needs-session-cwd t
          :args ((todo-id string "Optional: TODO file path, title, or ID")
                 (check-name string "Optional: specific check name to view logs for")))

        (claude-mcp-deftool todo-add-progress
          "Add an entry to the TODO's progress log.
Use this to document progress, decisions, or important events during task work.
Entries are timestamped automatically.

Examples of good progress entries:
- \"Identified root cause: missing null check in parser\"
- \"Implemented first draft of feature, needs testing\"
- \"Blocked: waiting for API documentation\"
- \"Fixed failing tests, all green now\""
          :function #'org-roam-todo-mcp-add-progress
          :safe t
          :args ((message string :required "Progress message to log")
                 (todo-id string "Optional: TODO file path, title, or ID (defaults to current)")))))))

(provide 'org-roam-todo-wf-tools)
;;; org-roam-todo-wf-tools.el ends here
