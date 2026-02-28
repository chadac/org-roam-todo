;;; org-roam-todo-wf-pr-feedback-test.el --- Tests for PR feedback module -*- lexical-binding: t; -*-

;; Author: Claude Code
;; Version: 0.1.0
;; Package-Requires: ((emacs "28.1") (ert "1.0") (mocker "0.5"))

;;; Commentary:
;; Tests for the PR feedback module which provides:
;; - Forge detection (GitHub/GitLab)
;; - PR feedback fetching (CI checks, reviews, comments)
;; - Feedback caching
;; - Auto-update PR on TODO save
;; - MCP tool integration

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'org-roam-todo-wf-test-utils)

;; Try to load mocker
(condition-case nil
    (require 'mocker)
  (error
   (message "Warning: mocker.el not available. Some tests will be skipped.")))

;; Require the module under test
(require 'org-roam-todo-wf-pr-feedback nil t)

;;; ============================================================
;;; Forge Detection Tests
;;; ============================================================

(ert-deftest wf-pr-feedback-test-detect-forge-github ()
  "Test forge detection identifies GitHub from remote URL."
  :tags '(:unit :wf :pr-feedback :git)
  (require 'org-roam-todo-wf-pr-feedback nil t)
  (let ((temp-dir (make-temp-file "test-repo-" t)))
    (unwind-protect
        (progn
          ;; Initialize git repo
          (let ((default-directory temp-dir))
            (call-process "git" nil nil nil "init")
            (call-process "git" nil nil nil "remote" "add" "origin"
                          "git@github.com:owner/repo.git"))
          (should (eq :github (org-roam-todo-wf-pr-feedback--detect-forge temp-dir))))
      (delete-directory temp-dir t))))

(ert-deftest wf-pr-feedback-test-detect-forge-gitlab ()
  "Test forge detection identifies GitLab from remote URL."
  :tags '(:unit :wf :pr-feedback :git)
  (require 'org-roam-todo-wf-pr-feedback nil t)
  (let ((temp-dir (make-temp-file "test-repo-" t)))
    (unwind-protect
        (progn
          ;; Initialize git repo
          (let ((default-directory temp-dir))
            (call-process "git" nil nil nil "init")
            (call-process "git" nil nil nil "remote" "add" "origin"
                          "git@gitlab.com:owner/repo.git"))
          (should (eq :gitlab (org-roam-todo-wf-pr-feedback--detect-forge temp-dir))))
      (delete-directory temp-dir t))))

(ert-deftest wf-pr-feedback-test-detect-forge-github-https ()
  "Test forge detection identifies GitHub from HTTPS URL."
  :tags '(:unit :wf :pr-feedback :git)
  (require 'org-roam-todo-wf-pr-feedback nil t)
  (let ((temp-dir (make-temp-file "test-repo-" t)))
    (unwind-protect
        (progn
          (let ((default-directory temp-dir))
            (call-process "git" nil nil nil "init")
            (call-process "git" nil nil nil "remote" "add" "origin"
                          "https://github.com/owner/repo.git"))
          (should (eq :github (org-roam-todo-wf-pr-feedback--detect-forge temp-dir))))
      (delete-directory temp-dir t))))

(ert-deftest wf-pr-feedback-test-detect-forge-no-remote ()
  "Test forge detection falls back to CLI check when no remote configured.
Note: This test verifies the fallback behavior - if gh/glab CLI is authenticated,
it will return that forge type even without a remote. This is intentional."
  :tags '(:unit :wf :pr-feedback :git)
  (require 'org-roam-todo-wf-pr-feedback nil t)
  (let ((temp-dir (make-temp-file "test-repo-" t)))
    (unwind-protect
        (progn
          (let ((default-directory temp-dir))
            (call-process "git" nil nil nil "init"))
          ;; Result depends on whether gh/glab CLI is authenticated on this system
          ;; Just verify it doesn't error
          (org-roam-todo-wf-pr-feedback--detect-forge temp-dir))
      (delete-directory temp-dir t))))

;;; ============================================================
;;; Feedback Summary Tests
;;; ============================================================

(ert-deftest wf-pr-feedback-test-summary-nil-input ()
  "Test feedback summary with nil feedback data returns nil."
  :tags '(:unit :wf :pr-feedback)
  (require 'org-roam-todo-wf-pr-feedback nil t)
  (should-not (org-roam-todo-wf-pr-feedback-summary nil)))

(ert-deftest wf-pr-feedback-test-summary-empty-feedback ()
  "Test feedback summary with empty plist."
  :tags '(:unit :wf :pr-feedback)
  (require 'org-roam-todo-wf-pr-feedback nil t)
  (let ((summary (org-roam-todo-wf-pr-feedback-summary '(:ci-checks nil))))
    (should summary)
    (should (= 0 (plist-get summary :ci-total-count)))
    (should (= 0 (plist-get summary :ci-failed-count)))
    (should (= 0 (plist-get summary :ci-pending-count)))
    (should (= 0 (plist-get summary :ci-success-count)))
    (should (= 0 (plist-get summary :unresolved-count)))))

(ert-deftest wf-pr-feedback-test-summary-ci-counts ()
  "Test feedback summary counts CI check states correctly."
  :tags '(:unit :wf :pr-feedback)
  (require 'org-roam-todo-wf-pr-feedback nil t)
  (let* ((feedback (list :ci-checks
                         (list (list :name "test" :status 'success)
                               (list :name "lint" :status 'failure)
                               (list :name "build" :status 'pending)
                               (list :name "deploy" :status 'success))))
         (summary (org-roam-todo-wf-pr-feedback-summary feedback)))
    (should (= 4 (plist-get summary :ci-total-count)))
    (should (= 1 (plist-get summary :ci-failed-count)))
    (should (= 1 (plist-get summary :ci-pending-count)))
    (should (= 2 (plist-get summary :ci-success-count)))))

(ert-deftest wf-pr-feedback-test-summary-ci-status-failure ()
  "Test feedback summary returns :failure status when any check fails."
  :tags '(:unit :wf :pr-feedback)
  (require 'org-roam-todo-wf-pr-feedback nil t)
  (let* ((feedback (list :ci-checks
                         (list (list :name "test" :status 'success)
                               (list :name "lint" :status 'failure))))
         (summary (org-roam-todo-wf-pr-feedback-summary feedback)))
    (should (eq :failure (plist-get summary :ci-status)))))

(ert-deftest wf-pr-feedback-test-summary-ci-status-pending ()
  "Test feedback summary returns :pending when checks are pending (no failures)."
  :tags '(:unit :wf :pr-feedback)
  (require 'org-roam-todo-wf-pr-feedback nil t)
  (let* ((feedback (list :ci-checks
                         (list (list :name "test" :status 'success)
                               (list :name "lint" :status 'pending))))
         (summary (org-roam-todo-wf-pr-feedback-summary feedback)))
    (should (eq :pending (plist-get summary :ci-status)))))

(ert-deftest wf-pr-feedback-test-summary-ci-status-success ()
  "Test feedback summary returns :success when all checks pass."
  :tags '(:unit :wf :pr-feedback)
  (require 'org-roam-todo-wf-pr-feedback nil t)
  (let* ((feedback (list :ci-checks
                         (list (list :name "test" :status 'success)
                               (list :name "lint" :status 'success))))
         (summary (org-roam-todo-wf-pr-feedback-summary feedback)))
    (should (eq :success (plist-get summary :ci-status)))))

(ert-deftest wf-pr-feedback-test-summary-review-state-approved ()
  "Test feedback summary detects approved review state."
  :tags '(:unit :wf :pr-feedback)
  (require 'org-roam-todo-wf-pr-feedback nil t)
  (let* ((feedback (list :reviews
                         (list (list :author "alice" :state 'approved))))
         (summary (org-roam-todo-wf-pr-feedback-summary feedback)))
    (should (eq :approved (plist-get summary :review-state)))))

(ert-deftest wf-pr-feedback-test-summary-review-state-changes-requested ()
  "Test feedback summary detects changes requested review state."
  :tags '(:unit :wf :pr-feedback)
  (require 'org-roam-todo-wf-pr-feedback nil t)
  (let* ((feedback (list :reviews
                         (list (list :author "alice" :state 'changes_requested))))
         (summary (org-roam-todo-wf-pr-feedback-summary feedback)))
    (should (eq :changes-requested (plist-get summary :review-state)))))

(ert-deftest wf-pr-feedback-test-summary-review-state-reviewed ()
  "Test feedback summary returns :reviewed when reviews exist but no approval/changes."
  :tags '(:unit :wf :pr-feedback)
  (require 'org-roam-todo-wf-pr-feedback nil t)
  (let* ((feedback (list :reviews
                         (list (list :author "alice" :state 'commented))))
         (summary (org-roam-todo-wf-pr-feedback-summary feedback)))
    (should (eq :reviewed (plist-get summary :review-state)))))

(ert-deftest wf-pr-feedback-test-summary-review-state-none ()
  "Test feedback summary returns :none when no reviews."
  :tags '(:unit :wf :pr-feedback)
  (require 'org-roam-todo-wf-pr-feedback nil t)
  (let* ((feedback (list :reviews nil))
         (summary (org-roam-todo-wf-pr-feedback-summary feedback)))
    (should (eq :none (plist-get summary :review-state)))))

(ert-deftest wf-pr-feedback-test-summary-unresolved-comments ()
  "Test feedback summary counts unresolved comments."
  :tags '(:unit :wf :pr-feedback)
  (require 'org-roam-todo-wf-pr-feedback nil t)
  (let* ((feedback (list :review-comments
                         (list (list :author "alice" :state 'unresolved)
                               (list :author "bob" :state 'resolved)
                               (list :author "charlie" :state 'unresolved))))
         (summary (org-roam-todo-wf-pr-feedback-summary feedback)))
    (should (= 2 (plist-get summary :unresolved-count)))))

(ert-deftest wf-pr-feedback-test-summary-comment-count ()
  "Test feedback summary counts total comments."
  :tags '(:unit :wf :pr-feedback)
  (require 'org-roam-todo-wf-pr-feedback nil t)
  (let* ((feedback (list :comments
                         (list (list :author "alice" :body "comment 1")
                               (list :author "bob" :body "comment 2"))))
         (summary (org-roam-todo-wf-pr-feedback-summary feedback)))
    (should (= 2 (plist-get summary :comment-count)))))

;;; ============================================================
;;; Cache Tests
;;; ============================================================

(ert-deftest wf-pr-feedback-test-cache-invalidation ()
  "Test cache invalidation clears cached feedback."
  :tags '(:unit :wf :pr-feedback)
  (require 'org-roam-todo-wf-pr-feedback nil t)
  (let ((test-path "/tmp/test-repo"))
    ;; Manually add to cache (timestamp . data)
    (puthash test-path
             (cons (float-time) '(:pr-number 123))
             org-roam-todo-wf-pr-feedback--cache)
    ;; Verify it's there
    (should (gethash test-path org-roam-todo-wf-pr-feedback--cache))
    ;; Invalidate
    (org-roam-todo-wf-pr-feedback-invalidate-cache test-path)
    ;; Verify it's gone
    (should-not (gethash test-path org-roam-todo-wf-pr-feedback--cache))))

(ert-deftest wf-pr-feedback-test-cache-invalidate-all ()
  "Test cache invalidation without path clears all entries."
  :tags '(:unit :wf :pr-feedback)
  (require 'org-roam-todo-wf-pr-feedback nil t)
  ;; Add multiple entries
  (puthash "/tmp/repo1" (cons (float-time) '(:pr-number 1))
           org-roam-todo-wf-pr-feedback--cache)
  (puthash "/tmp/repo2" (cons (float-time) '(:pr-number 2))
           org-roam-todo-wf-pr-feedback--cache)
  ;; Invalidate all
  (org-roam-todo-wf-pr-feedback-invalidate-cache nil)
  ;; Verify both are gone
  (should (= 0 (hash-table-count org-roam-todo-wf-pr-feedback--cache))))

(ert-deftest wf-pr-feedback-test-cache-valid-p-fresh ()
  "Test cache validity check returns t for fresh entry."
  :tags '(:unit :wf :pr-feedback)
  (require 'org-roam-todo-wf-pr-feedback nil t)
  (let ((test-path "/tmp/test-repo")
        (org-roam-todo-wf-pr-feedback-cache-ttl 300)) ; 5 minute TTL
    ;; Add entry with current timestamp
    (puthash test-path
             (cons (float-time) '(:pr-number 123))
             org-roam-todo-wf-pr-feedback--cache)
    (should (org-roam-todo-wf-pr-feedback--cache-valid-p test-path))
    ;; Clean up
    (remhash test-path org-roam-todo-wf-pr-feedback--cache)))

(ert-deftest wf-pr-feedback-test-cache-valid-p-expired ()
  "Test cache validity check returns nil for expired entry."
  :tags '(:unit :wf :pr-feedback)
  (require 'org-roam-todo-wf-pr-feedback nil t)
  (let ((test-path "/tmp/test-repo")
        (org-roam-todo-wf-pr-feedback-cache-ttl 1)) ; 1 second TTL
    ;; Add entry with old timestamp
    (puthash test-path
             (cons (- (float-time) 10) '(:pr-number 123)) ; 10 seconds ago
             org-roam-todo-wf-pr-feedback--cache)
    (should-not (org-roam-todo-wf-pr-feedback--cache-valid-p test-path))
    ;; Clean up
    (remhash test-path org-roam-todo-wf-pr-feedback--cache)))

(ert-deftest wf-pr-feedback-test-cache-get-returns-data ()
  "Test cache-get returns data when cache is valid."
  :tags '(:unit :wf :pr-feedback)
  (require 'org-roam-todo-wf-pr-feedback nil t)
  (let ((test-path "/tmp/test-repo")
        (org-roam-todo-wf-pr-feedback-cache-ttl 300))
    ;; Add entry
    (puthash test-path
             (cons (float-time) '(:pr-number 123))
             org-roam-todo-wf-pr-feedback--cache)
    (let ((cached (org-roam-todo-wf-pr-feedback--cache-get test-path)))
      (should cached)
      (should (= 123 (plist-get cached :pr-number))))
    ;; Clean up
    (remhash test-path org-roam-todo-wf-pr-feedback--cache)))

(ert-deftest wf-pr-feedback-test-cache-get-returns-nil-expired ()
  "Test cache-get returns nil when cache is expired."
  :tags '(:unit :wf :pr-feedback)
  (require 'org-roam-todo-wf-pr-feedback nil t)
  (let ((test-path "/tmp/test-repo")
        (org-roam-todo-wf-pr-feedback-cache-ttl 1))
    ;; Add expired entry
    (puthash test-path
             (cons (- (float-time) 10) '(:pr-number 123))
             org-roam-todo-wf-pr-feedback--cache)
    (should-not (org-roam-todo-wf-pr-feedback--cache-get test-path))
    ;; Clean up
    (remhash test-path org-roam-todo-wf-pr-feedback--cache)))

(ert-deftest wf-pr-feedback-test-cache-set ()
  "Test cache-set stores data with timestamp."
  :tags '(:unit :wf :pr-feedback)
  (require 'org-roam-todo-wf-pr-feedback nil t)
  (let ((test-path "/tmp/test-repo")
        (test-feedback '(:pr-number 456)))
    (org-roam-todo-wf-pr-feedback--cache-set test-path test-feedback)
    (let ((entry (gethash test-path org-roam-todo-wf-pr-feedback--cache)))
      (should entry)
      (should (numberp (car entry))) ; timestamp
      (should (equal test-feedback (cdr entry))))
    ;; Clean up
    (remhash test-path org-roam-todo-wf-pr-feedback--cache)))

;;; ============================================================
;;; Auto-Update Hook Tests
;;; ============================================================

(ert-deftest wf-pr-feedback-test-get-sections ()
  "Test extracting PR Title and PR Description from TODO file."
  :tags '(:unit :wf :pr-feedback :auto-update)
  (require 'org-roam-todo-wf-pr-feedback nil t)
  (let ((temp-file (make-temp-file "test-todo-" nil ".org")))
    (unwind-protect
        (progn
          (with-temp-file temp-file
            (insert ":PROPERTIES:\n:ID: test\n:END:\n#+title: My TODO\n\n")
            (insert "** PR Title\n\nFix: Important bug fix\n\n")
            (insert "** PR Description\n\nThis fixes an important bug.\n"))
          (let ((sections (org-roam-todo-wf-pr-feedback--get-sections temp-file)))
            (should sections)
            (should (string-match-p "Important bug fix" (car sections)))
            (should (string-match-p "This fixes an important bug" (cdr sections)))))
      (delete-file temp-file))))

(ert-deftest wf-pr-feedback-test-get-sections-missing-title ()
  "Test extracting sections when PR Title is missing."
  :tags '(:unit :wf :pr-feedback :auto-update)
  (require 'org-roam-todo-wf-pr-feedback nil t)
  (let ((temp-file (make-temp-file "test-todo-" nil ".org")))
    (unwind-protect
        (progn
          (with-temp-file temp-file
            (insert ":PROPERTIES:\n:ID: test\n:END:\n#+title: My TODO\n\n")
            (insert "** PR Description\n\nThis fixes an important bug.\n"))
          (let ((sections (org-roam-todo-wf-pr-feedback--get-sections temp-file)))
            (should sections)
            (should-not (car sections))  ; No title
            (should (cdr sections))))    ; Has description
      (delete-file temp-file))))

(ert-deftest wf-pr-feedback-test-auto-update-setup ()
  "Test that auto-update hooks are properly registered."
  :tags '(:unit :wf :pr-feedback :auto-update)
  (require 'org-roam-todo-wf-pr-feedback nil t)
  ;; The module auto-setups on load, so hooks should be present
  (should (memq 'org-roam-todo-wf-pr-feedback--before-save-hook before-save-hook))
  (should (memq 'org-roam-todo-wf-pr-feedback--after-save-hook after-save-hook)))

(ert-deftest wf-pr-feedback-test-auto-update-teardown ()
  "Test that auto-update hooks can be removed."
  :tags '(:unit :wf :pr-feedback :auto-update)
  (require 'org-roam-todo-wf-pr-feedback nil t)
  (unwind-protect
      (progn
        (org-roam-todo-wf-pr-feedback-teardown-auto-update)
        (should-not (memq 'org-roam-todo-wf-pr-feedback--before-save-hook before-save-hook))
        (should-not (memq 'org-roam-todo-wf-pr-feedback--after-save-hook after-save-hook)))
    ;; Re-enable for other tests
    (org-roam-todo-wf-pr-feedback-setup-auto-update)))

;;; ============================================================
;;; Status Buffer Integration Tests
;;; ============================================================

(ert-deftest wf-pr-feedback-test-ci-status-display-success ()
  "Test CI status display for success state."
  :tags '(:unit :wf :pr-feedback :status)
  (require 'org-roam-todo-status nil t)
  (let ((display (org-roam-todo-status--ci-status-display 'success)))
    (should (string= "✓" (car display)))
    (should (eq 'org-roam-todo-status-ci-success (cdr display)))))

(ert-deftest wf-pr-feedback-test-ci-status-display-failure ()
  "Test CI status display for failure state."
  :tags '(:unit :wf :pr-feedback :status)
  (require 'org-roam-todo-status nil t)
  (let ((display (org-roam-todo-status--ci-status-display 'failure)))
    (should (string= "✗" (car display)))
    (should (eq 'org-roam-todo-status-ci-failure (cdr display)))))

(ert-deftest wf-pr-feedback-test-ci-status-display-pending ()
  "Test CI status display for pending state."
  :tags '(:unit :wf :pr-feedback :status)
  (require 'org-roam-todo-status nil t)
  (let ((display (org-roam-todo-status--ci-status-display 'pending)))
    (should (string= "⧗" (car display)))
    (should (eq 'org-roam-todo-status-ci-pending (cdr display)))))

(ert-deftest wf-pr-feedback-test-ci-status-display-cancelled ()
  "Test CI status display for cancelled state."
  :tags '(:unit :wf :pr-feedback :status)
  (require 'org-roam-todo-status nil t)
  (let ((display (org-roam-todo-status--ci-status-display 'cancelled)))
    (should (string= "⊘" (car display)))))

(ert-deftest wf-pr-feedback-test-ci-status-display-unknown ()
  "Test CI status display for unknown state."
  :tags '(:unit :wf :pr-feedback :status)
  (require 'org-roam-todo-status nil t)
  (let ((display (org-roam-todo-status--ci-status-display 'some-unknown-state)))
    (should (string= "?" (car display)))))

;;; ============================================================
;;; Fetch Tests (edge cases)
;;; ============================================================

(ert-deftest wf-pr-feedback-test-fetch-nonexistent-path ()
  "Test feedback fetch returns nil for non-existent path."
  :tags '(:unit :wf :pr-feedback)
  (require 'org-roam-todo-wf-pr-feedback nil t)
  (should-not (org-roam-todo-wf-pr-feedback-fetch "/nonexistent/path/that/does/not/exist")))

(ert-deftest wf-pr-feedback-test-fetch-not-git-repo ()
  "Test feedback fetch returns nil for non-git directory."
  :tags '(:unit :wf :pr-feedback)
  (require 'org-roam-todo-wf-pr-feedback nil t)
  (let ((temp-dir (make-temp-file "not-a-repo-" t)))
    (unwind-protect
        (should-not (org-roam-todo-wf-pr-feedback-fetch temp-dir))
      (delete-directory temp-dir t))))

;;; ============================================================
;;; MCP Tools Tests
;;; ============================================================

(ert-deftest wf-pr-feedback-test-tools-defined ()
  "Test that PR feedback MCP tools are defined."
  :tags '(:unit :wf :pr-feedback :tools :mcp)
  (require 'org-roam-todo-wf-tools nil t)
  ;; Check functions exist
  (should (fboundp 'org-roam-todo-wf-tools-pr-feedback))
  (should (fboundp 'org-roam-todo-wf-tools-pr-comments))
  (should (fboundp 'org-roam-todo-wf-tools-pr-ci-logs)))

;;; ============================================================
;;; Update PR Tests
;;; ============================================================

(ert-deftest wf-pr-feedback-test-update-pr-nil-params ()
  "Test update-pr does nothing when both title and body are nil."
  :tags '(:unit :wf :pr-feedback :auto-update)
  (require 'org-roam-todo-wf-pr-feedback nil t)
  ;; Should not error when both are nil
  (should-not (org-roam-todo-wf-pr-feedback--update-pr "/tmp/test" nil nil)))

(provide 'org-roam-todo-wf-pr-feedback-test)
;;; org-roam-todo-wf-pr-feedback-test.el ends here
