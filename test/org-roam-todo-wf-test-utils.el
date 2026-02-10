;;; org-roam-todo-wf-test-utils.el --- Test utilities for workflow tests -*- lexical-binding: t; -*-

;; Author: Claude Code
;; Version: 0.1.0
;; Package-Requires: ((emacs "28.1") (ert "1.0") (mocker "0.5"))

;;; Commentary:
;; Test utilities for the org-roam-todo workflow system.
;; Provides:
;; - Temporary TODO file creation/cleanup
;; - Mock workflow setup
;; - Git repository scaffolding for integration tests
;; - Mocker.el helper macros
;;
;; Usage:
;;   (require 'org-roam-todo-wf-test-utils)
;;
;;   (ert-deftest my-test ()
;;     (org-roam-todo-wf-test-with-temp-todo
;;         '(:title "Test" :status "draft")
;;       ;; todo-file and todo-plist are bound
;;       (should (file-exists-p todo-file))))

;;; Code:

(require 'ert)
(require 'cl-lib)

;; Try to load mocker - tests will skip if not available
(condition-case nil
    (require 'mocker)
  (error
   (message "Warning: mocker.el not available. Some tests will be skipped.")))

;;; ============================================================
;;; Temporary TODO File Creation
;;; ============================================================

(defun org-roam-todo-wf-test--generate-todo-content (props)
  "Generate org content from PROPS plist.
PROPS can include:
  :id            - TODO ID (auto-generated if nil)
  :title         - TODO title (default: \"Test TODO\")
  :status        - Status string (default: \"draft\")
  :project-name  - Project name (default: \"test-project\")
  :project-root  - Project root (default: temp-dir)
  :worktree-path - Worktree path (optional)
  :worktree-branch - Branch name (optional)
  :target-branch - Target branch for subtasks (optional)
  :parent-todo   - Parent TODO ID for subtasks (optional)
  :workflow      - Workflow symbol (optional)
  :subtask-workflow - Workflow for child TODOs (optional)
  :description   - Task description (optional)
  :acceptance-criteria - Criteria text (optional)"
  (let ((id (or (plist-get props :id) (format "test-%s" (random 100000))))
        (title (or (plist-get props :title) "Test TODO"))
        (status (or (plist-get props :status) "draft"))
        (project-name (or (plist-get props :project-name) "test-project"))
        (project-root (or (plist-get props :project-root) "/tmp/test-project"))
        (worktree-path (plist-get props :worktree-path))
        (worktree-branch (plist-get props :worktree-branch))
        (target-branch (plist-get props :target-branch))
        (parent-todo (plist-get props :parent-todo))
        (workflow (plist-get props :workflow))
        (subtask-workflow (plist-get props :subtask-workflow))
        (description (or (plist-get props :description) "Test task description."))
        (criteria (or (plist-get props :acceptance-criteria)
                      "- [ ] First criterion\n- [ ] Second criterion")))
    (concat
     ":PROPERTIES:\n"
     (format ":ID: %s\n" id)
     (format ":PROJECT_NAME: %s\n" project-name)
     (format ":PROJECT_ROOT: %s\n" project-root)
     (format ":STATUS: %s\n" status)
     (when worktree-path (format ":WORKTREE_PATH: %s\n" worktree-path))
     (when worktree-branch (format ":WORKTREE_BRANCH: %s\n" worktree-branch))
     (when target-branch (format ":TARGET_BRANCH: %s\n" target-branch))
     (when parent-todo (format ":PARENT_TODO: %s\n" parent-todo))
     (when workflow (format ":WORKFLOW: %s\n" workflow))
     (when subtask-workflow (format ":SUBTASK_WORKFLOW: %s\n" subtask-workflow))
     ":END:\n"
     (format "#+title: %s\n\n" title)
     "** Task Description\n"
     description "\n\n"
     "** Acceptance Criteria\n"
     criteria "\n\n"
     "** Progress Log\n")))

(defun org-roam-todo-wf-test--cleanup-temp-dir (dir)
  "Clean up temporary directory DIR and any visiting buffers."
  (when dir
    ;; Kill any buffers visiting files in this directory
    (dolist (buf (buffer-list))
      (when-let ((file (buffer-file-name buf)))
        (when (string-prefix-p (expand-file-name dir) (expand-file-name file))
          (with-current-buffer buf
            (set-buffer-modified-p nil))
          (kill-buffer buf))))
    ;; Delete the directory
    (when (file-exists-p dir)
      (delete-directory dir t))))

(defmacro org-roam-todo-wf-test-with-temp-todo (properties &rest body)
  "Execute BODY with a temporary TODO file.
PROPERTIES is a plist of TODO properties (see `org-roam-todo-wf-test--generate-todo-content').
Binds:
  `todo-file'  - Path to the temporary TODO file
  `todo-plist' - Plist representation of the TODO for hook functions (with :file set)"
  (declare (indent 1) (debug (form body)))
  `(let* ((temp-dir (make-temp-file "wf-test-" t))
          (todo-file (expand-file-name "test-todo.org" temp-dir))
          (props ,properties)
          (todo-plist nil)
          (inhibit-message t))
     (unwind-protect
         (progn
           ;; Create TODO file from properties
           (with-temp-file todo-file
             (insert (org-roam-todo-wf-test--generate-todo-content props)))
           ;; Build plist for hook functions (mirrors what workflow engine provides)
           ;; IMPORTANT: :file must be set for org-roam-todo-prop to work
           (setq todo-plist
                 (list :file todo-file
                       :id (or (plist-get props :id) "test-id")
                       :title (or (plist-get props :title) "Test TODO")
                       :status (or (plist-get props :status) "draft")
                       :project-name (or (plist-get props :project-name) "test-project")
                       :project-root (or (plist-get props :project-root) temp-dir)
                       :worktree-path (plist-get props :worktree-path)
                       :worktree-branch (plist-get props :worktree-branch)
                       :target-branch (plist-get props :target-branch)
                       :parent-todo (plist-get props :parent-todo)
                       :workflow (plist-get props :workflow)
                       :subtask-workflow (plist-get props :subtask-workflow)))
           ,@body)
       ;; Cleanup
       (org-roam-todo-wf-test--cleanup-temp-dir temp-dir))))

(defun org-roam-todo-wf-test--create-todo-file (dir props)
  "Create a TODO file in DIR with PROPS and return the file path.
PROPS is a plist - see `org-roam-todo-wf-test--generate-todo-content'.
This is useful for integration tests that need a real file for `org-roam-todo-prop'."
  (let ((todo-file (expand-file-name "test-todo.org" dir)))
    (with-temp-file todo-file
      (insert (org-roam-todo-wf-test--generate-todo-content props)))
    todo-file))

(defun org-roam-todo-wf-test--make-event-with-file (todo-file workflow &optional old-status new-status)
  "Create an event with a TODO plist that has :file set to TODO-FILE.
WORKFLOW is the workflow struct.
OLD-STATUS and NEW-STATUS are optional status strings.
The event's todo plist will have :file set so org-roam-todo-prop can read from it."
  (make-org-roam-todo-event
   :todo (list :file todo-file)
   :workflow workflow
   :old-status old-status
   :new-status new-status))

;;; ============================================================
;;; Git Repository for Integration Tests
;;; ============================================================

(defmacro org-roam-todo-wf-test-with-git-repo (&rest body)
  "Execute BODY with a real git repository for integration tests.
Binds `repo-dir' to the repository path.
Initializes git with a basic config and initial commit."
  (declare (indent 0) (debug (body)))
  `(let* ((repo-dir (make-temp-file "wf-test-repo-" t))
          (inhibit-message t))
     (unwind-protect
         (progn
           ;; Initialize git repo with error checking
           (let ((default-directory repo-dir))
             (unless (= 0 (call-process "git" nil nil nil "init"))
               (error "Failed to init git repo"))
             (unless (= 0 (call-process "git" nil nil nil "config" "user.email" "test@test.com"))
               (error "Failed to configure git email"))
             (unless (= 0 (call-process "git" nil nil nil "config" "user.name" "Test User"))
               (error "Failed to configure git name"))
             ;; Disable GPG signing for test repo (user may have it enabled globally)
             (call-process "git" nil nil nil "config" "commit.gpgsign" "false")
             ;; Create initial commit - need a file to commit
             (with-temp-file (expand-file-name "README.md" repo-dir)
               (insert "# Test Repository\n"))
             (unless (= 0 (call-process "git" nil nil nil "add" "README.md"))
               (error "Failed to stage README.md"))
             (unless (= 0 (call-process "git" nil nil nil "commit" "-m" "Initial commit"))
               (error "Failed to create initial commit")))
           ,@body)
       (org-roam-todo-wf-test--cleanup-temp-dir repo-dir))))

(defmacro org-roam-todo-wf-test-with-git-worktree (&rest body)
  "Execute BODY with a git repo that has a feature branch and worktree.
Binds:
  `repo-dir'     - Main repository path
  `worktree-dir' - Worktree path
  `branch-name'  - Feature branch name"
  (declare (indent 0) (debug (body)))
  `(org-roam-todo-wf-test-with-git-repo
     (let* ((worktree-dir (make-temp-file "wf-test-worktree-" t))
            (branch-name "test-feature")
            (default-directory repo-dir))
       ;; Clean up the pre-made worktree-dir (we need it empty for git worktree add)
       (delete-directory worktree-dir t)
       (unwind-protect
           (progn
             ;; Create feature branch and worktree
             (call-process "git" nil nil nil "worktree" "add" "-b" branch-name worktree-dir)
             ,@body)
         ;; Cleanup worktree
         (let ((default-directory repo-dir))
           (call-process "git" nil nil nil "worktree" "remove" "--force" worktree-dir)
           (ignore-errors (call-process "git" nil nil nil "branch" "-D" branch-name)))
         (org-roam-todo-wf-test--cleanup-temp-dir worktree-dir)))))

;;; ============================================================
;;; Git Repository State Helpers
;;; ============================================================

(defun org-roam-todo-wf-test--git (repo-dir &rest args)
  "Run git command with ARGS in REPO-DIR.
Returns (exit-code . output) cons cell."
  (let ((default-directory repo-dir))
    (with-temp-buffer
      (let ((exit-code (apply #'call-process "git" nil t nil args)))
        (cons exit-code (string-trim (buffer-string)))))))

(defun org-roam-todo-wf-test--git! (repo-dir &rest args)
  "Run git command with ARGS in REPO-DIR.  Signal error on failure.
Returns output string on success."
  (let ((result (apply #'org-roam-todo-wf-test--git repo-dir args)))
    (unless (= 0 (car result))
      (error "git %s failed: %s" (string-join args " ") (cdr result)))
    (cdr result)))

(defun org-roam-todo-wf-test--create-branch (repo-dir branch-name &optional base-ref)
  "Create BRANCH-NAME in REPO-DIR from BASE-REF (default HEAD).
Does not check out the branch."
  (org-roam-todo-wf-test--git! repo-dir
                               "branch" branch-name (or base-ref "HEAD")))

(defun org-roam-todo-wf-test--checkout (repo-dir branch-or-ref)
  "Checkout BRANCH-OR-REF in REPO-DIR."
  (org-roam-todo-wf-test--git! repo-dir "checkout" branch-or-ref))

(defun org-roam-todo-wf-test--create-file (repo-dir filename &optional content)
  "Create FILENAME in REPO-DIR with optional CONTENT.
Returns the full path to the created file."
  (let ((filepath (expand-file-name filename repo-dir)))
    (make-directory (file-name-directory filepath) t)
    (with-temp-file filepath
      (insert (or content (format "Content of %s\n" filename))))
    filepath))

(defun org-roam-todo-wf-test--stage-file (repo-dir filename &optional content)
  "Create and stage FILENAME in REPO-DIR with optional CONTENT.
Returns the full path to the created file."
  (let ((filepath (org-roam-todo-wf-test--create-file repo-dir filename content)))
    (org-roam-todo-wf-test--git! repo-dir "add" filename)
    filepath))

(defun org-roam-todo-wf-test--commit (repo-dir message)
  "Create a commit in REPO-DIR with MESSAGE.
Returns the commit SHA."
  (org-roam-todo-wf-test--git! repo-dir "commit" "-m" message)
  (org-roam-todo-wf-test--git! repo-dir "rev-parse" "HEAD"))

(defun org-roam-todo-wf-test--add-commit (repo-dir filename message &optional content)
  "Add FILENAME with CONTENT and commit with MESSAGE in REPO-DIR.
Convenience function for creating a commit with a single file.
Returns the commit SHA."
  (org-roam-todo-wf-test--stage-file repo-dir filename content)
  (org-roam-todo-wf-test--commit repo-dir message))

(defun org-roam-todo-wf-test--create-worktree (repo-dir worktree-path branch-name &optional base-ref)
  "Create a worktree at WORKTREE-PATH for BRANCH-NAME in REPO-DIR.
If branch doesn't exist, creates it from BASE-REF (default HEAD).
Returns the worktree path."
  ;; Ensure worktree-path directory doesn't exist (git worktree add requires this)
  (when (file-exists-p worktree-path)
    (delete-directory worktree-path t))
  (org-roam-todo-wf-test--git! repo-dir
                               "worktree" "add"
                               "-b" branch-name
                               worktree-path
                               (or base-ref "HEAD"))
  worktree-path)

(defun org-roam-todo-wf-test--remove-worktree (repo-dir worktree-path &optional delete-branch)
  "Remove worktree at WORKTREE-PATH from REPO-DIR.
If DELETE-BRANCH is non-nil, also delete the associated branch."
  (let ((branch (cdr (org-roam-todo-wf-test--git
                      repo-dir "rev-parse" "--abbrev-ref"
                      (format "--path=%s" worktree-path)))))
    (org-roam-todo-wf-test--git repo-dir "worktree" "remove" "--force" worktree-path)
    (when (and delete-branch branch (not (string= branch "HEAD")))
      (org-roam-todo-wf-test--git repo-dir "branch" "-D" branch))))

(defun org-roam-todo-wf-test--current-branch (repo-dir)
  "Get the current branch name in REPO-DIR."
  (org-roam-todo-wf-test--git! repo-dir "rev-parse" "--abbrev-ref" "HEAD"))

(defun org-roam-todo-wf-test--branch-exists-p (repo-dir branch-name)
  "Return non-nil if BRANCH-NAME exists in REPO-DIR."
  (= 0 (car (org-roam-todo-wf-test--git
             repo-dir "rev-parse" "--verify" branch-name))))

(defun org-roam-todo-wf-test--has-staged-changes-p (repo-dir)
  "Return non-nil if REPO-DIR has staged changes."
  (not (string-empty-p
        (org-roam-todo-wf-test--git! repo-dir "diff" "--cached" "--name-only"))))

(defun org-roam-todo-wf-test--has-unstaged-changes-p (repo-dir)
  "Return non-nil if REPO-DIR has unstaged changes."
  (not (string-empty-p
        (org-roam-todo-wf-test--git! repo-dir "diff" "--name-only"))))

(defun org-roam-todo-wf-test--is-clean-p (repo-dir)
  "Return non-nil if REPO-DIR has no uncommitted changes."
  (string-empty-p
   (org-roam-todo-wf-test--git! repo-dir "status" "--porcelain")))

(defun org-roam-todo-wf-test--commit-count (repo-dir &optional branch)
  "Return the number of commits in REPO-DIR on BRANCH (default HEAD)."
  (string-to-number
   (org-roam-todo-wf-test--git! repo-dir "rev-list" "--count" (or branch "HEAD"))))

(defun org-roam-todo-wf-test--is-ancestor-p (repo-dir ancestor-ref descendant-ref)
  "Return non-nil if ANCESTOR-REF is an ancestor of DESCENDANT-REF in REPO-DIR."
  (= 0 (car (org-roam-todo-wf-test--git
             repo-dir "merge-base" "--is-ancestor" ancestor-ref descendant-ref))))

(defun org-roam-todo-wf-test--setup-diverged-branches (repo-dir main-branch feature-branch)
  "Set up REPO-DIR with diverged MAIN-BRANCH and FEATURE-BRANCH.
Creates commits on both branches so they have diverged.
Returns plist with :main-sha and :feature-sha."
  ;; Add a commit to main
  (org-roam-todo-wf-test--checkout repo-dir main-branch)
  (let ((main-sha (org-roam-todo-wf-test--add-commit
                   repo-dir "main-change.txt" "Add main change"
                   "Change on main branch\n")))
    ;; Checkout feature and add a commit
    (org-roam-todo-wf-test--checkout repo-dir feature-branch)
    (let ((feature-sha (org-roam-todo-wf-test--add-commit
                        repo-dir "feature-change.txt" "Add feature change"
                        "Change on feature branch\n")))
      (list :main-sha main-sha :feature-sha feature-sha))))

(defun org-roam-todo-wf-test--setup-conflict (repo-dir main-branch feature-branch filename)
  "Set up REPO-DIR with conflicting changes to FILENAME on both branches.
Returns plist with :main-sha, :feature-sha, and :filename."
  ;; Add conflicting change to main
  (org-roam-todo-wf-test--checkout repo-dir main-branch)
  (let ((main-sha (org-roam-todo-wf-test--add-commit
                   repo-dir filename "Add main version"
                   "Main branch content\n")))
    ;; Reset feature to before main's change and add conflicting content
    (org-roam-todo-wf-test--checkout repo-dir feature-branch)
    ;; Reset to the commit before main's change
    (org-roam-todo-wf-test--git! repo-dir "reset" "--hard" "HEAD~1")
    (let ((feature-sha (org-roam-todo-wf-test--add-commit
                        repo-dir filename "Add feature version"
                        "Feature branch content\n")))
      (list :main-sha main-sha
            :feature-sha feature-sha
            :filename filename))))

;;; ============================================================
;;; Mock Workflow for Testing
;;; ============================================================

;; We'll define the struct here for testing, but the real one comes from org-roam-todo-wf.el
;; This allows tests to run before the implementation exists
(unless (fboundp 'make-org-roam-todo-workflow)
  (cl-defstruct org-roam-todo-workflow
    "A TODO workflow definition (test stub)."
    name           ; Symbol: 'github-pr, 'local-ff
    statuses       ; List of status strings in order
    hooks          ; Alist: ((event-symbol . (functions...)) ...)
    config))       ; Plist of workflow-specific settings

(unless (fboundp 'make-org-roam-todo-event)
  (cl-defstruct org-roam-todo-event
    "Context passed to all hook functions (test stub)."
    type           ; Symbol: 'status-changed, ':on-enter-active, etc.
    todo           ; The TODO plist
    workflow       ; The workflow struct
    old-status     ; Previous status (for status-changed events)
    new-status     ; New status (for status-changed events)
    actor))        ; Symbol: 'human or 'ai - who is performing the action

(defvar org-roam-todo-wf-test--mock-workflow nil
  "Mock workflow for testing.")

(defvar org-roam-todo-wf-test--hook-calls nil
  "List of hook calls for verification. Each entry is (event-type event).")

(defun org-roam-todo-wf-test--reset-hook-calls ()
  "Reset the hook call tracking."
  (setq org-roam-todo-wf-test--hook-calls nil))

(defun org-roam-todo-wf-test--mock-enter-active (event)
  "Mock hook that records it was called."
  (push (list :on-enter-active event) org-roam-todo-wf-test--hook-calls)
  nil)

(defun org-roam-todo-wf-test--mock-exit-active (event)
  "Mock exit hook that records it was called."
  (push (list :on-exit-active event) org-roam-todo-wf-test--hook-calls)
  nil)

(defun org-roam-todo-wf-test--mock-validate-review (event)
  "Mock validation hook - fails if :should-fail is in TODO's :extra plist."
  (push (list :validate-review event) org-roam-todo-wf-test--hook-calls)
  (when (plist-get (plist-get (org-roam-todo-event-todo event) :extra) :should-fail)
    (user-error "Validation failed (mock)")))

(defun org-roam-todo-wf-test--mock-validate-active (event)
  "Mock validation hook for active status."
  (push (list :validate-active event) org-roam-todo-wf-test--hook-calls)
  (when (plist-get (plist-get (org-roam-todo-event-todo event) :extra) :should-fail)
    (user-error "Validation failed (mock)")))

(defun org-roam-todo-wf-test--setup-mock-workflow ()
  "Create a simple mock workflow for testing.
Workflow: draft -> active -> review -> done
Allows backward: review -> active
Hooks: :on-enter-active, :validate-review"
  (org-roam-todo-wf-test--reset-hook-calls)
  (setq org-roam-todo-wf-test--mock-workflow
        (make-org-roam-todo-workflow
         :name 'test-workflow
         :statuses '("draft" "active" "review" "done")
         :hooks '((:on-enter-active . (org-roam-todo-wf-test--mock-enter-active))
                  (:on-exit-active . (org-roam-todo-wf-test--mock-exit-active))
                  (:validate-review . (org-roam-todo-wf-test--mock-validate-review))
                  (:validate-active . (org-roam-todo-wf-test--mock-validate-active)))
         :config '(:allow-backward (review)
                   :rebase-target "main"))))

(defun org-roam-todo-wf-test--hook-was-called-p (event-type)
  "Return non-nil if a hook for EVENT-TYPE was called."
  (cl-find event-type org-roam-todo-wf-test--hook-calls :key #'car))

(defun org-roam-todo-wf-test--hook-call-count (event-type)
  "Return number of times hooks for EVENT-TYPE were called."
  (cl-count event-type org-roam-todo-wf-test--hook-calls :key #'car))

;;; ============================================================
;;; Mocker Helpers
;;; ============================================================

(defun org-roam-todo-wf-test--shell-regex-matcher (pattern)
  "Return a mocker matcher that matches shell commands against PATTERN regex."
  (lambda (cmd)
    (string-match-p pattern cmd)))

;; Convenience macro for common shell mocking patterns
(defmacro org-roam-todo-wf-test-with-mocked-shell (specs &rest body)
  "Execute BODY with shell-command-to-string mocked per SPECS.
SPECS is a list of (REGEX . RESPONSE) pairs.

Example:
  (org-roam-todo-wf-test-with-mocked-shell
      ((\"git status\" . \"\")
       (\"gh pr checks\" . \"SUCCESS\"))
    (should (eq \\='success (get-ci-status))))"
  (declare (indent 1) (debug (form body)))
  (if (featurep 'mocker)
      (let ((mocker-specs
             (mapcar (lambda (spec)
                       `(:input-matcher
                         (lambda (cmd) (string-match-p ,(car spec) cmd))
                         :output ,(cdr spec)))
                     specs)))
        `(mocker-let
             ((shell-command-to-string (cmd)
                (,@mocker-specs
                 ;; Fallback: error on unexpected calls
                 (:input-matcher (lambda (_) t)
                  :output-generator
                  (lambda (cmd)
                    (error "Unexpected shell command: %s" cmd))))))
           ,@body))
    ;; If mocker not available, skip
    `(progn
       (ert-skip "mocker.el not available")
       ,@body)))

(defmacro org-roam-todo-wf-test-with-mocked-git (staged-p clean-p &rest body)
  "Execute BODY with common git operations mocked.
STAGED-P - whether there are staged changes
CLEAN-P  - whether the worktree is clean (no uncommitted changes)"
  (declare (indent 2) (debug (form form body)))
  `(org-roam-todo-wf-test-with-mocked-shell
       (("git status --porcelain" . ,(if clean-p "" " M dirty.txt"))
        ("git diff --cached --quiet" . ,(if staged-p "M staged.txt" "")))
     ,@body))

;;; ============================================================
;;; Assertion Helpers
;;; ============================================================

(defun org-roam-todo-wf-test--file-contains-p (file pattern)
  "Return non-nil if FILE contains text matching PATTERN."
  (with-temp-buffer
    (insert-file-contents file)
    (string-match-p pattern (buffer-string))))

(defun org-roam-todo-wf-test--get-file-property (file property)
  "Get PROPERTY value from org FILE."
  (with-temp-buffer
    (insert-file-contents file)
    (goto-char (point-min))
    (when (re-search-forward (format "^:%s:[ \t]+\\(.+\\)$" property) nil t)
      (string-trim (match-string 1)))))

;;; ============================================================
;;; Skip Helpers
;;; ============================================================

(defun org-roam-todo-wf-test--require-mocker ()
  "Skip test if mocker.el is not available."
  (unless (featurep 'mocker)
    (ert-skip "mocker.el not available")))

(defun org-roam-todo-wf-test--require-git ()
  "Skip test if git is not available."
  (unless (executable-find "git")
    (ert-skip "git not available")))

(defun org-roam-todo-wf-test--require-wf ()
  "Skip test if org-roam-todo-wf is not loaded."
  (unless (featurep 'org-roam-todo-wf)
    (ert-skip "org-roam-todo-wf not loaded")))

;;; ============================================================
;;; Always Helper (for mocker)
;;; ============================================================

(defun always (&rest _args)
  "Return t for any arguments. Useful as mocker input-matcher."
  t)

;;; ============================================================
;;; Mock Property Helpers
;;; ============================================================

(defun org-roam-todo-wf-test--make-prop-mock-specs (prop-alist)
  "Create mocker specs for org-roam-todo-prop from PROP-ALIST.
PROP-ALIST is an alist of (PROPERTY-NAME . VALUE) pairs.
Returns a list of mocker record specs that:
1. Match each specified property and return its value
2. Return nil for any unspecified properties (catch-all)

Example:
  (org-roam-todo-wf-test--make-prop-mock-specs
   \\='((\"PROJECT_ROOT\" . \"/tmp/project\")
     (\"WORKTREE_PATH\" . \"/tmp/worktree\")))"
  (append
   ;; Specific property matchers
   (mapcar (lambda (pair)
             `(:input-matcher
               (lambda (e p) (string= p ,(car pair)))
               :output ,(cdr pair)))
           prop-alist)
   ;; Catch-all for any other properties - return nil
   '((:input-matcher (lambda (e p) t) :output nil))))

(provide 'org-roam-todo-wf-test-utils)
;;; org-roam-todo-wf-test-utils.el ends here
