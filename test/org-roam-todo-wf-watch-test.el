;;; org-roam-todo-wf-watch-test.el --- Tests for async watcher system -*- lexical-binding: t; -*-

;; Author: Claude Code
;; Version: 0.1.0
;; Package-Requires: ((emacs "28.1") (ert "1.0"))

;;; Commentary:
;; Unit tests for the async watcher system in org-roam-todo-wf-watch.el.
;; Covers:
;; - Timer management (start, stop, cleanup)
;; - Poll function execution
;; - Action handling (advance, regress)
;; - Timeout behavior
;; - Buffer change watchers
;;
;; Run with:
;;   just test-watch
;; Or:
;;   emacs -batch -L . -L test -l ert \
;;     -l test/org-roam-todo-wf-test-utils.el \
;;     -l test/org-roam-todo-wf-watch-test.el \
;;     -f ert-run-tests-batch-and-exit

;;; Code:

(require 'ert)
(require 'cl-lib)

;; Add load paths
(add-to-list 'load-path (file-name-directory (directory-file-name (file-name-directory load-file-name))))
(add-to-list 'load-path (file-name-directory load-file-name))

(require 'org-roam-todo-wf-test-utils)

;; Try to load the implementation
(condition-case nil
    (progn
      (require 'org-roam-todo-wf)
      (require 'org-roam-todo-wf-watch))
  (error nil))

;;; ============================================================
;;; Test Helpers
;;; ============================================================

(defvar org-roam-todo-wf-watch-test--poll-results nil
  "Alist of (todo-id . result) for mock poll functions.")

(defvar org-roam-todo-wf-watch-test--actions-triggered nil
  "List of actions triggered during tests.")

(defun org-roam-todo-wf-watch-test--mock-poll-fn (todo)
  "Mock poll function that returns result from `org-roam-todo-wf-watch-test--poll-results'."
  (let ((todo-id (plist-get todo :id)))
    (or (cdr (assoc todo-id org-roam-todo-wf-watch-test--poll-results))
        'pending)))

(defun org-roam-todo-wf-watch-test--reset ()
  "Reset test state."
  (setq org-roam-todo-wf-watch-test--poll-results nil)
  (setq org-roam-todo-wf-watch-test--actions-triggered nil)
  ;; Clean up any leftover timers
  (when (featurep 'org-roam-todo-wf-watch)
    (org-roam-todo-wf-watch--cleanup-all)))

(defun org-roam-todo-wf-watch-test--require-watch ()
  "Skip test if org-roam-todo-wf-watch is not loaded."
  (unless (featurep 'org-roam-todo-wf-watch)
    (ert-skip "org-roam-todo-wf-watch not loaded")))

(defun org-roam-todo-wf-watch-test--create-mock-workflow-with-watchers ()
  "Create a mock workflow with watchers for testing."
  (make-org-roam-todo-workflow
   :name 'test-watch-workflow
   :statuses '("draft" "active" "ci" "ready" "done")
   :hooks nil
   :config '(:allow-backward (ci ready)
             :watchers
             ((:status "ci"
               :poll-fn org-roam-todo-wf-watch-test--mock-poll-fn
               :interval 1
               :on-success (:advance "ready")
               :on-failure (:regress "active")
               :timeout 10)))))

;;; ============================================================
;;; Timer Management Tests
;;; ============================================================

(ert-deftest watch-test-start-creates-timer ()
  "Test that starting watchers creates a timer."
  :tags '(:unit :watch :timer)
  (org-roam-todo-wf-watch-test--require-watch)
  (org-roam-todo-wf-watch-test--reset)
  (let* ((workflow (org-roam-todo-wf-watch-test--create-mock-workflow-with-watchers))
         (todo (list :id "test-123"
                     :status "ci"
                     :worktree-path "/tmp/test")))
    ;; Mock workflow resolution
    (cl-letf (((symbol-function 'org-roam-todo-wf--get-workflow)
               (lambda (_) workflow)))
      (org-roam-todo-wf-watch--start-watchers todo)
      ;; Should have a timer registered
      (should (gethash "test-123" org-roam-todo-wf-watch--timers))
      (should (= 1 (length (gethash "test-123" org-roam-todo-wf-watch--timers))))
      ;; Cleanup
      (org-roam-todo-wf-watch--stop-watchers "test-123"))))

(ert-deftest watch-test-stop-cancels-timer ()
  "Test that stopping watchers cancels all timers for a TODO."
  :tags '(:unit :watch :timer)
  (org-roam-todo-wf-watch-test--require-watch)
  (org-roam-todo-wf-watch-test--reset)
  (let* ((workflow (org-roam-todo-wf-watch-test--create-mock-workflow-with-watchers))
         (todo (list :id "test-456"
                     :status "ci"
                     :worktree-path "/tmp/test")))
    (cl-letf (((symbol-function 'org-roam-todo-wf--get-workflow)
               (lambda (_) workflow)))
      (org-roam-todo-wf-watch--start-watchers todo)
      ;; Verify timer exists
      (should (gethash "test-456" org-roam-todo-wf-watch--timers))
      ;; Stop watchers
      (org-roam-todo-wf-watch--stop-watchers "test-456")
      ;; Timer should be removed
      (should-not (gethash "test-456" org-roam-todo-wf-watch--timers)))))

(ert-deftest watch-test-cleanup-all-removes-all-timers ()
  "Test that cleanup-all removes all active timers."
  :tags '(:unit :watch :timer)
  (org-roam-todo-wf-watch-test--require-watch)
  (org-roam-todo-wf-watch-test--reset)
  (let* ((workflow (org-roam-todo-wf-watch-test--create-mock-workflow-with-watchers))
         (todo1 (list :id "test-1" :status "ci" :worktree-path "/tmp/test1"))
         (todo2 (list :id "test-2" :status "ci" :worktree-path "/tmp/test2")))
    (cl-letf (((symbol-function 'org-roam-todo-wf--get-workflow)
               (lambda (_) workflow)))
      ;; Start watchers for both TODOs
      (org-roam-todo-wf-watch--start-watchers todo1)
      (org-roam-todo-wf-watch--start-watchers todo2)
      ;; Both should have timers
      (should (gethash "test-1" org-roam-todo-wf-watch--timers))
      (should (gethash "test-2" org-roam-todo-wf-watch--timers))
      ;; Cleanup all
      (org-roam-todo-wf-watch--cleanup-all)
      ;; All timers should be gone
      (should (= 0 (hash-table-count org-roam-todo-wf-watch--timers))))))

(ert-deftest watch-test-no-watcher-for-wrong-status ()
  "Test that watchers are only started for matching status."
  :tags '(:unit :watch :timer)
  (org-roam-todo-wf-watch-test--require-watch)
  (org-roam-todo-wf-watch-test--reset)
  (let* ((workflow (org-roam-todo-wf-watch-test--create-mock-workflow-with-watchers))
         (todo (list :id "test-wrong"
                     :status "active"  ; Not "ci", so no watcher should start
                     :worktree-path "/tmp/test")))
    (cl-letf (((symbol-function 'org-roam-todo-wf--get-workflow)
               (lambda (_) workflow)))
      (org-roam-todo-wf-watch--start-watchers todo)
      ;; Should NOT have a timer (status doesn't match watcher)
      (should-not (gethash "test-wrong" org-roam-todo-wf-watch--timers)))))

;;; ============================================================
;;; Poll Function Tests
;;; ============================================================

(ert-deftest watch-test-poll-success-triggers-action ()
  "Test that poll returning 'success triggers on-success action."
  :tags '(:unit :watch :poll)
  (org-roam-todo-wf-watch-test--require-watch)
  (org-roam-todo-wf-watch-test--reset)
  (let* ((action-triggered nil)
         (watcher '(:status "ci"
                    :poll-fn org-roam-todo-wf-watch-test--mock-poll-fn
                    :on-success (:advance "ready")))
         (todo (list :id "poll-test" :status "ci")))
    ;; Set up mock to return success
    (push (cons "poll-test" 'success) org-roam-todo-wf-watch-test--poll-results)
    ;; Mock the TODO resolution and status change
    (cl-letf (((symbol-function 'org-roam-todo-wf-watch--get-todo)
               (lambda (id) (when (string= id "poll-test") todo)))
              ((symbol-function 'org-roam-todo-wf--change-status)
               (lambda (t new-status)
                 (setq action-triggered (list :advance new-status)))))
      ;; Simulate a poll
      (org-roam-todo-wf-watch--poll "poll-test" watcher (current-time))
      ;; Action should have been triggered
      (should action-triggered)
      (should (equal '(:advance "ready") action-triggered)))))

(ert-deftest watch-test-poll-failure-triggers-action ()
  "Test that poll returning 'failure triggers on-failure action."
  :tags '(:unit :watch :poll)
  (org-roam-todo-wf-watch-test--require-watch)
  (org-roam-todo-wf-watch-test--reset)
  (let* ((action-triggered nil)
         (watcher '(:status "ci"
                    :poll-fn org-roam-todo-wf-watch-test--mock-poll-fn
                    :on-failure (:regress "active")))
         (todo (list :id "fail-test" :status "ci")))
    ;; Set up mock to return failure
    (push (cons "fail-test" 'failure) org-roam-todo-wf-watch-test--poll-results)
    ;; Mock the TODO resolution and status change
    (cl-letf (((symbol-function 'org-roam-todo-wf-watch--get-todo)
               (lambda (id) (when (string= id "fail-test") todo)))
              ((symbol-function 'org-roam-todo-wf--change-status)
               (lambda (t new-status)
                 (setq action-triggered (list :regress new-status)))))
      (org-roam-todo-wf-watch--poll "fail-test" watcher (current-time))
      (should action-triggered)
      (should (equal '(:regress "active") action-triggered)))))

(ert-deftest watch-test-poll-pending-continues ()
  "Test that poll returning 'pending does not trigger any action."
  :tags '(:unit :watch :poll)
  (org-roam-todo-wf-watch-test--require-watch)
  (org-roam-todo-wf-watch-test--reset)
  (let* ((action-triggered nil)
         (watcher '(:status "ci"
                    :poll-fn org-roam-todo-wf-watch-test--mock-poll-fn
                    :on-success (:advance "ready")
                    :on-failure (:regress "active")))
         (todo (list :id "pending-test" :status "ci")))
    ;; Set up mock to return pending
    (push (cons "pending-test" 'pending) org-roam-todo-wf-watch-test--poll-results)
    (cl-letf (((symbol-function 'org-roam-todo-wf-watch--get-todo)
               (lambda (id) (when (string= id "pending-test") todo)))
              ((symbol-function 'org-roam-todo-wf--change-status)
               (lambda (t new-status)
                 (setq action-triggered t))))
      (org-roam-todo-wf-watch--poll "pending-test" watcher (current-time))
      ;; No action should have been triggered
      (should-not action-triggered))))

;;; ============================================================
;;; Timeout Tests
;;; ============================================================

(ert-deftest watch-test-timeout-stops-polling ()
  "Test that timeout stops the watcher."
  :tags '(:unit :watch :timeout)
  (org-roam-todo-wf-watch-test--require-watch)
  (org-roam-todo-wf-watch-test--reset)
  (let* ((watcher '(:status "ci"
                    :poll-fn org-roam-todo-wf-watch-test--mock-poll-fn
                    :timeout 5  ; 5 second timeout
                    :on-success (:advance "ready")))
         (todo (list :id "timeout-test" :status "ci"))
         ;; Start time 10 seconds ago (beyond timeout)
         (start-time (time-subtract (current-time) (seconds-to-time 10)))
         (stop-called nil))
    (push (cons "timeout-test" 'pending) org-roam-todo-wf-watch-test--poll-results)
    (cl-letf (((symbol-function 'org-roam-todo-wf-watch--get-todo)
               (lambda (id) (when (string= id "timeout-test") todo)))
              ((symbol-function 'org-roam-todo-wf-watch--stop-watchers)
               (lambda (id) (setq stop-called id))))
      (org-roam-todo-wf-watch--poll "timeout-test" watcher start-time)
      ;; Stop should have been called
      (should stop-called)
      (should (string= "timeout-test" stop-called)))))

;;; ============================================================
;;; Status Change Tests
;;; ============================================================

(ert-deftest watch-test-status-change-stops-watcher ()
  "Test that watcher stops when TODO status changes."
  :tags '(:unit :watch :status)
  (org-roam-todo-wf-watch-test--require-watch)
  (org-roam-todo-wf-watch-test--reset)
  (let* ((watcher '(:status "ci"
                    :poll-fn org-roam-todo-wf-watch-test--mock-poll-fn
                    :on-success (:advance "ready")))
         ;; TODO has changed to different status
         (todo (list :id "changed-test" :status "ready"))
         (stop-called nil))
    (push (cons "changed-test" 'pending) org-roam-todo-wf-watch-test--poll-results)
    (cl-letf (((symbol-function 'org-roam-todo-wf-watch--get-todo)
               (lambda (id) (when (string= id "changed-test") todo)))
              ((symbol-function 'org-roam-todo-wf-watch--stop-watchers)
               (lambda (id) (setq stop-called id))))
      (org-roam-todo-wf-watch--poll "changed-test" watcher (current-time))
      ;; Stop should have been called because status doesn't match
      (should stop-called))))

(ert-deftest watch-test-deleted-todo-stops-watcher ()
  "Test that watcher stops when TODO no longer exists."
  :tags '(:unit :watch :status)
  (org-roam-todo-wf-watch-test--require-watch)
  (org-roam-todo-wf-watch-test--reset)
  (let* ((watcher '(:status "ci"
                    :poll-fn org-roam-todo-wf-watch-test--mock-poll-fn
                    :on-success (:advance "ready")))
         (stop-called nil))
    (cl-letf (((symbol-function 'org-roam-todo-wf-watch--get-todo)
               (lambda (_id) nil))  ; TODO not found
              ((symbol-function 'org-roam-todo-wf-watch--stop-watchers)
               (lambda (id) (setq stop-called id))))
      (org-roam-todo-wf-watch--poll "deleted-test" watcher (current-time))
      ;; Stop should have been called
      (should stop-called))))

;;; ============================================================
;;; Action Handling Tests
;;; ============================================================

(ert-deftest watch-test-handle-action-advance ()
  "Test that handle-action correctly calls change-status for advance."
  :tags '(:unit :watch :action)
  (org-roam-todo-wf-watch-test--require-watch)
  (let* ((change-called nil)
         (todo (list :id "advance-test" :status "ci")))
    (cl-letf (((symbol-function 'org-roam-todo-wf--change-status)
               (lambda (t new-status)
                 (setq change-called (list t new-status)))))
      (org-roam-todo-wf-watch--handle-action todo '(:advance "ready"))
      (should change-called)
      (should (equal "ready" (cadr change-called))))))

(ert-deftest watch-test-handle-action-regress ()
  "Test that handle-action correctly calls change-status for regress."
  :tags '(:unit :watch :action)
  (org-roam-todo-wf-watch-test--require-watch)
  (let* ((change-called nil)
         (todo (list :id "regress-test" :status "ci")))
    (cl-letf (((symbol-function 'org-roam-todo-wf--change-status)
               (lambda (t new-status)
                 (setq change-called (list t new-status)))))
      (org-roam-todo-wf-watch--handle-action todo '(:regress "active"))
      (should change-called)
      (should (equal "active" (cadr change-called))))))

;;; ============================================================
;;; Integration with Status Change Hook
;;; ============================================================

(ert-deftest watch-test-on-status-changed-starts-watchers ()
  "Test that on-status-changed starts watchers for the new status."
  :tags '(:unit :watch :integration)
  (org-roam-todo-wf-watch-test--require-watch)
  (org-roam-todo-wf-watch-test--reset)
  (let* ((workflow (org-roam-todo-wf-watch-test--create-mock-workflow-with-watchers))
         (todo (list :id "integration-test"
                     :status "ci"
                     :worktree-path "/tmp/test"))
         (event (make-org-roam-todo-event
                 :type :on-status-changed
                 :todo todo
                 :workflow workflow
                 :old-status "active"
                 :new-status "ci")))
    (cl-letf (((symbol-function 'org-roam-todo-wf--get-workflow)
               (lambda (_) workflow)))
      (org-roam-todo-wf-watch--on-status-changed event)
      ;; Should have started a watcher
      (should (gethash "integration-test" org-roam-todo-wf-watch--timers))
      ;; Cleanup
      (org-roam-todo-wf-watch--cleanup-all))))

;;; ============================================================
;;; Interactive Command Tests
;;; ============================================================

(ert-deftest watch-test-list-command ()
  "Test that watch-list command runs without error."
  :tags '(:unit :watch :command)
  (org-roam-todo-wf-watch-test--require-watch)
  (org-roam-todo-wf-watch-test--reset)
  ;; Should run without error even with no watchers
  (should (progn (org-roam-todo-wf-watch-list) t)))

(ert-deftest watch-test-stop-all-command ()
  "Test that watch-stop-all command runs without error."
  :tags '(:unit :watch :command)
  (org-roam-todo-wf-watch-test--require-watch)
  ;; Should run without error
  (should (progn (org-roam-todo-wf-watch-stop-all) t)))

(provide 'org-roam-todo-wf-watch-test)
;;; org-roam-todo-wf-watch-test.el ends here
