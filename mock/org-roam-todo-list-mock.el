;;; org-roam-todo-list-mock.el --- Mock data for testing TODO list display -*- lexical-binding: t; -*-

;;; Commentary:
;; Provides mock data and helper functions for testing org-roam-todo-list display.
;; Use `org-roam-todo-list-mock-show' to display the TODO list with fake data.

;;; Code:

(require 'org-roam-todo-list)
(require 'org-roam-todo-theme)
(require 'org-roam-todo-wf)

;;; ============================================================
;;; Sample TODO Data
;;; ============================================================

(defvar org-roam-todo-list-mock--sample-todos
  '(;; draft status TODOs
    (:id "d1" :title "Database migration scripts" :status "draft" :project-name "api-server"
     :worktree-path nil
     :subtasks ((:text "Write up migration" :status "draft"
                 :subtasks ((:text "Schema changes" :status "draft")
                            (:text "Data migration" :status "draft")))
                (:text "Test rollback" :status "draft")))
    (:id "d2" :title "Design new dashboard layout" :status "draft" :project-name "webapp"
     :worktree-path nil :subtasks nil)
    (:id "d3" :title "Plan API versioning strategy" :status "draft" :project-name "api-server"
     :worktree-path nil :subtasks nil)

    ;; active status TODOs
    (:id "a1" :title "Implement OAuth2 login flow" :status "active" :project-name "webapp"
     :worktree-path "/tmp/worktree-oauth"
     :subtasks ((:text "Add OAuth provider config" :status "done")
                (:text "Create login callback route" :status "active"
                 :subtasks ((:text "Setup route handler" :status "done")
                            (:text "Add CSRF protection" :status "draft")))
                (:text "Store tokens securely" :status "draft")))
    (:id "a2" :title "Refactor error handling" :status "active" :project-name "api-server"
     :worktree-path nil :subtasks nil)
    (:id "a3" :title "Add dark mode support" :status "active" :project-name "webapp"
     :worktree-path nil
     :subtasks ((:text "Define color tokens" :status "done")
                (:text "Update components" :status "active")
                (:text "Add toggle switch" :status "draft")))

    ;; ci status TODOs
    (:id "c1" :title "Setup CI/CD pipeline" :status "ci" :project-name "webapp"
     :worktree-path "/tmp/worktree-ci"
     :subtasks ((:text "Configure GitHub Actions" :status "done"
                 :subtasks ((:text "Setup Node.js workflow" :status "done")
                            (:text "Add test job" :status "done")
                            (:text "Add deploy job" :status "active")))
                (:text "Add deployment step" :status "draft")))
    (:id "c2" :title "Add integration test suite" :status "ci" :project-name "api-server"
     :worktree-path nil :subtasks nil)

    ;; ready status TODOs
    (:id "r1" :title "Fix authentication bug" :status "ready" :project-name "api-server"
     :worktree-path nil :subtasks nil)
    (:id "r2" :title "Update documentation" :status "ready" :project-name "cli-tools"
     :worktree-path nil :subtasks nil)

    ;; review status TODOs
    (:id "v1" :title "Add user profile endpoint" :status "review" :project-name "api-server"
     :worktree-path "/tmp/worktree-review"
     :subtasks ((:text "Define schema" :status "done")
                (:text "Add validation" :status "done")
                (:text "Write tests" :status "active"
                 :subtasks ((:text "Unit tests" :status "active")
                            (:text "Integration tests" :status "draft")))))
    (:id "v2" :title "Implement caching layer" :status "review" :project-name "webapp"
     :worktree-path nil :subtasks nil)
    (:id "v3" :title "Add rate limiting" :status "review" :project-name "api-server"
     :worktree-path nil :subtasks nil)

    ;; done status TODOs
    (:id "o1" :title "CLI argument parsing" :status "done" :project-name "cli-tools"
     :worktree-path nil :subtasks nil)
    (:id "o2" :title "Initial project setup" :status "done" :project-name "webapp"
     :worktree-path nil :subtasks nil)
    (:id "o3" :title "Database connection pool" :status "done" :project-name "api-server"
     :worktree-path nil :subtasks nil)

    ;; rejected status TODOs
    (:id "x1" :title "Deprecated config format" :status "rejected" :project-name "cli-tools"
     :worktree-path nil :subtasks nil)
    (:id "x2" :title "XML export feature" :status "rejected" :project-name "api-server"
     :worktree-path nil :subtasks nil))
  "Sample TODO data for testing the list display.
Includes multiple TODOs for each status to verify visual styling.")

;;; ============================================================
;;; Mock Display Functions
;;; ============================================================

;; Buffer-local storage for mock data (used by override functions)
(defvar-local org-roam-todo-list-mock--todos nil
  "Buffer-local mock TODO data for demo buffer.")

(defvar-local org-roam-todo-list-mock--workflow nil
  "Buffer-local mock workflow for demo buffer.")

;;;###autoload
(defun org-roam-todo-list-mock-show (&optional todos show-subtasks)
  "Display the TODO list with mock data.
TODOS defaults to `org-roam-todo-list-mock--sample-todos'.
SHOW-SUBTASKS defaults to t."
  (interactive)
  (let ((todos (or todos org-roam-todo-list-mock--sample-todos))
        (org-roam-todo-list-show-subtasks (if (null show-subtasks) t show-subtasks))
        (mock-workflow (make-org-roam-todo-workflow
                        :name 'pull-request
                        :statuses '("draft" "active" "ci" "ready" "review" "done")
                        :hooks nil
                        :config nil)))
    ;; Kill existing buffer to get fresh mode settings
    (when (get-buffer "*Org-Roam TODO List Demo*")
      (kill-buffer "*Org-Roam TODO List Demo*"))
    (let ((buffer (get-buffer-create "*Org-Roam TODO List Demo*")))
      (with-current-buffer buffer
        (unless (derived-mode-p 'org-roam-todo-list-mode)
          (org-roam-todo-list-mode))
        ;; Store mock data in buffer-local variables
        (setq org-roam-todo-list-mock--todos todos)
        (setq org-roam-todo-list-mock--workflow mock-workflow)
        ;; Set the override functions (these are buffer-local in org-roam-todo-list)
        (setq org-roam-todo-list--get-entries-fn
              (lambda () org-roam-todo-list-mock--todos))
        (setq org-roam-todo-list--get-workflow-fn
              (lambda (_todo) org-roam-todo-list-mock--workflow))
        ;; Render the buffer
        (let ((inhibit-read-only t))
          (erase-buffer)
          (org-roam-todo-list--insert-sections)))
      (pop-to-buffer buffer))))

