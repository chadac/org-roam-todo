;;; org-roam-todo-wf-actions-integration-test.el --- Integration tests for actions -*- lexical-binding: t; -*-

;; Author: Claude Code
;; Version: 0.1.0
;; Package-Requires: ((emacs "28.1") (ert "1.0"))

;;; Commentary:
;; Integration tests for action hooks using real git repositories.
;; These tests verify actual git behavior, not mocked behavior.
;;
;; Run with: just test-integration
;; Or: just test-match "wf-actions-integration"

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'org-roam-todo-wf)
(require 'org-roam-todo-wf-actions)
(require 'org-roam-todo-wf-test-utils)

;;; ============================================================
;;; git-run Helper Integration Tests
;;; ============================================================

(ert-deftest wf-actions-integration-git-run-real-command ()
  "Test git-run executes real git commands."
  :tags '(:integration :wf :actions :git)
  (org-roam-todo-wf-test--require-wf)
  (org-roam-todo-wf-test-with-git-repo
    (let ((result (org-roam-todo-wf--git-run repo-dir "status" "--porcelain")))
      ;; Should succeed with exit code 0
      (should (= 0 (car result)))
      ;; Clean repo should have empty output
      (should (string-empty-p (string-trim (cdr result)))))))

(ert-deftest wf-actions-integration-git-run-with-output ()
  "Test git-run captures command output."
  :tags '(:integration :wf :actions :git)
  (org-roam-todo-wf-test--require-wf)
  (org-roam-todo-wf-test-with-git-repo
    (let ((result (org-roam-todo-wf--git-run repo-dir "branch" "--list")))
      (should (= 0 (car result)))
      ;; Should show master or main branch
      (should (or (string-match-p "master\\|main" (cdr result)))))))

(ert-deftest wf-actions-integration-git-run-failure ()
  "Test git-run returns non-zero for bad commands."
  :tags '(:integration :wf :actions :git)
  (org-roam-todo-wf-test--require-wf)
  (org-roam-todo-wf-test-with-git-repo
    (let ((result (org-roam-todo-wf--git-run repo-dir "checkout" "nonexistent-branch")))
      ;; Should fail
      (should (not (= 0 (car result))))
      ;; Should have error message
      (should (string-match-p "error\\|did not match" (cdr result))))))

(ert-deftest wf-actions-integration-git-run!-signals-on-failure ()
  "Test git-run! signals error for failed commands."
  :tags '(:integration :wf :actions :git)
  (org-roam-todo-wf-test--require-wf)
  (org-roam-todo-wf-test-with-git-repo
    (should-error
     (org-roam-todo-wf--git-run! repo-dir "checkout" "nonexistent-branch"))))

;;; ============================================================
;;; Validation Hooks Integration Tests
;;; ============================================================

(ert-deftest wf-actions-integration-require-clean-worktree-clean ()
  "Test require-clean-worktree passes on clean repo."
  :tags '(:integration :wf :actions :validation)
  (org-roam-todo-wf-test--require-wf)
  (org-roam-todo-wf-test-with-git-repo
    ;; Create a TODO file OUTSIDE the repo so it doesn't make the repo dirty
    (let* ((todo-dir (make-temp-file "wf-test-todo-" t))
           (todo-file (org-roam-todo-wf-test--create-todo-file
                       todo-dir
                       (list :worktree-path repo-dir)))
           (event (make-org-roam-todo-event
                   :todo (list :file todo-file))))
      (unwind-protect
          ;; Should not error on clean repo
          (should-not (org-roam-todo-wf--require-clean-worktree event))
        (delete-directory todo-dir t)))))

(ert-deftest wf-actions-integration-require-clean-worktree-dirty ()
  "Test require-clean-worktree fails on dirty repo."
  :tags '(:integration :wf :actions :validation)
  (org-roam-todo-wf-test--require-wf)
  (org-roam-todo-wf-test-with-git-repo
    ;; Create uncommitted change
    (org-roam-todo-wf-test--create-file repo-dir "dirty.txt" "uncommitted")
    ;; Create a TODO file OUTSIDE the repo
    (let* ((todo-dir (make-temp-file "wf-test-todo-" t))
           (todo-file (org-roam-todo-wf-test--create-todo-file
                       todo-dir
                       (list :worktree-path repo-dir)))
           (event (make-org-roam-todo-event
                   :todo (list :file todo-file))))
      (unwind-protect
          ;; Should error on dirty repo
          (should-error (org-roam-todo-wf--require-clean-worktree event)
                        :type 'user-error)
        (delete-directory todo-dir t)))))

(ert-deftest wf-actions-integration-require-staged-changes-with-staged ()
  "Test require-staged-changes passes with staged changes."
  :tags '(:integration :wf :actions :validation)
  (org-roam-todo-wf-test--require-wf)
  (org-roam-todo-wf-test-with-git-repo
    ;; Stage a file
    (org-roam-todo-wf-test--stage-file repo-dir "new-file.txt" "staged content")
    ;; Create a TODO file OUTSIDE the repo
    (let* ((todo-dir (make-temp-file "wf-test-todo-" t))
           (todo-file (org-roam-todo-wf-test--create-todo-file
                       todo-dir
                       (list :worktree-path repo-dir)))
           (event (make-org-roam-todo-event
                   :todo (list :file todo-file))))
      (unwind-protect
          ;; Should not error with staged changes
          (should-not (org-roam-todo-wf--require-staged-changes event))
        (delete-directory todo-dir t)))))

(ert-deftest wf-actions-integration-require-staged-changes-without-staged ()
  "Test require-staged-changes fails without staged changes."
  :tags '(:integration :wf :actions :validation)
  (org-roam-todo-wf-test--require-wf)
  (org-roam-todo-wf-test-with-git-repo
    ;; Create a TODO file OUTSIDE the repo
    (let* ((todo-dir (make-temp-file "wf-test-todo-" t))
           (todo-file (org-roam-todo-wf-test--create-todo-file
                       todo-dir
                       (list :worktree-path repo-dir)))
           (event (make-org-roam-todo-event
                   :todo (list :file todo-file))))
      (unwind-protect
          ;; Should error without staged changes
          (should-error (org-roam-todo-wf--require-staged-changes event)
                        :type 'user-error)
        (delete-directory todo-dir t)))))

(ert-deftest wf-actions-integration-has-staged-changes-p ()
  "Test has-staged-changes-p detects staged changes."
  :tags '(:integration :wf :actions :validation)
  (org-roam-todo-wf-test--require-wf)
  (org-roam-todo-wf-test-with-git-repo
    ;; Initially no staged changes
    (should-not (org-roam-todo-wf--has-staged-changes-p repo-dir))
    ;; Stage a file
    (org-roam-todo-wf-test--stage-file repo-dir "staged.txt" "content")
    ;; Now should have staged changes
    (should (org-roam-todo-wf--has-staged-changes-p repo-dir))))

;;; ============================================================
;;; Worktree Action Integration Tests
;;; ============================================================

(ert-deftest wf-actions-integration-ensure-worktree-creates ()
  "Test ensure-worktree creates a new worktree."
  :tags '(:integration :wf :actions :worktree)
  (org-roam-todo-wf-test--require-wf)
  (org-roam-todo-wf-test-with-git-repo
    (let* ((worktree-path (expand-file-name "test-worktree" temporary-file-directory))
           (branch-name "feat/test-branch")
           (wf (make-org-roam-todo-workflow :config nil))
           ;; Create a TODO file with the required properties
           (todo-file (org-roam-todo-wf-test--create-todo-file
                       repo-dir
                       (list :project-root repo-dir
                             :worktree-path worktree-path
                             :worktree-branch branch-name)))
           (event (make-org-roam-todo-event
                   :todo (list :file todo-file)
                   :workflow wf)))
      ;; Ensure worktree-path doesn't exist
      (when (file-exists-p worktree-path)
        (delete-directory worktree-path t))
      (unwind-protect
          (progn
            ;; Create the worktree
            (org-roam-todo-wf--ensure-worktree event)
            ;; Verify worktree was created
            (should (file-directory-p worktree-path))
            ;; Verify it's a git worktree
            (should (file-exists-p (expand-file-name ".git" worktree-path)))
            ;; Verify branch was created
            (should (org-roam-todo-wf-test--branch-exists-p repo-dir branch-name)))
        ;; Cleanup
        (ignore-errors
          (org-roam-todo-wf-test--git repo-dir "worktree" "remove" "--force" worktree-path))
        (ignore-errors
          (org-roam-todo-wf-test--git repo-dir "branch" "-D" branch-name))
        (ignore-errors
          (delete-directory worktree-path t))))))

(ert-deftest wf-actions-integration-ensure-worktree-skips-existing ()
  "Test ensure-worktree does nothing if worktree exists."
  :tags '(:integration :wf :actions :worktree)
  (org-roam-todo-wf-test--require-wf)
  (org-roam-todo-wf-test-with-git-worktree
    (let* ((wf (make-org-roam-todo-workflow :config nil))
           ;; Create a TODO file with the required properties
           (todo-file (org-roam-todo-wf-test--create-todo-file
                       repo-dir
                       (list :project-root repo-dir
                             :worktree-path worktree-dir
                             :worktree-branch branch-name)))
           (event (make-org-roam-todo-event
                   :todo (list :file todo-file)
                   :workflow wf))
           (commit-before (org-roam-todo-wf-test--git! worktree-dir "rev-parse" "HEAD")))
      ;; Call ensure-worktree on existing worktree
      (org-roam-todo-wf--ensure-worktree event)
      ;; Verify nothing changed
      (let ((commit-after (org-roam-todo-wf-test--git! worktree-dir "rev-parse" "HEAD")))
        (should (string= commit-before commit-after))))))

(ert-deftest wf-actions-integration-cleanup-worktree ()
  "Test cleanup-worktree removes worktree and branch."
  :tags '(:integration :wf :actions :worktree)
  (org-roam-todo-wf-test--require-wf)
  (org-roam-todo-wf-test-with-git-repo
    (let* ((worktree-path (expand-file-name "cleanup-test-worktree" temporary-file-directory))
           (branch-name "feat/cleanup-test"))
      ;; Ensure clean state
      (when (file-exists-p worktree-path)
        (delete-directory worktree-path t))
      ;; Create worktree manually
      (org-roam-todo-wf-test--create-worktree repo-dir worktree-path branch-name)
      ;; Verify it exists
      (should (file-directory-p worktree-path))
      (should (org-roam-todo-wf-test--branch-exists-p repo-dir branch-name))
      ;; Create a TODO file with the required properties
      (let* ((todo-file (org-roam-todo-wf-test--create-todo-file
                         repo-dir
                         (list :project-root repo-dir
                               :worktree-path worktree-path
                               :worktree-branch branch-name)))
             (event (make-org-roam-todo-event
                     :todo (list :file todo-file))))
        (org-roam-todo-wf--cleanup-worktree event))
      ;; Verify worktree is gone
      (should-not (file-directory-p worktree-path))
      ;; Verify branch is gone
      (should-not (org-roam-todo-wf-test--branch-exists-p repo-dir branch-name)))))

;;; ============================================================
;;; Fast-Forward Merge Integration Tests
;;; ============================================================

(ert-deftest wf-actions-integration-ff-merge-success ()
  "Test ff-merge-to-target performs fast-forward merge."
  :tags '(:integration :wf :actions :merge)
  (org-roam-todo-wf-test--require-wf)
  (org-roam-todo-wf-test-with-git-repo
    (let* ((main-branch (org-roam-todo-wf-test--current-branch repo-dir))
           (feature-branch "feat/ff-test")
           (worktree-path (expand-file-name "ff-test-worktree" temporary-file-directory)))
      ;; Ensure clean state
      (when (file-exists-p worktree-path)
        (delete-directory worktree-path t))
      ;; Create feature branch and worktree
      (org-roam-todo-wf-test--create-worktree repo-dir worktree-path feature-branch)
      (unwind-protect
          (progn
            ;; Add a commit to feature branch
            (org-roam-todo-wf-test--add-commit worktree-path "feature.txt" "Add feature")
            ;; Get the feature commit SHA
            (let ((feature-sha (org-roam-todo-wf-test--git! worktree-path "rev-parse" "HEAD"))
                  (main-sha-before (org-roam-todo-wf-test--git! repo-dir "rev-parse" main-branch)))
              ;; Create a TODO file with the required properties
              (let* ((todo-file (org-roam-todo-wf-test--create-todo-file
                                 repo-dir
                                 (list :project-root repo-dir
                                       :worktree-branch feature-branch)))
                     (wf (make-org-roam-todo-workflow :config `(:rebase-target ,main-branch)))
                     (event (make-org-roam-todo-event
                             :todo (list :file todo-file)
                             :workflow wf)))
                ;; Perform ff-merge
                (org-roam-todo-wf--ff-merge-to-target event))
              ;; Verify main now points to feature's commit
              (let ((main-sha-after (org-roam-todo-wf-test--git! repo-dir "rev-parse" main-branch)))
                (should (string= feature-sha main-sha-after)))))
        ;; Cleanup
        (ignore-errors
          (org-roam-todo-wf-test--git repo-dir "worktree" "remove" "--force" worktree-path))
        (ignore-errors
          (org-roam-todo-wf-test--git repo-dir "branch" "-D" feature-branch))
        (ignore-errors
          (delete-directory worktree-path t))))))

(ert-deftest wf-actions-integration-ff-merge-fails-diverged ()
  "Test ff-merge-to-target fails when branches have diverged."
  :tags '(:integration :wf :actions :merge)
  (org-roam-todo-wf-test--require-wf)
  (org-roam-todo-wf-test-with-git-repo
    (let* ((main-branch (org-roam-todo-wf-test--current-branch repo-dir))
           (feature-branch "feat/diverged-test")
           (worktree-path (expand-file-name "diverged-test-worktree" temporary-file-directory)))
      ;; Ensure clean state
      (when (file-exists-p worktree-path)
        (delete-directory worktree-path t))
      ;; Create feature branch and worktree
      (org-roam-todo-wf-test--create-worktree repo-dir worktree-path feature-branch)
      (unwind-protect
          (progn
            ;; Add a commit to feature branch
            (org-roam-todo-wf-test--add-commit worktree-path "feature.txt" "Add feature")
            ;; Add a commit to main (causing divergence)
            (org-roam-todo-wf-test--add-commit repo-dir "main-change.txt" "Add main change")
            ;; Create a TODO file with the required properties
            (let* ((todo-file (org-roam-todo-wf-test--create-todo-file
                               repo-dir
                               (list :project-root repo-dir
                                     :worktree-branch feature-branch)))
                   (wf (make-org-roam-todo-workflow :config `(:rebase-target ,main-branch)))
                   (event (make-org-roam-todo-event
                           :todo (list :file todo-file)
                           :workflow wf)))
              ;; Try ff-merge - should fail
              (should-error (org-roam-todo-wf--ff-merge-to-target event))))
        ;; Cleanup
        (ignore-errors
          (org-roam-todo-wf-test--git repo-dir "worktree" "remove" "--force" worktree-path))
        (ignore-errors
          (org-roam-todo-wf-test--git repo-dir "branch" "-D" feature-branch))
        (ignore-errors
          (delete-directory worktree-path t))))))

;;; ============================================================
;;; Test Helper Verification Tests
;;; ============================================================

(ert-deftest wf-actions-integration-test-helpers-work ()
  "Meta-test: verify test helper functions work correctly."
  :tags '(:integration :wf :actions :helpers)
  (org-roam-todo-wf-test-with-git-repo
    ;; Test branch operations
    (org-roam-todo-wf-test--create-branch repo-dir "test-branch")
    (should (org-roam-todo-wf-test--branch-exists-p repo-dir "test-branch"))

    ;; Test file operations (stage the file so it doesn't leave repo dirty)
    (org-roam-todo-wf-test--stage-file repo-dir "test-file.txt" "test content")
    (should (file-exists-p (expand-file-name "test-file.txt" repo-dir)))

    ;; Test staging detection
    (should (org-roam-todo-wf-test--has-staged-changes-p repo-dir))

    ;; Test commit
    (let ((sha (org-roam-todo-wf-test--commit repo-dir "Test commit")))
      (should (= 40 (length sha))))  ; SHA is 40 chars

    ;; Test clean state (after committing all staged files)
    (should (org-roam-todo-wf-test--is-clean-p repo-dir))

    ;; Test unstaged changes detection
    (org-roam-todo-wf-test--create-file repo-dir "unstaged.txt" "unstaged")
    (should-not (org-roam-todo-wf-test--is-clean-p repo-dir))))

;;; ============================================================
;;; require-target-clean Integration Tests
;;; ============================================================

(ert-deftest wf-actions-integration-require-target-clean-clean ()
  "Integration test: require-target-clean passes on clean repo."
  :tags '(:integration :wf :actions :validation)
  (org-roam-todo-wf-test--require-wf)
  (org-roam-todo-wf-test-with-git-repo
    ;; Create a TODO file OUTSIDE the repo
    (let* ((todo-dir (make-temp-file "wf-test-todo-" t))
           (todo-file (org-roam-todo-wf-test--create-todo-file
                       todo-dir
                       (list :project-root repo-dir)))
           (event (make-org-roam-todo-event
                   :todo (list :file todo-file))))
      (unwind-protect
          ;; Should not error on clean repo
          (should-not (org-roam-todo-wf--require-target-clean event))
        (delete-directory todo-dir t)))))

(ert-deftest wf-actions-integration-require-target-clean-dirty ()
  "Integration test: require-target-clean fails on dirty repo."
  :tags '(:integration :wf :actions :validation)
  (org-roam-todo-wf-test--require-wf)
  (org-roam-todo-wf-test-with-git-repo
    ;; Create uncommitted change
    (org-roam-todo-wf-test--create-file repo-dir "dirty.txt" "uncommitted")
    ;; Create a TODO file OUTSIDE the repo
    (let* ((todo-dir (make-temp-file "wf-test-todo-" t))
           (todo-file (org-roam-todo-wf-test--create-todo-file
                       todo-dir
                       (list :project-root repo-dir)))
           (event (make-org-roam-todo-event
                   :todo (list :file todo-file))))
      (unwind-protect
          ;; Should error on dirty repo
          (should-error (org-roam-todo-wf--require-target-clean event)
                        :type 'user-error)
        (delete-directory todo-dir t)))))

;;; ============================================================
;;; require-ff-possible Integration Tests
;;; ============================================================

(ert-deftest wf-actions-integration-require-ff-possible-success ()
  "Integration test: require-ff-possible passes when ff is possible."
  :tags '(:integration :wf :actions :validation)
  (org-roam-todo-wf-test--require-wf)
  (org-roam-todo-wf-test-with-git-repo
    (let* ((main-branch (org-roam-todo-wf-test--current-branch repo-dir))
           (todo-dir (make-temp-file "wf-test-todo-" t)))
      (unwind-protect
          (progn
            ;; Create feature branch with a commit (ahead of main)
            (org-roam-todo-wf-test--create-branch repo-dir "feature")
            (org-roam-todo-wf-test--checkout repo-dir "feature")
            (org-roam-todo-wf-test--add-commit repo-dir "feature.txt" "Add feature")
            ;; Go back to main
            (org-roam-todo-wf-test--checkout repo-dir main-branch)
            ;; Create a TODO file OUTSIDE the repo
            (let* ((todo-file (org-roam-todo-wf-test--create-todo-file
                               todo-dir
                               (list :project-root repo-dir
                                     :worktree-branch "feature")))
                   (wf (make-org-roam-todo-workflow :config `(:rebase-target ,main-branch)))
                   (event (make-org-roam-todo-event
                           :todo (list :file todo-file)
                           :workflow wf)))
              ;; Should not error - feature is ahead of main, ff possible
              (should-not (org-roam-todo-wf--require-ff-possible event))))
        (delete-directory todo-dir t)))))

(ert-deftest wf-actions-integration-require-ff-possible-diverged ()
  "Integration test: require-ff-possible fails when branches diverged."
  :tags '(:integration :wf :actions :validation)
  (org-roam-todo-wf-test--require-wf)
  (org-roam-todo-wf-test-with-git-repo
    (let* ((main-branch (org-roam-todo-wf-test--current-branch repo-dir))
           (todo-dir (make-temp-file "wf-test-todo-" t)))
      (unwind-protect
          (progn
            ;; Create feature branch with a commit
            (org-roam-todo-wf-test--create-branch repo-dir "feature")
            (org-roam-todo-wf-test--checkout repo-dir "feature")
            (org-roam-todo-wf-test--add-commit repo-dir "feature.txt" "Add feature")
            ;; Go back to main and add a different commit (causing divergence)
            (org-roam-todo-wf-test--checkout repo-dir main-branch)
            (org-roam-todo-wf-test--add-commit repo-dir "main-change.txt" "Main change")
            ;; Create a TODO file OUTSIDE the repo
            (let* ((todo-file (org-roam-todo-wf-test--create-todo-file
                               todo-dir
                               (list :project-root repo-dir
                                     :worktree-branch "feature")))
                   (wf (make-org-roam-todo-workflow :config `(:rebase-target ,main-branch)))
                   (event (make-org-roam-todo-event
                           :todo (list :file todo-file)
                           :workflow wf)))
              ;; Should error - branches have diverged
              (should-error (org-roam-todo-wf--require-ff-possible event)
                            :type 'user-error)))
        (delete-directory todo-dir t)))))

(provide 'org-roam-todo-wf-actions-integration-test)
;;; org-roam-todo-wf-actions-integration-test.el ends here
