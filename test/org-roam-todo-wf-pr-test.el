;;; org-roam-todo-wf-pr-test.el --- Pull request workflow tests -*- lexical-binding: t; -*-

;; Author: Claude Code
;; Version: 0.1.0
;; Package-Requires: ((emacs "28.1") (ert "1.0") (mocker "0.5"))

;;; Commentary:
;; Tests for the pull-request workflow which provides forge-based PR integration.
;;
;; Workflow: draft -> active -> ci -> ready -> review -> done
;; - draft: TODO exists, no work started
;; - active: Worktree created, work in progress
;; - ci: Draft PR created, waiting for CI to pass
;; - ready: CI passed, PR ready for human review
;; - review: PR submitted for external review
;; - done: PR merged, cleaned up

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'org-roam-todo-wf)
(require 'org-roam-todo-wf-actions)
(require 'org-roam-todo-wf-test-utils)

;; Try to load mocker
(condition-case nil
    (require 'mocker)
  (error
   (message "Warning: mocker.el not available. Some tests will be skipped.")))

;; Mock forge types for testing
(cl-defstruct (org-roam-todo-wf-pr-test--mock-pullreq
               (:constructor make-org-roam-todo-wf-pr-test--mock-pullreq))
  "Mock pullreq struct for testing."
  (state 'open)
  (draft-p nil)
  (their-id "PR123")
  (number 42))

(cl-defstruct (org-roam-todo-wf-pr-test--mock-github-repo
               (:constructor make-org-roam-todo-wf-pr-test--mock-github-repo))
  "Mock GitHub repository struct for testing.
Named with 'github' so `org-roam-todo-wf-pr--repo-type' detects it correctly."
  (remote "origin")
  (owner "test-owner")
  (name "test-repo"))

(cl-defstruct (org-roam-todo-wf-pr-test--mock-gitlab-repo
               (:constructor make-org-roam-todo-wf-pr-test--mock-gitlab-repo))
  "Mock GitLab repository struct for testing.
Named with 'gitlab' so `org-roam-todo-wf-pr--repo-type' detects it correctly."
  (remote "origin")
  (owner "test-owner")
  (name "test-repo")
  (forge-id 12345))

;; Make oref work with our mock structs
(defun org-roam-todo-wf-pr-test--oref-advice (orig-fn obj slot)
  "Advice to handle mock objects in oref calls."
  (cond
   ((org-roam-todo-wf-pr-test--mock-pullreq-p obj)
    (pcase slot
      ('state (org-roam-todo-wf-pr-test--mock-pullreq-state obj))
      ('draft-p (org-roam-todo-wf-pr-test--mock-pullreq-draft-p obj))
      ('their-id (org-roam-todo-wf-pr-test--mock-pullreq-their-id obj))
      ('number (org-roam-todo-wf-pr-test--mock-pullreq-number obj))))
   ((org-roam-todo-wf-pr-test--mock-github-repo-p obj)
    (pcase slot
      ('remote (org-roam-todo-wf-pr-test--mock-github-repo-remote obj))
      ('owner (org-roam-todo-wf-pr-test--mock-github-repo-owner obj))
      ('name (org-roam-todo-wf-pr-test--mock-github-repo-name obj))))
   ((org-roam-todo-wf-pr-test--mock-gitlab-repo-p obj)
    (pcase slot
      ('remote (org-roam-todo-wf-pr-test--mock-gitlab-repo-remote obj))
      ('owner (org-roam-todo-wf-pr-test--mock-gitlab-repo-owner obj))
      ('name (org-roam-todo-wf-pr-test--mock-gitlab-repo-name obj))
      ('forge-id (org-roam-todo-wf-pr-test--mock-gitlab-repo-forge-id obj))))
   (t (funcall orig-fn obj slot))))

;;; ============================================================
;;; Workflow Definition Tests
;;; ============================================================

(ert-deftest wf-pr-test-workflow-registered ()
  "Test that pull-request workflow is registered after requiring the module."
  :tags '(:unit :wf :pr)
  (org-roam-todo-wf-test--require-wf)
  (require 'org-roam-todo-wf-pr nil t)
  (let ((wf (gethash 'pull-request org-roam-todo-wf--registry)))
    (should wf)
    (should (eq 'pull-request (org-roam-todo-workflow-name wf)))))

(ert-deftest wf-pr-test-workflow-statuses ()
  "Test that pull-request workflow has correct statuses."
  :tags '(:unit :wf :pr)
  (org-roam-todo-wf-test--require-wf)
  (require 'org-roam-todo-wf-pr nil t)
  (let ((wf (gethash 'pull-request org-roam-todo-wf--registry)))
    (should wf)
    (should (equal '("draft" "active" "ci" "ready" "review" "done")
                   (org-roam-todo-workflow-statuses wf)))))

(ert-deftest wf-pr-test-workflow-allows-backward ()
  "Test that pull-request workflow allows regressing from ci and ready."
  :tags '(:unit :wf :pr)
  (org-roam-todo-wf-test--require-wf)
  (require 'org-roam-todo-wf-pr nil t)
  (let ((wf (gethash 'pull-request org-roam-todo-wf--registry)))
    (should wf)
    (let ((config (org-roam-todo-workflow-config wf)))
      (should (member 'ci (plist-get config :allow-backward)))
      (should (member 'ready (plist-get config :allow-backward))))))

;;; ============================================================
;;; Hook Registration Tests
;;; ============================================================

(ert-deftest wf-pr-test-has-enter-active-hook ()
  "Test that pull-request workflow has :on-enter-active hooks."
  :tags '(:unit :wf :pr)
  (org-roam-todo-wf-test--require-wf)
  (require 'org-roam-todo-wf-pr nil t)
  (let* ((wf (gethash 'pull-request org-roam-todo-wf--registry))
         (hooks (org-roam-todo-workflow-hooks wf)))
    (should (assq :on-enter-active hooks))))

(ert-deftest wf-pr-test-has-validate-ci-hook ()
  "Test that pull-request workflow has :validate-ci hooks."
  :tags '(:unit :wf :pr)
  (org-roam-todo-wf-test--require-wf)
  (require 'org-roam-todo-wf-pr nil t)
  (let* ((wf (gethash 'pull-request org-roam-todo-wf--registry))
         (hooks (org-roam-todo-workflow-hooks wf)))
    (should (assq :validate-ci hooks))))

(ert-deftest wf-pr-test-has-enter-ci-hook ()
  "Test that pull-request workflow has :on-enter-ci hooks."
  :tags '(:unit :wf :pr)
  (org-roam-todo-wf-test--require-wf)
  (require 'org-roam-todo-wf-pr nil t)
  (let* ((wf (gethash 'pull-request org-roam-todo-wf--registry))
         (hooks (org-roam-todo-workflow-hooks wf)))
    (should (assq :on-enter-ci hooks))))

(ert-deftest wf-pr-test-has-enter-ready-hook ()
  "Test that pull-request workflow has :on-enter-ready hooks."
  :tags '(:unit :wf :pr)
  (org-roam-todo-wf-test--require-wf)
  (require 'org-roam-todo-wf-pr nil t)
  (let* ((wf (gethash 'pull-request org-roam-todo-wf--registry))
         (hooks (org-roam-todo-workflow-hooks wf)))
    (should (assq :on-enter-ready hooks))))

(ert-deftest wf-pr-test-has-enter-done-hook ()
  "Test that pull-request workflow has :on-enter-done hooks."
  :tags '(:unit :wf :pr)
  (org-roam-todo-wf-test--require-wf)
  (require 'org-roam-todo-wf-pr nil t)
  (let* ((wf (gethash 'pull-request org-roam-todo-wf--registry))
         (hooks (org-roam-todo-workflow-hooks wf)))
    (should (assq :on-enter-done hooks))))

;;; ============================================================
;;; Transition Tests
;;; ============================================================

(ert-deftest wf-pr-test-valid-forward-transitions ()
  "Test valid forward transitions in pull-request workflow."
  :tags '(:unit :wf :pr :transitions)
  (org-roam-todo-wf-test--require-wf)
  (require 'org-roam-todo-wf-pr nil t)
  (let ((wf (gethash 'pull-request org-roam-todo-wf--registry)))
    (should (org-roam-todo-wf--valid-transition-p wf "draft" "active"))
    (should (org-roam-todo-wf--valid-transition-p wf "active" "ci"))
    (should (org-roam-todo-wf--valid-transition-p wf "ci" "ready"))
    (should (org-roam-todo-wf--valid-transition-p wf "ready" "review"))
    (should (org-roam-todo-wf--valid-transition-p wf "review" "done"))))

(ert-deftest wf-pr-test-backward-from-ci ()
  "Test backward transition from ci to active is allowed."
  :tags '(:unit :wf :pr :transitions)
  (org-roam-todo-wf-test--require-wf)
  (require 'org-roam-todo-wf-pr nil t)
  (let ((wf (gethash 'pull-request org-roam-todo-wf--registry)))
    (should (org-roam-todo-wf--valid-transition-p wf "ci" "active"))))

(ert-deftest wf-pr-test-backward-from-ready ()
  "Test backward transition from ready to ci is allowed."
  :tags '(:unit :wf :pr :transitions)
  (org-roam-todo-wf-test--require-wf)
  (require 'org-roam-todo-wf-pr nil t)
  (let ((wf (gethash 'pull-request org-roam-todo-wf--registry)))
    (should (org-roam-todo-wf--valid-transition-p wf "ready" "ci"))))

(ert-deftest wf-pr-test-backward-from-review-not-allowed ()
  "Test backward transition from review is NOT allowed."
  :tags '(:unit :wf :pr :transitions)
  (org-roam-todo-wf-test--require-wf)
  (require 'org-roam-todo-wf-pr nil t)
  (let ((wf (gethash 'pull-request org-roam-todo-wf--registry)))
    (should-not (org-roam-todo-wf--valid-transition-p wf "review" "ready"))))

(ert-deftest wf-pr-test-rejected-always-available ()
  "Test that rejected is always available from any status."
  :tags '(:unit :wf :pr :transitions)
  (org-roam-todo-wf-test--require-wf)
  (require 'org-roam-todo-wf-pr nil t)
  (let ((wf (gethash 'pull-request org-roam-todo-wf--registry)))
    (should (org-roam-todo-wf--valid-transition-p wf "draft" "rejected"))
    (should (org-roam-todo-wf--valid-transition-p wf "active" "rejected"))
    (should (org-roam-todo-wf--valid-transition-p wf "ci" "rejected"))
    (should (org-roam-todo-wf--valid-transition-p wf "ready" "rejected"))
    (should (org-roam-todo-wf--valid-transition-p wf "review" "rejected"))))

;;; ============================================================
;;; Helper Function Tests
;;; ============================================================

(ert-deftest wf-pr-test-strip-remote-prefix ()
  "Test strip-remote-prefix strips origin/ prefix."
  :tags '(:unit :wf :pr)
  (org-roam-todo-wf-test--require-wf)
  (require 'org-roam-todo-wf-pr nil t)
  (should (string= "main" (org-roam-todo-wf-pr--strip-remote-prefix "origin/main")))
  (should (string= "main" (org-roam-todo-wf-pr--strip-remote-prefix "main")))
  (should (string= "feature/foo" (org-roam-todo-wf-pr--strip-remote-prefix "origin/feature/foo")))
  (should-not (org-roam-todo-wf-pr--strip-remote-prefix nil)))

(ert-deftest wf-pr-test-get-target-branch-returns-raw-value ()
  "Test get-target-branch returns the raw configured value."
  :tags '(:unit :wf :pr)
  (org-roam-todo-wf-test--require-wf)
  (require 'org-roam-todo-wf-pr nil t)
  (let* ((wf (make-org-roam-todo-workflow :config '(:rebase-target "origin/main")))
         (todo (list :worktree-path "/tmp/test")))
    ;; Should return "origin/main" as-is, not stripped
    (should (string= "origin/main"
                     (org-roam-todo-wf--get-target-branch todo wf)))))

(ert-deftest wf-pr-test-get-target-branch-nil-when-not-configured ()
  "Test get-target-branch returns nil when no target set."
  :tags '(:unit :wf :pr)
  (org-roam-todo-wf-test--require-wf)
  (require 'org-roam-todo-wf-pr nil t)
  (let* ((wf (make-org-roam-todo-workflow :config nil))
         (todo (list :worktree-path "/tmp/test")))
    (should-not (org-roam-todo-wf--get-target-branch todo wf))))

(ert-deftest wf-pr-test-get-target-branch-uses-project-config ()
  "Test get-target-branch uses project config when set."
  :tags '(:unit :wf :pr :project-config)
  (org-roam-todo-wf-test--require-wf)
  (require 'org-roam-todo-wf-pr nil t)
  (let* ((wf (make-org-roam-todo-workflow :config '(:rebase-target "origin/main")))
         (todo (list :worktree-path "/tmp/test"
                     :project-name "my-project"))
         ;; Set project config to override workflow config
         (org-roam-todo-project-config
          '(("my-project" . (:rebase-target "origin/develop")))))
    (should (string= "origin/develop"
                     (org-roam-todo-wf--get-target-branch todo wf)))))

(ert-deftest wf-pr-test-get-target-branch-todo-overrides-project-config ()
  "Test get-target-branch: TODO :target-branch overrides project config."
  :tags '(:unit :wf :pr :project-config)
  (org-roam-todo-wf-test--require-wf)
  (require 'org-roam-todo-wf-pr nil t)
  (let* ((wf (make-org-roam-todo-workflow :config '(:rebase-target "origin/main")))
         (todo (list :worktree-path "/tmp/test"
                     :project-name "my-project"
                     :target-branch "origin/feature"))
         ;; Set project config - should be overridden by TODO property
         (org-roam-todo-project-config
          '(("my-project" . (:rebase-target "origin/develop")))))
    (should (string= "origin/feature"
                     (org-roam-todo-wf--get-target-branch todo wf)))))

(ert-deftest wf-pr-test-get-target-branch-project-config-overrides-workflow ()
  "Test get-target-branch: project config overrides workflow config."
  :tags '(:unit :wf :pr :project-config)
  (org-roam-todo-wf-test--require-wf)
  (require 'org-roam-todo-wf-pr nil t)
  (let* ((wf (make-org-roam-todo-workflow :config '(:rebase-target "origin/main")))
         (todo (list :worktree-path "/tmp/test"
                     :project-name "my-project"))
         ;; Project config should override workflow config
         (org-roam-todo-project-config
          '(("my-project" . (:rebase-target "main")))))
    ;; Project config is "main", workflow is "origin/main"
    ;; Project config should win
    (should (string= "main"
                     (org-roam-todo-wf--get-target-branch todo wf)))))

(ert-deftest wf-pr-test-get-target-branch-falls-back-to-workflow ()
  "Test get-target-branch: falls back to workflow when no project config."
  :tags '(:unit :wf :pr :project-config)
  (org-roam-todo-wf-test--require-wf)
  (require 'org-roam-todo-wf-pr nil t)
  (let* ((wf (make-org-roam-todo-workflow :config '(:rebase-target "origin/release")))
         (todo (list :worktree-path "/tmp/test"
                     :project-name "other-project"))
         ;; Project config does not include "other-project"
         (org-roam-todo-project-config
          '(("my-project" . (:rebase-target "origin/develop")))))
    ;; Should fall back to workflow config
    (should (string= "origin/release"
                     (org-roam-todo-wf--get-target-branch todo wf)))))
;;; ============================================================
;;; Forge Type Detection Tests
;;; ============================================================

(ert-deftest wf-pr-test-repo-type-detects-github ()
  "Test repo-type correctly identifies GitHub repositories."
  :tags '(:unit :wf :pr)
  (org-roam-todo-wf-test--require-wf)
  (require 'org-roam-todo-wf-pr nil t)
  (let ((mock-repo (make-org-roam-todo-wf-pr-test--mock-github-repo)))
    (should (eq :github (org-roam-todo-wf-pr--repo-type mock-repo)))))

(ert-deftest wf-pr-test-repo-type-detects-gitlab ()
  "Test repo-type correctly identifies GitLab repositories."
  :tags '(:unit :wf :pr)
  (org-roam-todo-wf-test--require-wf)
  (require 'org-roam-todo-wf-pr nil t)
  (let ((mock-repo (make-org-roam-todo-wf-pr-test--mock-gitlab-repo)))
    (should (eq :gitlab (org-roam-todo-wf-pr--repo-type mock-repo)))))

(ert-deftest wf-pr-test-repo-type-returns-repo-for-unknown ()
  "Test repo-type returns the repo itself for unknown types."
  :tags '(:unit :wf :pr)
  (org-roam-todo-wf-test--require-wf)
  (require 'org-roam-todo-wf-pr nil t)
  ;; Use the pullreq mock as an "unknown" type
  (let ((unknown-obj (make-org-roam-todo-wf-pr-test--mock-pullreq)))
    (should (eq unknown-obj (org-roam-todo-wf-pr--repo-type unknown-obj)))))

;;; ============================================================
;;; create-draft-pr Tests (mocking forge)
;;; ============================================================

(ert-deftest wf-pr-test-create-draft-pr ()
  "Test create-draft-pr creates a draft PR using forge."
  :tags '(:unit :wf :pr :forge)
  (org-roam-todo-wf-test--require-wf)
  (org-roam-todo-wf-test--require-mocker)
  (require 'org-roam-todo-wf-pr nil t)
  (let* ((temp-dir (make-temp-file "test-repo-" t))
         (wf (make-org-roam-todo-workflow :config '(:rebase-target "origin/main")))
         (event (make-org-roam-todo-event
                 :todo (list :file "/tmp/test-todo.org")
                 :workflow wf))
         (mock-repo (make-org-roam-todo-wf-pr-test--mock-github-repo))
         (pr-created nil)
         (draft-value nil))
    (unwind-protect
        (progn
          (advice-add 'oref :around #'org-roam-todo-wf-pr-test--oref-advice)
          (mocker-let
              ((org-roam-todo-prop (event prop)
                 ;; Order: WORKTREE_PATH, WORKTREE_BRANCH, TITLE, DESCRIPTION, PROJECT_NAME, TARGET_BRANCH
                 ((:input-matcher (lambda (e p) (string= p "WORKTREE_PATH"))
                   :output temp-dir)
                  (:input-matcher (lambda (e p) (string= p "WORKTREE_BRANCH"))
                   :output "feat/my-feature")
                  (:input-matcher (lambda (e p) (string= p "TITLE"))
                   :output "Add new feature")
                  (:input-matcher (lambda (e p) (string= p "DESCRIPTION"))
                   :output nil)
                  (:input-matcher (lambda (e p) (string= p "PROJECT_NAME"))
                   :output nil)
                  (:input-matcher (lambda (e p) (string= p "TARGET_BRANCH"))
                   :output nil)))
               (org-roam-todo-wf-pr--get-forge-repo (path)
                 ((:input-matcher (lambda (p) (string= p temp-dir)) :output mock-repo)))
               (forge--rest (repo method endpoint data &rest args)
                 ((:input-matcher
                   (lambda (r m e d &rest a)
                     (when (and (string= m "POST")
                                (string-match-p "pulls" e))
                       (setq pr-created t)
                       (setq draft-value (alist-get 'draft d)))
                     t)
                   :output nil))))
            (org-roam-todo-wf-pr--create-draft-pr event)
            (should pr-created)
            (should (eq t draft-value))))
      (advice-remove 'oref #'org-roam-todo-wf-pr-test--oref-advice)
      (delete-directory temp-dir t))))

(ert-deftest wf-pr-test-create-draft-pr-uses-target ()
  "Test create-draft-pr uses the correct base branch."
  :tags '(:unit :wf :pr :forge)
  (org-roam-todo-wf-test--require-wf)
  (org-roam-todo-wf-test--require-mocker)
  (require 'org-roam-todo-wf-pr nil t)
  (let* ((temp-dir (make-temp-file "test-repo-" t))
         (wf (make-org-roam-todo-workflow :config '(:rebase-target "origin/develop")))
         (event (make-org-roam-todo-event
                 :todo (list :file "/tmp/test-todo.org")
                 :workflow wf))
         (mock-repo (make-org-roam-todo-wf-pr-test--mock-github-repo))
         (base-used nil))
    (unwind-protect
        (progn
          (advice-add 'oref :around #'org-roam-todo-wf-pr-test--oref-advice)
          (mocker-let
              ((org-roam-todo-prop (event prop)
                 ;; Order: WORKTREE_PATH, WORKTREE_BRANCH, TITLE, DESCRIPTION, PROJECT_NAME, TARGET_BRANCH
                 ((:input-matcher (lambda (e p) (string= p "WORKTREE_PATH"))
                   :output temp-dir)
                  (:input-matcher (lambda (e p) (string= p "WORKTREE_BRANCH"))
                   :output "feat/my-feature")
                  (:input-matcher (lambda (e p) (string= p "TITLE"))
                   :output "Add new feature")
                  (:input-matcher (lambda (e p) (string= p "DESCRIPTION"))
                   :output nil)
                  (:input-matcher (lambda (e p) (string= p "PROJECT_NAME"))
                   :output nil)
                  (:input-matcher (lambda (e p) (string= p "TARGET_BRANCH"))
                   :output nil)))
               (org-roam-todo-wf-pr--get-forge-repo (path)
                 ((:input-matcher (lambda (p) (string= p temp-dir)) :output mock-repo)))
               (forge--rest (repo method endpoint data &rest args)
                 ((:input-matcher
                   (lambda (r m e d &rest a)
                     (setq base-used (alist-get 'base d))
                     t)
                   :output nil))))
            (org-roam-todo-wf-pr--create-draft-pr event)
            (should (string= "develop" base-used))))
      (advice-remove 'oref #'org-roam-todo-wf-pr-test--oref-advice)
      (delete-directory temp-dir t))))

(ert-deftest wf-pr-test-create-draft-pr-gitlab ()
  "Test create-draft-pr uses GitLab API for GitLab repositories."
  :tags '(:unit :wf :pr :forge :gitlab)
  (org-roam-todo-wf-test--require-wf)
  (org-roam-todo-wf-test--require-mocker)
  (require 'org-roam-todo-wf-pr nil t)
  (let* ((temp-dir (make-temp-file "test-repo-" t))
         (wf (make-org-roam-todo-workflow :config '(:rebase-target "origin/main")))
         (event (make-org-roam-todo-event
                 :todo (list :file "/tmp/test-todo.org")
                 :workflow wf))
         (mock-repo (make-org-roam-todo-wf-pr-test--mock-gitlab-repo))
         (mr-created nil)
         (title-used nil))
    (unwind-protect
        (progn
          (advice-add 'oref :around #'org-roam-todo-wf-pr-test--oref-advice)
          (mocker-let
              ((org-roam-todo-prop (event prop)
                 ;; Order: WORKTREE_PATH, WORKTREE_BRANCH, TITLE, DESCRIPTION, PROJECT_NAME, TARGET_BRANCH
                 ((:input-matcher (lambda (e p) (string= p "WORKTREE_PATH"))
                   :output temp-dir)
                  (:input-matcher (lambda (e p) (string= p "WORKTREE_BRANCH"))
                   :output "feat/my-feature")
                  (:input-matcher (lambda (e p) (string= p "TITLE"))
                   :output "Add new feature")
                  (:input-matcher (lambda (e p) (string= p "DESCRIPTION"))
                   :output nil)
                  (:input-matcher (lambda (e p) (string= p "PROJECT_NAME"))
                   :output nil)
                  (:input-matcher (lambda (e p) (string= p "TARGET_BRANCH"))
                   :output nil)))
               (org-roam-todo-wf-pr--get-forge-repo (path)
                 ((:input-matcher (lambda (p) (string= p temp-dir)) :output mock-repo)))
               (forge--glab-post (repo endpoint data &rest args)
                 ((:input-matcher
                   (lambda (r e d &rest a)
                     (when (string-match-p "merge_requests" e)
                       (setq mr-created t)
                       (setq title-used (alist-get 'title d)))
                     t)
                   :output nil))))
            (org-roam-todo-wf-pr--create-draft-pr event)
            (should mr-created)
            ;; GitLab uses "Draft: " prefix for draft MRs
            (should (string-match-p "^Draft: " title-used))))
      (advice-remove 'oref #'org-roam-todo-wf-pr-test--oref-advice)
      (delete-directory temp-dir t))))

;;; ============================================================
;;; mark-pr-ready Tests (mocking forge)
;;; ============================================================

(ert-deftest wf-pr-test-mark-pr-ready ()
  "Test mark-pr-ready converts draft PR to ready using forge."
  :tags '(:unit :wf :pr :forge)
  (org-roam-todo-wf-test--require-wf)
  (org-roam-todo-wf-test--require-mocker)
  (require 'org-roam-todo-wf-pr nil t)
  (let* ((event (make-org-roam-todo-event
                 :todo (list :file "/tmp/test-todo.org")))
         (mock-repo (make-org-roam-todo-wf-pr-test--mock-github-repo))
         (mock-pullreq (make-org-roam-todo-wf-pr-test--mock-pullreq :draft-p t))
         (draft-set-to nil))
    (advice-add 'oref :around #'org-roam-todo-wf-pr-test--oref-advice)
    (unwind-protect
        (mocker-let
            ((org-roam-todo-prop (event prop)
               ((:input-matcher (lambda (e p) (string= p "WORKTREE_PATH"))
                 :output "/tmp/test-repo")))
             (org-roam-todo-wf-pr--get-forge-repo (path)
               ((:input '("/tmp/test-repo") :output mock-repo)))
             (org-roam-todo-wf-pr--get-pullreq (path)
               ((:input '("/tmp/test-repo") :output mock-pullreq)))
             (forge--set-topic-draft (repo topic value)
               ((:input-matcher
                 (lambda (r t v)
                   (setq draft-set-to v)
                   t)
                 :output nil))))
          (org-roam-todo-wf-pr--mark-pr-ready event)
          (should-not draft-set-to))  ;; nil means "not draft" = ready
      (advice-remove 'oref #'org-roam-todo-wf-pr-test--oref-advice))))

(ert-deftest wf-pr-test-mark-pr-ready-no-pr-error ()
  "Test mark-pr-ready errors when no PR exists."
  :tags '(:unit :wf :pr :forge)
  (org-roam-todo-wf-test--require-wf)
  (org-roam-todo-wf-test--require-mocker)
  (require 'org-roam-todo-wf-pr nil t)
  (let* ((event (make-org-roam-todo-event
                 :todo (list :file "/tmp/test-todo.org")))
         (mock-repo (make-org-roam-todo-wf-pr-test--mock-github-repo)))
    (mocker-let
        ((org-roam-todo-prop (event prop)
           ((:input-matcher (lambda (e p) (string= p "WORKTREE_PATH"))
             :output "/tmp/test-repo")))
         (org-roam-todo-wf-pr--get-forge-repo (path)
           ((:input '("/tmp/test-repo") :output mock-repo)))
         (org-roam-todo-wf-pr--get-pullreq (path)
           ((:input '("/tmp/test-repo") :output nil))))
      (should-error (org-roam-todo-wf-pr--mark-pr-ready event)
                    :type 'user-error))))

;;; ============================================================
;;; get-pr-state Tests (mocking forge)
;;; ============================================================

(ert-deftest wf-pr-test-get-pr-state-merged ()
  "Test get-pr-state returns merged when PR is merged."
  :tags '(:unit :wf :pr :forge)
  (org-roam-todo-wf-test--require-wf)
  (org-roam-todo-wf-test--require-mocker)
  (require 'org-roam-todo-wf-pr nil t)
  (let ((mock-pullreq (make-org-roam-todo-wf-pr-test--mock-pullreq :state 'merged)))
    (advice-add 'oref :around #'org-roam-todo-wf-pr-test--oref-advice)
    (unwind-protect
        (mocker-let
            ((org-roam-todo-wf-pr--get-pullreq (path)
               ((:input '("/tmp/test-repo") :output mock-pullreq))))
          (should (eq 'merged (org-roam-todo-wf-pr--get-pr-state "/tmp/test-repo"))))
      (advice-remove 'oref #'org-roam-todo-wf-pr-test--oref-advice))))

(ert-deftest wf-pr-test-get-pr-state-open ()
  "Test get-pr-state returns open when PR is still open."
  :tags '(:unit :wf :pr :forge)
  (org-roam-todo-wf-test--require-wf)
  (org-roam-todo-wf-test--require-mocker)
  (require 'org-roam-todo-wf-pr nil t)
  (let ((mock-pullreq (make-org-roam-todo-wf-pr-test--mock-pullreq :state 'open)))
    (advice-add 'oref :around #'org-roam-todo-wf-pr-test--oref-advice)
    (unwind-protect
        (mocker-let
            ((org-roam-todo-wf-pr--get-pullreq (path)
               ((:input '("/tmp/test-repo") :output mock-pullreq))))
          (should (eq 'open (org-roam-todo-wf-pr--get-pr-state "/tmp/test-repo"))))
      (advice-remove 'oref #'org-roam-todo-wf-pr-test--oref-advice))))

(ert-deftest wf-pr-test-get-pr-state-rejected ()
  "Test get-pr-state returns rejected when PR is closed without merge."
  :tags '(:unit :wf :pr :forge)
  (org-roam-todo-wf-test--require-wf)
  (org-roam-todo-wf-test--require-mocker)
  (require 'org-roam-todo-wf-pr nil t)
  (let ((mock-pullreq (make-org-roam-todo-wf-pr-test--mock-pullreq :state 'rejected)))
    (advice-add 'oref :around #'org-roam-todo-wf-pr-test--oref-advice)
    (unwind-protect
        (mocker-let
            ((org-roam-todo-wf-pr--get-pullreq (path)
               ((:input '("/tmp/test-repo") :output mock-pullreq))))
          (should (eq 'rejected (org-roam-todo-wf-pr--get-pr-state "/tmp/test-repo"))))
      (advice-remove 'oref #'org-roam-todo-wf-pr-test--oref-advice))))

(ert-deftest wf-pr-test-get-pr-state-no-pr ()
  "Test get-pr-state returns nil when no PR exists."
  :tags '(:unit :wf :pr :forge)
  (org-roam-todo-wf-test--require-wf)
  (org-roam-todo-wf-test--require-mocker)
  (require 'org-roam-todo-wf-pr nil t)
  (mocker-let
      ((org-roam-todo-wf-pr--get-pullreq (path)
         ((:input '("/tmp/test-repo") :output nil))))
    (should-not (org-roam-todo-wf-pr--get-pr-state "/tmp/test-repo"))))

;;; ============================================================
;;; request-reviewers Tests (mocking forge)
;;; ============================================================

(ert-deftest wf-pr-test-request-reviewers ()
  "Test request-reviewers adds reviewers to PR via forge."
  :tags '(:unit :wf :pr :forge)
  (org-roam-todo-wf-test--require-wf)
  (org-roam-todo-wf-test--require-mocker)
  (require 'org-roam-todo-wf-pr nil t)
  (let* ((wf (make-org-roam-todo-workflow
              :config '(:reviewers ("alice" "bob"))))
         (event (make-org-roam-todo-event
                 :todo (list :file "/tmp/test-todo.org")
                 :workflow wf))
         (mock-repo (make-org-roam-todo-wf-pr-test--mock-github-repo))
         (mock-pullreq (make-org-roam-todo-wf-pr-test--mock-pullreq))
         (reviewers-requested nil))
    (mocker-let
        ((org-roam-todo-prop (event prop)
           ((:input-matcher (lambda (e p) (string= p "WORKTREE_PATH"))
             :output "/tmp/test-repo")))
         (org-roam-todo-wf-pr--get-forge-repo (path)
           ((:input '("/tmp/test-repo") :output mock-repo)))
         (org-roam-todo-wf-pr--get-pullreq (path)
           ((:input '("/tmp/test-repo") :output mock-pullreq)))
         (forge--set-topic-review-requests (repo topic reviewers)
           ((:input-matcher
             (lambda (r t revs)
               (setq reviewers-requested revs)
               t)
             :output nil))))
      (org-roam-todo-wf-pr--request-reviewers event)
      (should reviewers-requested)
      (should (member "alice" reviewers-requested))
      (should (member "bob" reviewers-requested)))))

(ert-deftest wf-pr-test-request-reviewers-no-reviewers ()
  "Test request-reviewers does nothing when no reviewers configured."
  :tags '(:unit :wf :pr)
  (org-roam-todo-wf-test--require-wf)
  (require 'org-roam-todo-wf-pr nil t)
  (let* ((wf (make-org-roam-todo-workflow :config nil))
         (event (make-org-roam-todo-event
                 :todo (list :worktree-path "/tmp/test-repo")
                 :workflow wf)))
    ;; Should not error even without reviewers
    (should-not (org-roam-todo-wf-pr--request-reviewers event))))

;;; ============================================================
;;; require-ci-pass Tests
;;; ============================================================

(ert-deftest wf-pr-test-require-ci-pass-without-magit-forge-ci ()
  "Test require-ci-pass passes when magit-forge-ci is not available."
  :tags '(:unit :wf :pr :validation)
  (org-roam-todo-wf-test--require-wf)
  (require 'org-roam-todo-wf-pr nil t)
  ;; Ensure magit-forge-ci is not loaded for this test
  (let ((event (make-org-roam-todo-event
                :todo (list :worktree-path "/tmp/test-repo"))))
    ;; When magit-forge-ci is not available, should pass (nil = no error)
    (unwind-protect
        (progn
          ;; Temporarily unload magit-forge-ci if loaded
          (when (featurep 'magit-forge-ci)
            (unload-feature 'magit-forge-ci t))
          (should-not (org-roam-todo-wf-pr--require-ci-pass event)))
      ;; Re-require if it was loaded before
      (require 'magit-forge-ci nil t))))

(ert-deftest wf-pr-test-require-ci-pass-with-success ()
  "Test require-ci-pass passes when CI checks succeed."
  :tags '(:unit :wf :pr :validation :ci)
  (org-roam-todo-wf-test--require-wf)
  (org-roam-todo-wf-test--require-mocker)
  (require 'org-roam-todo-wf-pr nil t)
  ;; Only run if magit-forge-ci would be available
  (let* ((event (make-org-roam-todo-event
                 :todo (list :file "/tmp/test-todo.org")))
         (mock-repo (make-org-roam-todo-wf-pr-test--mock-github-repo))
         (mock-pullreq (make-org-roam-todo-wf-pr-test--mock-pullreq)))
    (advice-add 'oref :around #'org-roam-todo-wf-pr-test--oref-advice)
    (unwind-protect
        (mocker-let
            ((org-roam-todo-prop (event prop)
               ((:input-matcher (lambda (e p) (string= p "WORKTREE_PATH"))
                 :output "/tmp/test-repo")))
             (featurep (feature)
               ((:input '(magit-forge-ci) :output t)))
             (fboundp (sym)
               ((:input-matcher (lambda (s) t) :output t :min-occur 0 :max-occur nil)))
             (org-roam-todo-wf-pr--get-forge-repo (path)
               ((:input '("/tmp/test-repo") :output mock-repo)))
             (org-roam-todo-wf-pr--get-pullreq (path)
               ((:input '("/tmp/test-repo") :output mock-pullreq)))
             (magit-forge-ci--get-checks-via-gh-cli (owner name pr-number)
               ((:input-matcher (lambda (&rest _) t)
                 :output '(((state . "success"))))))
             (magit-forge-ci--compute-overall-status (checks)
               ((:input-matcher (lambda (&rest _) t) :output "success"))))
          ;; Should pass (return nil) when CI is successful
          (should-not (org-roam-todo-wf-pr--require-ci-pass event)))
      (advice-remove 'oref #'org-roam-todo-wf-pr-test--oref-advice))))

(ert-deftest wf-pr-test-require-ci-pass-with-failure ()
  "Test require-ci-pass returns :fail when CI checks fail."
  :tags '(:unit :wf :pr :validation :ci)
  (org-roam-todo-wf-test--require-wf)
  (org-roam-todo-wf-test--require-mocker)
  (require 'org-roam-todo-wf-pr nil t)
  (let* ((event (make-org-roam-todo-event
                 :todo (list :file "/tmp/test-todo.org")))
         (mock-repo (make-org-roam-todo-wf-pr-test--mock-github-repo))
         (mock-pullreq (make-org-roam-todo-wf-pr-test--mock-pullreq)))
    (advice-add 'oref :around #'org-roam-todo-wf-pr-test--oref-advice)
    (unwind-protect
        (mocker-let
            ((org-roam-todo-prop (event prop)
               ((:input-matcher (lambda (e p) (string= p "WORKTREE_PATH"))
                 :output "/tmp/test-repo")))
             (featurep (feature)
               ((:input '(magit-forge-ci) :output t)))
             (fboundp (sym)
               ((:input-matcher (lambda (s) t) :output t :min-occur 0 :max-occur nil)))
             (org-roam-todo-wf-pr--get-forge-repo (path)
               ((:input '("/tmp/test-repo") :output mock-repo)))
             (org-roam-todo-wf-pr--get-pullreq (path)
               ((:input '("/tmp/test-repo") :output mock-pullreq)))
             (magit-forge-ci--get-checks-via-gh-cli (owner name pr-number)
               ((:input-matcher (lambda (&rest _) t)
                 :output '(((state . "failure"))))))
             (magit-forge-ci--compute-overall-status (checks)
               ((:input-matcher (lambda (&rest _) t) :output "failure"))))
          ;; Should return (:fail "message") when CI has failures
          (let ((result (org-roam-todo-wf-pr--require-ci-pass event)))
            (should (listp result))
            (should (eq (car result) :fail))))
      (advice-remove 'oref #'org-roam-todo-wf-pr-test--oref-advice))))

(ert-deftest wf-pr-test-require-ci-pass-with-pending ()
  "Test require-ci-pass returns :pending when CI checks are pending."
  :tags '(:unit :wf :pr :validation :ci)
  (org-roam-todo-wf-test--require-wf)
  (org-roam-todo-wf-test--require-mocker)
  (require 'org-roam-todo-wf-pr nil t)
  (let* ((event (make-org-roam-todo-event
                 :todo (list :file "/tmp/test-todo.org")))
         (mock-repo (make-org-roam-todo-wf-pr-test--mock-github-repo))
         (mock-pullreq (make-org-roam-todo-wf-pr-test--mock-pullreq)))
    (advice-add 'oref :around #'org-roam-todo-wf-pr-test--oref-advice)
    (unwind-protect
        (mocker-let
            ((org-roam-todo-prop (event prop)
               ((:input-matcher (lambda (e p) (string= p "WORKTREE_PATH"))
                 :output "/tmp/test-repo")))
             (featurep (feature)
               ((:input '(magit-forge-ci) :output t)))
             (fboundp (sym)
               ((:input-matcher (lambda (s) t) :output t :min-occur 0 :max-occur nil)))
             (org-roam-todo-wf-pr--get-forge-repo (path)
               ((:input '("/tmp/test-repo") :output mock-repo)))
             (org-roam-todo-wf-pr--get-pullreq (path)
               ((:input '("/tmp/test-repo") :output mock-pullreq)))
             (magit-forge-ci--get-checks-via-gh-cli (owner name pr-number)
               ((:input-matcher (lambda (&rest _) t)
                 :output '(((state . "pending"))))))
             (magit-forge-ci--compute-overall-status (checks)
               ((:input-matcher (lambda (&rest _) t) :output "pending"))))
          ;; Should return (:pending "message") when CI is pending
          (let ((result (org-roam-todo-wf-pr--require-ci-pass event)))
            (should (listp result))
            (should (eq (car result) :pending))))
      (advice-remove 'oref #'org-roam-todo-wf-pr-test--oref-advice))))

(ert-deftest wf-pr-test-has-validate-ready-hook ()
  "Test that pull-request workflow has :validate-ready hook."
  :tags '(:unit :wf :pr)
  (org-roam-todo-wf-test--require-wf)
  (require 'org-roam-todo-wf-pr nil t)
  (let* ((wf (gethash 'pull-request org-roam-todo-wf--registry))
         (hooks (org-roam-todo-workflow-hooks wf)))
    (should (assq :validate-ready hooks))))

;;; ============================================================
;;; require-user-approval Tests
;;; ============================================================

(ert-deftest wf-pr-test-require-user-approval-approved ()
  "Test require-user-approval passes when :approved is set."
  :tags '(:unit :wf :pr :validation)
  (org-roam-todo-wf-test--require-wf)
  (org-roam-todo-wf-test--require-mocker)
  (require 'org-roam-todo-wf-pr nil t)
  (let* ((event (make-org-roam-todo-event
                 :todo (list :file "/tmp/test-todo.org"))))
    (mocker-let
        ((org-roam-todo-prop (event prop)
           ((:input-matcher (lambda (e p) (string= p "APPROVED"))
             :output t))))
      ;; Should not error when approved
      (should-not (org-roam-todo-wf-pr--require-user-approval event)))))

(ert-deftest wf-pr-test-require-user-approval-not-approved ()
  "Test require-user-approval fails when :approved is not set."
  :tags '(:unit :wf :pr :validation)
  (org-roam-todo-wf-test--require-wf)
  (require 'org-roam-todo-wf-pr nil t)
  (let* ((event (make-org-roam-todo-event
                 :todo (list :worktree-path "/tmp/test-repo"))))
    ;; Should error when not approved
    (should-error (org-roam-todo-wf-pr--require-user-approval event)
                  :type 'user-error)))

(ert-deftest wf-pr-test-require-user-approval-nil ()
  "Test require-user-approval fails when :approved is explicitly nil."
  :tags '(:unit :wf :pr :validation)
  (org-roam-todo-wf-test--require-wf)
  (require 'org-roam-todo-wf-pr nil t)
  (let* ((event (make-org-roam-todo-event
                 :todo (list :worktree-path "/tmp/test-repo"
                             :approved nil))))
    ;; Should error when explicitly nil
    (should-error (org-roam-todo-wf-pr--require-user-approval event)
                  :type 'user-error)))

(ert-deftest wf-pr-test-has-validate-review-hook ()
  "Test that pull-request workflow has :validate-review hook."
  :tags '(:unit :wf :pr)
  (org-roam-todo-wf-test--require-wf)
  (require 'org-roam-todo-wf-pr nil t)
  (let* ((wf (gethash 'pull-request org-roam-todo-wf--registry))
         (hooks (org-roam-todo-workflow-hooks wf)))
    (should (assq :validate-review hooks))))

;;; ============================================================
;;; require-pr-merged Tests
;;; ============================================================

(ert-deftest wf-pr-test-require-pr-merged-merged ()
  "Test require-pr-merged passes when PR is merged."
  :tags '(:unit :wf :pr :validation)
  (org-roam-todo-wf-test--require-wf)
  (org-roam-todo-wf-test--require-mocker)
  (require 'org-roam-todo-wf-pr nil t)
  (let* ((event (make-org-roam-todo-event
                 :todo (list :file "/tmp/test-todo.org"))))
    (mocker-let
        ((org-roam-todo-prop (event prop)
           ((:input-matcher (lambda (e p) (string= p "WORKTREE_PATH"))
             :output "/tmp/test-repo")))
         (org-roam-todo-wf-pr--get-pr-state (path)
           ((:input '("/tmp/test-repo") :output 'merged))))
      ;; Should not error when merged
      (should-not (org-roam-todo-wf-pr--require-pr-merged event)))))

(ert-deftest wf-pr-test-require-pr-merged-open ()
  "Test require-pr-merged fails when PR is still open."
  :tags '(:unit :wf :pr :validation)
  (org-roam-todo-wf-test--require-wf)
  (org-roam-todo-wf-test--require-mocker)
  (require 'org-roam-todo-wf-pr nil t)
  (let* ((event (make-org-roam-todo-event
                 :todo (list :file "/tmp/test-todo.org"))))
    (mocker-let
        ((org-roam-todo-prop (event prop)
           ((:input-matcher (lambda (e p) (string= p "WORKTREE_PATH"))
             :output "/tmp/test-repo")))
         (org-roam-todo-wf-pr--get-pr-state (path)
           ((:input '("/tmp/test-repo") :output 'open))))
      ;; Should error when still open
      (should-error (org-roam-todo-wf-pr--require-pr-merged event)
                    :type 'user-error))))

(ert-deftest wf-pr-test-require-pr-merged-rejected ()
  "Test require-pr-merged fails when PR is closed without merging."
  :tags '(:unit :wf :pr :validation)
  (org-roam-todo-wf-test--require-wf)
  (org-roam-todo-wf-test--require-mocker)
  (require 'org-roam-todo-wf-pr nil t)
  (let* ((event (make-org-roam-todo-event
                 :todo (list :file "/tmp/test-todo.org"))))
    (mocker-let
        ((org-roam-todo-prop (event prop)
           ((:input-matcher (lambda (e p) (string= p "WORKTREE_PATH"))
             :output "/tmp/test-repo")))
         (org-roam-todo-wf-pr--get-pr-state (path)
           ((:input '("/tmp/test-repo") :output 'rejected))))
      ;; Should error when closed without merge
      (should-error (org-roam-todo-wf-pr--require-pr-merged event)
                    :type 'user-error))))

(ert-deftest wf-pr-test-require-pr-merged-unknown ()
  "Test require-pr-merged fails when PR state cannot be determined."
  :tags '(:unit :wf :pr :validation)
  (org-roam-todo-wf-test--require-wf)
  (org-roam-todo-wf-test--require-mocker)
  (require 'org-roam-todo-wf-pr nil t)
  (let* ((event (make-org-roam-todo-event
                 :todo (list :file "/tmp/test-todo.org"))))
    (mocker-let
        ((org-roam-todo-prop (event prop)
           ((:input-matcher (lambda (e p) (string= p "WORKTREE_PATH"))
             :output "/tmp/test-repo")))
         (org-roam-todo-wf-pr--get-pr-state (path)
           ((:input '("/tmp/test-repo") :output nil))))
      ;; Should error when state is unknown
      (should-error (org-roam-todo-wf-pr--require-pr-merged event)
                    :type 'user-error))))

(ert-deftest wf-pr-test-has-validate-done-hook ()
  "Test that pull-request workflow has :validate-done hook."
  :tags '(:unit :wf :pr)
  (org-roam-todo-wf-test--require-wf)
  (require 'org-roam-todo-wf-pr nil t)
  (let* ((wf (gethash 'pull-request org-roam-todo-wf--registry))
         (hooks (org-roam-todo-workflow-hooks wf)))
    (should (assq :validate-done hooks))))

;;; ============================================================
;;; User Approval Detection Tests (org-roam-todo-status)
;;; ============================================================

(ert-deftest wf-pr-test-has-user-approval-validation-ready-status ()
  "Test that ready status in PR workflow triggers user approval detection.
When a TODO is in 'ready' status, the next status (review) has the
user-approval validation, so `org-roam-todo-status--has-user-approval-validation-p'
should return non-nil."
  :tags '(:unit :wf :pr :status)
  (org-roam-todo-wf-test--require-wf)
  (require 'org-roam-todo-wf-pr nil t)
  (require 'org-roam-todo-status nil t)
  (let* ((todo (list :file "/tmp/test-todo.org"
                     :status "ready"
                     :project-name nil)))
    ;; The next status after "ready" is "review", which has require-user-approval
    (should (org-roam-todo-status--has-user-approval-validation-p todo))))

(ert-deftest wf-pr-test-has-user-approval-validation-ci-status ()
  "Test that ci status does NOT trigger user approval detection.
When a TODO is in 'ci' status, the next status (ready) does NOT have
the user-approval validation."
  :tags '(:unit :wf :pr :status)
  (org-roam-todo-wf-test--require-wf)
  (require 'org-roam-todo-wf-pr nil t)
  (require 'org-roam-todo-status nil t)
  (let* ((todo (list :file "/tmp/test-todo.org"
                     :status "ci"
                     :project-name nil)))
    ;; The next status after "ci" is "ready", which does NOT have require-user-approval
    (should-not (org-roam-todo-status--has-user-approval-validation-p todo))))

(ert-deftest wf-pr-test-needs-review-when-not-approved ()
  "Test needs-review-p returns t when at ready status and not approved."
  :tags '(:unit :wf :pr :status)
  (org-roam-todo-wf-test--require-wf)
  (require 'org-roam-todo-wf-pr nil t)
  (require 'org-roam-todo-status nil t)
  (let* ((todo (list :file "/tmp/test-todo.org"
                     :status "ready"
                     :project-name nil
                     :approved nil)))
    (should (org-roam-todo-status--needs-review-p todo))))

(ert-deftest wf-pr-test-needs-review-when-already-approved ()
  "Test needs-review-p returns nil when already approved."
  :tags '(:unit :wf :pr :status)
  (org-roam-todo-wf-test--require-wf)
  (require 'org-roam-todo-wf-pr nil t)
  (require 'org-roam-todo-status nil t)
  (let* ((todo (list :file "/tmp/test-todo.org"
                     :status "ready"
                     :project-name nil
                     :approved "t")))
    (should-not (org-roam-todo-status--needs-review-p todo))))

(ert-deftest wf-pr-test-needs-review-at-wrong-status ()
  "Test needs-review-p returns nil when not at a status requiring approval."
  :tags '(:unit :wf :pr :status)
  (org-roam-todo-wf-test--require-wf)
  (require 'org-roam-todo-wf-pr nil t)
  (require 'org-roam-todo-status nil t)
  (let* ((todo (list :file "/tmp/test-todo.org"
                     :status "ci"
                     :project-name nil
                     :approved nil)))
    ;; Even though not approved, ci->ready doesn't require user approval
    (should-not (org-roam-todo-status--needs-review-p todo))))


;;; ============================================================
;;; PR Title and Body Helper Tests
;;; ============================================================

(ert-deftest wf-pr-test-get-pr-title-from-section ()
  "Test get-pr-title returns content from PR Title section."
  :tags '(:unit :wf :pr :pr-sections)
  (org-roam-todo-wf-test--require-wf)
  (require 'org-roam-todo-wf-pr nil t)
  (let* ((temp-file (make-temp-file "test-todo-" nil ".org")))
    (unwind-protect
        (progn
          (with-temp-file temp-file
            (insert ":PROPERTIES:\n:ID: test\n:END:\n#+title: My TODO\n\n")
            (insert "** PR Title\n\nFix: Important bug fix\n\n")
            (insert "** PR Description\n\nThis fixes an important bug.\n"))
          (let* ((event (make-org-roam-todo-event
                         :todo (list :file temp-file))))
            (should (string= "Fix: Important bug fix"
                             (org-roam-todo-wf-pr--get-pr-title event)))))
      (delete-file temp-file))))

(ert-deftest wf-pr-test-get-pr-title-fallback-to-title ()
  "Test get-pr-title falls back to TODO title when no PR Title section."
  :tags '(:unit :wf :pr :pr-sections)
  (org-roam-todo-wf-test--require-wf)
  (org-roam-todo-wf-test--require-mocker)
  (require 'org-roam-todo-wf-pr nil t)
  (let* ((temp-file (make-temp-file "test-todo-" nil ".org")))
    (unwind-protect
        (progn
          (with-temp-file temp-file
            (insert ":PROPERTIES:\n:ID: test\n:END:\n#+title: My TODO Title\n\n")
            (insert "** Task Description\n\nSome description.\n"))
          (let* ((event (make-org-roam-todo-event
                         :todo (list :file temp-file))))
            (mocker-let
                ((org-roam-todo-prop (event prop)
                   ((:input-matcher (lambda (e p) (string= p "TITLE"))
                     :output "My TODO Title"))))
              (should (string= "My TODO Title"
                               (org-roam-todo-wf-pr--get-pr-title event))))))
      (delete-file temp-file))))

(ert-deftest wf-pr-test-get-pr-title-custom-function ()
  "Test get-pr-title uses custom function when set."
  :tags '(:unit :wf :pr :pr-sections)
  (org-roam-todo-wf-test--require-wf)
  (require 'org-roam-todo-wf-pr nil t)
  (let* ((org-roam-todo-wf-pr-title-function
          (lambda (_event) "Custom PR Title"))
         (event (make-org-roam-todo-event
                 :todo (list :file "/tmp/test.org"))))
    (should (string= "Custom PR Title"
                     (org-roam-todo-wf-pr--get-pr-title event)))))

(ert-deftest wf-pr-test-get-pr-body-from-section ()
  "Test get-pr-body returns content from PR Description section."
  :tags '(:unit :wf :pr :pr-sections)
  (org-roam-todo-wf-test--require-wf)
  (require 'org-roam-todo-wf-pr nil t)
  (let* ((temp-file (make-temp-file "test-todo-" nil ".org")))
    (unwind-protect
        (progn
          (with-temp-file temp-file
            (insert ":PROPERTIES:\n:ID: test\n:END:\n#+title: My TODO\n\n")
            (insert "** PR Title\n\nFix bug\n\n")
            (insert "** PR Description\n\n## Summary\n\nThis PR fixes the bug.\n\n## Test Plan\n\n- Test manually\n"))
          (let* ((event (make-org-roam-todo-event
                         :todo (list :file temp-file)))
                 (body (org-roam-todo-wf-pr--get-pr-body event)))
            (should (string-match-p "## Summary" body))
            (should (string-match-p "This PR fixes the bug" body))))
      (delete-file temp-file))))

(ert-deftest wf-pr-test-get-pr-body-custom-function ()
  "Test get-pr-body uses custom function when set."
  :tags '(:unit :wf :pr :pr-sections)
  (org-roam-todo-wf-test--require-wf)
  (require 'org-roam-todo-wf-pr nil t)
  (let* ((org-roam-todo-wf-pr-body-function
          (lambda (_event) "Custom body content"))
         (event (make-org-roam-todo-event
                 :todo (list :file "/tmp/test.org"))))
    (should (string= "Custom body content"
                     (org-roam-todo-wf-pr--get-pr-body event)))))

;;; ============================================================
;;; PR Sections Validation Tests
;;; ============================================================

(ert-deftest wf-pr-test-require-pr-sections-pass ()
  "Test require-pr-sections passes when both sections exist."
  :tags '(:unit :wf :pr :validation :pr-sections)
  (org-roam-todo-wf-test--require-wf)
  (require 'org-roam-todo-wf-pr nil t)
  (let* ((temp-file (make-temp-file "test-todo-" nil ".org"))
         (org-roam-todo-wf-pr-require-pr-sections t))
    (unwind-protect
        (progn
          (with-temp-file temp-file
            (insert ":PROPERTIES:\n:ID: test\n:END:\n#+title: My TODO\n\n")
            (insert "** PR Title\n\nFix: Bug fix\n\n")
            (insert "** PR Description\n\nThis fixes the bug.\n"))
          (let* ((event (make-org-roam-todo-event
                         :todo (list :file temp-file))))
            ;; Should not error
            (should-not (org-roam-todo-wf-pr--require-pr-sections event))))
      (delete-file temp-file))))

(ert-deftest wf-pr-test-require-pr-sections-missing-title ()
  "Test require-pr-sections fails when PR Title section is missing."
  :tags '(:unit :wf :pr :validation :pr-sections)
  (org-roam-todo-wf-test--require-wf)
  (require 'org-roam-todo-wf-pr nil t)
  (let* ((temp-file (make-temp-file "test-todo-" nil ".org"))
         (org-roam-todo-wf-pr-require-pr-sections t))
    (unwind-protect
        (progn
          (with-temp-file temp-file
            (insert ":PROPERTIES:\n:ID: test\n:END:\n#+title: My TODO\n\n")
            (insert "** PR Description\n\nThis fixes the bug.\n"))
          (let* ((event (make-org-roam-todo-event
                         :todo (list :file temp-file))))
            (should-error (org-roam-todo-wf-pr--require-pr-sections event)
                          :type 'user-error)))
      (delete-file temp-file))))

(ert-deftest wf-pr-test-require-pr-sections-missing-description ()
  "Test require-pr-sections fails when PR Description section is missing."
  :tags '(:unit :wf :pr :validation :pr-sections)
  (org-roam-todo-wf-test--require-wf)
  (require 'org-roam-todo-wf-pr nil t)
  (let* ((temp-file (make-temp-file "test-todo-" nil ".org"))
         (org-roam-todo-wf-pr-require-pr-sections t))
    (unwind-protect
        (progn
          (with-temp-file temp-file
            (insert ":PROPERTIES:\n:ID: test\n:END:\n#+title: My TODO\n\n")
            (insert "** PR Title\n\nFix: Bug fix\n"))
          (let* ((event (make-org-roam-todo-event
                         :todo (list :file temp-file))))
            (should-error (org-roam-todo-wf-pr--require-pr-sections event)
                          :type 'user-error)))
      (delete-file temp-file))))

(ert-deftest wf-pr-test-require-pr-sections-empty-title ()
  "Test require-pr-sections fails when PR Title section is empty."
  :tags '(:unit :wf :pr :validation :pr-sections)
  (org-roam-todo-wf-test--require-wf)
  (require 'org-roam-todo-wf-pr nil t)
  (let* ((temp-file (make-temp-file "test-todo-" nil ".org"))
         (org-roam-todo-wf-pr-require-pr-sections t))
    (unwind-protect
        (progn
          (with-temp-file temp-file
            (insert ":PROPERTIES:\n:ID: test\n:END:\n#+title: My TODO\n\n")
            (insert "** PR Title\n\n")
            (insert "** PR Description\n\nSome description.\n"))
          (let* ((event (make-org-roam-todo-event
                         :todo (list :file temp-file))))
            (should-error (org-roam-todo-wf-pr--require-pr-sections event)
                          :type 'user-error)))
      (delete-file temp-file))))

(ert-deftest wf-pr-test-require-pr-sections-disabled ()
  "Test require-pr-sections passes when validation is disabled."
  :tags '(:unit :wf :pr :validation :pr-sections)
  (org-roam-todo-wf-test--require-wf)
  (require 'org-roam-todo-wf-pr nil t)
  (let* ((temp-file (make-temp-file "test-todo-" nil ".org"))
         (org-roam-todo-wf-pr-require-pr-sections nil))
    (unwind-protect
        (progn
          (with-temp-file temp-file
            (insert ":PROPERTIES:\n:ID: test\n:END:\n#+title: My TODO\n\n")
            (insert "** Task Description\n\nNo PR sections here.\n"))
          (let* ((event (make-org-roam-todo-event
                         :todo (list :file temp-file))))
            ;; Should not error when validation is disabled
            (should-not (org-roam-todo-wf-pr--require-pr-sections event))))
      (delete-file temp-file))))

;;; ============================================================
;;; PR Creation with PR Property Tests
;;; ============================================================

(ert-deftest wf-pr-test-create-draft-pr-saves-pr-number ()
  "Test create-draft-pr saves PR number to TODO file."
  :tags '(:unit :wf :pr :forge :pr-property)
  (org-roam-todo-wf-test--require-wf)
  (org-roam-todo-wf-test--require-mocker)
  (require 'org-roam-todo-wf-pr nil t)
  (let* ((temp-dir (make-temp-file "test-repo-" t))
         (temp-todo (make-temp-file "test-todo-" nil ".org"))
         (wf (make-org-roam-todo-workflow :config '(:rebase-target "origin/main")))
         (event (make-org-roam-todo-event
                 :todo (list :file temp-todo)
                 :workflow wf))
         (mock-repo (make-org-roam-todo-wf-pr-test--mock-github-repo))
         (callback-called nil)
         (saved-pr-number nil)
         (org-roam-todo-wf-pr-require-pr-sections nil))
    (unwind-protect
        (progn
          ;; Create TODO file with PR sections
          (with-temp-file temp-todo
            (insert ":PROPERTIES:\n:ID: test\n:END:\n#+title: Test TODO\n\n")
            (insert "** PR Title\n\nTest PR\n\n")
            (insert "** PR Description\n\nTest description.\n"))
          (advice-add 'oref :around #'org-roam-todo-wf-pr-test--oref-advice)
          (mocker-let
              ((org-roam-todo-prop (event prop)
                 ((:input-matcher (lambda (e p) (string= p "WORKTREE_PATH"))
                   :output temp-dir)
                  (:input-matcher (lambda (e p) (string= p "WORKTREE_BRANCH"))
                   :output "feat/my-feature")
                  (:input-matcher (lambda (e p) (string= p "TITLE"))
                   :output "Test TODO")
                  (:input-matcher (lambda (e p) (string= p "DESCRIPTION"))
                   :output nil)
                  (:input-matcher (lambda (e p) (string= p "PROJECT_NAME"))
                   :output nil)
                  (:input-matcher (lambda (e p) (string= p "TARGET_BRANCH"))
                   :output nil)))
               (org-roam-todo-wf-pr--get-forge-repo (path)
                 ((:input-matcher (lambda (p) (string= p temp-dir)) :output mock-repo)))
               (forge--rest (repo method endpoint data &rest args)
                 ((:input-matcher
                   (lambda (r m e d &rest a)
                     (when (and (string= m "POST")
                                (string-match-p "pulls" e))
                       ;; Simulate calling the callback with PR data
                       (let ((callback (plist-get (car a) :callback)))
                         (when callback
                           (funcall callback '((number . 123))))))
                     t)
                   :output nil)))
               (org-roam-todo-set-file-property (file prop value)
                 ((:input-matcher
                   (lambda (f p v)
                     (when (string= p "PR")
                       (setq saved-pr-number v))
                     t)
                   :output nil)))
               (forge--pull (repo)
                 ((:input-matcher (lambda (r) t) :output nil))))
            (org-roam-todo-wf-pr--create-draft-pr event)
            ;; Verify PR number was saved
            (should (string= "123" saved-pr-number))))
      (advice-remove 'oref #'org-roam-todo-wf-pr-test--oref-advice)
      (delete-directory temp-dir t)
      (delete-file temp-todo))))

(ert-deftest wf-pr-test-validate-ci-includes-pr-sections ()
  "Test that :validate-ci hook includes PR sections validation."
  :tags '(:unit :wf :pr :validation)
  (org-roam-todo-wf-test--require-wf)
  (require 'org-roam-todo-wf-pr nil t)
  (let* ((wf (gethash 'pull-request org-roam-todo-wf--registry))
         (hooks (org-roam-todo-workflow-hooks wf))
         (validate-ci-hooks (cdr (assq :validate-ci hooks))))
    (should validate-ci-hooks)
    (should (member 'org-roam-todo-wf-pr--require-pr-sections validate-ci-hooks))))

;;; ============================================================
;;; PR Info Detection Tests (gh CLI fallback)
;;; ============================================================

(ert-deftest wf-pr-test-get-pr-number-from-props ()
  "Test get-pr-number-from-props reads PR_NUMBER from TODO properties."
  :tags '(:unit :wf :pr :detection)
  (org-roam-todo-wf-test--require-wf)
  (org-roam-todo-wf-test--require-mocker)
  (require 'org-roam-todo-wf-pr nil t)
  (let ((event (make-org-roam-todo-event
                :todo (list :file "/tmp/test-todo.org"))))
    (mocker-let
        ((org-roam-todo-prop (event prop)
           ((:input-matcher (lambda (e p) (string= p "PR_NUMBER"))
             :output "123"))))
      (should (string= "123" (org-roam-todo-wf-pr--get-pr-number-from-props event))))))

(ert-deftest wf-pr-test-get-pr-number-from-props-nil ()
  "Test get-pr-number-from-props returns nil when PR_NUMBER not set."
  :tags '(:unit :wf :pr :detection)
  (org-roam-todo-wf-test--require-wf)
  (org-roam-todo-wf-test--require-mocker)
  (require 'org-roam-todo-wf-pr nil t)
  (let ((event (make-org-roam-todo-event
                :todo (list :file "/tmp/test-todo.org"))))
    (mocker-let
        ((org-roam-todo-prop (event prop)
           ((:input-matcher (lambda (e p) (string= p "PR_NUMBER"))
             :output nil))))
      (should-not (org-roam-todo-wf-pr--get-pr-number-from-props event)))))

(ert-deftest wf-pr-test-get-pr-info-uses-forge-first ()
  "Test get-pr-info uses forge when PR is known to forge."
  :tags '(:unit :wf :pr :detection)
  (org-roam-todo-wf-test--require-wf)
  (org-roam-todo-wf-test--require-mocker)
  (require 'org-roam-todo-wf-pr nil t)
  (let* ((event (make-org-roam-todo-event
                 :todo (list :file "/tmp/test-todo.org")))
         (mock-repo (make-org-roam-todo-wf-pr-test--mock-github-repo))
         (mock-pullreq (make-org-roam-todo-wf-pr-test--mock-pullreq :number 42)))
    (advice-add 'oref :around #'org-roam-todo-wf-pr-test--oref-advice)
    (unwind-protect
        (mocker-let
            ((org-roam-todo-wf-pr--get-pullreq (path)
               ((:input '("/tmp/test-repo") :output mock-pullreq)))
             (org-roam-todo-wf-pr--get-forge-repo (path)
               ((:input '("/tmp/test-repo") :output mock-repo))))
          (let ((pr-info (org-roam-todo-wf-pr--get-pr-info event "/tmp/test-repo")))
            (should pr-info)
            (should (eq 'forge (plist-get pr-info :source)))
            (should (= 42 (plist-get pr-info :pr-number)))
            (should (string= "test-owner" (plist-get pr-info :owner)))
            (should (string= "test-repo" (plist-get pr-info :name)))))
      (advice-remove 'oref #'org-roam-todo-wf-pr-test--oref-advice))))

(ert-deftest wf-pr-test-get-pr-info-falls-back-to-properties ()
  "Test get-pr-info falls back to TODO properties when forge doesn't know PR."
  :tags '(:unit :wf :pr :detection)
  (org-roam-todo-wf-test--require-wf)
  (org-roam-todo-wf-test--require-mocker)
  (require 'org-roam-todo-wf-pr nil t)
  (let* ((event (make-org-roam-todo-event
                 :todo (list :file "/tmp/test-todo.org"))))
    (mocker-let
        ((org-roam-todo-wf-pr--get-pullreq (path)
           ((:input '("/tmp/test-repo") :output nil)))
         (org-roam-todo-prop (event prop)
           ((:input-matcher (lambda (e p) (string= p "PR_NUMBER"))
             :output "99")))
         (org-roam-todo-wf-pr--get-repo-info-via-gh (path)
           ((:input '("/tmp/test-repo") :output '("my-owner" . "my-repo")))))
      (let ((pr-info (org-roam-todo-wf-pr--get-pr-info event "/tmp/test-repo")))
        (should pr-info)
        (should (eq 'property (plist-get pr-info :source)))
        (should (= 99 (plist-get pr-info :pr-number)))
        (should (string= "my-owner" (plist-get pr-info :owner)))
        (should (string= "my-repo" (plist-get pr-info :name)))))))

(ert-deftest wf-pr-test-get-pr-info-falls-back-to-gh-cli ()
  "Test get-pr-info falls back to gh CLI when forge and properties unavailable."
  :tags '(:unit :wf :pr :detection)
  (org-roam-todo-wf-test--require-wf)
  (org-roam-todo-wf-test--require-mocker)
  (require 'org-roam-todo-wf-pr nil t)
  (let* ((event (make-org-roam-todo-event
                 :todo (list :file "/tmp/test-todo.org"))))
    (mocker-let
        ((org-roam-todo-wf-pr--get-pullreq (path)
           ((:input '("/tmp/test-repo") :output nil)))
         (org-roam-todo-prop (event prop)
           ((:input-matcher (lambda (e p) (string= p "PR_NUMBER"))
             :output nil)
            (:input-matcher (lambda (e p) (string= p "WORKTREE_BRANCH"))
             :output "feature/my-branch")))
         (org-roam-todo-wf-pr--get-pr-number-via-gh (path branch)
           ((:input '("/tmp/test-repo" "feature/my-branch") :output "77")))
         (org-roam-todo-wf-pr--get-repo-info-via-gh (path)
           ((:input '("/tmp/test-repo") :output '("gh-owner" . "gh-repo")))))
      (let ((pr-info (org-roam-todo-wf-pr--get-pr-info event "/tmp/test-repo")))
        (should pr-info)
        (should (eq 'gh-cli (plist-get pr-info :source)))
        (should (= 77 (plist-get pr-info :pr-number)))
        (should (string= "gh-owner" (plist-get pr-info :owner)))
        (should (string= "gh-repo" (plist-get pr-info :name)))))))

(ert-deftest wf-pr-test-get-pr-info-returns-nil-when-no-pr ()
  "Test get-pr-info returns nil when no PR can be found."
  :tags '(:unit :wf :pr :detection)
  (org-roam-todo-wf-test--require-wf)
  (org-roam-todo-wf-test--require-mocker)
  (require 'org-roam-todo-wf-pr nil t)
  (let* ((event (make-org-roam-todo-event
                 :todo (list :file "/tmp/test-todo.org"))))
    (mocker-let
        ((org-roam-todo-wf-pr--get-pullreq (path)
           ((:input '("/tmp/test-repo") :output nil)))
         (org-roam-todo-prop (event prop)
           ((:input-matcher (lambda (e p) (string= p "PR_NUMBER"))
             :output nil)
            (:input-matcher (lambda (e p) (string= p "WORKTREE_BRANCH"))
             :output "feature/my-branch")))
         (org-roam-todo-wf-pr--get-pr-number-via-gh (path branch)
           ((:input '("/tmp/test-repo" "feature/my-branch") :output nil))))
      (should-not (org-roam-todo-wf-pr--get-pr-info event "/tmp/test-repo")))))

(ert-deftest wf-pr-test-require-ci-pass-uses-pr-info-fallback ()
  "Test require-ci-pass uses get-pr-info for PR detection."
  :tags '(:unit :wf :pr :validation :ci :detection)
  (org-roam-todo-wf-test--require-wf)
  (org-roam-todo-wf-test--require-mocker)
  (require 'org-roam-todo-wf-pr nil t)
  ;; Test that require-ci-pass uses the new get-pr-info which falls back
  (let* ((event (make-org-roam-todo-event
                 :todo (list :file "/tmp/test-todo.org"))))
    (mocker-let
        ((org-roam-todo-prop (event prop)
           ((:input-matcher (lambda (e p) (string= p "WORKTREE_PATH"))
             :output "/tmp/test-repo")))
         (featurep (feature)
           ((:input '(magit-forge-ci) :output t)))
         (fboundp (sym)
           ((:input-matcher (lambda (s) t) :output t :min-occur 0 :max-occur nil)))
         ;; Return PR info via property fallback
         (org-roam-todo-wf-pr--get-pr-info (event path)
           ((:input-matcher (lambda (e p) (string= p "/tmp/test-repo"))
             :output '(:pr-number 123 :owner "test-owner" :name "test-repo" :source property))))
         (magit-forge-ci--get-checks-via-gh-cli (owner name pr-number)
           ((:input '("test-owner" "test-repo" 123)
             :output '(((state . "success"))))))
         (magit-forge-ci--compute-overall-status (checks)
           ((:input-matcher (lambda (&rest _) t) :output "success"))))
      ;; Should pass when using property-based PR detection
      (should-not (org-roam-todo-wf-pr--require-ci-pass event)))))

(ert-deftest wf-pr-test-require-ci-pass-fails-when-no-pr-found ()
  "Test require-ci-pass returns :fail when no PR can be found via any method."
  :tags '(:unit :wf :pr :validation :ci :detection)
  (org-roam-todo-wf-test--require-wf)
  (org-roam-todo-wf-test--require-mocker)
  (require 'org-roam-todo-wf-pr nil t)
  (let* ((event (make-org-roam-todo-event
                 :todo (list :file "/tmp/test-todo.org"))))
    (mocker-let
        ((org-roam-todo-prop (event prop)
           ((:input-matcher (lambda (e p) (string= p "WORKTREE_PATH"))
             :output "/tmp/test-repo")))
         (featurep (feature)
           ((:input '(magit-forge-ci) :output t)))
         (fboundp (sym)
           ((:input-matcher (lambda (s) t) :output t :min-occur 0 :max-occur nil)))
         ;; No PR found via any method
         (org-roam-todo-wf-pr--get-pr-info (event path)
           ((:input-matcher (lambda (e p) (string= p "/tmp/test-repo"))
             :output nil))))
      (let ((result (org-roam-todo-wf-pr--require-ci-pass event)))
        (should (listp result))
        (should (eq (car result) :fail))
        ;; Error message should mention all methods tried
        (should (string-match-p "forge" (cadr result)))
        (should (string-match-p "properties" (cadr result)))
        (should (string-match-p "gh CLI" (cadr result)))))))

(provide 'org-roam-todo-wf-pr-test)
;;; org-roam-todo-wf-pr-test.el ends here
