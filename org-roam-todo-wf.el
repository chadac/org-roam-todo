;;; org-roam-todo-wf.el --- Workflow engine for org-roam-todo -*- lexical-binding: t; -*-

;; Author: Claude Code
;; Version: 0.1.0
;; Package-Requires: ((emacs "28.1") (org-roam "2.0"))

;;; Commentary:
;; Hook-based workflow engine for org-roam-todo.
;; Provides:
;; - Workflow definition with custom statuses and hooks
;; - Event-driven status transitions with validation
;; - Implicit transition model: forward +1, backward -1 (if allowed), rejected always
;;
;; See CLAUDE.md for design details and test/org-roam-todo-wf-test.el for usage.

;;; Code:

(require 'cl-lib)

;;; ============================================================
;;; Data Structures
;;; ============================================================

(cl-defstruct org-roam-todo-workflow
  "A TODO workflow definition."
  name           ; Symbol: 'github-pr, 'local-ff, etc.
  statuses       ; List of status strings in order (first is initial, last is terminal)
  hooks          ; Alist: ((event-symbol . (functions...)) ...)
  config)        ; Plist of workflow-specific settings

(cl-defstruct org-roam-todo-event
  "Context passed to all hook functions."
  type           ; Symbol: ':on-enter-active, ':validate-review, etc.
  todo           ; The TODO plist (file, project, status, worktree-path, etc.)
  workflow       ; The workflow struct
  old-status     ; Previous status (for status-changed events)
  new-status     ; New status (for status-changed events)
  actor)         ; Symbol: 'human or 'ai - who is performing the action

;;; ============================================================
;;; Workflow Registry
;;; ============================================================

(defvar org-roam-todo-wf--registry (make-hash-table :test 'eq)
  "Hash table mapping workflow names (symbols) to workflow structs.")

(defcustom org-roam-todo-project-workflows nil
  "Alist mapping project names to workflow symbols.
Example: \\='((\"my-project\" . pull-request) (\"scripts\" . local-ff))"
  :type '(alist :key-type string :value-type symbol)
  :group 'org-roam-todo)

(defcustom org-roam-todo-default-workflow 'pull-request
  "Default workflow when none is configured for a project.
Available workflows: `pull-request', `local-ff', `basic'."
  :type 'symbol
  :group 'org-roam-todo)

;;; ============================================================
;;; Workflow Definition Macro
;;; ============================================================

(defmacro org-roam-todo-define-workflow (name _docstring &rest args)
  "Define and register a workflow named NAME.
_DOCSTRING describes the workflow (for documentation).
ARGS is a plist with :statuses, :hooks, and :config."
  (declare (indent 2) (doc-string 2))
  (let ((statuses (plist-get args :statuses))
        (hooks (plist-get args :hooks))
        (config (plist-get args :config)))
    `(puthash ',name
              (make-org-roam-todo-workflow
               :name ',name
               :statuses ,statuses
               :hooks ,hooks
               :config ,config)
              org-roam-todo-wf--registry)))

;;; ============================================================
;;; Transition Validation
;;; ============================================================

(defun org-roam-todo-wf--valid-transition-p (workflow from-status to-status)
  "Return non-nil if FROM-STATUS -> TO-STATUS is allowed in WORKFLOW.
Rules:
- Forward by exactly one step: always allowed
- Backward by one step: allowed if FROM-STATUS is in :allow-backward
- To rejected: always allowed from any status
- From rejected to first status (resurrect): always allowed
- Same status: not allowed
- Skip statuses: not allowed"
  (let* ((statuses (org-roam-todo-workflow-statuses workflow))
         (config (org-roam-todo-workflow-config workflow))
         (allow-backward (plist-get config :allow-backward))
         (from-idx (cl-position from-status statuses :test #'string=))
         (to-idx (cl-position to-status statuses :test #'string=)))
    (cond
     ;; Same status: not allowed
     ((string= from-status to-status) nil)
     ;; Always allow -> rejected
     ((string= to-status "rejected") t)
     ;; Always allow rejected -> first status (resurrect)
     ((and (string= from-status "rejected")
           (string= to-status (car statuses))) t)
     ;; From rejected to anything else: not allowed
     ((string= from-status "rejected") nil)
     ;; Forward by exactly one step: always allowed
     ((and from-idx to-idx (= to-idx (1+ from-idx))) t)
     ;; Backward by one step: allowed if status is in :allow-backward
     ((and from-idx to-idx (= to-idx (1- from-idx))
           (member (intern from-status) allow-backward)) t)
     ;; Otherwise: not allowed
     (t nil))))

(defun org-roam-todo-wf--next-statuses (workflow current-status)
  "Return list of valid next statuses from CURRENT-STATUS in WORKFLOW."
  (let* ((statuses (org-roam-todo-workflow-statuses workflow))
         (config (org-roam-todo-workflow-config workflow))
         (allow-backward (plist-get config :allow-backward))
         (idx (cl-position current-status statuses :test #'string=))
         (result '()))
    ;; Rejected always available (except from rejected itself)
    (unless (string= current-status "rejected")
      (push "rejected" result))
    ;; From rejected: can go to first status
    (when (string= current-status "rejected")
      (push (car statuses) result))
    (when idx
      ;; Forward step
      (when (< idx (1- (length statuses)))
        (push (nth (1+ idx) statuses) result))
      ;; Backward step (if allowed)
      (when (and (> idx 0)
                 (member (intern current-status) allow-backward))
        (push (nth (1- idx) statuses) result)))
    result))

;;; ============================================================
;;; Validation Results Storage
;;; ============================================================

(defvar org-roam-todo-wf--validation-results (make-hash-table :test 'equal)
  "Hash table storing validation results.
Key: (file . status) cons
Value: (:results list-of-results :timestamp time)")

(defun org-roam-todo-wf--store-validation-results (file status results)
  "Store validation RESULTS for FILE at STATUS."
  (puthash (cons file status)
           (list :results (plist-get results :results)
                 :timestamp (current-time))
           org-roam-todo-wf--validation-results))

(defun org-roam-todo-wf--get-validation-results (file status)
  "Get stored validation results for FILE at STATUS."
  (gethash (cons file status) org-roam-todo-wf--validation-results))

(defun org-roam-todo-wf--clear-validation-results (file status)
  "Clear validation results for FILE at STATUS."
  (remhash (cons file status) org-roam-todo-wf--validation-results))

;;; ============================================================
;;; Auto-Upgrade Configuration
;;; ============================================================

(defun org-roam-todo-wf--get-auto-upgrade-config (workflow status)
  "Get auto-upgrade configuration for STATUS in WORKFLOW.
Returns a plist with keys:
  :on-pass - status to advance to when all validations pass
  :on-fail - status to regress to when any validation fails
  :poll-interval - seconds between validation checks
  :timeout - maximum seconds to wait
  :feedback - whether to capture feedback on failure"
  (when-let ((config (org-roam-todo-workflow-config workflow))
             (auto-upgrade (plist-get config :auto-upgrade)))
    (cdr (assoc status auto-upgrade))))

(defun org-roam-todo-wf--status-has-auto-upgrade-p (workflow status)
  "Return non-nil if STATUS has auto-upgrade configured in WORKFLOW."
  (org-roam-todo-wf--get-auto-upgrade-config workflow status))

(defun org-roam-todo-wf--validation-state (results)
  "Determine overall state from validation RESULTS list.
Returns:
  :pass - all validations passed
  :pending - at least one validation is pending
  :fail - at least one validation failed (and none pending)
  :feedback - at least one validation requires feedback"
  (let ((has-pending nil)
        (has-fail nil)
        (has-feedback nil))
    (dolist (result results)
      (when (listp result)
        (pcase (car result)
          (:pending (setq has-pending t))
          (:fail (setq has-fail t))
          (:error (setq has-fail t))
          (:feedback (setq has-feedback t)))))
    (cond
     (has-feedback :feedback)
     (has-pending :pending)
     (has-fail :fail)
     (t :pass))))

;;; ============================================================
;;; Event Dispatch
;;; ============================================================

(defun org-roam-todo-wf--dispatch-event (event)
  "Run all hooks registered for EVENT in its workflow.
For :validate-* events: collects structured results from all hooks.
For other events: runs hooks sequentially, stopping on 'stop return.

Validation hooks can return:
- nil or :pass - validation passed
- (:pending \"message\") - async validation in progress
- (:feedback \"message\") - requires user feedback
- (:fail \"message\") - validation failed
- Can also signal user-error (caught and converted to :fail)

Returns:
- For :validate-* events: (:results (list-of-results...))
- For other events: 'completed or 'stopped"
  (let* ((workflow (org-roam-todo-event-workflow event))
         (event-type (org-roam-todo-event-type event))
         (hooks (org-roam-todo-workflow-hooks workflow))
         (fns (cdr (assq event-type hooks)))
         (is-validation (string-match-p "^:validate-" (symbol-name event-type))))
    (if (null fns)
        (if is-validation '(:results nil) 'completed)
      (if is-validation
          ;; Validation mode: collect all results (don't short-circuit)
          (list :results
                (cl-loop for fn in fns
                         collect (condition-case err
                                     (let ((result (funcall fn event)))
                                       (or result :pass))
                                   (user-error (list :fail (cadr err)))
                                   (error (list :error (error-message-string err))))))
          ;; Normal mode: run hooks sequentially
          (cl-loop for fn in fns
                   for result = (funcall fn event)
                   when (eq result 'stop) return 'stopped
                   finally return 'completed)))))

;;; ============================================================
;;; Status Change
;;; ============================================================

(defun org-roam-todo-wf--change-status (todo new-status &optional actor)
  "Change TODO to NEW-STATUS, firing appropriate events.
ACTOR is who is performing the action: `human' (default) or `ai'.

Transition flow:
1. Validate transition is allowed (state machine rules)
2. Run :validate-NEW-STATUS hooks (can reject with error)
3. Fire :on-exit-OLD-STATUS hooks
4. Update status in file
5. Fire :on-status-changed hooks
6. Fire :on-enter-NEW-STATUS hooks (actions)"
  (let* ((workflow (org-roam-todo-wf--get-workflow todo))
         (old-status (plist-get todo :status))
         (file (plist-get todo :file))
         (event (make-org-roam-todo-event
                 :todo todo
                 :workflow workflow
                 :old-status old-status
                 :new-status new-status
                 :actor (or actor 'human))))

    ;; 1. Validate transition is allowed by state machine
    (unless (org-roam-todo-wf--valid-transition-p workflow old-status new-status)
      (user-error "Invalid transition: %s -> %s (allowed: %s)"
                  old-status new-status
                  (org-roam-todo-wf--next-statuses workflow old-status)))

    ;; 2. Run validation hooks - collect results, block on :fail/:error
    (setf (org-roam-todo-event-type event)
          (intern (format ":validate-%s" new-status)))
    (let ((validation-results (org-roam-todo-wf--dispatch-event event)))
      ;; Check for blocking failures (:fail or :error)
      (cl-loop for result in (plist-get validation-results :results)
               when (and (listp result)
                         (memq (car result) '(:fail :error)))
               do (user-error "Validation failed: %s" (cadr result)))

      ;; Store results for auto-upgrade system and feedback display
      (when (plist-get validation-results :results)
        (org-roam-todo-wf--store-validation-results file new-status validation-results)))

    ;; 3. Fire exit hook (validation passed, now committing to transition)
    (setf (org-roam-todo-event-type event)
          (intern (format ":on-exit-%s" old-status)))
    (org-roam-todo-wf--dispatch-event event)

    ;; 4. Update status in file
    (org-roam-todo-wf--set-status-in-file file new-status)

    ;; 5. Fire status-changed hook
    (setf (org-roam-todo-event-type event) :on-status-changed)
    (org-roam-todo-wf--dispatch-event event)

    ;; 6. Fire enter hook (actions)
    (setf (org-roam-todo-event-type event)
          (intern (format ":on-enter-%s" new-status)))
    (org-roam-todo-wf--dispatch-event event)

    ;; 7. Start watchers for the new status (if org-roam-todo-wf-watch is loaded)
    (when (fboundp 'org-roam-todo-wf-watch--on-status-changed)
      (org-roam-todo-wf-watch--on-status-changed event))))


;;; ============================================================
;;; Auto-Upgrade Check and Apply
;;; ============================================================

(defun org-roam-todo-wf-check-auto-upgrade (todo-file &optional current-status)
  "Check if TODO at TODO-FILE can be auto-upgraded.
Returns a plist:
  :can-upgrade - t if upgrade/downgrade should happen
  :action - 'advance or 'regress
  :target-status - status to transition to
  :state - :pass, :pending, :fail, or :feedback
  :results - list of validation results
  :message - human-readable message

If CURRENT-STATUS is provided, uses it; otherwise reads from file."
  (require 'org-roam-todo-core)
  (let* ((status (or current-status
                     (org-roam-todo-get-file-property todo-file "STATUS")))
         (project-name (org-roam-todo-get-file-property todo-file "PROJECT_NAME"))
         (workflow-name (or (cdr (assoc project-name org-roam-todo-project-workflows))
                           (intern (or (org-roam-todo-get-file-property todo-file "WORKFLOW")
                                      "basic"))))
         (workflow (gethash workflow-name org-roam-todo-wf--registry))
         (auto-config (org-roam-todo-wf--get-auto-upgrade-config workflow status)))

    (if (not auto-config)
        ;; No auto-upgrade configured for this status
        (list :can-upgrade nil
              :message (format "No auto-upgrade configured for status '%s'" status))

      ;; Check validations for next status
      (let* ((on-pass (plist-get auto-config :on-pass))
             (on-fail (plist-get auto-config :on-fail))
             (todo (list :file todo-file
                        :status status
                        :project-name project-name))
             (event (make-org-roam-todo-event
                     :todo todo
                     :workflow workflow
                     :old-status status
                     :new-status on-pass
                     :actor 'ai))
             (_ (setf (org-roam-todo-event-type event)
                     (intern (format ":validate-%s" on-pass))))
             (results (org-roam-todo-wf--dispatch-event event))
             (results-list (plist-get results :results))
             (state (org-roam-todo-wf--validation-state results-list)))

        (pcase state
          (:pass
           (list :can-upgrade t
                 :action 'advance
                 :target-status on-pass
                 :state :pass
                 :results results-list
                 :message (format "All validations passed - ready to advance to '%s'" on-pass)))

          (:fail
           (if on-fail
               (list :can-upgrade t
                     :action 'regress
                     :target-status on-fail
                     :state :fail
                     :results results-list
                     :message (format "Validations failed - ready to regress to '%s'" on-fail))
             (list :can-upgrade nil
                   :state :fail
                   :results results-list
                   :message "Validations failed but no :on-fail configured")))

          (:pending
           (list :can-upgrade nil
                 :state :pending
                 :results results-list
                 :message "Validations still pending - waiting for completion"))

          (:feedback
           (list :can-upgrade nil
                 :state :feedback
                 :results results-list
                 :message "User feedback required before proceeding")))))))

(defun org-roam-todo-wf-apply-auto-upgrade (todo-file)
  "Apply auto-upgrade to TODO at TODO-FILE if possible.
Returns result plist from check, with :applied t/nil added."
  (let ((check-result (org-roam-todo-wf-check-auto-upgrade todo-file)))
    (if (plist-get check-result :can-upgrade)
        (let* ((action (plist-get check-result :action))
               (target-status (plist-get check-result :target-status))
               (current-status (org-roam-todo-get-file-property todo-file "STATUS"))
               (todo (list :file todo-file :status current-status)))
          (condition-case err
              (progn
                (org-roam-todo-wf--change-status todo target-status 'ai)
                (plist-put check-result :applied t)
                (plist-put check-result :message
                          (format "Auto-upgraded: %s -> %s (%s)"
                                  current-status target-status
                                  (if (eq action 'advance) "advanced" "regressed")))
                check-result)
            (error
             (plist-put check-result :applied nil)
             (plist-put check-result :error (error-message-string err))
             check-result)))
      ;; Can't upgrade
      (plist-put check-result :applied nil)
      check-result)))

;;; ============================================================
;;; Workflow Resolution
;;; ============================================================

(defun org-roam-todo-wf--resolve-workflow (todo)
  "Resolve which workflow applies to TODO.
Resolution order:
1. TODO's own :workflow property
2. Parent TODO's workflow (if :parent-todo is set)
3. Project configuration from `org-roam-todo-project-workflows'
4. Default from `org-roam-todo-default-workflow'"
  (let ((workflow-name
         (or
          ;; 1. Explicit workflow on this TODO
          (plist-get todo :workflow)
          ;; 2. Parent TODO's workflow
          (org-roam-todo-wf--get-parent-workflow todo)
          ;; 3. Project configuration
          (org-roam-todo-wf--get-project-workflow
           (plist-get todo :project-name))
          ;; 4. Default
          org-roam-todo-default-workflow)))
    (or (gethash workflow-name org-roam-todo-wf--registry)
        (error "Unknown workflow: %s" workflow-name))))

(defun org-roam-todo-wf--get-parent-workflow (todo)
  "Get workflow from parent TODO if :parent-todo is set.
Returns the workflow symbol or nil."
  (when-let ((parent-file (plist-get todo :parent-todo)))
    (when (file-exists-p parent-file)
      (with-temp-buffer
        (insert-file-contents parent-file nil 0 2000)
        (goto-char (point-min))
        (when (re-search-forward "^:WORKFLOW:\\s-*\\(.+\\)$" nil t)
          (intern (string-trim (match-string 1))))))))

(defun org-roam-todo-wf--get-project-workflow (project-name)
  "Get workflow symbol for PROJECT-NAME.
Checks `org-roam-todo-project-workflows' first, then falls back to
`:merge-workflow' in `org-roam-todo-project-config'."
  (or (alist-get project-name org-roam-todo-project-workflows nil nil #'string=)
      (org-roam-todo-project-config-get project-name :merge-workflow)))

;;; ============================================================
;;; File Operations
;;; ============================================================

(defun org-roam-todo-wf--set-status-in-file (file new-status)
  "Update STATUS property to NEW-STATUS in FILE."
  (with-current-buffer (find-file-noselect file)
    (save-excursion
      (goto-char (point-min))
      (when (re-search-forward "^:STATUS:.*$" nil t)
        (replace-match (format ":STATUS: %s" new-status))))
    (save-buffer)))

(defun org-roam-todo-wf--get-workflow (todo)
  "Get the workflow struct for TODO."
  (org-roam-todo-wf--resolve-workflow todo))

(defun org-roam-todo-wf--get-todo (_id)
  "Get TODO plist by _ID.
This is a stub - the real implementation will query org-roam."
  ;; TODO: Implement actual TODO retrieval
  nil)

;;; ============================================================
;;; Actor-Based Permission Checks
;;; ============================================================

(defun org-roam-todo-wf--only-human (event)
  "Validation hook that blocks AI agents.
Use in :validate-STATUS hooks for transitions that require human judgment.
Reads the actor from EVENT (set by `org-roam-todo-wf--change-status').

Example uses:
- Approving code review (human must review before merging)
- Signing off on releases
- Security-sensitive status changes

When an AI agent attempts this transition, signals a user-error with
a clear message indicating human action is required."
  (when (eq (org-roam-todo-event-actor event) 'ai)
    (let ((new-status (org-roam-todo-event-new-status event)))
      (user-error "This transition to '%s' requires human action.

AI agents cannot perform this transition - it requires human judgment.

WHAT THIS MEANS:
This status change is restricted to humans for safety reasons, such as:
- Approving code review before merge
- Signing off on releases
- Security-sensitive operations

WHAT TO DO:
1. Wait for a human to perform this action:
   - Use the org-roam-todo status buffer and press 'a' to advance
   - Or use M-x org-roam-todo-advance

2. If you (the agent) believe this is ready:
   - Notify the user that review is needed
   - MCP: mcp__emacs__request_attention with message explaining the situation"
                    new-status))))


(provide 'org-roam-todo-wf)
;;; org-roam-todo-wf.el ends here
