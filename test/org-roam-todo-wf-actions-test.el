;;; org-roam-todo-wf-actions-test.el --- Action hook tests -*- lexical-binding: t; -*-

;; Author: Claude Code
;; Version: 0.1.0
;; Package-Requires: ((emacs "28.1") (ert "1.0") (mocker "0.5"))

;;; Commentary:
;; Tests for action hooks in the workflow system.
;; These hooks run during status transitions to perform git operations.

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
;;; git-run Helper Tests
;;; ============================================================

(ert-deftest wf-actions-test-git-run-success ()
  "Test git-run returns exit code and output on success."
  :tags '(:unit :wf :actions :git)
  (org-roam-todo-wf-test--require-wf)
  (org-roam-todo-wf-test--require-mocker)
  (mocker-let
      ((call-process (program &optional infile destination display &rest args)
         ((:input-matcher
           (lambda (prog &rest _) (string= prog "git"))
           :output-generator
           (lambda (&rest _)
             (insert "output text")
             0)))))
    (let ((result (org-roam-todo-wf--git-run "/tmp/test" "status")))
      (should (= 0 (car result)))
      (should (string= "output text" (cdr result))))))

(ert-deftest wf-actions-test-git-run-failure ()
  "Test git-run returns non-zero exit code on failure."
  :tags '(:unit :wf :actions :git)
  (org-roam-todo-wf-test--require-wf)
  (org-roam-todo-wf-test--require-mocker)
  (mocker-let
      ((call-process (program &optional infile destination display &rest args)
         ((:input-matcher
           (lambda (prog &rest _) (string= prog "git"))
           :output-generator
           (lambda (&rest _)
             (insert "error: something failed")
             1)))))
    (let ((result (org-roam-todo-wf--git-run "/tmp/test" "bad-command")))
      (should (= 1 (car result)))
      (should (string-match-p "error" (cdr result))))))

(ert-deftest wf-actions-test-git-run!-success ()
  "Test git-run! returns output on success."
  :tags '(:unit :wf :actions :git)
  (org-roam-todo-wf-test--require-wf)
  (org-roam-todo-wf-test--require-mocker)
  (mocker-let
      ((call-process (program &optional infile destination display &rest args)
         ((:input-matcher
           (lambda (prog &rest _) (string= prog "git"))
           :output-generator
           (lambda (&rest _)
             (insert "success output")
             0)))))
    (should (string= "success output"
                     (org-roam-todo-wf--git-run! "/tmp/test" "status")))))

(ert-deftest wf-actions-test-git-run!-error ()
  "Test git-run! signals error on failure."
  :tags '(:unit :wf :actions :git)
  (org-roam-todo-wf-test--require-wf)
  (org-roam-todo-wf-test--require-mocker)
  (mocker-let
      ((call-process (program &optional infile destination display &rest args)
         ((:input-matcher
           (lambda (prog &rest _) (string= prog "git"))
           :output-generator
           (lambda (&rest _)
             (insert "fatal: bad command")
             128)))))
    (should-error (org-roam-todo-wf--git-run! "/tmp/test" "bad-command"))))

;;; ============================================================
;;; rebase-onto-target Tests
;;; ============================================================

