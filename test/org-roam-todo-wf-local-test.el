;;; org-roam-todo-wf-local-test.el --- Local fast-forward workflow tests -*- lexical-binding: t; -*-

;; Author: Claude Code
;; Version: 0.1.0
;; Package-Requires: ((emacs "28.1") (ert "1.0") (mocker "0.5"))

;;; Commentary:
;; Tests for the local-ff workflow which provides a simple local fast-forward
;; merge workflow without GitHub PR integration.
;;
;; Workflow: draft -> active -> review -> done
;; - draft: TODO exists, no work started
;; - active: Worktree created, work in progress
;; - review: Changes ready for local review (magit diff)
;; - done: Fast-forward merged to main, pushed, cleaned up

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

;;; ============================================================
;;; Workflow Definition Tests
;;; ============================================================

(ert-deftest wf-local-test-workflow-registered ()
  "Test that local-ff workflow is registered after requiring the module."
  :tags '(:unit :wf :local)
  (org-roam-todo-wf-test--require-wf)
  ;; Load the local workflow module
  (require 'org-roam-todo-wf-local nil t)
  (let ((wf (gethash 'local-ff org-roam-todo-wf--registry)))
    (should wf)
    (should (eq 'local-ff (org-roam-todo-workflow-name wf)))))

(ert-deftest wf-local-test-workflow-statuses ()
  "Test that local-ff workflow has correct statuses."
  :tags '(:unit :wf :local)
  (org-roam-todo-wf-test--require-wf)
  (require 'org-roam-todo-wf-local nil t)
  (let ((wf (gethash 'local-ff org-roam-todo-wf--registry)))
    (should wf)
    (should (equal '("draft" "active" "review" "done")
                   (org-roam-todo-workflow-statuses wf)))))

(ert-deftest wf-local-test-workflow-allows-review-regress ()
  "Test that local-ff workflow allows regressing from review to active."
  :tags '(:unit :wf :local)
  (org-roam-todo-wf-test--require-wf)
  (require 'org-roam-todo-wf-local nil t)
  (let ((wf (gethash 'local-ff org-roam-todo-wf--registry)))
    (should wf)
    (let ((config (org-roam-todo-workflow-config wf)))
      (should (member 'review (plist-get config :allow-backward))))))

;;; ============================================================
;;; Hook Registration Tests
;;; ============================================================

(ert-deftest wf-local-test-has-enter-active-hook ()
  "Test that local-ff workflow has :on-enter-active hooks."
  :tags '(:unit :wf :local)
  (org-roam-todo-wf-test--require-wf)
  (require 'org-roam-todo-wf-local nil t)
  (let* ((wf (gethash 'local-ff org-roam-todo-wf--registry))
         (hooks (org-roam-todo-workflow-hooks wf)))
    (should (assq :on-enter-active hooks))))

(ert-deftest wf-local-test-has-validate-review-hook ()
  "Test that local-ff workflow has :validate-review hooks."
  :tags '(:unit :wf :local)
  (org-roam-todo-wf-test--require-wf)
  (require 'org-roam-todo-wf-local nil t)
  (let* ((wf (gethash 'local-ff org-roam-todo-wf--registry))
         (hooks (org-roam-todo-workflow-hooks wf)))
    (should (assq :validate-review hooks))))

(ert-deftest wf-local-test-has-enter-review-hook ()
  "Test that local-ff workflow has :on-enter-review hooks."
  :tags '(:unit :wf :local)
  (org-roam-todo-wf-test--require-wf)
  (require 'org-roam-todo-wf-local nil t)
  (let* ((wf (gethash 'local-ff org-roam-todo-wf--registry))
         (hooks (org-roam-todo-workflow-hooks wf)))
    (should (assq :on-enter-review hooks))))

(ert-deftest wf-local-test-has-enter-done-hook ()
  "Test that local-ff workflow has :on-enter-done hooks."
  :tags '(:unit :wf :local)
  (org-roam-todo-wf-test--require-wf)
  (require 'org-roam-todo-wf-local nil t)
  (let* ((wf (gethash 'local-ff org-roam-todo-wf--registry))
         (hooks (org-roam-todo-workflow-hooks wf)))
    (should (assq :on-enter-done hooks))))

(ert-deftest wf-local-test-has-validate-done-hook ()
  "Test that local-ff workflow has :validate-done hooks."
  :tags '(:unit :wf :local)
  (org-roam-todo-wf-test--require-wf)
  (require 'org-roam-todo-wf-local nil t)
  (let* ((wf (gethash 'local-ff org-roam-todo-wf--registry))
         (hooks (org-roam-todo-workflow-hooks wf)))
    (should (assq :validate-done hooks))))

;;; ============================================================
;;; Transition Tests
;;; ============================================================

(ert-deftest wf-local-test-valid-forward-transitions ()
  "Test valid forward transitions in local-ff workflow."
  :tags '(:unit :wf :local :transitions)
  (org-roam-todo-wf-test--require-wf)
  (require 'org-roam-todo-wf-local nil t)
  (let ((wf (gethash 'local-ff org-roam-todo-wf--registry)))
    (should (org-roam-todo-wf--valid-transition-p wf "draft" "active"))
    (should (org-roam-todo-wf--valid-transition-p wf "active" "review"))
    (should (org-roam-todo-wf--valid-transition-p wf "review" "done"))))

(ert-deftest wf-local-test-backward-from-review ()
  "Test backward transition from review to active is allowed."
  :tags '(:unit :wf :local :transitions)
  (org-roam-todo-wf-test--require-wf)
  (require 'org-roam-todo-wf-local nil t)
  (let ((wf (gethash 'local-ff org-roam-todo-wf--registry)))
    (should (org-roam-todo-wf--valid-transition-p wf "review" "active"))))

(ert-deftest wf-local-test-backward-from-active-not-allowed ()
  "Test backward transition from active to draft is NOT allowed."
  :tags '(:unit :wf :local :transitions)
  (org-roam-todo-wf-test--require-wf)
  (require 'org-roam-todo-wf-local nil t)
  (let ((wf (gethash 'local-ff org-roam-todo-wf--registry)))
    (should-not (org-roam-todo-wf--valid-transition-p wf "active" "draft"))))

(ert-deftest wf-local-test-rejected-always-available ()
  "Test that rejected is always available from any status."
  :tags '(:unit :wf :local :transitions)
  (org-roam-todo-wf-test--require-wf)
  (require 'org-roam-todo-wf-local nil t)
  (let ((wf (gethash 'local-ff org-roam-todo-wf--registry)))
    (should (org-roam-todo-wf--valid-transition-p wf "draft" "rejected"))
    (should (org-roam-todo-wf--valid-transition-p wf "active" "rejected"))
    (should (org-roam-todo-wf--valid-transition-p wf "review" "rejected"))
    (should (org-roam-todo-wf--valid-transition-p wf "done" "rejected"))))

;;; ============================================================
;;; open-magit-review Tests
;;; ============================================================

(ert-deftest wf-local-test-open-magit-review ()
  "Test that entering review opens magit for diff review."
  :tags '(:unit :wf :local)
  (org-roam-todo-wf-test--require-wf)
  (org-roam-todo-wf-test--require-mocker)
  (require 'org-roam-todo-wf-local nil t)
  (let ((magit-opened nil))
    (mocker-let
        ((org-roam-todo-prop (event prop)
           ;; Order matches actual read order: WORKTREE_PATH, WORKTREE_BRANCH, TARGET_BRANCH
           ((:input-matcher (lambda (e p) (string= p "WORKTREE_PATH"))
             :output "/tmp/test-repo")
            (:input-matcher (lambda (e p) (string= p "WORKTREE_BRANCH"))
             :output "feature")
            (:input-matcher (lambda (e p) (string= p "TARGET_BRANCH"))
             :output nil)))
         (magit-diff-range (range)
           ((:input-matcher #'always
             :output-generator (lambda (range) (setq magit-opened range) nil)))))
      (let* ((wf (make-org-roam-todo-workflow :config '(:rebase-target "main")))
             (event (make-org-roam-todo-event
                     :todo (list :file "/tmp/test-todo.org")
                     :workflow wf)))
        (org-roam-todo-wf-local--open-magit-review event)
        (should magit-opened)
        (should (string-match-p "main" magit-opened))
        (should (string-match-p "feature" magit-opened))))))

;;; ============================================================
;;; push-main Tests
;;; ============================================================

(ert-deftest wf-local-test-push-main ()
  "Test push-main pushes the target branch to origin."
  :tags '(:unit :wf :local :git)
  (org-roam-todo-wf-test--require-wf)
  (org-roam-todo-wf-test--require-mocker)
  (require 'org-roam-todo-wf-local nil t)
  (let* ((wf (make-org-roam-todo-workflow :config '(:rebase-target "main")))
         (event (make-org-roam-todo-event
                 :todo (list :file "/tmp/test-todo.org")
                 :workflow wf)))
    (mocker-let
        ((org-roam-todo-prop (event prop)
           ;; Order matches actual read order: PROJECT_ROOT, TARGET_BRANCH
           ((:input-matcher (lambda (e p) (string= p "PROJECT_ROOT"))
             :output "/tmp/project")
            (:input-matcher (lambda (e p) (string= p "TARGET_BRANCH"))
             :output nil)))
         (org-roam-todo-wf--git-run! (dir &rest args)
           ((:input-matcher
             (lambda (d &rest a)
               (and (string= d "/tmp/project")
                    (member "push" a)
                    (member "origin" a)
                    (member "main" a)))
             :output "Everything up-to-date"))))
      ;; Should complete without error
      (org-roam-todo-wf-local--push-main event))))

(ert-deftest wf-local-test-push-main-no-target ()
  "Test push-main errors when no rebase target configured."
  :tags '(:unit :wf :local)
  (org-roam-todo-wf-test--require-wf)
  (require 'org-roam-todo-wf-local nil t)
  (let* ((wf (make-org-roam-todo-workflow :config nil))
         (event (make-org-roam-todo-event
                 :todo (list :project-root "/tmp/project")
                 :workflow wf)))
    (should-error (org-roam-todo-wf-local--push-main event)
                  :type 'user-error)))

;;; ============================================================
;;; Integration Tests with Real Git
;;; ============================================================

(ert-deftest wf-local-integration-enter-active-creates-worktree ()
  "Integration test: entering active status creates worktree.
Uses a workflow without rebase-target since we have no remote."
  :tags '(:integration :wf :local :git)
  (org-roam-todo-wf-test--require-wf)
  (require 'org-roam-todo-wf-local nil t)
  (org-roam-todo-wf-test-with-git-repo
    (let* ((worktree-dir (make-temp-file "wf-worktree-" t))
           (todo-dir (make-temp-file "wf-test-todo-" t))
           ;; Use a workflow without rebase-target to avoid needing origin
           (wf (make-org-roam-todo-workflow :config nil))
           (todo-file (org-roam-todo-wf-test--create-todo-file
                       todo-dir
                       (list :project-root repo-dir
                             :worktree-path worktree-dir
                             :worktree-branch "feat/test-feature")))
           (event (make-org-roam-todo-event
                   :todo (list :file todo-file)
                   :workflow wf)))
      ;; Remove the temp dir so git worktree add can create it
      (delete-directory worktree-dir)
      (unwind-protect
          (progn
            (org-roam-todo-wf--ensure-worktree event)
            (should (file-directory-p worktree-dir))
            ;; Verify it's a git worktree
            (should (file-exists-p (expand-file-name ".git" worktree-dir))))
        ;; Cleanup
        (when (file-directory-p worktree-dir)
          (let ((default-directory repo-dir))
            (call-process "git" nil nil nil "worktree" "remove" "--force" worktree-dir)
            (ignore-errors
              (call-process "git" nil nil nil "branch" "-D" "feat/test-feature"))))
        (delete-directory todo-dir t)))))

(ert-deftest wf-local-integration-ff-merge-to-main ()
  "Integration test: fast-forward merge to main works."
  :tags '(:integration :wf :local :git)
  (org-roam-todo-wf-test--require-wf)
  (require 'org-roam-todo-wf-local nil t)
  (org-roam-todo-wf-test-with-git-repo
    ;; Create a feature branch with a commit
    (org-roam-todo-wf-test--create-branch repo-dir "feature")
    (org-roam-todo-wf-test--checkout repo-dir "feature")
    (org-roam-todo-wf-test--add-commit repo-dir "feature.txt" "Add feature" "feature content")

    ;; Get the feature SHA before merge
    (let ((feature-sha (org-roam-todo-wf-test--git! repo-dir "rev-parse" "HEAD")))
      ;; Switch back to main
      (org-roam-todo-wf-test--checkout repo-dir "main")

      ;; Create TODO file and event, then perform ff-merge
      (let* ((todo-dir (make-temp-file "wf-test-todo-" t))
             (wf (make-org-roam-todo-workflow :config '(:rebase-target "main")))
             (todo-file (org-roam-todo-wf-test--create-todo-file
                         todo-dir
                         (list :project-root repo-dir
                               :worktree-branch "feature")))
             (event (make-org-roam-todo-event
                     :todo (list :file todo-file)
                     :workflow wf)))
        (unwind-protect
            (progn
              (org-roam-todo-wf--ff-merge-to-target event)

              ;; Verify main now points to feature's commit
              (let ((main-sha (org-roam-todo-wf-test--git! repo-dir "rev-parse" "HEAD")))
                (should (string= feature-sha main-sha)))

              ;; Verify feature.txt exists on main
              (should (file-exists-p (expand-file-name "feature.txt" repo-dir))))
          (delete-directory todo-dir t))))))

(ert-deftest wf-local-integration-full-workflow ()
  "Integration test: complete local-ff workflow from draft to done."
  :tags '(:integration :wf :local :git)
  (org-roam-todo-wf-test--require-wf)
  (require 'org-roam-todo-wf-local nil t)
  (org-roam-todo-wf-test-with-git-repo
    (let* ((worktree-dir (make-temp-file "wf-worktree-" t))
           (todo-dir (make-temp-file "wf-test-todo-" t))
           (branch-name "feat/full-workflow-test")
           (wf (gethash 'local-ff org-roam-todo-wf--registry))
           (todo-file (org-roam-todo-wf-test--create-todo-file
                       todo-dir
                       (list :project-root repo-dir
                             :worktree-path worktree-dir
                             :worktree-branch branch-name))))
      ;; Remove temp dir for git worktree add
      (delete-directory worktree-dir)

      (unwind-protect
          (progn
            ;; 1. Create worktree (simulates entering active)
            (org-roam-todo-wf-test--create-worktree repo-dir worktree-dir branch-name)
            (should (file-directory-p worktree-dir))

            ;; 2. Make changes in worktree
            (org-roam-todo-wf-test--add-commit worktree-dir "new-feature.txt"
                                                "Add new feature" "feature code")

            ;; 3. Verify we can ff-merge (simulates entering done)
            (org-roam-todo-wf-test--checkout repo-dir "main")
            (let ((event (make-org-roam-todo-event
                          :todo (list :file todo-file)
                          :workflow wf)))
              (org-roam-todo-wf--ff-merge-to-target event))

            ;; 4. Verify merge succeeded
            (should (file-exists-p (expand-file-name "new-feature.txt" repo-dir)))

            ;; 5. Cleanup worktree (simulates cleanup on done)
            (let ((event (make-org-roam-todo-event
                          :todo (list :file todo-file)
                          :workflow wf)))
              (org-roam-todo-wf--cleanup-worktree event))

            ;; 6. Verify cleanup
            (should-not (file-directory-p worktree-dir))
            (should-not (org-roam-todo-wf-test--branch-exists-p repo-dir branch-name)))

        ;; Ensure cleanup even on test failure
        (when (file-directory-p worktree-dir)
          (ignore-errors
            (let ((default-directory repo-dir))
              (call-process "git" nil nil nil "worktree" "remove" "--force" worktree-dir)
              (call-process "git" nil nil nil "branch" "-D" branch-name))))
        (delete-directory todo-dir t)))))

;;; ============================================================
;;; End-to-End Workflow Tests
;;; ============================================================

(ert-deftest wf-local-e2e-validate-done-rejects-dirty-target ()
  "E2E test: validate-done rejects transition when target repo is dirty."
  :tags '(:integration :wf :local :e2e)
  (org-roam-todo-wf-test--require-wf)
  (require 'org-roam-todo-wf-local nil t)
  (org-roam-todo-wf-test-with-git-repo
    (let* ((worktree-dir (make-temp-file "wf-worktree-" t))
           (todo-dir (make-temp-file "wf-test-todo-" t))
           (branch-name "feat/e2e-dirty-test")
           (wf (gethash 'local-ff org-roam-todo-wf--registry))
           (todo-file (org-roam-todo-wf-test--create-todo-file
                       todo-dir
                       (list :project-root repo-dir
                             :worktree-path worktree-dir
                             :worktree-branch branch-name))))
      (delete-directory worktree-dir)
      (unwind-protect
          (progn
            ;; Create worktree and make a commit
            (org-roam-todo-wf-test--create-worktree repo-dir worktree-dir branch-name)
            (org-roam-todo-wf-test--add-commit worktree-dir "feature.txt"
                                                "Add feature" "feature code")
            ;; Go back to main
            (org-roam-todo-wf-test--checkout repo-dir "main")

            ;; Make target repo dirty (uncommitted file)
            (org-roam-todo-wf-test--create-file repo-dir "dirty.txt" "uncommitted")

            ;; Try to validate done - should fail due to dirty target
            (let ((event (make-org-roam-todo-event
                          :todo (list :file todo-file)
                          :workflow wf)))
              (should-error (org-roam-todo-wf--require-target-clean event)
                            :type 'user-error)))

        ;; Cleanup
        (when (file-directory-p worktree-dir)
          (ignore-errors
            (let ((default-directory repo-dir))
              (call-process "git" nil nil nil "worktree" "remove" "--force" worktree-dir)
              (call-process "git" nil nil nil "branch" "-D" branch-name))))
        (delete-directory todo-dir t)))))

(ert-deftest wf-local-e2e-validate-done-rejects-diverged ()
  "E2E test: validate-done rejects transition when branches have diverged."
  :tags '(:integration :wf :local :e2e)
  (org-roam-todo-wf-test--require-wf)
  (require 'org-roam-todo-wf-local nil t)
  (org-roam-todo-wf-test-with-git-repo
    (let* ((worktree-dir (make-temp-file "wf-worktree-" t))
           (todo-dir (make-temp-file "wf-test-todo-" t))
           (branch-name "feat/e2e-diverged-test")
           (wf (gethash 'local-ff org-roam-todo-wf--registry))
           (todo-file (org-roam-todo-wf-test--create-todo-file
                       todo-dir
                       (list :project-root repo-dir
                             :worktree-path worktree-dir
                             :worktree-branch branch-name))))
      (delete-directory worktree-dir)
      (unwind-protect
          (progn
            ;; Create worktree and make a commit
            (org-roam-todo-wf-test--create-worktree repo-dir worktree-dir branch-name)
            (org-roam-todo-wf-test--add-commit worktree-dir "feature.txt"
                                                "Add feature" "feature code")
            ;; Go back to main and add a different commit (causes divergence)
            (org-roam-todo-wf-test--checkout repo-dir "main")
            (org-roam-todo-wf-test--add-commit repo-dir "main-change.txt"
                                                "Main change" "main code")

            ;; Try to validate done - should fail due to divergence
            (let ((event (make-org-roam-todo-event
                          :todo (list :file todo-file)
                          :workflow wf)))
              (should-error (org-roam-todo-wf--require-ff-possible event)
                            :type 'user-error)))

        ;; Cleanup
        (when (file-directory-p worktree-dir)
          (ignore-errors
            (let ((default-directory repo-dir))
              (call-process "git" nil nil nil "worktree" "remove" "--force" worktree-dir)
              (call-process "git" nil nil nil "branch" "-D" branch-name))))
        (delete-directory todo-dir t)))))

(ert-deftest wf-local-e2e-validate-done-passes-clean-ff ()
  "E2E test: validate-done passes when target is clean and ff is possible."
  :tags '(:integration :wf :local :e2e)
  (org-roam-todo-wf-test--require-wf)
  (require 'org-roam-todo-wf-local nil t)
  (org-roam-todo-wf-test-with-git-repo
    (let* ((worktree-dir (make-temp-file "wf-worktree-" t))
           (branch-name "feat/e2e-clean-ff-test")
           (wf (gethash 'local-ff org-roam-todo-wf--registry))
           (todo-dir (make-temp-file "wf-test-todo-" t))
           (todo-file (org-roam-todo-wf-test--create-todo-file
                       todo-dir
                       (list :project-root repo-dir
                             :worktree-path worktree-dir
                             :worktree-branch branch-name))))
      (delete-directory worktree-dir)
      (unwind-protect
          (progn
            ;; Create worktree and make a commit
            (org-roam-todo-wf-test--create-worktree repo-dir worktree-dir branch-name)
            (org-roam-todo-wf-test--add-commit worktree-dir "feature.txt"
                                                "Add feature" "feature code")
            ;; Go back to main (leave it clean, no additional commits)
            (org-roam-todo-wf-test--checkout repo-dir "main")

            ;; Validate done - should pass
            (let ((event (make-org-roam-todo-event
                          :todo (list :file todo-file)
                          :workflow wf)))
              ;; Both validations should pass
              (should-not (org-roam-todo-wf--require-target-clean event))
              (should-not (org-roam-todo-wf--require-ff-possible event))))

        ;; Cleanup
        (when (file-directory-p worktree-dir)
          (ignore-errors
            (let ((default-directory repo-dir))
              (call-process "git" nil nil nil "worktree" "remove" "--force" worktree-dir)
              (call-process "git" nil nil nil "branch" "-D" branch-name))))
        (delete-directory todo-dir t)))))

(ert-deftest wf-local-e2e-complete-workflow-with-validations ()
  "E2E test: complete local-ff workflow including all validations.
Tests the full lifecycle: draft -> active -> review -> done.
Note: Uses test helpers for worktree creation since we don't have a remote."
  :tags '(:integration :wf :local :e2e)
  (org-roam-todo-wf-test--require-wf)
  (require 'org-roam-todo-wf-local nil t)
  (org-roam-todo-wf-test-with-git-repo
    (let* ((worktree-dir (make-temp-file "wf-worktree-" t))
           (branch-name "feat/e2e-complete-workflow")
           (wf (gethash 'local-ff org-roam-todo-wf--registry))
           (todo-dir (make-temp-file "wf-test-todo-" t))
           (todo-file (org-roam-todo-wf-test--create-todo-file
                       todo-dir
                       (list :project-root repo-dir
                             :worktree-path worktree-dir
                             :worktree-branch branch-name))))
      (delete-directory worktree-dir)
      (unwind-protect
          (progn
            ;; === PHASE 1: draft -> active ===
            ;; Use test helper for worktree creation (no remote in test repo)
            (org-roam-todo-wf-test--create-worktree repo-dir worktree-dir branch-name)
            (should (file-directory-p worktree-dir))
            (should (org-roam-todo-wf-test--branch-exists-p repo-dir branch-name))

            ;; === PHASE 2: Work in active state ===
            ;; Make changes and commit
            (org-roam-todo-wf-test--add-commit worktree-dir "feature.txt"
                                                "Implement feature" "feature code")

            ;; === PHASE 3: active -> review ===
            ;; Validate review requirements (clean worktree)
            (let ((event (make-org-roam-todo-event
                          :todo (list :file todo-file)
                          :workflow wf)))
              (should-not (org-roam-todo-wf--require-clean-worktree event)))

            ;; === PHASE 4: review -> done ===
            ;; First checkout main for the merge
            (org-roam-todo-wf-test--checkout repo-dir "main")

            ;; Validate done requirements
            (let ((event (make-org-roam-todo-event
                          :todo (list :file todo-file)
                          :workflow wf)))
              ;; Target should be clean
              (should-not (org-roam-todo-wf--require-target-clean event))
              ;; FF should be possible
              (should-not (org-roam-todo-wf--require-ff-possible event))

              ;; Perform the merge
              (org-roam-todo-wf--ff-merge-to-target event)
              ;; Verify merge succeeded
              (should (file-exists-p (expand-file-name "feature.txt" repo-dir)))

              ;; Cleanup worktree
              (org-roam-todo-wf--cleanup-worktree event))

            ;; === PHASE 5: Verify final state ===
            (should-not (file-directory-p worktree-dir))
            (should-not (org-roam-todo-wf-test--branch-exists-p repo-dir branch-name))
            ;; Feature file should be on main
            (should (file-exists-p (expand-file-name "feature.txt" repo-dir))))

        ;; Cleanup on test failure
        (when (file-directory-p worktree-dir)
          (ignore-errors
            (let ((default-directory repo-dir))
              (call-process "git" nil nil nil "worktree" "remove" "--force" worktree-dir)
              (call-process "git" nil nil nil "branch" "-D" branch-name))))
        (delete-directory todo-dir t)))))

(provide 'org-roam-todo-wf-local-test)
;;; org-roam-todo-wf-local-test.el ends here
