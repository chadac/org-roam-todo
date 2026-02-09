;;; org-roam-todo-wf-tools-test.el --- Tests for workflow MCP tools -*- lexical-binding: t; -*-

;; Author: Claude Code
;; Version: 0.1.0
;; Package-Requires: ((emacs "28.1") (ert "1.0") (mocker "0.5"))

;;; Commentary:
;; Tests for the workflow-aware MCP tools.
;; These tools provide the human-centric interface for managing TODOs:
;; - todo-start: Create worktree and advance draft -> active
;; - todo-stage-changes: Stage and commit changes per commit-strategy
;; - todo-advance: Move to next status (+1)
;; - todo-regress: Move to previous status (-1, if allowed)
;; - todo-reject: Abandon TODO
;; - todo-delegate: Spawn agent in worktree

;;; Code:

(require 'ert)
(require 'cl-lib)

;; Load test utilities
(let ((test-dir (file-name-directory (or load-file-name buffer-file-name))))
  (add-to-list 'load-path (expand-file-name ".." test-dir))
  (add-to-list 'load-path test-dir))

(require 'org-roam-todo-wf-test-utils)

;; Try to load mocker
(condition-case nil
    (require 'mocker)
  (error
   (message "Warning: mocker.el not available. Some tests will be skipped.")))

;;; ============================================================
;;; Test Utilities
;;; ============================================================

(defvar org-roam-todo-wf-tools-test--temp-dirs nil
  "List of temp directories to clean up after tests.")

(defun org-roam-todo-wf-tools-test--create-temp-todo (props)
  "Create a temporary TODO file with PROPS.
Returns a plist with :file and :todo keys."
  (let* ((temp-dir (make-temp-file "wf-tools-test-" t))
         (todo-file (expand-file-name "test-todo.org" temp-dir))
         (id (or (plist-get props :id) (format "%s%04x" (format-time-string "%Y%m%dT%H%M%S") (random 65536))))
         (status (or (plist-get props :status) "draft"))
         (title (or (plist-get props :title) "Test TODO"))
         (project-name (or (plist-get props :project-name) "test-project"))
         (project-root (or (plist-get props :project-root) temp-dir))
         (worktree-path (plist-get props :worktree-path))
         (worktree-branch (plist-get props :worktree-branch)))
    (push temp-dir org-roam-todo-wf-tools-test--temp-dirs)
    (with-temp-file todo-file
      (insert (format ":PROPERTIES:
:ID: %s
:PROJECT_NAME: %s
:PROJECT_ROOT: %s
:STATUS: %s%s%s
:END:
#+title: %s

** Task Description
Test task description.

** Acceptance Criteria
- [ ] First criterion
- [ ] Second criterion

** Progress Log

"
                      id
                      project-name
                      project-root
                      status
                      (if worktree-path
                          (format "\n:WORKTREE_PATH: %s" worktree-path)
                        "")
                      (if worktree-branch
                          (format "\n:WORKTREE_BRANCH: %s" worktree-branch)
                        "")
                      title)))
    (list :file todo-file
          :todo (list :id id
                      :file todo-file
                      :title title
                      :status status
                      :project-name project-name
                      :project-root project-root
                      :worktree-path worktree-path
                      :worktree-branch worktree-branch))))

(defun org-roam-todo-wf-tools-test--cleanup ()
  "Clean up all temporary directories."
  (dolist (dir org-roam-todo-wf-tools-test--temp-dirs)
    (when (file-exists-p dir)
      (delete-directory dir t)))
  (setq org-roam-todo-wf-tools-test--temp-dirs nil))

;;; ============================================================
;;; todo-start Tests
;;; ============================================================

(ert-deftest wf-tools-test-start-requires-draft-status ()
  "Test that todo-start fails if TODO is not in draft status."
  :tags '(:unit :wf :tools)
  (org-roam-todo-wf-test--require-wf)
  (org-roam-todo-wf-test--require-mocker)
  (require 'org-roam-todo-wf-tools nil t)
  (unwind-protect
      (let* ((test-data (org-roam-todo-wf-tools-test--create-temp-todo
                         '(:status "active" :title "Already Active")))
             (todo (plist-get test-data :todo)))
        (mocker-let
            ((org-roam-todo-wf-tools--get-todo (id)
               ((:input-matcher #'always :output todo))))
          (should-error (org-roam-todo-wf-tools-start nil)
                        :type 'user-error)))
    (org-roam-todo-wf-tools-test--cleanup)))

(ert-deftest wf-tools-test-start-changes-status-to-active ()
  "Test that todo-start changes status from draft to active."
  :tags '(:unit :wf :tools)
  (org-roam-todo-wf-test--require-wf)
  (org-roam-todo-wf-test--require-mocker)
  (require 'org-roam-todo-wf-tools nil t)
  (unwind-protect
      (let* ((test-data (org-roam-todo-wf-tools-test--create-temp-todo
                         '(:status "draft" :title "New TODO")))
             (todo (plist-get test-data :todo))
             (status-changed-to nil))
        (mocker-let
            ((org-roam-todo-wf-tools--get-todo (id)
               ((:input-matcher #'always :output todo)))
             (org-roam-todo-wf--change-status (todo new-status)
               ((:input-matcher #'always
                 :output-generator (lambda (t s)
                                     (setq status-changed-to s)
                                     nil)))))
          (org-roam-todo-wf-tools-start nil)
          (should (string= "active" status-changed-to))))
    (org-roam-todo-wf-tools-test--cleanup)))

(ert-deftest wf-tools-test-start-returns-status-message ()
  "Test that todo-start returns a status message."
  :tags '(:unit :wf :tools)
  (org-roam-todo-wf-test--require-wf)
  (org-roam-todo-wf-test--require-mocker)
  (require 'org-roam-todo-wf-tools nil t)
  (unwind-protect
      (let* ((test-data (org-roam-todo-wf-tools-test--create-temp-todo
                         '(:status "draft" :title "New TODO")))
             (todo (plist-get test-data :todo)))
        (mocker-let
            ((org-roam-todo-wf-tools--get-todo (id)
               ((:input-matcher #'always :output todo)))
             (org-roam-todo-wf--change-status (todo new-status)
               ((:input-matcher #'always :output nil))))
          (let ((result (org-roam-todo-wf-tools-start nil)))
            (should (stringp result))
            (should (string-match-p "Started" result)))))
    (org-roam-todo-wf-tools-test--cleanup)))


;;; ============================================================
;;; todo-advance Tests
;;; ============================================================

(ert-deftest wf-tools-test-advance-advances-one-status ()
  "Test that todo-advance advances by one status."
  :tags '(:unit :wf :tools)
  (org-roam-todo-wf-test--require-wf)
  (org-roam-todo-wf-test--require-mocker)
  (require 'org-roam-todo-wf-tools nil t)
  (unwind-protect
      (let* ((test-data (org-roam-todo-wf-tools-test--create-temp-todo
                         '(:status "ci" :title "In CI")))
             (todo (plist-get test-data :todo))
             (mock-workflow (make-org-roam-todo-workflow
                             :name 'pull-request
                             :statuses '("draft" "active" "ci" "ready" "review" "done")
                             :config '(:allow-backward (ci ready))))
             (new-status nil))
        (mocker-let
            ((org-roam-todo-wf-tools--get-todo (id)
               ((:input-matcher #'always :output todo)))
             (org-roam-todo-wf--get-workflow (todo)
               ((:input-matcher #'always :output mock-workflow)))
             (org-roam-todo-wf--change-status (todo status)
               ((:input-matcher #'always
                 :output-generator (lambda (t s)
                                     (setq new-status s)
                                     nil)))))
          (org-roam-todo-wf-tools-advance nil)
          (should (string= "ready" new-status))))
    (org-roam-todo-wf-tools-test--cleanup)))

(ert-deftest wf-tools-test-advance-fails-at-terminal ()
  "Test that todo-advance fails at terminal status."
  :tags '(:unit :wf :tools)
  (org-roam-todo-wf-test--require-wf)
  (org-roam-todo-wf-test--require-mocker)
  (require 'org-roam-todo-wf-tools nil t)
  (unwind-protect
      (let* ((test-data (org-roam-todo-wf-tools-test--create-temp-todo
                         '(:status "done" :title "Already Done")))
             (todo (plist-get test-data :todo))
             (mock-workflow (make-org-roam-todo-workflow
                             :name 'pull-request
                             :statuses '("draft" "active" "ci" "ready" "review" "done")
                             :config nil)))
        (mocker-let
            ((org-roam-todo-wf-tools--get-todo (id)
               ((:input-matcher #'always :output todo)))
             (org-roam-todo-wf--get-workflow (todo)
               ((:input-matcher #'always :output mock-workflow))))
          (should-error (org-roam-todo-wf-tools-advance nil)
                        :type 'user-error)))
    (org-roam-todo-wf-tools-test--cleanup)))

;;; ============================================================
;;; todo-regress Tests
;;; ============================================================

(ert-deftest wf-tools-test-regress-moves-back-when-allowed ()
  "Test that todo-regress moves back when status allows it."
  :tags '(:unit :wf :tools)
  (org-roam-todo-wf-test--require-wf)
  (org-roam-todo-wf-test--require-mocker)
  (require 'org-roam-todo-wf-tools nil t)
  (unwind-protect
      (let* ((test-data (org-roam-todo-wf-tools-test--create-temp-todo
                         '(:status "ci" :title "In CI")))
             (todo (plist-get test-data :todo))
             (mock-workflow (make-org-roam-todo-workflow
                             :name 'pull-request
                             :statuses '("draft" "active" "ci" "ready" "review" "done")
                             :config '(:allow-backward (ci ready))))
             (new-status nil))
        (mocker-let
            ((org-roam-todo-wf-tools--get-todo (id)
               ((:input-matcher #'always :output todo)))
             (org-roam-todo-wf--get-workflow (todo)
               ((:input-matcher #'always :output mock-workflow)))
             (org-roam-todo-wf--change-status (todo status)
               ((:input-matcher #'always
                 :output-generator (lambda (t s)
                                     (setq new-status s)
                                     nil)))))
          (org-roam-todo-wf-tools-regress nil)
          (should (string= "active" new-status))))
    (org-roam-todo-wf-tools-test--cleanup)))

(ert-deftest wf-tools-test-regress-fails-when-not-allowed ()
  "Test that todo-regress fails when status doesn't allow backward."
  :tags '(:unit :wf :tools)
  (org-roam-todo-wf-test--require-wf)
  (org-roam-todo-wf-test--require-mocker)
  (require 'org-roam-todo-wf-tools nil t)
  (unwind-protect
      (let* ((test-data (org-roam-todo-wf-tools-test--create-temp-todo
                         '(:status "active" :title "Active")))
             (todo (plist-get test-data :todo))
             (mock-workflow (make-org-roam-todo-workflow
                             :name 'pull-request
                             :statuses '("draft" "active" "ci" "ready" "review" "done")
                             :config '(:allow-backward (ci ready)))))  ; active not in list
        (mocker-let
            ((org-roam-todo-wf-tools--get-todo (id)
               ((:input-matcher #'always :output todo)))
             (org-roam-todo-wf--get-workflow (todo)
               ((:input-matcher #'always :output mock-workflow))))
          (should-error (org-roam-todo-wf-tools-regress nil)
                        :type 'user-error)))
    (org-roam-todo-wf-tools-test--cleanup)))

(ert-deftest wf-tools-test-regress-fails-at-first-status ()
  "Test that todo-regress fails at first status."
  :tags '(:unit :wf :tools)
  (org-roam-todo-wf-test--require-wf)
  (org-roam-todo-wf-test--require-mocker)
  (require 'org-roam-todo-wf-tools nil t)
  (unwind-protect
      (let* ((test-data (org-roam-todo-wf-tools-test--create-temp-todo
                         '(:status "draft" :title "Draft")))
             (todo (plist-get test-data :todo))
             (mock-workflow (make-org-roam-todo-workflow
                             :name 'pull-request
                             :statuses '("draft" "active" "ci" "ready" "review" "done")
                             :config '(:allow-backward (draft)))))  ; even if allowed, can't go before first
        (mocker-let
            ((org-roam-todo-wf-tools--get-todo (id)
               ((:input-matcher #'always :output todo)))
             (org-roam-todo-wf--get-workflow (todo)
               ((:input-matcher #'always :output mock-workflow))))
          (should-error (org-roam-todo-wf-tools-regress nil)
                        :type 'user-error)))
    (org-roam-todo-wf-tools-test--cleanup)))

;;; ============================================================
;;; todo-reject Tests
;;; ============================================================

(ert-deftest wf-tools-test-reject-changes-status-to-rejected ()
  "Test that todo-reject changes status to rejected."
  :tags '(:unit :wf :tools)
  (org-roam-todo-wf-test--require-wf)
  (org-roam-todo-wf-test--require-mocker)
  (require 'org-roam-todo-wf-tools nil t)
  (unwind-protect
      (let* ((test-data (org-roam-todo-wf-tools-test--create-temp-todo
                         '(:status "active" :title "Active TODO")))
             (todo (plist-get test-data :todo))
             (new-status nil))
        (mocker-let
            ((org-roam-todo-wf-tools--get-todo (id)
               ((:input-matcher #'always :output todo)))
             (org-roam-todo-wf--change-status (todo status)
               ((:input-matcher #'always
                 :output-generator (lambda (t s)
                                     (setq new-status s)
                                     nil))))
             (org-roam-todo-mcp-add-progress (msg &optional todo-id)
               ((:input-matcher #'always :output nil))))
          (org-roam-todo-wf-tools-reject "No longer needed" nil)
          (should (string= "rejected" new-status))))
    (org-roam-todo-wf-tools-test--cleanup)))

(ert-deftest wf-tools-test-reject-logs-reason ()
  "Test that todo-reject logs the rejection reason."
  :tags '(:unit :wf :tools)
  (org-roam-todo-wf-test--require-wf)
  (org-roam-todo-wf-test--require-mocker)
  (require 'org-roam-todo-wf-tools nil t)
  (unwind-protect
      (let* ((test-data (org-roam-todo-wf-tools-test--create-temp-todo
                         '(:status "active" :title "Active TODO")))
             (todo (plist-get test-data :todo))
             (logged-msg nil))
        (mocker-let
            ((org-roam-todo-wf-tools--get-todo (id)
               ((:input-matcher #'always :output todo)))
             (org-roam-todo-wf--change-status (todo status)
               ((:input-matcher #'always :output nil)))
             (org-roam-todo-mcp-add-progress (msg &optional todo-id)
               ((:input-matcher #'always
                 :output-generator (lambda (m &rest _)
                                     (setq logged-msg m)
                                     nil)))))
          (org-roam-todo-wf-tools-reject "No longer needed" nil)
          (should logged-msg)
          (should (string-match-p "REJECTED" logged-msg))
          (should (string-match-p "No longer needed" logged-msg))))
    (org-roam-todo-wf-tools-test--cleanup)))

;;; ============================================================
;;; todo-delegate Tests
;;; ============================================================

(ert-deftest wf-tools-test-delegate-requires-active-status ()
  "Test that todo-delegate fails if not in active status."
  :tags '(:unit :wf :tools)
  (org-roam-todo-wf-test--require-wf)
  (org-roam-todo-wf-test--require-mocker)
  (require 'org-roam-todo-wf-tools nil t)
  (unwind-protect
      (let* ((test-data (org-roam-todo-wf-tools-test--create-temp-todo
                         '(:status "draft" :title "Draft TODO")))
             (todo (plist-get test-data :todo)))
        (mocker-let
            ((org-roam-todo-wf-tools--get-todo (id)
               ((:input-matcher #'always :output todo))))
          (should-error (org-roam-todo-wf-tools-delegate nil)
                        :type 'user-error)))
    (org-roam-todo-wf-tools-test--cleanup)))

(ert-deftest wf-tools-test-delegate-requires-worktree ()
  "Test that todo-delegate fails if no worktree exists."
  :tags '(:unit :wf :tools)
  (org-roam-todo-wf-test--require-wf)
  (org-roam-todo-wf-test--require-mocker)
  (require 'org-roam-todo-wf-tools nil t)
  (unwind-protect
      (let* ((test-data (org-roam-todo-wf-tools-test--create-temp-todo
                         '(:status "active" :title "No Worktree")))
             (todo (plist-get test-data :todo)))
        (mocker-let
            ((org-roam-todo-wf-tools--get-todo (id)
               ((:input-matcher #'always :output todo))))
          (should-error (org-roam-todo-wf-tools-delegate nil)
                        :type 'user-error)))
    (org-roam-todo-wf-tools-test--cleanup)))

(ert-deftest wf-tools-test-delegate-spawns-agent ()
  "Test that todo-delegate spawns an agent in the worktree."
  :tags '(:unit :wf :tools)
  (org-roam-todo-wf-test--require-wf)
  (org-roam-todo-wf-test--require-mocker)
  (require 'org-roam-todo-wf-tools nil t)
  (unwind-protect
      (let* ((test-data (org-roam-todo-wf-tools-test--create-temp-todo
                         '(:status "active"
                           :title "Has Worktree"
                           :worktree-path "/tmp/test-worktree"
                           :worktree-branch "feat/test")))
             (todo (plist-get test-data :todo))
             (agent-spawned nil)
             (spawned-path nil))
        (mocker-let
            ((org-roam-todo-wf-tools--get-todo (id)
               ((:input-matcher #'always :output todo)))
             (org-roam-todo-wf-tools--spawn-agent (worktree-path todo)
               ((:input-matcher
                 (lambda (p t)
                   (setq agent-spawned t)
                   (setq spawned-path p)
                   t)
                 :output "*claude:/tmp/test-worktree*"))))
          (let ((result (org-roam-todo-wf-tools-delegate nil)))
            (should agent-spawned)
            (should (string= "/tmp/test-worktree" spawned-path))
            (should (stringp result)))))
    (org-roam-todo-wf-tools-test--cleanup)))

;;; ============================================================
;;; get-todo Resolution Tests
;;; ============================================================

(ert-deftest wf-tools-test-get-todo-from-worktree ()
  "Test that get-todo resolves TODO from current worktree."
  :tags '(:unit :wf :tools)
  (org-roam-todo-wf-test--require-wf)
  (org-roam-todo-wf-test--require-mocker)
  (require 'org-roam-todo-wf-tools nil t)
  (unwind-protect
      (let* ((test-data (org-roam-todo-wf-tools-test--create-temp-todo
                         '(:status "active"
                           :title "Worktree TODO"
                           :worktree-path "/home/user/worktrees/my-feature")))
             (todo (plist-get test-data :todo))
             (todos-list (list todo)))
        (let ((default-directory "/home/user/worktrees/my-feature/"))
          (mocker-let
              ((org-roam-todo--query-todos (&optional project)
                 ((:input-matcher #'always :output todos-list))))
            (let ((resolved (org-roam-todo-wf-tools--get-todo nil)))
              (should resolved)
              (should (string= "Worktree TODO" (plist-get resolved :title)))))))
    (org-roam-todo-wf-tools-test--cleanup)))

(ert-deftest wf-tools-test-get-todo-by-file-path ()
  "Test that get-todo accepts a file path."
  :tags '(:unit :wf :tools)
  (org-roam-todo-wf-test--require-wf)
  (require 'org-roam-todo-wf-tools nil t)
  (unwind-protect
      (let* ((test-data (org-roam-todo-wf-tools-test--create-temp-todo
                         '(:status "active" :title "File Path TODO")))
             (file (plist-get test-data :file)))
        (let ((resolved (org-roam-todo-wf-tools--get-todo file)))
          (should resolved)
          (should (string= file (plist-get resolved :file)))))
    (org-roam-todo-wf-tools-test--cleanup)))

;;; ============================================================
;;; Stage Changes Tests
;;; ============================================================

(ert-deftest wf-tools-test-stage-requires-worktree ()
  "Test that stage-changes fails without a worktree."
  :tags '(:unit :wf :tools :stage)
  (org-roam-todo-wf-test--require-wf)
  (require 'org-roam-todo-wf-tools nil t)
  (unwind-protect
      (let* ((test-data (org-roam-todo-wf-tools-test--create-temp-todo
                         '(:status "active" :title "No Worktree TODO")))
             (file (plist-get test-data :file))
             ;; Create a mock workflow with default strategy
             (mock-workflow (make-org-roam-todo-workflow
                             :name 'mock-test
                             :statuses '("draft" "active" "done")
                             :hooks nil
                             :config nil)))
        ;; Mock org-roam-todo--query-todos and workflow lookup
        (cl-letf (((symbol-function 'org-roam-todo--query-todos)
                   (lambda (&optional _) (list (plist-get test-data :todo))))
                  ((symbol-function 'org-roam-todo-wf--get-workflow)
                   (lambda (_) mock-workflow)))
          (should-error
           (org-roam-todo-wf-tools-stage "Test changes" file)
           :type 'user-error)))
    (org-roam-todo-wf-tools-test--cleanup)))

(ert-deftest wf-tools-test-stage-single-commit-default ()
  "Test that :single-commit is the default strategy."
  :tags '(:unit :wf :tools :stage)
  (org-roam-todo-wf-test--require-wf)
  (require 'org-roam-todo-wf-tools nil t)
  (unwind-protect
      (let* ((temp-dir (make-temp-file "stage-test-" t))
             (test-data (org-roam-todo-wf-tools-test--create-temp-todo
                         `(:status "active"
                           :title "Stage Test TODO"
                           :worktree-path ,temp-dir
                           :worktree-branch "test-branch")))
             (file (plist-get test-data :file))
             (git-commands nil)
             ;; Create a mock workflow with NO commit-strategy (should default)
             (mock-workflow (make-org-roam-todo-workflow
                             :name 'default-test
                             :statuses '("draft" "active" "done")
                             :hooks nil
                             :config nil)))  ; No :commit-strategy = defaults to :single-commit
        (push temp-dir org-roam-todo-wf-tools-test--temp-dirs)
        ;; Initialize git repo
        (let ((default-directory temp-dir))
          (call-process "git" nil nil nil "init")
          (call-process "git" nil nil nil "config" "user.email" "test@test.com")
          (call-process "git" nil nil nil "config" "user.name" "Test")
          ;; Create initial commit
          (with-temp-file (expand-file-name "README.md" temp-dir)
            (insert "# Test\n"))
          (call-process "git" nil nil nil "add" "-A")
          (call-process "git" nil nil nil "commit" "-m" "Initial commit"))
        ;; Mock org-roam-todo--query-todos and workflow
        (cl-letf (((symbol-function 'org-roam-todo--query-todos)
                   (lambda (&optional _) (list (plist-get test-data :todo))))
                  ((symbol-function 'org-roam-todo-wf--get-workflow)
                   (lambda (_) mock-workflow))
                  ;; Mock validation to pass (no unstaged, has staged)
                  ((symbol-function 'org-roam-todo-wf-tools--require-no-unstaged)
                   (lambda () nil))
                  ((symbol-function 'org-roam-todo-wf-tools--require-staged-changes)
                   (lambda () nil))
                  ;; Track git commands
                  ((symbol-function 'call-process)
                   (lambda (program &rest args)
                     (when (string= program "git")
                       (push args git-commands))
                     0))
                  ;; Mock branch-has-commits to return nil (no upstream)
                  ((symbol-function 'org-roam-todo-wf-tools--branch-has-commits-p)
                   (lambda () nil)))
          (org-roam-todo-wf-tools-stage "Test changes" file)
          ;; Should have called git commit with --no-gpg-sign
          (should (cl-some (lambda (cmd) (member "--no-gpg-sign" cmd)) git-commands))))
    (org-roam-todo-wf-tools-test--cleanup)))

(ert-deftest wf-tools-test-stage-managed-commit-no-commit ()
  "Test that :managed-commit only validates, no commit."
  :tags '(:unit :wf :tools :stage)
  (org-roam-todo-wf-test--require-wf)
  (require 'org-roam-todo-wf-tools nil t)
  (unwind-protect
      (let* ((temp-dir (make-temp-file "stage-managed-test-" t))
             (test-data (org-roam-todo-wf-tools-test--create-temp-todo
                         `(:status "active"
                           :title "Managed Commit TODO"
                           :worktree-path ,temp-dir
                           :worktree-branch "test-branch")))
             (file (plist-get test-data :file))
             (commit-called nil))
        (push temp-dir org-roam-todo-wf-tools-test--temp-dirs)
        ;; Create a workflow with :managed-commit strategy
        (let ((managed-workflow (make-org-roam-todo-workflow
                                 :name 'managed-test
                                 :statuses '("draft" "active" "done")
                                 :hooks nil
                                 :config '(:commit-strategy :managed-commit))))
          ;; Mock functions
          (cl-letf (((symbol-function 'org-roam-todo--query-todos)
                     (lambda (&optional _) (list (plist-get test-data :todo))))
                    ((symbol-function 'org-roam-todo-wf--get-workflow)
                     (lambda (_) managed-workflow))
                    ;; Mock validation to pass
                    ((symbol-function 'org-roam-todo-wf-tools--require-no-unstaged)
                     (lambda () nil))
                    ((symbol-function 'org-roam-todo-wf-tools--commit-single)
                     (lambda (_) (setq commit-called t) "committed"))
                    ((symbol-function 'org-roam-todo-wf-tools--commit-new)
                     (lambda (_) (setq commit-called t) "committed")))
            (let ((result (org-roam-todo-wf-tools-stage "Test changes" file)))
              ;; Should NOT have called commit
              (should-not commit-called)
              ;; Should return message about manual commit
              (should (string-match-p "managed-commit" result))))))
    (org-roam-todo-wf-tools-test--cleanup)))

(ert-deftest wf-tools-test-stage-single-commit-amends ()
  "Test that :single-commit amends when branch has commits."
  :tags '(:unit :wf :tools :stage)
  (org-roam-todo-wf-test--require-wf)
  (require 'org-roam-todo-wf-tools nil t)
  (unwind-protect
      (let* ((temp-dir (make-temp-file "stage-amend-test-" t))
             (test-data (org-roam-todo-wf-tools-test--create-temp-todo
                         `(:status "active"
                           :title "Amend Test TODO"
                           :worktree-path ,temp-dir
                           :worktree-branch "test-branch")))
             (file (plist-get test-data :file))
             (amend-called nil)
             (new-commit-called nil))
        (push temp-dir org-roam-todo-wf-tools-test--temp-dirs)
        ;; Create workflow with default :single-commit
        (let ((single-workflow (make-org-roam-todo-workflow
                                :name 'single-test
                                :statuses '("draft" "active" "done")
                                :hooks nil
                                :config '(:commit-strategy :single-commit))))
          ;; Mock functions - branch HAS commits
          (cl-letf (((symbol-function 'org-roam-todo--query-todos)
                     (lambda (&optional _) (list (plist-get test-data :todo))))
                    ((symbol-function 'org-roam-todo-wf--get-workflow)
                     (lambda (_) single-workflow))
                    ;; Mock validation to pass
                    ((symbol-function 'org-roam-todo-wf-tools--require-no-unstaged)
                     (lambda () nil))
                    ((symbol-function 'org-roam-todo-wf-tools--require-staged-changes)
                     (lambda () nil))
                    ((symbol-function 'org-roam-todo-wf-tools--branch-has-commits-p)
                     (lambda () t))  ; Has commits!
                    ((symbol-function 'call-process)
                     (lambda (program &rest args)
                       (when (and (string= program "git")
                                  (member "--amend" args))
                         (setq amend-called t))
                       0)))
            (org-roam-todo-wf-tools-stage "Amend test" file)
            ;; Should have called amend
            (should amend-called))))
    (org-roam-todo-wf-tools-test--cleanup)))

(ert-deftest wf-tools-test-stage-many-commit-always-new ()
  "Test that :many-commit always creates new commits."
  :tags '(:unit :wf :tools :stage)
  (org-roam-todo-wf-test--require-wf)
  (require 'org-roam-todo-wf-tools nil t)
  (unwind-protect
      (let* ((temp-dir (make-temp-file "stage-many-test-" t))
             (test-data (org-roam-todo-wf-tools-test--create-temp-todo
                         `(:status "active"
                           :title "Many Commit TODO"
                           :worktree-path ,temp-dir
                           :worktree-branch "test-branch")))
             (file (plist-get test-data :file))
             (amend-called nil)
             (new-commit-called nil))
        (push temp-dir org-roam-todo-wf-tools-test--temp-dirs)
        ;; Create workflow with :many-commit
        (let ((many-workflow (make-org-roam-todo-workflow
                              :name 'many-test
                              :statuses '("draft" "active" "done")
                              :hooks nil
                              :config '(:commit-strategy :many-commit))))
          ;; Mock functions - branch HAS commits but should NOT amend
          (cl-letf (((symbol-function 'org-roam-todo--query-todos)
                     (lambda (&optional _) (list (plist-get test-data :todo))))
                    ((symbol-function 'org-roam-todo-wf--get-workflow)
                     (lambda (_) many-workflow))
                    ;; Mock validation to pass
                    ((symbol-function 'org-roam-todo-wf-tools--require-no-unstaged)
                     (lambda () nil))
                    ((symbol-function 'org-roam-todo-wf-tools--require-staged-changes)
                     (lambda () nil))
                    ((symbol-function 'org-roam-todo-wf-tools--branch-has-commits-p)
                     (lambda () t))  ; Has commits, but shouldn't matter
                    ((symbol-function 'call-process)
                     (lambda (program &rest args)
                       (when (string= program "git")
                         (when (member "--amend" args)
                           (setq amend-called t))
                         (when (and (member "commit" args)
                                    (not (member "--amend" args)))
                           (setq new-commit-called t)))
                       0)))
            (org-roam-todo-wf-tools-stage "New commit test" file)
            ;; Should NOT have called amend
            (should-not amend-called)
            ;; Should have created new commit
            (should new-commit-called))))
    (org-roam-todo-wf-tools-test--cleanup)))

(ert-deftest wf-tools-test-stage-errors-on-unstaged-changes ()
  "Test that stage-changes errors when there are unstaged changes."
  :tags '(:unit :wf :tools :stage)
  (org-roam-todo-wf-test--require-wf)
  (require 'org-roam-todo-wf-tools nil t)
  (unwind-protect
      (let* ((temp-dir (make-temp-file "stage-unstaged-test-" t))
             (test-data (org-roam-todo-wf-tools-test--create-temp-todo
                         `(:status "active"
                           :title "Unstaged Test TODO"
                           :worktree-path ,temp-dir
                           :worktree-branch "test-branch")))
             (file (plist-get test-data :file))
             (mock-workflow (make-org-roam-todo-workflow
                             :name 'test-wf
                             :statuses '("draft" "active" "done")
                             :hooks nil
                             :config nil)))
        (push temp-dir org-roam-todo-wf-tools-test--temp-dirs)
        ;; Mock functions - require-no-unstaged will error
        (cl-letf (((symbol-function 'org-roam-todo--query-todos)
                   (lambda (&optional _) (list (plist-get test-data :todo))))
                  ((symbol-function 'org-roam-todo-wf--get-workflow)
                   (lambda (_) mock-workflow))
                  ;; This validation fails - there are unstaged changes
                  ((symbol-function 'org-roam-todo-wf-tools--require-no-unstaged)
                   (lambda () (user-error "Unstaged changes detected"))))
          (should-error
           (org-roam-todo-wf-tools-stage "Test" file)
           :type 'user-error)))
    (org-roam-todo-wf-tools-test--cleanup)))

(ert-deftest wf-tools-test-stage-errors-on-no-staged-changes ()
  "Test that stage-changes errors when there are no staged changes."
  :tags '(:unit :wf :tools :stage)
  (org-roam-todo-wf-test--require-wf)
  (require 'org-roam-todo-wf-tools nil t)
  (unwind-protect
      (let* ((temp-dir (make-temp-file "stage-nostaged-test-" t))
             (test-data (org-roam-todo-wf-tools-test--create-temp-todo
                         `(:status "active"
                           :title "No Staged Test TODO"
                           :worktree-path ,temp-dir
                           :worktree-branch "test-branch")))
             (file (plist-get test-data :file))
             (mock-workflow (make-org-roam-todo-workflow
                             :name 'test-wf
                             :statuses '("draft" "active" "done")
                             :hooks nil
                             :config nil)))
        (push temp-dir org-roam-todo-wf-tools-test--temp-dirs)
        ;; Mock functions - no unstaged (passes), no staged (fails)
        (cl-letf (((symbol-function 'org-roam-todo--query-todos)
                   (lambda (&optional _) (list (plist-get test-data :todo))))
                  ((symbol-function 'org-roam-todo-wf--get-workflow)
                   (lambda (_) mock-workflow))
                  ;; First validation passes
                  ((symbol-function 'org-roam-todo-wf-tools--require-no-unstaged)
                   (lambda () nil))
                  ;; Second validation fails - no staged changes
                  ((symbol-function 'org-roam-todo-wf-tools--require-staged-changes)
                   (lambda () (user-error "No staged changes"))))
          (should-error
           (org-roam-todo-wf-tools-stage "Test" file)
           :type 'user-error)))
    (org-roam-todo-wf-tools-test--cleanup)))

(provide 'org-roam-todo-wf-tools-test)
;;; org-roam-todo-wf-tools-test.el ends here
