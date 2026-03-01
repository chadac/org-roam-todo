;;; org-roam-todo-wf-project-test.el --- Tests for per-project config -*- lexical-binding: t; -*-

;; Author: Claude Code
;; Version: 0.1.0
;; Package-Requires: ((emacs "28.1") (ert "1.0"))

;;; Commentary:
;; Tests for org-roam-todo-wf-project.el - per-project workflow configuration.
;; Tests cover:
;; - Config file loading and caching
;; - Validation registration and retrieval
;; - Integration with workflow dispatch

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'org-roam-todo-wf-project)
(require 'org-roam-todo-wf-test-utils)

;;; ============================================================
;;; Test Fixtures
;;; ============================================================

(defvar org-roam-todo-wf-project-test--validation-called nil
  "Tracks whether the test validation was called.")

(defun org-roam-todo-wf-project-test--reset ()
  "Reset test state."
  (setq org-roam-todo-wf-project-test--validation-called nil)
  (org-roam-todo-wf-project-clear-cache))

(defun org-roam-todo-wf-project-test--sample-validation (event)
  "Sample validation function for testing.
Records that it was called and returns :pass."
  (ignore event)
  (setq org-roam-todo-wf-project-test--validation-called t)
  :pass)

(defun org-roam-todo-wf-project-test--failing-validation (event)
  "Sample validation that always fails."
  (ignore event)
  (user-error "Test validation failed"))

;;; ============================================================
;;; Config File Loading Tests
;;; ============================================================

(ert-deftest wf-project-test-no-config-file ()
  "Test that missing config file returns nil."
  :tags '(:unit :wf :project)
  (org-roam-todo-wf-project-test--reset)
  (let ((temp-dir (make-temp-file "wf-project-test-" t)))
    (unwind-protect
        (should-not (org-roam-todo-wf-project--load-config temp-dir))
      (delete-directory temp-dir t))))

(ert-deftest wf-project-test-empty-config-file ()
  "Test that empty config file returns nil validations."
  :tags '(:unit :wf :project)
  (org-roam-todo-wf-project-test--reset)
  (let ((temp-dir (make-temp-file "wf-project-test-" t)))
    (unwind-protect
        (progn
          ;; Create empty config file
          (with-temp-file (expand-file-name ".org-todo-config.el" temp-dir)
            (insert ";; Empty config\n"))
          (should-not (org-roam-todo-wf-project--load-config temp-dir)))
      (delete-directory temp-dir t))))

(ert-deftest wf-project-test-load-simple-config ()
  "Test loading a simple config with one validation."
  :tags '(:unit :wf :project)
  (org-roam-todo-wf-project-test--reset)
  (let ((temp-dir (make-temp-file "wf-project-test-" t)))
    (unwind-protect
        (progn
          ;; Create config file with one validation
          (with-temp-file (expand-file-name ".org-todo-config.el" temp-dir)
            (insert "(org-roam-todo-project-validations\n")
            (insert " :validate-review (org-roam-todo-wf-project-test--sample-validation))\n"))
          (let ((config (org-roam-todo-wf-project--load-config temp-dir)))
            (should config)
            (should (eq :validate-review (car config)))
            (should (equal '(org-roam-todo-wf-project-test--sample-validation)
                           (cadr config)))))
      (delete-directory temp-dir t))))

(ert-deftest wf-project-test-load-multiple-validations ()
  "Test loading config with multiple validations for one status."
  :tags '(:unit :wf :project)
  (org-roam-todo-wf-project-test--reset)
  (let ((temp-dir (make-temp-file "wf-project-test-" t)))
    (unwind-protect
        (progn
          (with-temp-file (expand-file-name ".org-todo-config.el" temp-dir)
            (insert "(org-roam-todo-project-validations\n")
            (insert " :validate-done (validation-one validation-two validation-three))\n"))
          (let ((config (org-roam-todo-wf-project--load-config temp-dir)))
            (should config)
            (should (equal '(validation-one validation-two validation-three)
                           (plist-get config :validate-done)))))
      (delete-directory temp-dir t))))

(ert-deftest wf-project-test-load-global-validations ()
  "Test loading config with global validations."
  :tags '(:unit :wf :project)
  (org-roam-todo-wf-project-test--reset)
  (let ((temp-dir (make-temp-file "wf-project-test-" t)))
    (unwind-protect
        (progn
          (with-temp-file (expand-file-name ".org-todo-config.el" temp-dir)
            (insert "(org-roam-todo-project-validations\n")
            (insert " :global (global-check)\n")
            (insert " :validate-review (review-check))\n"))
          (let ((config (org-roam-todo-wf-project--load-config temp-dir)))
            (should config)
            (should (equal '(global-check) (plist-get config :global)))
            (should (equal '(review-check) (plist-get config :validate-review)))))
      (delete-directory temp-dir t))))

;;; ============================================================
;;; Config Caching Tests
;;; ============================================================

(ert-deftest wf-project-test-config-is-cached ()
  "Test that config is cached after first load."
  :tags '(:unit :wf :project)
  (org-roam-todo-wf-project-test--reset)
  (let ((temp-dir (make-temp-file "wf-project-test-" t)))
    (unwind-protect
        (progn
          (with-temp-file (expand-file-name ".org-todo-config.el" temp-dir)
            (insert "(org-roam-todo-project-validations :validate-review (test-fn))\n"))
          ;; First load
          (org-roam-todo-wf-project--load-config temp-dir)
          ;; Should be in cache
          (should (gethash temp-dir org-roam-todo-wf-project--config-cache)))
      (delete-directory temp-dir t))))

(ert-deftest wf-project-test-cache-invalidated-on-file-change ()
  "Test that cache is invalidated when file is modified."
  :tags '(:unit :wf :project)
  (org-roam-todo-wf-project-test--reset)
  (let ((temp-dir (make-temp-file "wf-project-test-" t)))
    (unwind-protect
        (let ((config-file (expand-file-name ".org-todo-config.el" temp-dir)))
          ;; Create initial config
          (with-temp-file config-file
            (insert "(org-roam-todo-project-validations :validate-review (old-fn))\n"))
          ;; First load
          (let ((first-config (org-roam-todo-wf-project--load-config temp-dir)))
            (should (equal '(old-fn) (plist-get first-config :validate-review))))
          ;; Wait a moment to ensure different mtime
          (sleep-for 0.1)
          ;; Modify config
          (with-temp-file config-file
            (insert "(org-roam-todo-project-validations :validate-review (new-fn))\n"))
          ;; Should reload and get new config
          (let ((second-config (org-roam-todo-wf-project--load-config temp-dir)))
            (should (equal '(new-fn) (plist-get second-config :validate-review)))))
      (delete-directory temp-dir t))))

(ert-deftest wf-project-test-clear-cache ()
  "Test clearing the config cache."
  :tags '(:unit :wf :project)
  (org-roam-todo-wf-project-test--reset)
  (let ((temp-dir (make-temp-file "wf-project-test-" t)))
    (unwind-protect
        (progn
          (with-temp-file (expand-file-name ".org-todo-config.el" temp-dir)
            (insert "(org-roam-todo-project-validations :validate-review (test-fn))\n"))
          ;; Load to populate cache
          (org-roam-todo-wf-project--load-config temp-dir)
          (should (gethash temp-dir org-roam-todo-wf-project--config-cache))
          ;; Clear specific project
          (org-roam-todo-wf-project-clear-cache temp-dir)
          (should-not (gethash temp-dir org-roam-todo-wf-project--config-cache)))
      (delete-directory temp-dir t))))

;;; ============================================================
;;; Validation Retrieval Tests
;;; ============================================================

(ert-deftest wf-project-test-get-validations-for-status ()
  "Test getting validations for a specific status."
  :tags '(:unit :wf :project)
  (org-roam-todo-wf-project-test--reset)
  (let ((temp-dir (make-temp-file "wf-project-test-" t)))
    (unwind-protect
        (progn
          (with-temp-file (expand-file-name ".org-todo-config.el" temp-dir)
            (insert "(org-roam-todo-project-validations\n")
            (insert " :validate-review (review-check)\n")
            (insert " :validate-done (done-check))\n"))
          ;; Get review validations
          (let ((fns (org-roam-todo-wf-project-get-validations temp-dir :validate-review)))
            (should (equal '(review-check) fns)))
          ;; Get done validations
          (let ((fns (org-roam-todo-wf-project-get-validations temp-dir :validate-done)))
            (should (equal '(done-check) fns)))
          ;; Get non-existent status
          (let ((fns (org-roam-todo-wf-project-get-validations temp-dir :validate-active)))
            (should-not fns)))
      (delete-directory temp-dir t))))

(ert-deftest wf-project-test-global-validations-included ()
  "Test that global validations are included for all validate events."
  :tags '(:unit :wf :project)
  (org-roam-todo-wf-project-test--reset)
  (let ((temp-dir (make-temp-file "wf-project-test-" t)))
    (unwind-protect
        (progn
          (with-temp-file (expand-file-name ".org-todo-config.el" temp-dir)
            (insert "(org-roam-todo-project-validations\n")
            (insert " :global (global-lint)\n")
            (insert " :validate-review (review-check))\n"))
          ;; Review should have both global and specific
          (let ((fns (org-roam-todo-wf-project-get-validations temp-dir :validate-review)))
            (should (member 'global-lint fns))
            (should (member 'review-check fns)))
          ;; Done should have global even without specific
          (let ((fns (org-roam-todo-wf-project-get-validations temp-dir :validate-done)))
            (should (equal '(global-lint) fns)))
          ;; Non-validate events should not have global
          (let ((fns (org-roam-todo-wf-project-get-validations temp-dir :on-enter-review)))
            (should-not fns)))
      (delete-directory temp-dir t))))

(ert-deftest wf-project-test-global-runs-first ()
  "Test that global validations run before status-specific ones."
  :tags '(:unit :wf :project)
  (org-roam-todo-wf-project-test--reset)
  (let ((temp-dir (make-temp-file "wf-project-test-" t)))
    (unwind-protect
        (progn
          (with-temp-file (expand-file-name ".org-todo-config.el" temp-dir)
            (insert "(org-roam-todo-project-validations\n")
            (insert " :global (global-first)\n")
            (insert " :validate-review (review-second))\n"))
          (let ((fns (org-roam-todo-wf-project-get-validations temp-dir :validate-review)))
            ;; Global should be first in list
            (should (eq 'global-first (car fns)))
            (should (eq 'review-second (cadr fns)))))
      (delete-directory temp-dir t))))

;;; ============================================================
;;; Error Handling Tests
;;; ============================================================

(ert-deftest wf-project-test-syntax-error-in-config ()
  "Test that syntax errors in config are handled gracefully."
  :tags '(:unit :wf :project)
  (org-roam-todo-wf-project-test--reset)
  (let ((temp-dir (make-temp-file "wf-project-test-" t)))
    (unwind-protect
        (progn
          (with-temp-file (expand-file-name ".org-todo-config.el" temp-dir)
            (insert "(org-roam-todo-project-validations\n")
            (insert " :validate-review (missing-paren)\n"))  ;; Missing closing paren
          ;; Should return nil and not error
          (should-not (org-roam-todo-wf-project--load-config temp-dir)))
      (delete-directory temp-dir t))))

(ert-deftest wf-project-test-nil-project-root ()
  "Test that nil project root returns nil."
  :tags '(:unit :wf :project)
  (org-roam-todo-wf-project-test--reset)
  (should-not (org-roam-todo-wf-project--load-config nil)))

;;; ============================================================
;;; Integration with Workflow Dispatch
;;; ============================================================

(ert-deftest wf-project-test-integration-with-dispatch ()
  "Test that project validations are called during workflow dispatch."
  :tags '(:integration :wf :project)
  (org-roam-todo-wf-project-test--reset)
  ;; Skip if org-roam-todo-wf not loaded
  (unless (featurep 'org-roam-todo-wf)
    (ert-skip "org-roam-todo-wf not loaded"))
  (let ((temp-dir (make-temp-file "wf-project-test-" t)))
    (unwind-protect
        (progn
          ;; Create config with our test validation
          (with-temp-file (expand-file-name ".org-todo-config.el" temp-dir)
            (insert "(org-roam-todo-project-validations\n")
            (insert " :validate-review (org-roam-todo-wf-project-test--sample-validation))\n"))
          ;; Create a minimal workflow
          (let* ((workflow (make-org-roam-todo-workflow
                            :name 'test-wf
                            :statuses '("draft" "active" "review" "done")
                            :hooks nil
                            :config nil))
                 (event (make-org-roam-todo-event
                         :type :validate-review
                         :todo (list :project-root temp-dir)
                         :workflow workflow)))
            ;; Dispatch the event
            (org-roam-todo-wf--dispatch-event event)
            ;; Our validation should have been called
            (should org-roam-todo-wf-project-test--validation-called)))
      (delete-directory temp-dir t))))

(ert-deftest wf-project-test-project-validation-failure-blocks-transition ()
  "Test that a failing project validation blocks the transition."
  :tags '(:integration :wf :project)
  (org-roam-todo-wf-project-test--reset)
  (unless (featurep 'org-roam-todo-wf)
    (ert-skip "org-roam-todo-wf not loaded"))
  (let ((temp-dir (make-temp-file "wf-project-test-" t)))
    (unwind-protect
        (progn
          ;; Create config with failing validation
          (with-temp-file (expand-file-name ".org-todo-config.el" temp-dir)
            (insert "(org-roam-todo-project-validations\n")
            (insert " :validate-review (org-roam-todo-wf-project-test--failing-validation))\n"))
          ;; Create a minimal workflow
          (let* ((workflow (make-org-roam-todo-workflow
                            :name 'test-wf
                            :statuses '("draft" "active" "review" "done")
                            :hooks nil
                            :config nil))
                 (event (make-org-roam-todo-event
                         :type :validate-review
                         :todo (list :project-root temp-dir)
                         :workflow workflow)))
            ;; Dispatch and check results
            (let ((results (org-roam-todo-wf--dispatch-event event)))
              ;; Results should contain a :fail
              (should (plist-get results :results))
              (let* ((result-list (plist-get results :results))
                     (first-result (car result-list))
                     (status (plist-get first-result :result)))
                (should (and (listp status) (eq :fail (car status))))))))
      (delete-directory temp-dir t))))

(provide 'org-roam-todo-wf-project-test)
;;; org-roam-todo-wf-project-test.el ends here
