;;; org-roam-todo-list.el --- Flat TODO list using magit-section -*- lexical-binding: t; -*-

;; Author: Claude Code
;; Version: 0.1.0
;; Package-Requires: ((emacs "28.1") (org-roam "2.0") (magit-section "3.0"))

;;; Commentary:
;; Provides a flat TODO list display using magit-section.
;; Features:
;; - Flat list sorted by status (workflow order)
;; - Clear columns: status | project | title | agent | wt
;; - Subtask display with tree characters (collapsible)
;; - Status change commands
;; - Worktree navigation

;;; Code:

(require 'cl-lib)
(require 'magit-section)
(require 'org-roam-todo-theme)
(require 'org-roam-todo-core)

;; Forward declarations for workflow module (loaded on demand)
(declare-function org-roam-todo-wf--change-status "org-roam-todo-wf")
(declare-function org-roam-todo-wf--next-statuses "org-roam-todo-wf")
(declare-function org-roam-todo-wf--get-workflow "org-roam-todo-wf")
(declare-function org-roam-todo-workflow-statuses "org-roam-todo-wf")

;; Forward declarations for claude-agent integration
(declare-function claude-agent-run "claude-agent-repl")
(defvar claude-agent--session-info)

;; Declare claude-sessions faces (defined in claude-sessions.el)
(defvar claude-sessions-status-ready)
(defvar claude-sessions-status-thinking)
(defvar claude-sessions-status-waiting)

;;; ============================================================
;;; Customization
;;; ============================================================

(defgroup org-roam-todo-list nil
  "Flat TODO list display."
  :group 'org-roam-todo)

(defcustom org-roam-todo-list-show-subtasks t
  "Whether to show subtasks under each TODO."
  :type 'boolean
  :group 'org-roam-todo-list)

(defcustom org-roam-todo-list-column-widths
  '((status . 10)
    (project . 20)
    (title . 45)
    (worktree . 4)
    (agent . 8))
  "Alist of column widths for TODO display.
Columns are: status, project, title, wt (worktree), agent."
  :type '(alist :key-type symbol :value-type integer)
  :group 'org-roam-todo-list)

(defcustom org-roam-todo-list-refresh-interval 5
  "Seconds between auto-refresh of agent status.
Set to nil to disable auto-refresh."
  :type '(choice integer (const :tag "Disabled" nil))
  :group 'org-roam-todo-list)

;;; ============================================================
;;; Auto-Refresh Timer
;;; ============================================================

(defvar-local org-roam-todo-list--refresh-timer nil
  "Timer for auto-refreshing agent status.")

(defun org-roam-todo-list--start-auto-refresh ()
  "Start the auto-refresh timer for agent status."
  (when (and org-roam-todo-list-refresh-interval
             (null org-roam-todo-list--refresh-timer))
    (setq org-roam-todo-list--refresh-timer
          (run-with-timer org-roam-todo-list-refresh-interval
                          org-roam-todo-list-refresh-interval
                          #'org-roam-todo-list--maybe-refresh
                          (current-buffer)))))

(defun org-roam-todo-list--stop-auto-refresh ()
  "Stop the auto-refresh timer."
  (when org-roam-todo-list--refresh-timer
    (cancel-timer org-roam-todo-list--refresh-timer)
    (setq org-roam-todo-list--refresh-timer nil)))

(defun org-roam-todo-list--maybe-refresh (buffer)
  "Refresh BUFFER if it's still live and visible."
  (when (and (buffer-live-p buffer)
             (get-buffer-window buffer t))
    (with-current-buffer buffer
      (org-roam-todo-list-refresh))))

;;; ============================================================
;;; Face Aliases (inheriting from org-roam-todo-theme)
;;; ============================================================

;; These faces inherit from the shared theme faces for consistency.
;; Customize via `org-roam-todo-theme' group for global changes,
;; or override these for list-specific styling.

(defface org-roam-todo-list-project-face
  '((t :inherit org-roam-todo-project))
  "Face for project names in TODO list."
  :group 'org-roam-todo-list)

(defface org-roam-todo-list-status-draft
  '((t :inherit org-roam-todo-status-draft))
  "Face for draft status in TODO list."
  :group 'org-roam-todo-list)

(defface org-roam-todo-list-status-active
  '((t :inherit org-roam-todo-status-active))
  "Face for active status in TODO list."
  :group 'org-roam-todo-list)

(defface org-roam-todo-list-status-review
  '((t :inherit org-roam-todo-status-review))
  "Face for review status in TODO list."
  :group 'org-roam-todo-list)

(defface org-roam-todo-list-status-done
  '((t :inherit org-roam-todo-status-done))
  "Face for done status in TODO list."
  :group 'org-roam-todo-list)

(defface org-roam-todo-list-status-rejected
  '((t :inherit org-roam-todo-status-rejected))
  "Face for rejected status in TODO list."
  :group 'org-roam-todo-list)

(defface org-roam-todo-list-worktree-active
  '((t :inherit org-roam-todo-worktree-active))
  "Face for active worktree indicator in TODO list."
  :group 'org-roam-todo-list)

(defface org-roam-todo-list-agent-running
  '((t :inherit org-roam-todo-agent-running))
  "Face for running agent indicator in TODO list."
  :group 'org-roam-todo-list)

(defface org-roam-todo-list-subtask-face
  '((t :inherit org-roam-todo-subtask))
  "Face for subtask text in TODO list."
  :group 'org-roam-todo-list)

(defface org-roam-todo-list-tree-face
  '((t :inherit org-roam-todo-tree))
  "Face for tree drawing characters in TODO list."
  :group 'org-roam-todo-list)

;;; ============================================================
;;; Section Classes
;;; ============================================================

(defclass org-roam-todo-list-root-section (magit-section)
  ((keymap :initform 'org-roam-todo-list-mode-map)))

(defclass org-roam-todo-list-todo-section (magit-section)
  ((keymap :initform 'org-roam-todo-list-todo-map)
   (todo :initform nil :initarg :todo)))

(defclass org-roam-todo-list-subtask-section (magit-section)
  ((keymap :initform 'org-roam-todo-list-subtask-map)
   (subtask :initform nil :initarg :subtask)
   (parent-todo :initform nil :initarg :parent-todo)))

;;; ============================================================
;;; Column Formatting
;;; ============================================================

(defun org-roam-todo-list--get-width (column)
  "Get width for COLUMN from `org-roam-todo-list-column-widths'."
  (or (alist-get column org-roam-todo-list-column-widths) 15))

(defun org-roam-todo-list--pad (str width &optional align)
  "Pad STR to WIDTH characters, ALIGNing left (default) or right."
  (let ((len (length str)))
    (if (>= len width)
        (substring str 0 width)
      (if (eq align 'right)
          (concat (make-string (- width len) ?\s) str)
        (concat str (make-string (- width len) ?\s))))))

(defun org-roam-todo-list--format-status (status)
  "Format STATUS with appropriate face.
Uses `org-roam-todo-theme-status-face' to support custom workflow statuses."
  (let ((face (org-roam-todo-theme-status-face status)))
    (propertize (org-roam-todo-list--pad status
                                          (org-roam-todo-list--get-width 'status))
                'face face
                'font-lock-face face)))

(defun org-roam-todo-list--format-project (project)
  "Format PROJECT name."
  (propertize (org-roam-todo-list--pad (or project "-")
                                        (org-roam-todo-list--get-width 'project))
              'face 'org-roam-todo-list-project-face
              'font-lock-face 'org-roam-todo-list-project-face))

(defun org-roam-todo-list--format-title (title)
  "Format TODO TITLE."
  (org-roam-todo-list--pad (or title "Untitled")
                            (org-roam-todo-list--get-width 'title)))

(defun org-roam-todo-list--format-worktree (todo)
  "Format worktree indicator for TODO.
Shows ✓ if worktree exists, ✗ if not (only for non-draft TODOs)."
  (let* ((worktree-path (plist-get todo :worktree-path))
         (status (plist-get todo :status))
         (has-worktree (and worktree-path (file-directory-p worktree-path)))
         ;; Only show indicator for TODOs that should have worktrees
         (should-have-wt (and (not (string= status "draft"))
                              (not (string= status "done"))
                              (not (string= status "rejected"))))
         (indicator (cond
                     (has-worktree "✓")
                     (should-have-wt "✗")
                     (t " ")))
         (face (cond
                (has-worktree 'org-roam-todo-list-worktree-active)
                (should-have-wt 'error)
                (t 'default))))
    (propertize (org-roam-todo-list--pad indicator
                                          (org-roam-todo-list--get-width 'worktree))
                'face face
                'font-lock-face face)))

(defun org-roam-todo-list--get-agent-status (worktree-path)
  "Get agent status info for WORKTREE-PATH.
Returns a status symbol: `ready', `thinking', `waiting', or nil if no agent.
Uses the same logic as `claude-sessions--get-session-status'."
  (let ((expanded-path (file-name-as-directory (expand-file-name worktree-path))))
    (cl-loop for buffer in (buffer-list)
             for name = (buffer-name buffer)
             when (string-match-p "^\\*claude:" name)
             do (with-current-buffer buffer
                  (let ((buf-dir (file-name-as-directory
                                  (expand-file-name default-directory))))
                    (when (string= buf-dir expanded-path)
                      ;; Found matching buffer, determine status
                      (cl-return
                       (cond
                        ;; Check if process is alive
                        ((not (and (boundp 'claude-agent--process)
                                   claude-agent--process
                                   (process-live-p claude-agent--process)))
                         nil)  ; Dead/no process = no agent
                        ;; Waiting for permission
                        ((and (boundp 'claude-agent--permission-data)
                              claude-agent--permission-data)
                         'waiting)
                        ;; Thinking/processing
                        ((and (boundp 'claude-agent--thinking-status)
                              claude-agent--thinking-status)
                         'thinking)
                        ;; Compacting
                        ((and (boundp 'claude-agent--compacting)
                              claude-agent--compacting)
                         'thinking)
                        ;; Ready
                        (t 'ready)))))))))

(defun org-roam-todo-list--format-agent (todo)
  "Format agent status indicator for TODO.
Shows status matching `*claude-sessions*': ready, thinking, waiting."
  (let* ((worktree-path (plist-get todo :worktree-path))
         (status (and worktree-path
                      (org-roam-todo-list--get-agent-status worktree-path)))
         (indicator (pcase status
                      ('ready "ready")
                      ('thinking "thinking")
                      ('waiting "waiting")
                      (_ "")))
         (face (pcase status
                 ('ready 'claude-sessions-status-ready)
                 ('thinking 'claude-sessions-status-thinking)
                 ('waiting 'claude-sessions-status-waiting)
                 (_ 'default))))
    (propertize (org-roam-todo-list--pad indicator
                                          (org-roam-todo-list--get-width 'agent))
                'face face
                'font-lock-face face)))

;;; ============================================================
;;; Status Sorting
;;; ============================================================

;; Function variables for dependency injection (used by mock/testing)
(defvar-local org-roam-todo-list--get-entries-fn nil
  "Override function for getting TODO entries.
When non-nil, called instead of `org-roam-todo-list--get-entries'.")

(defvar-local org-roam-todo-list--get-workflow-fn nil
  "Override function for getting workflow for a TODO.
When non-nil, called with TODO plist.")

(defvar-local org-roam-todo-list--project-filter nil
  "When non-nil, filter TODOs to only show this project.")

(defun org-roam-todo-list--call-get-entries ()
  "Get TODO entries, using override if set.
When `org-roam-todo-list--project-filter' is non-nil, filters results
to only include TODOs from that project."
  (let ((entries (if org-roam-todo-list--get-entries-fn
                     (funcall org-roam-todo-list--get-entries-fn)
                   (org-roam-todo-list--get-entries))))
    (if org-roam-todo-list--project-filter
        (cl-remove-if-not
         (lambda (todo)
           (string= (plist-get todo :project-name)
                    org-roam-todo-list--project-filter))
         entries)
      entries)))

(defun org-roam-todo-list--call-get-workflow (todo)
  "Get workflow for TODO, using override if set."
  (if org-roam-todo-list--get-workflow-fn
      (funcall org-roam-todo-list--get-workflow-fn todo)
    (org-roam-todo-wf--get-workflow todo)))

(defun org-roam-todo-list--collect-workflow-statuses (todos)
  "Collect all unique workflow statuses from TODOS in their defined order.
Returns a list of status strings where workflow-defined statuses come first
in their workflow order, followed by rejected at the end."
  (let ((seen (make-hash-table :test 'equal))
        (workflow-statuses '())
        (has-rejected nil))
    ;; Collect statuses from each TODO's workflow
    (dolist (todo todos)
      (when-let* ((workflow (ignore-errors
                              (org-roam-todo-list--call-get-workflow todo)))
                  (statuses (org-roam-todo-workflow-statuses workflow)))
        (dolist (status statuses)
          (unless (gethash status seen)
            (puthash status t seen)
            (if (string= status "rejected")
                (setq has-rejected t)
              (push status workflow-statuses))))))
    ;; Return in order (reverse because we pushed), with rejected last
    (let ((result (nreverse workflow-statuses)))
      (when has-rejected
        (setq result (append result '("rejected"))))
      result)))

(defun org-roam-todo-list--status-index (status status-order)
  "Get the sort index for STATUS within STATUS-ORDER.
Lower index means earlier in the list."
  (or (cl-position status status-order :test #'string=)
      ;; Unknown statuses sort at the end before rejected
      (1- (length status-order))))

(defun org-roam-todo-list--sort-todos (todos)
  "Sort TODOS by status using workflow-defined order.
Statuses are ordered according to their workflow definition.
The rejected status always sorts last."
  (let ((status-order (org-roam-todo-list--collect-workflow-statuses todos)))
    (sort (copy-sequence todos)
          (lambda (a b)
            (< (org-roam-todo-list--status-index (or (plist-get a :status) "draft") status-order)
               (org-roam-todo-list--status-index (or (plist-get b :status) "draft") status-order))))))

;;; ============================================================
;;; Section Insertion
;;; ============================================================

(defun org-roam-todo-list--insert-header ()
  "Insert column headers."
  (let ((header (concat
                 (org-roam-todo-list--pad "STATUS" (org-roam-todo-list--get-width 'status))
                 " "
                 (org-roam-todo-list--pad "PROJECT" (org-roam-todo-list--get-width 'project))
                 " "
                 (org-roam-todo-list--pad "TITLE" (org-roam-todo-list--get-width 'title))
                 " "
                 (org-roam-todo-list--pad "WT" (org-roam-todo-list--get-width 'worktree))
                 " "
                 (org-roam-todo-list--pad "AGENT" (org-roam-todo-list--get-width 'agent)))))
    (insert (propertize header 'face 'bold 'font-lock-face 'bold))
    (insert "\n")
    (insert (make-string (length header) ?─))
    (insert "\n")))

(defun org-roam-todo-list--insert-todo (todo)
  "Insert a TODO item as a section."
  (let ((title (plist-get todo :title))
        (status (plist-get todo :status))
        (project (plist-get todo :project-name))
        (subtasks (plist-get todo :subtasks))
        (has-subtasks (and org-roam-todo-list-show-subtasks
                           (plist-get todo :subtasks))))
    (magit-insert-section section (org-roam-todo-list-todo-section nil nil)
      (oset section todo todo)
      ;; Build the heading line: status | project | title | wt | agent
      (let ((heading (concat
                      (org-roam-todo-list--format-status status)
                      " "
                      (org-roam-todo-list--format-project project)
                      " "
                      (org-roam-todo-list--format-title title)
                      " "
                      (org-roam-todo-list--format-worktree todo)
                      " "
                      (org-roam-todo-list--format-agent todo))))
        (if has-subtasks
            ;; Use heading for collapsible TODOs with subtasks
            (magit-insert-heading heading)
          ;; Just insert text for TODOs without subtasks
          (insert heading "\n")))
      ;; Insert subtasks in section body (makes them collapsible)
      (when has-subtasks
        (magit-insert-section-body
          (org-roam-todo-list--insert-subtasks todo subtasks 0))))))


(defun org-roam-todo-list--insert-subtasks (todo subtasks depth &optional parent-prefix)
  "Insert SUBTASKS for TODO with tree characters.
DEPTH is the nesting level (0 for top-level subtasks).
PARENT-PREFIX is the prefix string from parent levels for tree drawing.
Tree characters appear at the start of line, followed by status.
The tree+status can extend into the PROJECT column since project is
already shown on the parent TODO."
  (let ((total (length subtasks))
        (idx 0)
        (title-start (+ (org-roam-todo-list--get-width 'status) 1
                        (org-roam-todo-list--get-width 'project) 1)))
    (dolist (subtask subtasks)
      (setq idx (1+ idx))
      (let* ((is-last (= idx total))
             (tree-char (if is-last "└─ " "├─ "))
             (text (plist-get subtask :text))
             (done (plist-get subtask :done))
             (children (plist-get subtask :subtasks))
             ;; Build continuation prefix for children
             (child-prefix (concat (or parent-prefix "")
                                   (if is-last "   " "│  ")))
             ;; Get status
             (status (or (plist-get subtask :status)
                         (if done "done" "draft")))
             (face (org-roam-todo-theme-status-face status))
             ;; Calculate tree prefix total length
             (tree-prefix (concat (or parent-prefix "") tree-char))
             (tree-len (length tree-prefix))
             ;; Space needed after status to reach title column
             (status-end (+ tree-len (length status)))
             (padding-needed (max 1 (- title-start status-end))))
        (magit-insert-section section (org-roam-todo-list-subtask-section)
          (oset section subtask subtask)
          (oset section parent-todo todo)
          ;; Tree prefix at start of line (parent continuation + branch)
          (when parent-prefix
            (insert (propertize parent-prefix
                                'face 'org-roam-todo-list-tree-face
                                'font-lock-face 'org-roam-todo-list-tree-face)))
          (insert (propertize tree-char
                              'face 'org-roam-todo-list-tree-face
                              'font-lock-face 'org-roam-todo-list-tree-face))
          ;; Status immediately after tree
          (insert (propertize status 'face face 'font-lock-face face))
          ;; Padding to align with TITLE column
          (insert (make-string padding-needed ?\s))
          ;; Subtask text in TITLE column
          (insert (propertize text
                              'face 'org-roam-todo-list-subtask-face
                              'font-lock-face 'org-roam-todo-list-subtask-face))
          (insert "\n")
          ;; Recursively insert children if present
          (when children
            (org-roam-todo-list--insert-subtasks todo children (1+ depth) child-prefix)))))))

(defun org-roam-todo-list--insert-sections ()
  "Insert all TODO sections into the buffer.
TODOs are displayed as a flat list, sorted by status (workflow order)."
  (let* ((todos (org-roam-todo-list--call-get-entries))
         (sorted (org-roam-todo-list--sort-todos todos)))
    (magit-insert-section (org-roam-todo-list-root-section)
      (org-roam-todo-list--insert-header)
      (if (null sorted)
          (insert (propertize "No TODOs found.\n" 'face 'font-lock-comment-face))
        (dolist (todo sorted)
          (org-roam-todo-list--insert-todo todo))))))

;;; ============================================================
;;; Commands
;;; ============================================================

(defun org-roam-todo-list-refresh ()
  "Refresh the TODO list buffer."
  (interactive)
  (when (derived-mode-p 'org-roam-todo-list-mode)
    (let ((inhibit-read-only t)
          (pos (point)))
      (erase-buffer)
      (org-roam-todo-list--insert-sections)
      (goto-char (min pos (point-max))))))

(defun org-roam-todo-list-open-todo ()
  "Open the TODO file at point."
  (interactive)
  (when-let* ((section (magit-current-section))
              (todo (and (org-roam-todo-list-todo-section-p section)
                         (oref section todo))))
    (org-roam-todo--open-todo-file (plist-get todo :file))))

(defun org-roam-todo-list-change-status ()
  "Change status of TODO at point.
Only allows advancing to the next status or regressing to the previous
status (if allowed by workflow).  Use `org-roam-todo-list-reject' for rejection."
  (interactive)
  (when-let* ((section (magit-current-section))
              (todo (and (org-roam-todo-list-todo-section-p section)
                         (oref section todo))))
    (let* ((workflow (org-roam-todo-wf--get-workflow todo))
           (current-status (plist-get todo :status))
           (all-next (org-roam-todo-wf--next-statuses workflow current-status))
           ;; Filter out "rejected" - that has its own command
           (next-statuses (cl-remove "rejected" all-next :test #'equal)))
      (if (null next-statuses)
          (user-error "No valid transitions from '%s'" current-status)
        (let ((new-status (if (= 1 (length next-statuses))
                              (car next-statuses)
                            (completing-read
                             (format "Change status from %s to: " current-status)
                             next-statuses nil t))))
          (when new-status
            (org-roam-todo-wf--change-status todo new-status)
            (org-roam-todo-list-refresh)))))))

(defun org-roam-todo-list-advance ()
  "Advance TODO at point to the next status in the workflow.
This is like `org-roam-todo-list-change-status' but automatically
selects the next forward status without prompting."
  (interactive)
  (when-let* ((section (magit-current-section))
              (todo (and (org-roam-todo-list-todo-section-p section)
                         (oref section todo))))
    (let* ((workflow (org-roam-todo-wf--get-workflow todo))
           (current-status (plist-get todo :status))
           (statuses (org-roam-todo-workflow-statuses workflow))
           (current-idx (cl-position current-status statuses :test #'equal))
           (next-status (when (and current-idx (< current-idx (1- (length statuses))))
                          (nth (1+ current-idx) statuses))))
      (if next-status
          (progn
            (org-roam-todo-wf--change-status todo next-status)
            (org-roam-todo-list-refresh)
            (message "Advanced: %s -> %s" current-status next-status))
        (user-error "Cannot advance from '%s' - already at terminal status" current-status)))))

(defun org-roam-todo-list-reject ()
  "Reject/abandon the TODO at point.
Prompts for a reason and moves the TODO to rejected status."
  (interactive)
  (when-let* ((section (magit-current-section))
              (todo (and (org-roam-todo-list-todo-section-p section)
                         (oref section todo))))
    (let ((current-status (plist-get todo :status)))
      (if (string= current-status "rejected")
          (user-error "TODO is already rejected")
        (let ((reason (read-string "Rejection reason: ")))
          (when (and reason (not (string-empty-p reason)))
            ;; TODO: store reason in progress log
            (org-roam-todo-wf--change-status todo "rejected")
            (org-roam-todo-list-refresh)
            (message "Rejected: %s" (plist-get todo :title))))))))
(defun org-roam-todo-list-open-worktree ()
  "Open dired in the worktree for TODO at point."
  (interactive)
  (when-let* ((section (magit-current-section))
              (todo (and (org-roam-todo-list-todo-section-p section)
                         (oref section todo)))
              (file (plist-get todo :file))
              (worktree-path (org-roam-todo-get-file-property file "WORKTREE_PATH")))
    (if (file-directory-p worktree-path)
        (dired worktree-path)
      (message "No worktree found for this TODO"))))

(defun org-roam-todo-list-toggle-subtasks ()
  "Toggle subtask display."
  (interactive)
  (setq org-roam-todo-list-show-subtasks
        (not org-roam-todo-list-show-subtasks))
  (org-roam-todo-list-refresh)
  (message "Subtasks: %s" (if org-roam-todo-list-show-subtasks "shown" "hidden")))

(defun org-roam-todo-list--build-initial-message (file title)
  "Build initial message for agent from TODO FILE with TITLE.
Extracts task description and acceptance criteria from the file.
Returns an org-mode formatted message."
  (let* ((first-section (org-roam-todo-get-first-section file))
         (task-heading (car first-section))
         (task-content (cdr first-section))
         (acceptance (org-roam-todo-get-file-section file "Acceptance Criteria")))
    (concat
     "I'm delegating the following task to you:\n\n"
     "* " title "\n\n"
     "TODO file: " file "\n\n"
     ;; Task description from first section
     (when (and task-heading task-content)
       (format "** %s\n\n%s\n\n" task-heading task-content))
     ;; Acceptance criteria
     (when acceptance
       (format "** Acceptance Criteria\n\n%s\n\n" acceptance))
     "** Workflow Tools\n\n"
     "You have access to =mcp__emacs__todo_*= tools for managing this task:\n\n"
     "- =mcp__emacs__todo_advance= - Advance the TODO to the next workflow status\n"
     "- =mcp__emacs__todo_reject= - If the task cannot be completed, reject it with a reason\n\n"
     "Please review the task and acceptance criteria, then begin working on it.")))

(defun org-roam-todo-list--find-agent-buffer (worktree-path)
  "Find an existing Claude agent buffer for WORKTREE-PATH.
Returns the buffer if found and has a live process, nil otherwise."
  (let ((short-name (file-name-nondirectory
                     (directory-file-name (expand-file-name worktree-path))))
        (buf-name (format "*claude:%s*" 
                          (file-name-nondirectory
                           (directory-file-name (expand-file-name worktree-path))))))
    (when-let ((buf (get-buffer buf-name)))
      (when (buffer-live-p buf)
        (with-current-buffer buf
          (when (and (boundp 'claude-agent--process)
                     claude-agent--process
                     (process-live-p claude-agent--process))
            buf))))))

(defun org-roam-todo-list-delegate ()
  "Delegate TODO at point to a Claude agent.
If an agent is already running for this TODO's worktree, switches to it.
If the TODO is in draft status, activates it first (creating worktree).
If the TODO has a saved CLAUDE_SESSION_ID, resumes that session.
Otherwise starts a new session and saves the session ID to the TODO."
  (interactive)
  (when-let* ((section (magit-current-section))
              (todo (and (org-roam-todo-list-todo-section-p section)
                         (oref section todo))))
    (let* ((status (plist-get todo :status))
           (file (plist-get todo :file))
           (title (plist-get todo :title)))
      ;; If draft, activate first to create worktree
      (when (string= status "draft")
        (message "Activating TODO to create worktree...")
        (org-roam-todo-wf--change-status todo "active")
        ;; Refresh to update the display
        (org-roam-todo-list-refresh))
      ;; Read properties fresh from file (worktree-path may have just been set)
      (let* ((worktree-path (org-roam-todo-get-file-property file "WORKTREE_PATH"))
             (model (org-roam-todo-get-file-property file "WORKTREE_MODEL"))
             (saved-session (org-roam-todo-get-file-property file "CLAUDE_SESSION_ID"))
             (allowed-tools (org-roam-todo-effective-agent-allowed-tools)))
        (unless (and worktree-path (file-directory-p worktree-path))
          (user-error "No worktree found for this TODO"))
        ;; Check if agent is already running for this worktree
        (if-let ((existing-buf (org-roam-todo-list--find-agent-buffer worktree-path)))
            (progn
              (message "Switching to existing agent session...")
              (pop-to-buffer existing-buf))
          ;; No existing agent, start or resume
          (require 'claude-agent-repl nil t)
          (unless (fboundp 'claude-agent-run)
            (user-error "claude-agent-repl not available"))
          ;; Start or resume the session
          ;; Don't pass a slug - the worktree directory name is already descriptive
          (let* ((buffer (if saved-session
                             (progn
                               (message "Resuming Claude session %s..." (substring saved-session 0 8))
                               (claude-agent-run worktree-path saved-session nil nil model allowed-tools))
                           (message "Starting new Claude session for %s..." title)
                           (claude-agent-run worktree-path nil nil nil model allowed-tools))))
            ;; If new session, save the session ID and send initial message
            (unless saved-session
              (when buffer
                (let ((initial-msg (org-roam-todo-list--build-initial-message file title)))
                  ;; Use a timer to wait for process to be ready
                  (run-with-timer
                   2 nil
                   (lambda (buf todo-file msg)
                     (when (buffer-live-p buf)
                       (with-current-buffer buf
                         ;; Save session ID
                         (when-let ((session-id (plist-get claude-agent--session-info :session-id)))
                           (org-roam-todo-set-file-property todo-file "CLAUDE_SESSION_ID" session-id)
                           (message "Saved session ID %s to TODO" (substring session-id 0 8)))
                         ;; Send initial message to start the agent
                         (when (and claude-agent--process
                                    (process-live-p claude-agent--process))
                           (claude-agent--dispatch-user-message msg)))))
                   buffer file initial-msg))))
            ;; Switch to the buffer
            (when buffer
              (pop-to-buffer buffer))))))))

(defun org-roam-todo-list-create-todo ()
  "Create a new TODO from the TODO list buffer.
If in a project-filtered buffer, creates a TODO for that project.
If in the general TODO list, prompts for project selection first."
  (interactive)
  (if org-roam-todo-list--project-filter
      ;; Project-filtered buffer: find project root and capture for it
      (let ((project-root (org-roam-todo-list--find-project-root
                           org-roam-todo-list--project-filter)))
        (if project-root
            (org-roam-todo-capture project-root)
          (user-error "Could not find project root for %s"
                      org-roam-todo-list--project-filter)))
    ;; General buffer: prompt for project selection
    (org-roam-todo-capture)))

(defun org-roam-todo-list--find-project-root (project-name)
  "Find the project root for PROJECT-NAME.
Searches existing TODOs for the project root path."
  (let ((todos (org-roam-todo-list--call-get-entries)))
    (cl-loop for todo in todos
             when (string= (plist-get todo :project-name) project-name)
             return (plist-get todo :project-root))))
;;; ============================================================
;;; Keymaps
;;; ============================================================

(defvar org-roam-todo-list-mode-map
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map magit-section-mode-map)
    (define-key map (kbd "g") #'org-roam-todo-list-refresh)
    (define-key map (kbd "s") #'org-roam-todo-list-toggle-subtasks)
    (define-key map (kbd "t") #'org-roam-todo-list-create-todo)
    (define-key map (kbd "q") #'quit-window)
    map)
  "Keymap for `org-roam-todo-list-mode'.")



(defvar-keymap org-roam-todo-list-todo-map
  :doc "Keymap for TODO sections."
  "RET" #'org-roam-todo-list-open-todo
  "a" #'org-roam-todo-list-advance
  "c" #'org-roam-todo-list-change-status
  "r" #'org-roam-todo-list-reject
  "w" #'org-roam-todo-list-open-worktree
  "d" #'org-roam-todo-list-delegate)

(defvar-keymap org-roam-todo-list-subtask-map
  :doc "Keymap for subtask sections.")

;;; ============================================================
;;; Mode Definition
;;; ============================================================

(define-derived-mode org-roam-todo-list-mode magit-section-mode "Org-Roam-TODO-List"
  "Major mode for displaying org-roam TODOs in a collapsible list.

\\{org-roam-todo-list-mode-map}"
  :group 'org-roam-todo-list
  ;; Use keywords-only font-lock with no keywords - this enables font-lock-mode
  ;; (needed for magit-section highlighting via font-lock-face property) while
  ;; preserving our custom 'face properties for status colors.
  ;; This matches magit's approach.
  (setq-local font-lock-defaults '(nil t))
  (setq-local magit-section-highlight-hook '(magit-section-highlight))
  (setq-local revert-buffer-function
              (lambda (_ignore-auto _noconfirm)
                (org-roam-todo-list-refresh)))
  (setq-local bookmark-make-record-function
              #'org-roam-todo-list--bookmark-make-record)
  ;; Start auto-refresh timer for agent status updates
  (org-roam-todo-list--start-auto-refresh)
  ;; Stop timer when buffer is killed
  (add-hook 'kill-buffer-hook #'org-roam-todo-list--stop-auto-refresh nil t))

;; Evil mode support: use emacs state like magit does
;; This allows TAB to work for section toggling without evil interference
(with-eval-after-load 'evil
  (when (boundp 'evil-emacs-state-modes)
    (add-to-list 'evil-emacs-state-modes 'org-roam-todo-list-mode)))

;;; ============================================================
;;; Entry Point
;;; ============================================================

;;;###autoload
(defun org-roam-todo-list ()
  "Display org-roam TODOs in a collapsible list buffer."
  (interactive)
  (let ((buffer (get-buffer-create "*todo-list*")))
    (with-current-buffer buffer
      (unless (derived-mode-p 'org-roam-todo-list-mode)
        (org-roam-todo-list-mode))
      (setq org-roam-todo-list--project-filter nil)
      (org-roam-todo-list-refresh))
    (pop-to-buffer buffer)))

;;;###autoload
(defun org-roam-todo-list-project (project-name)
  "Display org-roam TODOs filtered to PROJECT-NAME.
If called interactively, prompts for the project name."
  (interactive
   (list (completing-read "Project: "
                          (org-roam-todo-list--get-project-names)
                          nil t)))
  (let ((buffer (get-buffer-create (format "*todo-list:%s*" project-name))))
    (with-current-buffer buffer
      (unless (derived-mode-p 'org-roam-todo-list-mode)
        (org-roam-todo-list-mode))
      (setq org-roam-todo-list--project-filter project-name)
      (org-roam-todo-list-refresh))
    (pop-to-buffer buffer)))

(defun org-roam-todo-list--get-project-names ()
  "Get a list of unique project names from all TODOs."
  (let ((todos (org-roam-todo-list--get-entries))
        (projects (make-hash-table :test 'equal)))
    (dolist (todo todos)
      (when-let ((project (plist-get todo :project-name)))
        (puthash project t projects)))
    (hash-table-keys projects)))

;;;###autoload
(defun org-roam-todo-list-for-project ()
  "Show TODO list filtered to current project."
  (interactive)
  (if-let* ((project-root (org-roam-todo-infer-project))
            (project-name (org-roam-todo-project-name project-root)))
      (org-roam-todo-list-project project-name)
    (call-interactively #'org-roam-todo-list-project)))

;;; ============================================================
;;; Keybindings
;;; ============================================================

(defvar org-roam-todo-global-map (make-sparse-keymap)
  "Keymap for global TODO commands (C-c n t).")

(defvar org-roam-todo-project-map (make-sparse-keymap)
  "Keymap for project-scoped TODO commands (C-c n p).")

;; Global TODO keymap (C-c n t):
(define-key org-roam-todo-global-map (kbd "t") #'org-roam-todo-capture)
(define-key org-roam-todo-global-map (kbd "l") #'org-roam-todo-list)

;; Project-scoped keymap (C-c n p):
(define-key org-roam-todo-project-map (kbd "t") #'org-roam-todo-capture-project)
(define-key org-roam-todo-project-map (kbd "l") #'org-roam-todo-list-for-project)

;;;###autoload
(defun org-roam-todo-setup-keybindings ()
  "Set up org-roam-todo keybindings under C-c n prefix.

Bindings:
  \\[org-roam-todo-capture] - Capture a new TODO
  \\[org-roam-todo-list] - List all TODOs
  \\[org-roam-todo-capture-for-project] - Capture TODO (project inferred)
  \\[org-roam-todo-list-for-project] - List project TODOs"
  (interactive)
  ;; Create C-c n prefix if it doesn't exist
  (unless (keymapp (lookup-key global-map (kbd "C-c n")))
    (define-key global-map (kbd "C-c n") (make-sparse-keymap)))
  ;; Bind C-c n t to global TODO map
  (define-key global-map (kbd "C-c n t") org-roam-todo-global-map)
  ;; Bind C-c n p to project map
  (define-key global-map (kbd "C-c n p") org-roam-todo-project-map)
  (message "TODO keybindings set up: C-c n t (global), C-c n p (project)"))

;; Auto-setup keybindings when loaded
(org-roam-todo-setup-keybindings)

;;; ============================================================
;;; Bookmark Support
;;; ============================================================

(defun org-roam-todo-list--bookmark-make-record ()
  "Create a bookmark record for the TODO list."
  (let ((project org-roam-todo-list--project-filter))
    (if project
        `(,(format "TODO List: %s" project)
          (project . ,project)
          (handler . org-roam-todo-list--bookmark-handler))
      `("TODO List"
        (handler . org-roam-todo-list--bookmark-handler)))))

(defun org-roam-todo-list--bookmark-handler (bookmark)
  "Handle BOOKMARK for TODO list."
  (let ((project (alist-get 'project (cdr bookmark))))
    (if project
        (org-roam-todo-list-project project)
      (org-roam-todo-list))))

(provide 'org-roam-todo-list)
;;; org-roam-todo-list.el ends here
