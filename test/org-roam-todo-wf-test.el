;;; org-roam-todo-wf-test.el --- Workflow engine tests -*- lexical-binding: t; -*-

;; Author: Claude Code
;; Version: 0.1.0
;; Package-Requires: ((emacs "28.1") (ert "1.0") (mocker "0.5"))

;;; Commentary:
;; Unit tests for the core workflow engine in org-roam-todo-wf.el.
;; Covers:
;; - Workflow struct creation and registration
;; - Transition validation (forward, backward, rejected, resurrect)
;; - Event dispatch and hook execution
;; - Status change flow
;;
;; Run with:
;;   just test-wf
;; Or:
;;   emacs -batch -L . -L test -l ert -l mocker \
;;     -l test/org-roam-todo-wf-test-utils.el \
;;     -l test/org-roam-todo-wf-test.el \
;;     -f ert-run-tests-batch-and-exit

;;; Code:

(require 'ert)
(require 'cl-lib)

;; Add load paths
(add-to-list 'load-path (file-name-directory (directory-file-name (file-name-directory load-file-name))))
(add-to-list 'load-path (file-name-directory load-file-name))

(require 'org-roam-todo-wf-test-utils)

;; Try to load the implementation (may not exist yet - TDD!)
(condition-case nil
    (require 'org-roam-todo-wf)
  (error nil))

;;; ============================================================
;;; Workflow Struct Tests
;;; ============================================================

(ert-deftest wf-test-workflow-struct-creation ()
  "Test that workflow struct can be created with all fields."
  :tags '(:unit :wf :core)
  (let ((wf (make-org-roam-todo-workflow
             :name 'test-wf
             :statuses '("a" "b" "c")
             :hooks '((:on-enter-b . (identity)))
             :config '(:allow-backward (b)))))
    (should wf)
    (should (eq 'test-wf (org-roam-todo-workflow-name wf)))
    (should (equal '("a" "b" "c") (org-roam-todo-workflow-statuses wf)))
    (should (org-roam-todo-workflow-hooks wf))
    (should (org-roam-todo-workflow-config wf))))

(ert-deftest wf-test-workflow-statuses-order ()
  "Test that statuses preserve order."
  :tags '(:unit :wf :core)
  (org-roam-todo-wf-test--setup-mock-workflow)
  (should (equal '("draft" "active" "review" "done")
                 (org-roam-todo-workflow-statuses
                  org-roam-todo-wf-test--mock-workflow))))

(ert-deftest wf-test-define-workflow-macro ()
  "Test that org-roam-todo-define-workflow creates and registers a workflow."
  :tags '(:unit :wf :core)
  (org-roam-todo-wf-test--require-wf)
  ;; Define a test workflow
  (org-roam-todo-define-workflow test-macro-wf
    "Test workflow from macro"
    :statuses '("a" "b" "c")
    :hooks '((:on-enter-b . (identity)))
    :config '(:allow-backward (b)))
  ;; Verify it's registered
  (let ((wf (gethash 'test-macro-wf org-roam-todo-wf--registry)))
    (should wf)
    (should (equal '("a" "b" "c") (org-roam-todo-workflow-statuses wf)))
    (should (assq :on-enter-b (org-roam-todo-workflow-hooks wf)))
    (should (equal '(b) (plist-get (org-roam-todo-workflow-config wf) :allow-backward)))))

;;; ============================================================
;;; Transition Validation Tests
;;; ============================================================

(ert-deftest wf-test-valid-forward-transition ()
  "Test that forward +1 transitions are always valid."
  :tags '(:unit :wf :transitions)
  (org-roam-todo-wf-test--require-wf)
  (org-roam-todo-wf-test--setup-mock-workflow)
  (let ((wf org-roam-todo-wf-test--mock-workflow))
    (should (org-roam-todo-wf--valid-transition-p wf "draft" "active"))
    (should (org-roam-todo-wf--valid-transition-p wf "active" "review"))
    (should (org-roam-todo-wf--valid-transition-p wf "review" "done"))))

(ert-deftest wf-test-invalid-skip-transition ()
  "Test that skipping statuses is not allowed."
  :tags '(:unit :wf :transitions)
  (org-roam-todo-wf-test--require-wf)
  (org-roam-todo-wf-test--setup-mock-workflow)
  (let ((wf org-roam-todo-wf-test--mock-workflow))
    (should-not (org-roam-todo-wf--valid-transition-p wf "draft" "review"))
    (should-not (org-roam-todo-wf--valid-transition-p wf "draft" "done"))
    (should-not (org-roam-todo-wf--valid-transition-p wf "active" "done"))))

(ert-deftest wf-test-backward-allowed ()
  "Test backward transition when allowed by :allow-backward."
  :tags '(:unit :wf :transitions)
  (org-roam-todo-wf-test--require-wf)
  (org-roam-todo-wf-test--setup-mock-workflow)
  (let ((wf org-roam-todo-wf-test--mock-workflow))
    ;; review is in :allow-backward, so review->active is valid
    (should (org-roam-todo-wf--valid-transition-p wf "review" "active"))))

(ert-deftest wf-test-backward-not-allowed ()
  "Test backward transition when NOT allowed."
  :tags '(:unit :wf :transitions)
  (org-roam-todo-wf-test--require-wf)
  (org-roam-todo-wf-test--setup-mock-workflow)
  (let ((wf org-roam-todo-wf-test--mock-workflow))
    ;; active is not in :allow-backward, so active->draft is invalid
    (should-not (org-roam-todo-wf--valid-transition-p wf "active" "draft"))
    ;; done is not in :allow-backward
    (should-not (org-roam-todo-wf--valid-transition-p wf "done" "review"))))

(ert-deftest wf-test-rejected-always-available ()
  "Test that any status can transition to 'rejected'."
  :tags '(:unit :wf :transitions)
  (org-roam-todo-wf-test--require-wf)
  (org-roam-todo-wf-test--setup-mock-workflow)
  (let ((wf org-roam-todo-wf-test--mock-workflow))
    (should (org-roam-todo-wf--valid-transition-p wf "draft" "rejected"))
    (should (org-roam-todo-wf--valid-transition-p wf "active" "rejected"))
    (should (org-roam-todo-wf--valid-transition-p wf "review" "rejected"))
    (should (org-roam-todo-wf--valid-transition-p wf "done" "rejected"))))

(ert-deftest wf-test-resurrect-from-rejected ()
  "Test that 'rejected' can transition to first status (resurrect)."
  :tags '(:unit :wf :transitions)
  (org-roam-todo-wf-test--require-wf)
  (org-roam-todo-wf-test--setup-mock-workflow)
  (let ((wf org-roam-todo-wf-test--mock-workflow))
    (should (org-roam-todo-wf--valid-transition-p wf "rejected" "draft"))
    ;; But not to other statuses
    (should-not (org-roam-todo-wf--valid-transition-p wf "rejected" "active"))
    (should-not (org-roam-todo-wf--valid-transition-p wf "rejected" "review"))))

(ert-deftest wf-test-next-statuses ()
  "Test that next-statuses returns correct options."
  :tags '(:unit :wf :transitions)
  (org-roam-todo-wf-test--require-wf)
  (org-roam-todo-wf-test--setup-mock-workflow)
  (let ((wf org-roam-todo-wf-test--mock-workflow))
    ;; From draft: can go to active or rejected
    (let ((next (org-roam-todo-wf--next-statuses wf "draft")))
      (should (member "active" next))
      (should (member "rejected" next))
      (should-not (member "review" next)))
    ;; From review: can go to done, active (backward allowed), or rejected
    (let ((next (org-roam-todo-wf--next-statuses wf "review")))
      (should (member "done" next))
      (should (member "active" next))
      (should (member "rejected" next)))
    ;; From rejected: can only go to draft (resurrect)
    (let ((next (org-roam-todo-wf--next-statuses wf "rejected")))
      (should (member "draft" next)))))

(ert-deftest wf-test-same-status-not-valid ()
  "Test that staying in the same status is not a valid transition."
  :tags '(:unit :wf :transitions)
  (org-roam-todo-wf-test--require-wf)
  (org-roam-todo-wf-test--setup-mock-workflow)
  (let ((wf org-roam-todo-wf-test--mock-workflow))
    (should-not (org-roam-todo-wf--valid-transition-p wf "draft" "draft"))
    (should-not (org-roam-todo-wf--valid-transition-p wf "active" "active"))))

;;; ============================================================
;;; Event Dispatch Tests
;;; ============================================================

(ert-deftest wf-test-event-dispatch-calls-hooks ()
  "Test that dispatch-event calls registered hooks."
  :tags '(:unit :wf :events)
  (org-roam-todo-wf-test--require-wf)
  (org-roam-todo-wf-test--setup-mock-workflow)

  (let ((event (make-org-roam-todo-event
                :type :on-enter-active
                :todo '(:title "Test")
                :workflow org-roam-todo-wf-test--mock-workflow)))
    (org-roam-todo-wf--dispatch-event event)
    (should (= 1 (org-roam-todo-wf-test--hook-call-count :on-enter-active)))))

(ert-deftest wf-test-event-dispatch-no-hooks ()
  "Test that dispatch-event handles missing hooks gracefully."
  :tags '(:unit :wf :events)
  (org-roam-todo-wf-test--require-wf)
  (org-roam-todo-wf-test--setup-mock-workflow)

  (let ((event (make-org-roam-todo-event
                :type :on-enter-nonexistent  ; No hook registered for this
                :todo '(:title "Test")
                :workflow org-roam-todo-wf-test--mock-workflow)))
    ;; Should not error
    (should (org-roam-todo-wf--dispatch-event event))))

(ert-deftest wf-test-validation-hook-can-reject ()
  "Test that validation hooks can reject transitions."
  :tags '(:unit :wf :validation)
  (org-roam-todo-wf-test--require-wf)
  (org-roam-todo-wf-test--setup-mock-workflow)

  (let ((event (make-org-roam-todo-event
                :type :validate-review
                :todo '(:title "Test" :extra (:should-fail t))
                :workflow org-roam-todo-wf-test--mock-workflow)))
    (should-error (org-roam-todo-wf--dispatch-event event)
                  :type 'user-error)))

(ert-deftest wf-test-validation-hook-passes ()
  "Test that validation hooks pass when conditions are met."
  :tags '(:unit :wf :validation)
  (org-roam-todo-wf-test--require-wf)
  (org-roam-todo-wf-test--setup-mock-workflow)

  (let ((event (make-org-roam-todo-event
                :type :validate-review
                :todo '(:title "Test")
                :workflow org-roam-todo-wf-test--mock-workflow
                :actor 'human)))  ; no :should-fail in todo
    (should (org-roam-todo-wf--dispatch-event event))
    (should (org-roam-todo-wf-test--hook-was-called-p :validate-review))))

(ert-deftest wf-test-hook-stop-skips-remaining ()
  "Test that returning 'stop from a hook skips remaining hooks."
  :tags '(:unit :wf :events)
  (org-roam-todo-wf-test--require-wf)
  ;; Create a workflow with two hooks, first returns 'stop
  (let* ((call-log nil)
         (hook1 (lambda (e) (push 'hook1 call-log) 'stop))
         (hook2 (lambda (e) (push 'hook2 call-log) nil))
         (wf (make-org-roam-todo-workflow
              :name 'stop-test
              :statuses '("a" "b")
              :hooks `((:on-enter-b . (,hook1 ,hook2)))
              :config nil)))
    (let ((event (make-org-roam-todo-event
                  :type :on-enter-b
                  :todo '(:title "Test")
                  :workflow wf)))
      (org-roam-todo-wf--dispatch-event event)
      ;; Only hook1 should have been called
      (should (equal '(hook1) call-log)))))

;;; ============================================================
;;; Status Change Integration Tests
;;; ============================================================

(ert-deftest wf-test-change-status-updates-file ()
  "Test that change-status updates the TODO file."
  :tags '(:unit :wf :status)
  (org-roam-todo-wf-test--require-wf)
  (org-roam-todo-wf-test--require-mocker)
  (org-roam-todo-wf-test--setup-mock-workflow)

  (org-roam-todo-wf-test-with-temp-todo
      '(:title "Test TODO" :status "draft")
    (mocker-let
        ((org-roam-todo-wf--get-workflow (todo)
           ((:input-matcher #'always
             :output org-roam-todo-wf-test--mock-workflow))))
      (org-roam-todo-wf--change-status todo-plist "active")
      ;; Verify file was updated
      (should (equal "active" (org-roam-todo-wf-test--get-file-property todo-file "STATUS"))))))

(ert-deftest wf-test-change-status-fires-enter-hook ()
  "Test that change-status fires :on-enter hooks."
  :tags '(:unit :wf :status)
  (org-roam-todo-wf-test--require-wf)
  (org-roam-todo-wf-test--require-mocker)
  (org-roam-todo-wf-test--setup-mock-workflow)

  (org-roam-todo-wf-test-with-temp-todo
      '(:title "Test TODO" :status "draft")
    (mocker-let
        ((org-roam-todo-wf--get-workflow (todo)
           ((:input-matcher #'always
             :output org-roam-todo-wf-test--mock-workflow))))
      (org-roam-todo-wf--change-status todo-plist "active")
      ;; Should have called :on-enter-active
      (should (org-roam-todo-wf-test--hook-was-called-p :on-enter-active)))))

(ert-deftest wf-test-change-status-fires-exit-hook ()
  "Test that change-status fires :on-exit hooks."
  :tags '(:unit :wf :status)
  (org-roam-todo-wf-test--require-wf)
  (org-roam-todo-wf-test--require-mocker)
  (org-roam-todo-wf-test--setup-mock-workflow)

  (org-roam-todo-wf-test-with-temp-todo
      '(:title "Test TODO" :status "active")
    (mocker-let
        ((org-roam-todo-wf--get-workflow (todo)
           ((:input-matcher #'always
             :output org-roam-todo-wf-test--mock-workflow))))
      (org-roam-todo-wf--change-status todo-plist "review")
      ;; Should have called :on-exit-active
      (should (org-roam-todo-wf-test--hook-was-called-p :on-exit-active)))))

(ert-deftest wf-test-change-status-runs-validation-first ()
  "Test that change-status runs validation before making changes."
  :tags '(:unit :wf :status :validation)
  (org-roam-todo-wf-test--require-wf)
  (org-roam-todo-wf-test--require-mocker)
  (org-roam-todo-wf-test--setup-mock-workflow)

  (org-roam-todo-wf-test-with-temp-todo
      '(:title "Test TODO" :status "active")
    (mocker-let
        ((org-roam-todo-wf--get-workflow (todo)
           ((:input-matcher #'always
             :output org-roam-todo-wf-test--mock-workflow))))
      ;; Validation should fail
      (should-error (org-roam-todo-wf--change-status
                     (plist-put (copy-sequence todo-plist) :extra '(:should-fail t))
                     "review")
                    :type 'user-error)
      ;; File should NOT have been updated
      (should (equal "active" (org-roam-todo-wf-test--get-file-property todo-file "STATUS"))))))

(ert-deftest wf-test-change-status-rejects-invalid-transition ()
  "Test that change-status rejects invalid transitions."
  :tags '(:unit :wf :status)
  (org-roam-todo-wf-test--require-wf)
  (org-roam-todo-wf-test--require-mocker)
  (org-roam-todo-wf-test--setup-mock-workflow)

  (org-roam-todo-wf-test-with-temp-todo
      '(:title "Test TODO" :status "draft")
    (mocker-let
        ((org-roam-todo-wf--get-workflow (todo)
           ((:input-matcher #'always
             :output org-roam-todo-wf-test--mock-workflow))))
      ;; Can't skip from draft to review
      (should-error (org-roam-todo-wf--change-status todo-plist "review")
                    :type 'user-error))))

;;; ============================================================
;;; Workflow Resolution Tests
;;; ============================================================

(ert-deftest wf-test-resolve-workflow-from-todo ()
  "Test resolve-workflow uses TODO's own WORKFLOW property first."
  :tags '(:unit :wf :resolution)
  (org-roam-todo-wf-test--require-wf)
  ;; Register a workflow
  (puthash 'local-ff
           (make-org-roam-todo-workflow :name 'local-ff :statuses '("a" "b"))
           org-roam-todo-wf--registry)
  (let ((todo (list :workflow 'local-ff :project-name "test-project")))
    (should (eq 'local-ff
                (org-roam-todo-workflow-name
                 (org-roam-todo-wf--resolve-workflow todo))))))

(ert-deftest wf-test-resolve-workflow-from-project-config ()
  "Test resolve-workflow falls back to project configuration."
  :tags '(:unit :wf :resolution)
  (org-roam-todo-wf-test--require-wf)
  ;; Register workflows
  (puthash 'github-pr
           (make-org-roam-todo-workflow :name 'github-pr :statuses '("a" "b" "c"))
           org-roam-todo-wf--registry)
  (let ((todo (list :project-name "my-project"))
        (org-roam-todo-project-workflows '(("my-project" . github-pr)
                                           ("scripts" . local-ff))))
    (should (eq 'github-pr
                (org-roam-todo-workflow-name
                 (org-roam-todo-wf--resolve-workflow todo))))))

(ert-deftest wf-test-resolve-workflow-default ()
  "Test resolve-workflow uses default when nothing configured."
  :tags '(:unit :wf :resolution)
  (org-roam-todo-wf-test--require-wf)
  ;; Register the default workflow
  (puthash 'github-pr
           (make-org-roam-todo-workflow :name 'github-pr :statuses '("a" "b"))
           org-roam-todo-wf--registry)
  (let ((todo (list :project-name "unknown-project"))
        (org-roam-todo-project-workflows nil)
        (org-roam-todo-default-workflow 'github-pr))
    (should (eq 'github-pr
                (org-roam-todo-workflow-name
                 (org-roam-todo-wf--resolve-workflow todo))))))

;;; ============================================================
;;; Event Struct Tests
;;; ============================================================

(ert-deftest wf-test-event-struct-creation ()
  "Test that event struct can be created with all fields."
  :tags '(:unit :wf :core)
  (let ((event (make-org-roam-todo-event
                :type :on-enter-active
                :todo '(:title "Test" :status "draft")
                :workflow (make-org-roam-todo-workflow :name 'test)
                :old-status "draft"
                :new-status "active"
                :actor 'human)))
    (should event)
    (should (eq :on-enter-active (org-roam-todo-event-type event)))
    (should (equal "draft" (org-roam-todo-event-old-status event)))
    (should (equal "active" (org-roam-todo-event-new-status event)))
    (should (eq 'human (org-roam-todo-event-actor event)))))


;;; ============================================================
;;; Actor-Based Permission Tests
;;; ============================================================

(ert-deftest wf-test-only-human-passes-for-humans ()
  "Test that only-human validation passes when actor is human."
  :tags '(:unit :wf :permissions)
  (org-roam-todo-wf-test--require-wf)
  (let ((event (make-org-roam-todo-event :type :validate-done :actor 'human)))
    ;; Should not error
    (should-not (org-roam-todo-wf--only-human event))))

(ert-deftest wf-test-only-human-blocks-ai ()
  "Test that only-human validation blocks AI agents."
  :tags '(:unit :wf :permissions)
  (org-roam-todo-wf-test--require-wf)
  (let ((event (make-org-roam-todo-event :type :validate-done :actor 'ai)))
    (should-error (org-roam-todo-wf--only-human event)
                  :type 'user-error)))

(ert-deftest wf-test-only-human-error-message ()
  "Test that only-human provides a clear error message."
  :tags '(:unit :wf :permissions)
  (org-roam-todo-wf-test--require-wf)
  (let ((event (make-org-roam-todo-event :type :validate-done :actor 'ai)))
    (condition-case err
        (org-roam-todo-wf--only-human event)
      (user-error
       (should (string-match-p "human action" (cadr err)))
       (should (string-match-p "AI agent" (cadr err)))))))

(ert-deftest wf-test-only-ai-passes-for-ai ()
  "Test that only-ai validation passes when actor is AI."
  :tags '(:unit :wf :permissions)
  (org-roam-todo-wf-test--require-wf)
  (let ((event (make-org-roam-todo-event :type :validate-ci :actor 'ai)))
    ;; Should not error
    (should-not (org-roam-todo-wf--only-ai event))))

(ert-deftest wf-test-only-ai-blocks-humans ()
  "Test that only-ai validation blocks human actors."
  :tags '(:unit :wf :permissions)
  (org-roam-todo-wf-test--require-wf)
  (let ((event (make-org-roam-todo-event :type :validate-ci :actor 'human)))
    (should-error (org-roam-todo-wf--only-ai event)
                  :type 'user-error)))

(ert-deftest wf-test-only-ai-error-message ()
  "Test that only-ai provides a clear error message."
  :tags '(:unit :wf :permissions)
  (org-roam-todo-wf-test--require-wf)
  (let ((event (make-org-roam-todo-event :type :validate-ci :actor 'human)))
    (condition-case err
        (org-roam-todo-wf--only-ai event)
      (user-error
       (should (string-match-p "automated" (cadr err)))
       (should (string-match-p "human" (cadr err)))))))

(ert-deftest wf-test-only-human-nil-actor-treated-as-human ()
  "Test that nil actor is treated as human (default)."
  :tags '(:unit :wf :permissions)
  (org-roam-todo-wf-test--require-wf)
  (let ((event (make-org-roam-todo-event :type :validate-done :actor nil)))
    ;; nil actor should be treated as human, so only-human passes
    (should-not (org-roam-todo-wf--only-human event))
    ;; and only-ai should fail
    (should-error (org-roam-todo-wf--only-ai event)
                  :type 'user-error)))

;;; ============================================================
;;; Permission Hook Integration Tests
;;; ============================================================

(ert-deftest wf-test-permission-hook-in-workflow ()
  "Test that permission hooks work within workflow dispatch."
  :tags '(:unit :wf :permissions :integration)
  (org-roam-todo-wf-test--require-wf)
  ;; Create a workflow with only-human validation
  (let* ((wf (make-org-roam-todo-workflow
              :name 'permission-test
              :statuses '("a" "b")
              :hooks '((:validate-b . (org-roam-todo-wf--only-human)))
              :config nil)))
    ;; Human should pass
    (let ((event (make-org-roam-todo-event
                  :type :validate-b
                  :todo '(:title "Test")
                  :workflow wf
                  :actor 'human)))
      (should (org-roam-todo-wf--dispatch-event event)))
    ;; AI should fail
    (let ((event (make-org-roam-todo-event
                  :type :validate-b
                  :todo '(:title "Test")
                  :workflow wf
                  :actor 'ai)))
      (should-error (org-roam-todo-wf--dispatch-event event)
                    :type 'user-error))))

(ert-deftest wf-test-permission-hook-combined-with-other-validation ()
  "Test that permission hooks work alongside other validation hooks."
  :tags '(:unit :wf :permissions :integration)
  (org-roam-todo-wf-test--require-wf)
  ;; Create a workflow with both permission and custom validation
  (let* ((custom-passed nil)
         (custom-validator (lambda (e)
                             (setq custom-passed t)
                             nil))  ; passes
         (wf (make-org-roam-todo-workflow
              :name 'combined-test
              :statuses '("a" "b")
              :hooks `((:validate-b . (,custom-validator org-roam-todo-wf--only-human)))
              :config nil)))
    ;; Human should pass both hooks
    (let ((event (make-org-roam-todo-event
                  :type :validate-b
                  :todo '(:title "Test")
                  :workflow wf
                  :actor 'human)))
      (setq custom-passed nil)
      (should (org-roam-todo-wf--dispatch-event event))
      (should custom-passed))
    ;; AI should fail at permission hook (custom should still run first)
    (let ((event (make-org-roam-todo-event
                  :type :validate-b
                  :todo '(:title "Test")
                  :workflow wf
                  :actor 'ai)))
      (setq custom-passed nil)
      (should-error (org-roam-todo-wf--dispatch-event event)
                    :type 'user-error)
      ;; Custom validator should have been called before permission check
      (should custom-passed))))

(ert-deftest wf-test-change-status-passes-actor-to-hooks ()
  "Test that change-status correctly passes actor to validation hooks."
  :tags '(:unit :wf :permissions :integration)
  (org-roam-todo-wf-test--require-wf)
  (org-roam-todo-wf-test--require-mocker)
  ;; Create a workflow where :validate-b uses only-human
  (let* ((wf (make-org-roam-todo-workflow
              :name 'actor-test
              :statuses '("a" "b")
              :hooks '((:validate-b . (org-roam-todo-wf--only-human)))
              :config nil)))
    (org-roam-todo-wf-test-with-temp-todo
        '(:title "Actor Test" :status "a")
      (mocker-let
          ((org-roam-todo-wf--get-workflow (todo)
             ((:input-matcher #'always
               :output wf))))
        ;; Human actor should succeed
        (org-roam-todo-wf--change-status todo-plist "b" 'human)
        (should (equal "b" (org-roam-todo-wf-test--get-file-property todo-file "STATUS")))))))

(ert-deftest wf-test-change-status-ai-blocked-by-only-human ()
  "Test that AI actor is blocked by only-human validation."
  :tags '(:unit :wf :permissions :integration)
  (org-roam-todo-wf-test--require-wf)
  (org-roam-todo-wf-test--require-mocker)
  ;; Create a workflow where :validate-b uses only-human
  (let* ((wf (make-org-roam-todo-workflow
              :name 'actor-test
              :statuses '("a" "b")
              :hooks '((:validate-b . (org-roam-todo-wf--only-human)))
              :config nil)))
    (org-roam-todo-wf-test-with-temp-todo
        '(:title "Actor Test" :status "a")
      (mocker-let
          ((org-roam-todo-wf--get-workflow (todo)
             ((:input-matcher #'always
               :output wf))))
        ;; AI actor should be blocked
        (should-error (org-roam-todo-wf--change-status todo-plist "b" 'ai)
                      :type 'user-error)
        ;; Status should not have changed
        (should (equal "a" (org-roam-todo-wf-test--get-file-property todo-file "STATUS")))))))

(ert-deftest wf-test-change-status-defaults-to-human ()
  "Test that change-status defaults to human actor when not specified."
  :tags '(:unit :wf :permissions :integration)
  (org-roam-todo-wf-test--require-wf)
  (org-roam-todo-wf-test--require-mocker)
  ;; Create a workflow where :validate-b uses only-ai (blocks humans)
  (let* ((wf (make-org-roam-todo-workflow
              :name 'default-actor-test
              :statuses '("a" "b")
              :hooks '((:validate-b . (org-roam-todo-wf--only-ai)))
              :config nil)))
    (org-roam-todo-wf-test-with-temp-todo
        '(:title "Default Actor Test" :status "a")
      (mocker-let
          ((org-roam-todo-wf--get-workflow (todo)
             ((:input-matcher #'always
               :output wf))))
        ;; No actor specified - should default to human and be blocked by only-ai
        (should-error (org-roam-todo-wf--change-status todo-plist "b")
                      :type 'user-error)))))

(provide 'org-roam-todo-wf-test)
;;; org-roam-todo-wf-test.el ends here