;;;###autoload
(defun org-roam-todo-list-show-demo ()
  "Show a demo of the TODO list with sample data.
Closes any existing demo buffer and opens a fresh one."
  (interactive)
  (org-roam-todo-list-mock-show))

;;; ============================================================
;;; Custom Mock Data Helpers
;;; ============================================================

(defun org-roam-todo-list-mock-todo (id title status project &optional subtasks worktree)
  "Create a mock TODO plist.
ID is a unique identifier string.
TITLE is the TODO title.
STATUS is one of: draft, active, ci, ready, review, done, rejected.
PROJECT is the project name.
SUBTASKS is an optional list of subtask plists (see `org-roam-todo-list-mock-subtask').
WORKTREE is an optional worktree path string."
  (list :id id
        :title title
        :status status
        :project-name project
        :worktree-path worktree
        :subtasks subtasks))

(defun org-roam-todo-list-mock-subtask (text &optional status children)
  "Create a mock subtask plist.
TEXT is the subtask description.
STATUS is the subtask status (default \"draft\").
CHILDREN is optional list of nested subtasks."
  (let ((subtask (list :text text :status (or status "draft"))))
    (when children
      (setq subtask (plist-put subtask :subtasks children)))
    subtask))
;;; ============================================================
;;; Example: Building Custom Mock Data
;;; ============================================================

;; Example usage:
;;
;; (org-roam-todo-list-mock-show
;;  (list
;;   (org-roam-todo-list-mock-todo "1" "My Task" "active" "my-project"
;;     (list (org-roam-todo-list-mock-subtask "Step 1" t)
;;           (org-roam-todo-list-mock-subtask "Step 2")))
;;   (org-roam-todo-list-mock-todo "2" "Another Task" "draft" "my-project"))
;;  'project t)

(provide 'org-roam-todo-list-mock)
;;; org-roam-todo-list-mock.el ends here