(ert-deftest wf-actions-test-rebase-onto-target-success ()
  "Test rebase-onto-target succeeds with clean rebase."
  :tags '(:unit :wf :actions :git)
  (org-roam-todo-wf-test--require-wf)
  (org-roam-todo-wf-test--require-mocker)
  (let* ((wf (make-org-roam-todo-workflow :config '(:rebase-target "main")))
         (event (make-org-roam-todo-event
                 :todo (list :file "/tmp/test-todo.org")
                 :workflow wf)))
    (mocker-let
        ((org-roam-todo-prop (event prop)
           ((:input-matcher (lambda (e p) (string= p "PROJECT_NAME"))
             :output nil)
            (:input-matcher (lambda (e p) (string= p "TARGET_BRANCH"))
             :output nil)
            (:input-matcher (lambda (e p) (string= p "WORKTREE_PATH"))
             :output "/tmp/test-repo")))
         (org-roam-todo-wf--git-run (dir &rest args)
           ;; fetch succeeds
           ((:input-matcher
             (lambda (d &rest a) (member "fetch" a))
             :output '(0 . ""))
            ;; rebase succeeds
            (:input-matcher
             (lambda (d &rest a) (member "rebase" a))
             :output '(0 . "Successfully rebased")))))
      (should-not (org-roam-todo-wf--rebase-onto-target event)))))

(ert-deftest wf-actions-test-rebase-onto-target-conflict ()
  "Test rebase-onto-target aborts and signals error on conflict."
  :tags '(:unit :wf :actions :git)
  (org-roam-todo-wf-test--require-wf)
  (org-roam-todo-wf-test--require-mocker)
  (let* ((wf (make-org-roam-todo-workflow :config '(:rebase-target "main")))
         (event (make-org-roam-todo-event
                 :todo (list :file "/tmp/test-todo.org")
                 :workflow wf)))
    (mocker-let
        ((org-roam-todo-prop (event prop)
           ((:input-matcher (lambda (e p) (string= p "PROJECT_NAME"))
             :output nil)
            (:input-matcher (lambda (e p) (string= p "TARGET_BRANCH"))
             :output nil)
            (:input-matcher (lambda (e p) (string= p "WORKTREE_PATH"))
             :output "/tmp/test-repo")))
         (org-roam-todo-wf--git-run (dir &rest args)
           ;; fetch succeeds
           ((:input-matcher
             (lambda (d &rest a) (member "fetch" a))
             :output '(0 . ""))
            ;; rebase fails
            (:input-matcher
             (lambda (d &rest a) (and (member "rebase" a)
                                      (not (member "--abort" a))))
             :output '(1 . "CONFLICT"))
            ;; abort succeeds
            (:input-matcher
             (lambda (d &rest a) (member "--abort" a))
             :output '(0 . "")))))
      (should-error (org-roam-todo-wf--rebase-onto-target event)
                    :type 'user-error))))

(ert-deftest wf-actions-test-rebase-onto-target-no-target ()
  "Test rebase-onto-target does nothing when no target configured."
  :tags '(:unit :wf :actions)
  (org-roam-todo-wf-test--require-wf)
  (org-roam-todo-wf-test--require-mocker)
  (let* ((wf (make-org-roam-todo-workflow :config nil))
         (event (make-org-roam-todo-event
                 :todo (list :file "/tmp/test-todo.org")
                 :workflow wf)))
    (mocker-let
        ((org-roam-todo-prop (event prop)
           ((:input-matcher (lambda (e p) t) :output nil :min-occur 0))))
      ;; Should return nil without calling any git commands
      (should-not (org-roam-todo-wf--rebase-onto-target event)))))

;;; ============================================================
;;; push-branch Tests
;;; ============================================================

(ert-deftest wf-actions-test-push-branch-success ()
  "Test push-branch pushes with force-with-lease."
  :tags '(:unit :wf :actions :git)
  (org-roam-todo-wf-test--require-wf)
  (org-roam-todo-wf-test--require-mocker)
  (let* ((event (make-org-roam-todo-event
                 :todo (list :file "/tmp/test-todo.org"))))
    (mocker-let
        ((org-roam-todo-prop (event prop)
           ((:input-matcher (lambda (e p) (string= p "WORKTREE_PATH"))
             :output "/tmp/test-repo")
            (:input-matcher (lambda (e p) (string= p "WORKTREE_BRANCH"))
             :output "feat/my-branch")))
         (org-roam-todo-wf--git-run! (dir &rest args)
           ((:input-matcher
             (lambda (d &rest a)
               (and (member "push" a)
                    (member "--force-with-lease" a)
                    (member "feat/my-branch" a)))
             :output "Everything up-to-date"))))
      ;; Should complete without error
      (org-roam-todo-wf--push-branch event))))

(ert-deftest wf-actions-test-push-branch-no-branch ()
  "Test push-branch signals error when no branch configured."
  :tags '(:unit :wf :actions)
  (org-roam-todo-wf-test--require-wf)
  (org-roam-todo-wf-test--require-mocker)
  (let* ((event (make-org-roam-todo-event
                 :todo (list :file "/tmp/test-todo.org"))))
    (mocker-let
        ((org-roam-todo-prop (event prop)
           ((:input-matcher (lambda (e p) (string= p "WORKTREE_PATH"))
             :output "/tmp/test-repo")
            (:input-matcher (lambda (e p) (string= p "WORKTREE_BRANCH"))
             :output nil))))
      (should-error (org-roam-todo-wf--push-branch event)
                    :type 'user-error))))

;;; ============================================================
;;; ff-merge-to-target Tests
;;; ============================================================

(ert-deftest wf-actions-test-ff-merge-success ()
  "Test ff-merge-to-target performs fast-forward merge."
  :tags '(:unit :wf :actions :git)
  (org-roam-todo-wf-test--require-wf)
  (org-roam-todo-wf-test--require-mocker)
  (let* ((wf (make-org-roam-todo-workflow :config '(:rebase-target "main")))
         (event (make-org-roam-todo-event
                 :todo (list :file "/tmp/test-todo.org")
                 :workflow wf)))
    (mocker-let
        ((org-roam-todo-prop (event prop)
           ((:input-matcher (lambda (e p) (string= p "PROJECT_ROOT"))
             :output "/tmp/project")
            (:input-matcher (lambda (e p) (string= p "WORKTREE_BRANCH"))
             :output "feat/my-branch")
            (:input-matcher (lambda (e p) (string= p "PROJECT_NAME"))
             :output nil)
            (:input-matcher (lambda (e p) (string= p "TARGET_BRANCH"))
             :output nil)))
         (org-roam-todo-wf--git-run! (dir &rest args)
           ((:input-matcher
             (lambda (d &rest a)
               (and (string= d "/tmp/project")
                    (member "merge" a)
                    (member "--ff-only" a)
                    (member "feat/my-branch" a)))
             :output "Fast-forward merge successful"))))
      ;; Should complete without error
      (org-roam-todo-wf--ff-merge-to-target event))))

(ert-deftest wf-actions-test-ff-merge-no-target ()
  "Test ff-merge-to-target signals error when no target configured."
  :tags '(:unit :wf :actions)
  (org-roam-todo-wf-test--require-wf)
  (org-roam-todo-wf-test--require-mocker)
  (let* ((wf (make-org-roam-todo-workflow :config nil))
         (event (make-org-roam-todo-event
                 :todo (list :file "/tmp/test-todo.org")
                 :workflow wf)))
    (mocker-let
        ((org-roam-todo-prop (event prop)
           ((:input-matcher (lambda (e p) t) :output nil :min-occur 0))))
      (should-error (org-roam-todo-wf--ff-merge-to-target event)
                    :type 'user-error))))

(ert-deftest wf-actions-test-ff-merge-no-branch ()
  "Test ff-merge-to-target signals error when no branch."
  :tags '(:unit :wf :actions)
  (org-roam-todo-wf-test--require-wf)
  (org-roam-todo-wf-test--require-mocker)
  (let* ((wf (make-org-roam-todo-workflow :config '(:rebase-target "main")))
         (event (make-org-roam-todo-event
                 :todo (list :file "/tmp/test-todo.org")
                 :workflow wf)))
    (mocker-let
        ((org-roam-todo-prop (event prop)
           ((:input-matcher (lambda (e p) (string= p "PROJECT_ROOT"))
             :output "/tmp/project")
            (:input-matcher (lambda (e p) (string= p "WORKTREE_BRANCH"))
             :output nil)
            (:input-matcher (lambda (e p) (string= p "PROJECT_NAME"))
             :output nil)
            (:input-matcher (lambda (e p) (string= p "TARGET_BRANCH"))
             :output nil))))
      (should-error (org-roam-todo-wf--ff-merge-to-target event)
                    :type 'user-error))))

;;; ============================================================
;;; cleanup-worktree Tests
;;; ============================================================

(ert-deftest wf-actions-test-cleanup-worktree-full ()
  "Test cleanup-worktree removes worktree and deletes branch."
  :tags '(:unit :wf :actions :git)
  (org-roam-todo-wf-test--require-wf)
  (org-roam-todo-wf-test--require-mocker)
  (let* ((event (make-org-roam-todo-event
                 :todo (list :file "/tmp/test-todo.org")))
         (worktree-removed nil)
         (branch-deleted nil))
    (mocker-let
        ((org-roam-todo-prop (event prop)
           ((:input-matcher (lambda (e p) (string= p "PROJECT_ROOT"))
             :output "/tmp/project")
            (:input-matcher (lambda (e p) (string= p "WORKTREE_PATH"))
             :output "/tmp/worktree")
            (:input-matcher (lambda (e p) (string= p "WORKTREE_BRANCH"))
             :output "feat/my-branch")))
         (org-roam-todo-wf--git-run! (dir &rest args)
           ((:input-matcher
             (lambda (d &rest a)
               (when (and (member "worktree" a) (member "remove" a))
                 (setq worktree-removed t))
               (member "worktree" a))
             :output "")
            (:input-matcher
             (lambda (d &rest a)
               (when (and (member "branch" a) (member "-D" a))
                 (setq branch-deleted t))
               (member "branch" a))
             :output ""))))
      (org-roam-todo-wf--cleanup-worktree event)
      (should worktree-removed)
      (should branch-deleted))))

(ert-deftest wf-actions-test-cleanup-worktree-no-worktree ()
  "Test cleanup-worktree handles missing worktree path gracefully."
  :tags '(:unit :wf :actions)
  (org-roam-todo-wf-test--require-wf)
  (org-roam-todo-wf-test--require-mocker)
  (let* ((event (make-org-roam-todo-event
                 :todo (list :file "/tmp/test-todo.org"))))
    (mocker-let
        ((org-roam-todo-prop (event prop)
           ((:input-matcher (lambda (e p) t) :output nil :min-occur 0))))
      ;; Should not error, just skip cleanup
      (should-not (org-roam-todo-wf--cleanup-worktree event)))))

;;; ============================================================
;;; ensure-worktree Tests
;;; ============================================================

(ert-deftest wf-actions-test-ensure-worktree-creates ()
  "Test ensure-worktree creates worktree if not exists."
  :tags '(:unit :wf :actions :git)
  (org-roam-todo-wf-test--require-wf)
  (org-roam-todo-wf-test--require-mocker)
  (let* ((wf (make-org-roam-todo-workflow :config '(:rebase-target "main")))
         (event (make-org-roam-todo-event
                 :todo (list :file "/tmp/test-todo.org")
                 :workflow wf))
         (worktree-created nil))
    (mocker-let
        ((org-roam-todo-prop (event prop)
           ((:input-matcher (lambda (e p) (string= p "PROJECT_ROOT"))
             :output "/tmp/project")
            (:input-matcher (lambda (e p) (string= p "WORKTREE_BRANCH"))
             :output "feat/my-branch")
            (:input-matcher (lambda (e p) (string= p "WORKTREE_PATH"))
             :output "/tmp/worktree")
            (:input-matcher (lambda (e p) (string= p "PROJECT_NAME"))
             :output nil)
            (:input-matcher (lambda (e p) (string= p "TARGET_BRANCH"))
             :output nil)))
         (file-directory-p (path)
           ((:input '("/tmp/worktree") :output nil)))
         (org-roam-todo-branch-exists-p (root branch)
           ((:input '("/tmp/project" "feat/my-branch") :output nil)))
         (org-roam-todo-wf--git-run! (dir &rest args)
           ((:input-matcher
             (lambda (d &rest a)
               (when (and (member "worktree" a) (member "add" a))
                 (setq worktree-created t))
               t)
             :output ""))))
      (org-roam-todo-wf--ensure-worktree event)
      (should worktree-created))))

(ert-deftest wf-actions-test-ensure-worktree-exists ()
  "Test ensure-worktree does nothing if worktree exists."
  :tags '(:unit :wf :actions)
  (org-roam-todo-wf-test--require-wf)
  (org-roam-todo-wf-test--require-mocker)
  (let* ((wf (make-org-roam-todo-workflow :config '(:rebase-target "main")))
         (event (make-org-roam-todo-event
                 :todo (list :file "/tmp/test-todo.org")
                 :workflow wf)))
    (mocker-let
        ((org-roam-todo-prop (event prop)
           ((:input-matcher (lambda (e p) (string= p "PROJECT_ROOT"))
             :output "/tmp/project")
            (:input-matcher (lambda (e p) (string= p "WORKTREE_BRANCH"))
             :output "feat/my-branch")
            (:input-matcher (lambda (e p) (string= p "WORKTREE_PATH"))
             :output "/tmp/worktree")
            (:input-matcher (lambda (e p) (string= p "PROJECT_NAME"))
             :output nil)
            (:input-matcher (lambda (e p) (string= p "TARGET_BRANCH"))
             :output nil)))
         (file-directory-p (path)
           ((:input '("/tmp/worktree") :output t))))
      ;; Should return nil without calling git
      (should-not (org-roam-todo-wf--ensure-worktree event)))))

;;; ============================================================
;;; require-target-clean Tests
;;; ============================================================

(ert-deftest wf-actions-test-require-target-clean-success ()
  "Test require-target-clean passes on clean repo."
  :tags '(:unit :wf :actions :validation)
  (org-roam-todo-wf-test--require-wf)
  (org-roam-todo-wf-test--require-mocker)
  (let* ((event (make-org-roam-todo-event
                 :todo (list :file "/tmp/test-todo.org"))))
    (mocker-let
        ((org-roam-todo-prop (event prop)
           ((:input-matcher (lambda (e p) (string= p "PROJECT_ROOT"))
             :output "/tmp/project")))
         (org-roam-todo-wf--git-run (dir &rest args)
           ((:input-matcher
             (lambda (d &rest a) (member "status" a))
             :output '(0 . "")))))
      ;; Should not error on clean repo
      (should-not (org-roam-todo-wf--require-target-clean event)))))

(ert-deftest wf-actions-test-require-target-clean-dirty ()
  "Test require-target-clean fails on dirty repo."
  :tags '(:unit :wf :actions :validation)
  (org-roam-todo-wf-test--require-wf)
  (org-roam-todo-wf-test--require-mocker)
  (let* ((event (make-org-roam-todo-event
                 :todo (list :file "/tmp/test-todo.org"))))
    (mocker-let
        ((org-roam-todo-prop (event prop)
           ((:input-matcher (lambda (e p) (string= p "PROJECT_ROOT"))
             :output "/tmp/project")))
         (org-roam-todo-wf--git-run (dir &rest args)
           ((:input-matcher
             (lambda (d &rest a) (member "status" a))
             :output '(0 . " M dirty-file.txt\n")))))
      ;; Should error on dirty repo
      (should-error (org-roam-todo-wf--require-target-clean event)
                    :type 'user-error))))

;;; ============================================================
;;; require-ff-possible Tests
;;; ============================================================

(ert-deftest wf-actions-test-require-ff-possible-success ()
  "Test require-ff-possible passes when ff is possible."
  :tags '(:unit :wf :actions :validation)
  (org-roam-todo-wf-test--require-wf)
  (org-roam-todo-wf-test--require-mocker)
  (let* ((wf (make-org-roam-todo-workflow :config '(:rebase-target "main")))
         (event (make-org-roam-todo-event
                 :todo (list :file "/tmp/test-todo.org")
                 :workflow wf)))
    (mocker-let
        ((org-roam-todo-prop (event prop)
           ((:input-matcher (lambda (e p) (string= p "PROJECT_ROOT"))
             :output "/tmp/project")
            (:input-matcher (lambda (e p) (string= p "WORKTREE_BRANCH"))
             :output "feat/my-branch")
            (:input-matcher (lambda (e p) (string= p "PROJECT_NAME"))
             :output nil)
            (:input-matcher (lambda (e p) (string= p "TARGET_BRANCH"))
             :output nil)))
         (org-roam-todo-wf--git-run (dir &rest args)
           ((:input-matcher
             (lambda (d &rest a) (member "merge-base" a))
             :output '(0 . "")))))  ; 0 means target is ancestor
      ;; Should not error when ff is possible
      (should-not (org-roam-todo-wf--require-ff-possible event)))))

(ert-deftest wf-actions-test-require-ff-possible-diverged ()
  "Test require-ff-possible fails when branches have diverged."
  :tags '(:unit :wf :actions :validation)
  (org-roam-todo-wf-test--require-wf)
  (org-roam-todo-wf-test--require-mocker)
  (let* ((wf (make-org-roam-todo-workflow :config '(:rebase-target "main")))
         (event (make-org-roam-todo-event
                 :todo (list :file "/tmp/test-todo.org")
                 :workflow wf)))
    (mocker-let
        ((org-roam-todo-prop (event prop)
           ((:input-matcher (lambda (e p) (string= p "PROJECT_ROOT"))
             :output "/tmp/project")
            (:input-matcher (lambda (e p) (string= p "WORKTREE_BRANCH"))
             :output "feat/my-branch")
            (:input-matcher (lambda (e p) (string= p "PROJECT_NAME"))
             :output nil)
            (:input-matcher (lambda (e p) (string= p "TARGET_BRANCH"))
             :output nil)))
         (org-roam-todo-wf--git-run (dir &rest args)
           ((:input-matcher
             (lambda (d &rest a) (member "merge-base" a))
             :output '(1 . "")))))  ; 1 means target is NOT ancestor (diverged)
      ;; Should error when ff is not possible
      (should-error (org-roam-todo-wf--require-ff-possible event)
                    :type 'user-error))))

(ert-deftest wf-actions-test-require-ff-possible-no-target ()
  "Test require-ff-possible does nothing without target configured."
  :tags '(:unit :wf :actions :validation)
  (org-roam-todo-wf-test--require-wf)
  (org-roam-todo-wf-test--require-mocker)
  (let* ((wf (make-org-roam-todo-workflow :config nil))
         (event (make-org-roam-todo-event
                 :todo (list :file "/tmp/test-todo.org")
                 :workflow wf)))
    (mocker-let
        ((org-roam-todo-prop (event prop)
           ((:input-matcher (lambda (e p) t) :output nil :min-occur 0))))
      ;; Should return nil without error when no target configured
      (should-not (org-roam-todo-wf--require-ff-possible event)))))

;;; ============================================================
;;; cleanup-project-buffers Tests
;;; ============================================================

(ert-deftest wf-actions-test-cleanup-project-buffers-no-worktree ()
  "Test cleanup-project-buffers does nothing when no worktree."
  :tags '(:unit :wf :actions :cleanup)
  (org-roam-todo-wf-test--require-wf)
  (org-roam-todo-wf-test--require-mocker)
  (let* ((event (make-org-roam-todo-event
                 :todo (list :file "/tmp/test-todo.org"))))
    (mocker-let
        ((org-roam-todo-prop (event prop)
           ((:input-matcher (lambda (e p) t) :output nil :min-occur 0))))
      ;; Should not error when no worktree-path
      (should-not (org-roam-todo-wf--cleanup-project-buffers event)))))

(ert-deftest wf-actions-test-cleanup-project-buffers-nonexistent ()
  "Test cleanup-project-buffers does nothing when worktree doesn't exist."
  :tags '(:unit :wf :actions :cleanup)
  (org-roam-todo-wf-test--require-wf)
  (org-roam-todo-wf-test--require-mocker)
  (let* ((event (make-org-roam-todo-event
                 :todo (list :file "/tmp/test-todo.org"))))
    (mocker-let
        ((org-roam-todo-prop (event prop)
           ((:input-matcher (lambda (e p) (string= p "WORKTREE_PATH"))
             :output "/nonexistent/path"))))
      ;; Should not error when directory doesn't exist
      (should-not (org-roam-todo-wf--cleanup-project-buffers event)))))

;;; ============================================================
;;; cleanup-todo-buffer Tests
;;; ============================================================

(ert-deftest wf-actions-test-cleanup-todo-buffer-no-file ()
  "Test cleanup-todo-buffer does nothing when no file."
  :tags '(:unit :wf :actions :cleanup)
  (org-roam-todo-wf-test--require-wf)
  (let* ((event (make-org-roam-todo-event
                 :todo (list :file nil))))
    ;; Should not error when no file
    (should-not (org-roam-todo-wf--cleanup-todo-buffer event))))

(ert-deftest wf-actions-test-cleanup-todo-buffer-not-visiting ()
  "Test cleanup-todo-buffer does nothing when buffer not visiting file."
  :tags '(:unit :wf :actions :cleanup)
  (org-roam-todo-wf-test--require-wf)
  (let* ((event (make-org-roam-todo-event
                 :todo (list :file "/tmp/nonexistent-todo.org"))))
    ;; Should not error when no buffer visiting that file
    (should-not (org-roam-todo-wf--cleanup-todo-buffer event))))

;;; ============================================================
;;; cleanup-claude-agent Tests
;;; ============================================================

(ert-deftest wf-actions-test-cleanup-claude-agent-no-worktree ()
  "Test cleanup-claude-agent does nothing when no worktree."
  :tags '(:unit :wf :actions :cleanup)
  (org-roam-todo-wf-test--require-wf)
  (org-roam-todo-wf-test--require-mocker)
  (let* ((event (make-org-roam-todo-event
                 :todo (list :file "/tmp/test-todo.org"))))
    (mocker-let
        ((org-roam-todo-prop (event prop)
           ((:input-matcher (lambda (e p) t) :output nil :min-occur 0))))
      ;; Should not error when no worktree-path
      (should-not (org-roam-todo-wf--cleanup-claude-agent event)))))

(ert-deftest wf-actions-test-cleanup-claude-agent-no-matching-buffer ()
  "Test cleanup-claude-agent does nothing when no matching buffer."
  :tags '(:unit :wf :actions :cleanup)
  (org-roam-todo-wf-test--require-wf)
  (org-roam-todo-wf-test--require-mocker)
  (let* ((event (make-org-roam-todo-event
                 :todo (list :file "/tmp/test-todo.org"))))
    (mocker-let
        ((org-roam-todo-prop (event prop)
           ((:input-matcher (lambda (e p) (string= p "WORKTREE_PATH"))
             :output "/tmp/test-worktree"))))
      ;; Should not error when no claude buffer matches
      (should-not (org-roam-todo-wf--cleanup-claude-agent event)))))

;;; ============================================================
;;; cleanup-all Tests
;;; ============================================================

(ert-deftest wf-actions-test-cleanup-all-calls-all-cleanups ()
  "Test cleanup-all calls all cleanup functions."
  :tags '(:unit :wf :actions :cleanup)
  (org-roam-todo-wf-test--require-wf)
  (org-roam-todo-wf-test--require-mocker)
  (let* ((event (make-org-roam-todo-event
                 :todo (list :file "/tmp/todo.org")))
         (calls '()))
    (mocker-let
        ((org-roam-todo-wf--cleanup-claude-agent (e)
           ((:input-matcher (lambda (_) t)
             :output (push 'claude calls))))
         (org-roam-todo-wf--cleanup-project-buffers (e)
           ((:input-matcher (lambda (_) t)
             :output (push 'project calls))))
         (org-roam-todo-wf--cleanup-todo-buffer (e)
           ((:input-matcher (lambda (_) t)
             :output (push 'todo calls))))
         (org-roam-todo-wf--cleanup-worktree (e)
           ((:input-matcher (lambda (_) t)
             :output (push 'worktree calls)))))
      (org-roam-todo-wf--cleanup-all event)
      ;; All functions should have been called (in reverse order due to push)
      (should (member 'claude calls))
      (should (member 'project calls))
      (should (member 'todo calls))
      (should (member 'worktree calls)))))

;;; ============================================================
;;; ensure-branch Tests
;;; ============================================================

(ert-deftest wf-actions-test-ensure-branch-generates-name ()
  "Test ensure-branch generates branch name from title."
  :tags '(:unit :wf :actions :branch)
  (org-roam-todo-wf-test--require-wf)
  (org-roam-todo-wf-test--require-mocker)
  (let* ((workflow (make-org-roam-todo-workflow
                    :name 'test
                    :statuses '("draft" "active" "done")
                    :hooks nil
                    :config '(:rebase-target "main")))
         (event (make-org-roam-todo-event
                 :type :on-enter-active
                 :todo (list :file "/tmp/test-todo.org")
                 :workflow workflow))
         (created-branch nil))
    (mocker-let
        ((org-roam-todo-prop (event prop)
           ((:input-matcher (lambda (e p) (string= p "PROJECT_ROOT"))
             :output "/tmp/test-project")
            (:input-matcher (lambda (e p) (string= p "PROJECT_NAME"))
             :output "test-project")
            (:input-matcher (lambda (e p) (string= p "TITLE"))
             :output "Test Feature")
            (:input-matcher (lambda (e p) (string= p "WORKTREE_BRANCH"))
             :output nil)
            ;; get-target-branch-from-event reads PROJECT_NAME then TARGET_BRANCH
            (:input-matcher (lambda (e p) (string= p "PROJECT_NAME"))
             :output "test-project")
            (:input-matcher (lambda (e p) (string= p "TARGET_BRANCH"))
             :output nil)
            ;; Then ensure-branch checks WORKTREE_PATH to set it if missing
            (:input-matcher (lambda (e p) (string= p "WORKTREE_PATH"))
             :output nil)))
         (org-roam-todo--resolve-file (event)
           ((:input-matcher (lambda (e) t)
             :output "/tmp/test-todo.org")))
         (org-roam-todo-branch-exists-p (root branch)
           ((:input-matcher (lambda (r b) t)
             :output nil)))
         (org-roam-todo-wf--git-run (dir &rest args)
           ((:input-matcher (lambda (d &rest a) t)
             :output '(0 . "") :min-occur 0)))
         (org-roam-todo-wf--git-run! (dir &rest args)
           ((:input-matcher (lambda (d &rest a) t)
             :output-generator (lambda (d &rest a)
                                 (when (equal (car a) "branch")
                                   (setq created-branch (nth 1 a)))
                                 ""))))
         (org-roam-todo-wf--set-todo-property (file prop val)
           ((:input-matcher (lambda (f p v) t)
             :output nil :min-occur 0))))
      (org-roam-todo-wf--ensure-branch event)
      ;; Should have created a branch with slugified name
      (should created-branch)
      (should (string-match-p "test-feature" created-branch)))))

(ert-deftest wf-actions-test-ensure-branch-uses-existing ()
  "Test ensure-branch uses existing branch name from TODO."
  :tags '(:unit :wf :actions :branch)
  (org-roam-todo-wf-test--require-wf)
  (org-roam-todo-wf-test--require-mocker)
  (let* ((workflow (make-org-roam-todo-workflow
                    :name 'test
                    :statuses '("draft" "active" "done")
                    :hooks nil
                    :config '(:rebase-target "main")))
         (event (make-org-roam-todo-event
                 :type :on-enter-active
                 :todo (list :file "/tmp/test-todo.org")
                 :workflow workflow))
         (created-branch nil))
    (mocker-let
        ((org-roam-todo-prop (event prop)
           ((:input-matcher (lambda (e p) (string= p "PROJECT_ROOT"))
             :output "/tmp/test-project")
            (:input-matcher (lambda (e p) (string= p "PROJECT_NAME"))
             :output "test-project")
            (:input-matcher (lambda (e p) (string= p "TITLE"))
             :output "Test Feature")
            (:input-matcher (lambda (e p) (string= p "WORKTREE_BRANCH"))
             :output "custom/my-branch")
            ;; get-target-branch-from-event reads PROJECT_NAME then TARGET_BRANCH
            (:input-matcher (lambda (e p) (string= p "PROJECT_NAME"))
             :output "test-project")
            (:input-matcher (lambda (e p) (string= p "TARGET_BRANCH"))
             :output nil)
            ;; Then ensure-branch checks WORKTREE_PATH to set it if missing
            (:input-matcher (lambda (e p) (string= p "WORKTREE_PATH"))
             :output nil)))
         (org-roam-todo--resolve-file (event)
           ((:input-matcher (lambda (e) t)
             :output "/tmp/test-todo.org")))
         (org-roam-todo-branch-exists-p (root branch)
           ((:input-matcher (lambda (r b) (string= b "custom/my-branch"))
             :output t)))
         (org-roam-todo-wf--git-run (dir &rest args)
           ((:input-matcher (lambda (d &rest a) t)
             :output '(0 . "") :min-occur 0)))
         (org-roam-todo-wf--git-run! (dir &rest args)
           ((:input-matcher (lambda (d &rest a) t)
             :output-generator (lambda (d &rest a)
                                 (when (equal (car a) "branch")
                                   (setq created-branch (nth 1 a)))
                                 "")
             :min-occur 0)))
         (org-roam-todo-wf--set-todo-property (file prop val)
           ((:input-matcher (lambda (f p v) t)
             :output nil :min-occur 0))))
      (org-roam-todo-wf--ensure-branch event)
      ;; Should NOT create a new branch - existing one is used
      (should-not created-branch))))

(ert-deftest wf-actions-test-ensure-branch-fetches-when-configured ()
  "Test ensure-branch fetches from origin when configured."
  :tags '(:unit :wf :actions :branch)
  (org-roam-todo-wf-test--require-wf)
  (org-roam-todo-wf-test--require-mocker)
  (let* ((workflow (make-org-roam-todo-workflow
                    :name 'test
                    :statuses '("draft" "active" "done")
                    :hooks nil
                    :config '(:rebase-target "main")))
         (event (make-org-roam-todo-event
                 :type :on-enter-active
                 :todo (list :file "/tmp/test-todo.org")
                 :workflow workflow))
         (fetch-called nil)
         ;; Enable fetch
         (org-roam-todo-worktree-fetch-before-create t))
    (mocker-let
        ((org-roam-todo-prop (event prop)
           ((:input-matcher (lambda (e p) (string= p "PROJECT_ROOT"))
             :output "/tmp/test-project")
            (:input-matcher (lambda (e p) (string= p "PROJECT_NAME"))
             :output "test-project")
            (:input-matcher (lambda (e p) (string= p "TITLE"))
             :output "Test Feature")
            (:input-matcher (lambda (e p) (string= p "WORKTREE_BRANCH"))
             :output "existing-branch")
            ;; get-target-branch-from-event reads PROJECT_NAME then TARGET_BRANCH
            (:input-matcher (lambda (e p) (string= p "PROJECT_NAME"))
             :output "test-project")
            (:input-matcher (lambda (e p) (string= p "TARGET_BRANCH"))
             :output nil)
            ;; Then ensure-branch checks WORKTREE_PATH to set it if missing
            (:input-matcher (lambda (e p) (string= p "WORKTREE_PATH"))
             :output nil)))
         (org-roam-todo--resolve-file (event)
           ((:input-matcher (lambda (e) t)
             :output "/tmp/test-todo.org")))
         (org-roam-todo-branch-exists-p (root branch)
           ((:input-matcher (lambda (r b) t)
             :output t)))
         (org-roam-todo-wf--git-run (dir &rest args)
           ((:input-matcher (lambda (d &rest a) (member "fetch" a))
             :output-generator (lambda (d &rest a)
                                 (setq fetch-called t)
                                 '(0 . "")))))
         (org-roam-todo-wf--git-run! (dir &rest args)
           ((:input-matcher (lambda (d &rest a) t)
             :output "" :min-occur 0)))
         (org-roam-todo-wf--set-todo-property (file prop val)
           ((:input-matcher (lambda (f p v) t)
             :output nil :min-occur 0))))
      (org-roam-todo-wf--ensure-branch event)
      ;; Should have fetched
      (should fetch-called))))

(ert-deftest wf-actions-test-ensure-branch-no-fetch-when-disabled ()
  "Test ensure-branch skips fetch when disabled."
  :tags '(:unit :wf :actions :branch)
  (org-roam-todo-wf-test--require-wf)
  (org-roam-todo-wf-test--require-mocker)
  (let* ((workflow (make-org-roam-todo-workflow
                    :name 'test
                    :statuses '("draft" "active" "done")
                    :hooks nil
                    :config '(:rebase-target "main")))
         (event (make-org-roam-todo-event
                 :type :on-enter-active
                 :todo (list :file "/tmp/test-todo.org")
                 :workflow workflow))
         (fetch-called nil)
         ;; Disable fetch
         (org-roam-todo-worktree-fetch-before-create nil))
    (mocker-let
        ((org-roam-todo-prop (event prop)
           ((:input-matcher (lambda (e p) (string= p "PROJECT_ROOT"))
             :output "/tmp/test-project")
            (:input-matcher (lambda (e p) (string= p "PROJECT_NAME"))
             :output "test-project")
            (:input-matcher (lambda (e p) (string= p "TITLE"))
             :output "Test Feature")
            (:input-matcher (lambda (e p) (string= p "WORKTREE_BRANCH"))
             :output "existing-branch")
            ;; get-target-branch-from-event reads PROJECT_NAME then TARGET_BRANCH
            (:input-matcher (lambda (e p) (string= p "PROJECT_NAME"))
             :output "test-project")
            (:input-matcher (lambda (e p) (string= p "TARGET_BRANCH"))
             :output nil)
            ;; Then ensure-branch checks WORKTREE_PATH to set it if missing
            (:input-matcher (lambda (e p) (string= p "WORKTREE_PATH"))
             :output nil)))
         (org-roam-todo--resolve-file (event)
           ((:input-matcher (lambda (e) t)
             :output "/tmp/test-todo.org")))
         (org-roam-todo-branch-exists-p (root branch)
           ((:input-matcher (lambda (r b) t)
             :output t)))
         (org-roam-todo-wf--git-run (dir &rest args)
           ((:input-matcher (lambda (d &rest a) (member "fetch" a))
             :output-generator (lambda (d &rest a)
                                 (setq fetch-called t)
                                 '(0 . ""))
             :min-occur 0)))
         (org-roam-todo-wf--git-run! (dir &rest args)
           ((:input-matcher (lambda (d &rest a) t)
             :output "" :min-occur 0)))
         (org-roam-todo-wf--set-todo-property (file prop val)
           ((:input-matcher (lambda (f p v) t)
             :output nil :min-occur 0))))
      (org-roam-todo-wf--ensure-branch event)
      ;; Should NOT have fetched
      (should-not fetch-called))))

(provide 'org-roam-todo-wf-actions-test)
;;; org-roam-todo-wf-actions-test.el ends here
