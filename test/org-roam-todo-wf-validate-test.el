;;; org-roam-todo-wf-validate-test.el --- Validation hook tests -*- lexical-binding: t; -*-

;; Author: Claude Code
;; Version: 0.1.0
;; Package-Requires: ((emacs "28.1") (ert "1.0") (mocker "0.5"))

;;; Commentary:
;; Tests for validation hooks in the workflow system.
;; These hooks run before status transitions and can reject them.

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
;;; require-clean-worktree Tests
;;; ============================================================

(ert-deftest wf-validate-test-clean-worktree-passes ()
  "Test require-clean-worktree passes with clean worktree."
  :tags '(:unit :wf :validation :git)
  (org-roam-todo-wf-test--require-wf)
  (org-roam-todo-wf-test--require-mocker)
  (let ((event (make-org-roam-todo-event
                :todo (list :file "/tmp/test-todo.org"))))
    ;; Mock org-roam-todo-prop and git-run
    (mocker-let
        ((org-roam-todo-prop (event prop)
           ((:input-matcher (lambda (e p) (string= p "WORKTREE_PATH"))
             :output "/tmp/test-repo")))
         (org-roam-todo-wf--git-run (dir &rest args)
           ((:input-matcher
             (lambda (d &rest a) (member "status" a))
             :output '(0 . "")))))
      (should-not (org-roam-todo-wf--require-clean-worktree event)))))

(ert-deftest wf-validate-test-clean-worktree-fails ()
  "Test require-clean-worktree fails with uncommitted changes."
  :tags '(:unit :wf :validation :git)
  (org-roam-todo-wf-test--require-wf)
  (org-roam-todo-wf-test--require-mocker)
  (let ((event (make-org-roam-todo-event
                :todo (list :file "/tmp/test-todo.org"))))
    ;; Mock org-roam-todo-prop and git-run returning dirty files
    (mocker-let
        ((org-roam-todo-prop (event prop)
           ((:input-matcher (lambda (e p) (string= p "WORKTREE_PATH"))
             :output "/tmp/test-repo")))
         (org-roam-todo-wf--git-run (dir &rest args)
           ((:input-matcher
             (lambda (d &rest a) (member "status" a))
             :output '(0 . " M dirty.txt\n?? untracked.txt")))))
      (should-error (org-roam-todo-wf--require-clean-worktree event)
                    :type 'user-error))))

;;; ============================================================
;;; require-staged-changes Tests
;;; ============================================================

(ert-deftest wf-validate-test-staged-changes-passes ()
  "Test require-staged-changes passes with staged changes."
  :tags '(:unit :wf :validation :git)
  (org-roam-todo-wf-test--require-wf)
  (org-roam-todo-wf-test--require-mocker)
  (let ((event (make-org-roam-todo-event
                :todo (list :file "/tmp/test-todo.org"))))
    (mocker-let
        ((org-roam-todo-prop (event prop)
           ((:input-matcher (lambda (e p) (string= p "WORKTREE_PATH"))
             :output "/tmp/test-repo")))
         (org-roam-todo-wf--has-staged-changes-p (path)
           ((:input '("/tmp/test-repo") :output t))))
      (should-not (org-roam-todo-wf--require-staged-changes event)))))

(ert-deftest wf-validate-test-staged-changes-fails ()
  "Test require-staged-changes fails without staged changes."
  :tags '(:unit :wf :validation :git)
  (org-roam-todo-wf-test--require-wf)
  (org-roam-todo-wf-test--require-mocker)
  (let ((event (make-org-roam-todo-event
                :todo (list :file "/tmp/test-todo.org"))))
    (mocker-let
        ((org-roam-todo-prop (event prop)
           ((:input-matcher (lambda (e p) (string= p "WORKTREE_PATH"))
             :output "/tmp/test-repo")))
         (org-roam-todo-wf--has-staged-changes-p (path)
           ((:input '("/tmp/test-repo") :output nil))))
      (should-error (org-roam-todo-wf--require-staged-changes event)
                    :type 'user-error))))

;;; ============================================================
;;; require-rebase-clean Tests
;;; ============================================================

(ert-deftest wf-validate-test-rebase-clean-no-target ()
  "Test require-rebase-clean passes when no rebase target configured."
  :tags '(:unit :wf :validation)
  (org-roam-todo-wf-test--require-wf)
  (org-roam-todo-wf-test--require-mocker)
  (let* ((wf (make-org-roam-todo-workflow :config nil))
         (event (make-org-roam-todo-event
                 :todo (list :file "/tmp/test-todo.org")
                 :workflow wf)))
    ;; Mock org-roam-todo-prop to return nil for TARGET_BRANCH
    (mocker-let
        ((org-roam-todo-prop (event prop)
           ((:input-matcher (lambda (e p) t) :output nil :min-occur 0))))
      ;; No target = no rebase = passes
      (should-not (org-roam-todo-wf--require-rebase-clean event)))))

(ert-deftest wf-validate-test-rebase-clean-passes ()
  "Test require-rebase-clean passes when rebase is clean."
  :tags '(:unit :wf :validation)
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
           ((:input-matcher (lambda (d &rest a) (member "fetch" a))
             :output '(0 . ""))
            ;; rebase succeeds
            (:input-matcher (lambda (d &rest a) (member "rebase" a))
             :output '(0 . "")))))
      (should-not (org-roam-todo-wf--require-rebase-clean event)))))

(ert-deftest wf-validate-test-rebase-clean-fails ()
  "Test require-rebase-clean fails on rebase conflict."
  :tags '(:unit :wf :validation)
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
           ((:input-matcher (lambda (d &rest a) (member "fetch" a))
             :output '(0 . ""))
            ;; rebase fails with conflict
            (:input-matcher (lambda (d &rest a)
                              (and (member "rebase" a)
                                   (not (member "--abort" a))))
             :output '(1 . "CONFLICT"))
            ;; abort is called
            (:input-matcher (lambda (d &rest a) (member "--abort" a))
             :output '(0 . "")))))
      (should-error (org-roam-todo-wf--require-rebase-clean event)
                    :type 'user-error))))

(ert-deftest wf-validate-test-rebase-uses-todo-target-branch ()
  "Test require-rebase-clean uses TODO's TARGET_BRANCH over workflow config."
  :tags '(:unit :wf :validation)
  (org-roam-todo-wf-test--require-wf)
  (org-roam-todo-wf-test--require-mocker)
  (let* ((wf (make-org-roam-todo-workflow :config '(:rebase-target "main")))
         (event (make-org-roam-todo-event
                 :todo (list :file "/tmp/test-todo.org")
                 :workflow wf))
         (rebased-target nil))
    (mocker-let
        ((org-roam-todo-prop (event prop)
           ((:input-matcher (lambda (e p) (string= p "PROJECT_NAME"))
             :output nil)
            (:input-matcher (lambda (e p) (string= p "TARGET_BRANCH"))
             :output "feat/parent-branch")
            (:input-matcher (lambda (e p) (string= p "WORKTREE_PATH"))
             :output "/tmp/test-repo")))
         (org-roam-todo-wf--git-run (dir &rest args)
           (;; fetch is called (just `git fetch`, no specific branch)
            (:input-matcher (lambda (d &rest a) (member "fetch" a))
             :output '(0 . ""))
            ;; rebase uses the TODO's target branch
            (:input-matcher
             (lambda (d &rest a)
               (when (member "rebase" a)
                 (setq rebased-target (car (last a)))
                 t))
             :output '(0 . "")))))
      (org-roam-todo-wf--require-rebase-clean event)
      ;; Should have rebased onto the TODO's target branch, not workflow's
      (should (equal "feat/parent-branch" rebased-target)))))

;;; ============================================================
;;; require-pre-commit-pass Tests
;;; ============================================================

(ert-deftest wf-validate-test-pre-commit-no-hook ()
  "Test require-pre-commit-pass passes when no pre-commit hook exists."
  :tags '(:unit :wf :validation)
  (org-roam-todo-wf-test--require-wf)
  (org-roam-todo-wf-test--require-mocker)
  (let ((event (make-org-roam-todo-event
                :todo (list :file "/tmp/test-todo.org"))))
    (mocker-let
        ((org-roam-todo-prop (event prop)
           ((:input-matcher (lambda (e p) (string= p "WORKTREE_PATH"))
             :output "/tmp/test-repo")))
         (file-exists-p (path)
           ((:input-matcher
             (lambda (p) (string-match-p "hooks/pre-commit" p))
             :output nil))))
      (should-not (org-roam-todo-wf--require-pre-commit-pass event)))))

(ert-deftest wf-validate-test-pre-commit-not-executable ()
  "Test require-pre-commit-pass passes when hook exists but isn't executable."
  :tags '(:unit :wf :validation)
  (org-roam-todo-wf-test--require-wf)
  (org-roam-todo-wf-test--require-mocker)
  (let ((event (make-org-roam-todo-event
                :todo (list :file "/tmp/test-todo.org"))))
    (mocker-let
        ((org-roam-todo-prop (event prop)
           ((:input-matcher (lambda (e p) (string= p "WORKTREE_PATH"))
             :output "/tmp/test-repo")))
         (file-exists-p (path)
           ((:input-matcher
             (lambda (p) (string-match-p "hooks/pre-commit" p))
             :output t)))
         (file-executable-p (path)
           ((:input-matcher
             (lambda (p) (string-match-p "hooks/pre-commit" p))
             :output nil))))
      (should-not (org-roam-todo-wf--require-pre-commit-pass event)))))

(ert-deftest wf-validate-test-pre-commit-passes ()
  "Test require-pre-commit-pass when hook passes."
  :tags '(:unit :wf :validation)
  (org-roam-todo-wf-test--require-wf)
  (org-roam-todo-wf-test--require-mocker)
  (let ((event (make-org-roam-todo-event
                :todo (list :file "/tmp/test-todo.org"))))
    (mocker-let
        ((org-roam-todo-prop (event prop)
           ((:input-matcher (lambda (e p) (string= p "WORKTREE_PATH"))
             :output "/tmp/test-repo")))
         (file-exists-p (path)
           ((:input-matcher
             (lambda (p) (string-match-p "hooks/pre-commit" p))
             :output t)))
         (file-executable-p (path)
           ((:input-matcher
             (lambda (p) (string-match-p "hooks/pre-commit" p))
             :output t)))
         (call-process (program &optional infile destination display &rest args)
           ((:input-matcher
             (lambda (prog &rest _) (string-match-p "hooks/pre-commit" prog))
             :output 0))))
      (should-not (org-roam-todo-wf--require-pre-commit-pass event)))))

(ert-deftest wf-validate-test-pre-commit-fails ()
  "Test require-pre-commit-pass when hook fails."
  :tags '(:unit :wf :validation)
  (org-roam-todo-wf-test--require-wf)
  (org-roam-todo-wf-test--require-mocker)
  (let ((event (make-org-roam-todo-event
                :todo (list :file "/tmp/test-todo.org"))))
    (mocker-let
        ((org-roam-todo-prop (event prop)
           ((:input-matcher (lambda (e p) (string= p "WORKTREE_PATH"))
             :output "/tmp/test-repo")))
         (file-exists-p (path)
           ((:input-matcher
             (lambda (p) (string-match-p "hooks/pre-commit" p))
             :output t)))
         (file-executable-p (path)
           ((:input-matcher
             (lambda (p) (string-match-p "hooks/pre-commit" p))
             :output t)))
         (call-process (program &optional infile destination display &rest args)
           ((:input-matcher
             (lambda (prog &rest _) (string-match-p "hooks/pre-commit" prog))
             :output 1))))
      (should-error (org-roam-todo-wf--require-pre-commit-pass event)
                    :type 'user-error))))

;;; ============================================================
;;; has-staged-changes-p Helper Tests
;;; ============================================================

(ert-deftest wf-validate-test-has-staged-changes-true ()
  "Test has-staged-changes-p returns t when there are staged changes."
  :tags '(:unit :wf :validation :git)
  (org-roam-todo-wf-test--require-wf)
  (org-roam-todo-wf-test--require-mocker)
  (mocker-let
      ((org-roam-todo-wf--git-run (dir &rest args)
         ((:input-matcher
           (lambda (d &rest a) (and (member "diff" a) (member "--cached" a)))
           :output '(0 . "staged-file.txt")))))
    (should (org-roam-todo-wf--has-staged-changes-p "/tmp/test-repo"))))

(ert-deftest wf-validate-test-has-staged-changes-false ()
  "Test has-staged-changes-p returns nil when no staged changes."
  :tags '(:unit :wf :validation :git)
  (org-roam-todo-wf-test--require-wf)
  (org-roam-todo-wf-test--require-mocker)
  (mocker-let
      ((org-roam-todo-wf--git-run (dir &rest args)
         ((:input-matcher
           (lambda (d &rest a) (and (member "diff" a) (member "--cached" a)))
           :output '(0 . "")))))
    (should-not (org-roam-todo-wf--has-staged-changes-p "/tmp/test-repo"))))

;;; ============================================================
;;; get-target-branch-from-event Helper Tests
;;; ============================================================

(ert-deftest wf-validate-test-get-target-branch-from-todo ()
  "Test get-target-branch-from-event prioritizes TODO's TARGET_BRANCH property."
  :tags '(:unit :wf :validation)
  (org-roam-todo-wf-test--require-wf)
  (org-roam-todo-wf-test--require-mocker)
  (let* ((workflow (make-org-roam-todo-workflow
                    :config '(:rebase-target "main")))
         (event (make-org-roam-todo-event
                 :todo (list :file "/tmp/test-todo.org")
                 :workflow workflow)))
    (mocker-let
        ((org-roam-todo-prop (event prop)
           ((:input-matcher (lambda (e p) (string= p "PROJECT_NAME"))
             :output nil)
            (:input-matcher (lambda (e p) (string= p "TARGET_BRANCH"))
             :output "feat/custom-branch"))))
      (should (string= "feat/custom-branch"
                       (org-roam-todo-wf--get-target-branch-from-event event workflow))))))
(ert-deftest wf-validate-test-get-target-branch-fallback ()
  "Test get-target-branch-from-event falls back to workflow config."
  :tags '(:unit :wf :validation)
  (org-roam-todo-wf-test--require-wf)
  (org-roam-todo-wf-test--require-mocker)
  (let* ((workflow (make-org-roam-todo-workflow
                    :config '(:rebase-target "main")))
         (event (make-org-roam-todo-event
                 :todo (list :file "/tmp/test-todo.org")
                 :workflow workflow)))
    (mocker-let
        ((org-roam-todo-prop (event prop)
           ((:input-matcher (lambda (e p) (string= p "PROJECT_NAME"))
             :output nil)
            (:input-matcher (lambda (e p) (string= p "TARGET_BRANCH"))
             :output nil))))
      (should (string= "main"
                       (org-roam-todo-wf--get-target-branch-from-event event workflow))))))
(ert-deftest wf-validate-test-get-target-branch-nil ()
  "Test get-target-branch-from-event returns nil when nothing configured."
  :tags '(:unit :wf :validation)
  (org-roam-todo-wf-test--require-wf)
  (org-roam-todo-wf-test--require-mocker)
  (let* ((workflow (make-org-roam-todo-workflow :config nil))
         (event (make-org-roam-todo-event
                 :todo (list :file "/tmp/test-todo.org")
                 :workflow workflow)))
    (mocker-let
        ((org-roam-todo-prop (event prop)
           ((:input-matcher (lambda (e p) (string= p "PROJECT_NAME"))
             :output nil)
            (:input-matcher (lambda (e p) (string= p "TARGET_BRANCH"))
             :output nil))))
      (should-not (org-roam-todo-wf--get-target-branch-from-event event workflow)))))
(provide 'org-roam-todo-wf-validate-test)
;;; org-roam-todo-wf-validate-test.el ends here
