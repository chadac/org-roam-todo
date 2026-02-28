;;; org-roam-todo-status.el --- Magit-style TODO status buffer -*- lexical-binding: t; -*-

;; Author: Claude Code
;; Version: 0.1.0
;; Package-Requires: ((emacs "28.1") (org-roam "2.0") (magit-section "3.0"))

;;; Commentary:
;; Provides a magit-style buffer for viewing and managing a single TODO's status.
;; Shows current workflow status, validation checks for the next status, and
;; quick actions for advancing/regressing the TODO.
;;
;; Bound to C-x j globally.

;;; Code:

(require 'cl-lib)
(require 'magit-section)
(require 'transient)
(require 'org-roam-todo-theme)
(require 'org-roam-todo-core)
;; Forward declarations for workflow module
(declare-function org-roam-todo-wf--get-workflow "org-roam-todo-wf")
(declare-function org-roam-todo-wf--change-status "org-roam-todo-wf")
(declare-function org-roam-todo-wf--next-statuses "org-roam-todo-wf")
(declare-function org-roam-todo-workflow-statuses "org-roam-todo-wf")
(declare-function org-roam-todo-workflow-hooks "org-roam-todo-wf")
(declare-function org-roam-todo-workflow-config "org-roam-todo-wf")
(declare-function org-roam-todo-workflow-name "org-roam-todo-wf")
(declare-function make-org-roam-todo-event "org-roam-todo-wf")
(declare-function org-roam-todo-event-workflow "org-roam-todo-wf")

;; Forward declarations for list module
(declare-function org-roam-todo-list--get-entries "org-roam-todo-list")
(declare-function org-roam-todo-list--get-agent-status "org-roam-todo-list")
(declare-function org-roam-todo-list-mode "org-roam-todo-list")
(declare-function org-roam-todo-list-refresh "org-roam-todo-list")
(defvar org-roam-todo-list--project-filter)
;; Forward declarations for wf-tools module
(declare-function org-roam-todo-wf-tools-start "org-roam-todo-wf-tools")
(declare-function org-roam-todo-wf-tools-delegate "org-roam-todo-wf-tools")
;; Forward declarations for PR feedback module
(declare-function org-roam-todo-wf-pr-feedback-fetch "org-roam-todo-wf-pr-feedback")
(declare-function org-roam-todo-wf-pr-feedback-summary "org-roam-todo-wf-pr-feedback")
(declare-function org-roam-todo-wf-pr-feedback-invalidate-cache "org-roam-todo-wf-pr-feedback")
(declare-function org-roam-todo-wf-pr-feedback-view-full-log "org-roam-todo-wf-pr-feedback")

;;; ============================================================
;;; Customization
;;; ============================================================

(defgroup org-roam-todo-status nil
  "Magit-style TODO status buffer."
  :group 'org-roam-todo)

(defface org-roam-todo-status-validation-pass
  '((((class color) (background dark)) :foreground "#98c379")
    (((class color) (background light)) :foreground "#28a428")
    (t :inherit success))
  "Face for passing validation checks."
  :group 'org-roam-todo-status)

(defface org-roam-todo-status-validation-fail
  '((((class color) (background dark)) :foreground "#e06c75")
    (((class color) (background light)) :foreground "#cc0000")
    (t :inherit error))
  "Face for failing validation checks."
  :group 'org-roam-todo-status)

(defface org-roam-todo-status-validation-pending
  '((((class color) (background dark)) :foreground "#61afef")
    (((class color) (background light)) :foreground "#0070cc")
    (t :inherit warning))
  "Face for pending/async validation checks."
  :group 'org-roam-todo-status)

(defface org-roam-todo-status-validation-feedback
  '((((class color) (background dark)) :foreground "#e5c07b")
    (((class color) (background light)) :foreground "#b08000")
    (t :inherit warning))
  "Face for validation checks requiring user feedback."
  :group 'org-roam-todo-status)

(defface org-roam-todo-status-header-key
  '((t :inherit font-lock-keyword-face))
  "Face for header labels."
  :group 'org-roam-todo-status)

(defface org-roam-todo-status-header-value
  '((t :inherit default))
  "Face for header values."
  :group 'org-roam-todo-status)

(defface org-roam-todo-status-action-key
  '((((class color) (background dark)) :foreground "LightSalmon3" :weight bold)
    (((class color) (background light)) :foreground "salmon4" :weight bold)
    (t :inherit transient-key))
  "Face for action keybindings (magit-style reddish)."
  :group 'org-roam-todo-status)



(defface org-roam-todo-status-section-heading
  '((((class color) (background dark)) :foreground "LightGoldenrod2" :weight bold)
    (((class color) (background light)) :foreground "DarkGoldenrod4" :weight bold)
    (t :inherit magit-section-heading))
  "Face for section headings (magit-style golden/blue)."
  :group 'org-roam-todo-status)

(defface org-roam-todo-status-worktree-active
  '((((class color) (background dark)) :foreground "#98c379")
    (((class color) (background light)) :foreground "#28a428"))
  "Face for active worktree indicator."
  :group 'org-roam-todo-status)

(defface org-roam-todo-status-worktree-missing
  '((((class color) (background dark)) :foreground "#e06c75")
    (((class color) (background light)) :foreground "#cc0000"))
  "Face for missing worktree indicator."
  :group 'org-roam-todo-status)

(defface org-roam-todo-status-agent-ready
  '((((class color) (background dark)) :foreground "#98c379")
    (((class color) (background light)) :foreground "#28a428"))
  "Face for ready agent status."
  :group 'org-roam-todo-status)

(defface org-roam-todo-status-agent-thinking
  '((((class color) (background dark)) :foreground "#61afef")
    (((class color) (background light)) :foreground "#0070cc"))
  "Face for thinking agent status."
  :group 'org-roam-todo-status)

(defface org-roam-todo-status-agent-waiting
  '((((class color) (background dark)) :foreground "#e5c07b")
    (((class color) (background light)) :foreground "#b08000"))
  "Face for waiting agent status."
  :group 'org-roam-todo-status)

;;; ============================================================
;;; PR Feedback Faces
;;; ============================================================

(defface org-roam-todo-status-ci-success
  '((((class color) (background dark)) :foreground "#98c379")
    (((class color) (background light)) :foreground "#28a428"))
  "Face for successful CI checks."
  :group 'org-roam-todo-status)

(defface org-roam-todo-status-ci-failure
  '((((class color) (background dark)) :foreground "#e06c75")
    (((class color) (background light)) :foreground "#cc0000"))
  "Face for failed CI checks."
  :group 'org-roam-todo-status)

(defface org-roam-todo-status-ci-pending
  '((((class color) (background dark)) :foreground "#61afef")
    (((class color) (background light)) :foreground "#0070cc"))
  "Face for pending CI checks."
  :group 'org-roam-todo-status)

(defface org-roam-todo-status-review-approved
  '((((class color) (background dark)) :foreground "#98c379")
    (((class color) (background light)) :foreground "#28a428"))
  "Face for approved reviews."
  :group 'org-roam-todo-status)

(defface org-roam-todo-status-review-changes-requested
  '((((class color) (background dark)) :foreground "#e06c75")
    (((class color) (background light)) :foreground "#cc0000"))
  "Face for reviews requesting changes."
  :group 'org-roam-todo-status)

(defface org-roam-todo-status-comment-unresolved
  '((((class color) (background dark)) :foreground "#e5c07b")
    (((class color) (background light)) :foreground "#b08000"))
  "Face for unresolved comments."
  :group 'org-roam-todo-status)

(defface org-roam-todo-status-comment-resolved
  '((((class color) (background dark)) :foreground "#5c6370")
    (((class color) (background light)) :foreground "#909090"))
  "Face for resolved comments."
  :group 'org-roam-todo-status)

(defface org-roam-todo-status-log-tail
  '((((class color) (background dark)) :foreground "#abb2bf" :background "#282c34")
    (((class color) (background light)) :foreground "#383a42" :background "#f0f0f0"))
  "Face for CI log tail display."
  :group 'org-roam-todo-status)

;;; ============================================================
;;; Hook Name Registry
;;; ============================================================

(defconst org-roam-todo-status--hook-info
  '((org-roam-todo-wf--require-clean-worktree
     :name "Clean worktree"
     :target :magit)
    (org-roam-todo-wf--require-staged-changes
     :name "Staged changes"
     :target :magit)
    (org-roam-todo-wf--require-branch-has-commits
     :name "Branch has commits"
     :target :magit-log)
    (org-roam-todo-wf--require-rebase-clean
     :name "Rebase clean"
     :target :magit)
    (org-roam-todo-wf--require-pre-commit-pass
     :name "Pre-commit hook passes"
     :target :magit)
    (org-roam-todo-wf--require-target-clean
     :name "Target repo clean"
     :target :project-magit)
    (org-roam-todo-wf--require-ff-possible
     :name "Fast-forward possible"
     :target :magit-log)
    (org-roam-todo-wf--require-acceptance-complete
     :name "Acceptance criteria complete"
     :target :todo-acceptance)
    (org-roam-todo-wf-pr--require-ci-pass
     :name "CI checks pass"
     :target :pr-url)
    (org-roam-todo-wf--require-user-approval
     :name "User approval"
     :target nil)
    (org-roam-todo-wf-pr--require-pr-merged
     :name "PR merged"
     :target :pr-url)
    (org-roam-todo-wf--only-human
     :name "Human action required"
     :target nil)
)
  "Alist mapping validation hooks to their display info.
Each entry is (HOOK-FN :name NAME :target TARGET-TYPE).
TARGET-TYPE can be:
  :magit         - Open magit-status in worktree
  :magit-log     - Open magit-log in worktree
  :project-magit - Open magit-status in project root
  :todo-acceptance - Jump to Acceptance Criteria in TODO file
  :pr-url        - Open PR URL in browser
  nil            - No navigation target")

(defun org-roam-todo-status--hook-name (fn)
  "Get human-readable name for hook function FN."
  (or (plist-get (cdr (assq fn org-roam-todo-status--hook-info)) :name)
      (symbol-name fn)))

(defun org-roam-todo-status--hook-target (fn)
  "Get navigation target type for hook function FN."
  (plist-get (cdr (assq fn org-roam-todo-status--hook-info)) :target))

;;; ============================================================
;;; Buffer-local Variables
;;; ============================================================

(defvar-local org-roam-todo-status--todo nil
  "The TODO plist being displayed in this buffer.")

(defvar-local org-roam-todo-status--validation-results nil
  "Cached validation results for display.")

;;; ============================================================
;;; Section Classes
;;; ============================================================

(defclass org-roam-todo-status-root-section (magit-section)
  ((keymap :initform 'org-roam-todo-status-mode-map)))

(defclass org-roam-todo-status-header-section (magit-section)
  ())

(defclass org-roam-todo-status-validations-section (magit-section)
  ())

(defclass org-roam-todo-status-validation-section (magit-section)
  ((result :initform nil :initarg :result)))

;; PR Feedback section classes
(defclass org-roam-todo-status-pr-feedback-section (magit-section)
  ((feedback :initform nil :initarg :feedback)))

(defclass org-roam-todo-status-ci-section (magit-section)
  ((checks :initform nil :initarg :checks)))

(defclass org-roam-todo-status-ci-check-section (magit-section)
  ((check :initform nil :initarg :check)
   (worktree-path :initform nil :initarg :worktree-path)))

(defclass org-roam-todo-status-comments-section (magit-section)
  ((comments :initform nil :initarg :comments)))

(defclass org-roam-todo-status-comment-section (magit-section)
  ((comment :initform nil :initarg :comment)))

(defclass org-roam-todo-status-reviews-section (magit-section)
  ((reviews :initform nil :initarg :reviews)))

;;; ============================================================
;;; Validation Runner
;;; ============================================================

(defun org-roam-todo-status--run-validations (todo workflow next-status)
  "Run validation hooks for NEXT-STATUS and return results list.
TODO is the todo plist, WORKFLOW is the workflow struct.
Returns list of result plists with :hook, :status, :message, :name, :target.
Status can be: pass, pending, fail, feedback, or error."
  (let* ((hooks (org-roam-todo-workflow-hooks workflow))
         (validate-key (intern (format ":validate-%s" next-status)))
         (fns (cdr (assq validate-key hooks)))
         (event (make-org-roam-todo-event
                 :todo todo
                 :workflow workflow
                 :old-status (plist-get todo :status)
                 :new-status next-status
                 :actor 'human))
         (results '()))
    (dolist (fn fns)
      (let* ((raw-result (condition-case err
                             (funcall fn event)
                           (user-error (list :fail (cadr err)))
                           (error (list :error (error-message-string err)))))
             ;; Parse the result: nil/:pass, (:pending "msg"), (:fail "msg"), (:feedback "msg"), (:error "msg")
             (parsed (cond
                      ;; Structured result: (:status "message") or (:status "message" :other-data...)
                      ((and (listp raw-result) (keywordp (car raw-result)))
                       (let ((status (car raw-result))
                             (message (cadr raw-result)))
                         (cons (intern (substring (symbol-name status) 1)) message)))
                      ;; nil or :pass - validation passed
                      ((or (null raw-result) (eq raw-result :pass))
                       (cons 'pass nil))
                      ;; Unknown - treat as pass
                      (t (cons 'pass nil)))))
        (push (list :hook fn
                    :status (car parsed)
                    :message (cdr parsed)
                    :name (org-roam-todo-status--hook-name fn)
                    :target (org-roam-todo-status--hook-target fn))
              results)))
    (nreverse results)))

;;; ============================================================
;;; Buffer Rendering
;;; ============================================================

(defsubst org-roam-todo-status--face-props (face)
  "Return property list for FACE with both face and font-lock-face."
  (list 'face face 'font-lock-face face))

(defun org-roam-todo-status--propertize (str face)
  "Propertize STR with FACE for both face and font-lock-face properties."
  (propertize str 'face face 'font-lock-face face))

(defun org-roam-todo-status--insert-header-line (label value &optional face)
  "Insert a header line with LABEL and VALUE.
FACE is optional face for the value."
  (insert (org-roam-todo-status--propertize (format "%-12s" label)
                                             'org-roam-todo-status-header-key))
  (insert (org-roam-todo-status--propertize value
                                             (or face 'org-roam-todo-status-header-value)))
  (insert "\n"))

(defun org-roam-todo-status--get-worktree-status (todo)
  "Get worktree status for TODO.
Returns (indicator . face) cons."
  (let* ((worktree-path (plist-get todo :worktree-path))
         (status (plist-get todo :status))
         (has-worktree (and worktree-path (file-directory-p worktree-path)))
         (should-have-wt (and (not (string= status "draft"))
                              (not (string= status "done"))
                              (not (string= status "rejected")))))
    (cond
     (has-worktree (cons "✓ Active" 'org-roam-todo-status-worktree-active))
     (should-have-wt (cons "✗ Missing" 'org-roam-todo-status-worktree-missing))
     (t (cons "—" 'font-lock-comment-face)))))

(defface org-roam-todo-status-agent-needs-input
  '((((class color) (background dark)) :foreground "#e5c07b" :weight bold)
    (((class color) (background light)) :foreground "#b08000" :weight bold))
  "Face for agent needing user input status."
  :group 'org-roam-todo-status)

(defun org-roam-todo-status--get-agent-status (todo)
  "Get agent status for TODO.
Returns (indicator . face) cons."
  (let* ((worktree-path (plist-get todo :worktree-path))
         (status (and worktree-path
                      (org-roam-todo-list--get-agent-status worktree-path))))
    (pcase status
      ('ready (cons "Ready" 'org-roam-todo-status-agent-ready))
      ('thinking (cons "Thinking" 'org-roam-todo-status-agent-thinking))
      ('waiting (cons "Waiting" 'org-roam-todo-status-agent-waiting))
      ('waiting-user (cons "Needs Input" 'org-roam-todo-status-agent-needs-input))
      (_ (cons "—" 'font-lock-comment-face)))))

(defun org-roam-todo-status--insert-header (todo workflow)
  "Insert header section for TODO with WORKFLOW."
  (let* ((title (plist-get todo :title))
         (project (plist-get todo :project-name))
         (status (plist-get todo :status))
         (statuses (org-roam-todo-workflow-statuses workflow))
         (current-idx (cl-position status statuses :test #'equal))
         (next-status (when (and current-idx (< current-idx (1- (length statuses))))
                        (nth (1+ current-idx) statuses)))
         (workflow-name (symbol-name (org-roam-todo-workflow-name workflow)))
         (wt-status (org-roam-todo-status--get-worktree-status todo))
         (agent-status (org-roam-todo-status--get-agent-status todo)))
    (magit-insert-section (org-roam-todo-status-header-section)
      ;; Title
      (insert (org-roam-todo-status--propertize title '(:weight bold :height 1.2)))
      (insert "\n\n")
      ;; Info grid
      (org-roam-todo-status--insert-header-line "Project:" (or project "—"))
      (org-roam-todo-status--insert-header-line "Workflow:" workflow-name)
      ;; Status with next indicator
      (insert (org-roam-todo-status--propertize (format "%-12s" "Status:")
                                                 'org-roam-todo-status-header-key))
      (insert (org-roam-todo-status--propertize status
                                                 (org-roam-todo-theme-status-face status)))
      (when next-status
        (insert " → ")
        (insert (org-roam-todo-status--propertize next-status
                                                   (org-roam-todo-theme-status-face next-status))))
      (insert "\n")
      ;; Worktree and Agent status
      (insert (org-roam-todo-status--propertize (format "%-12s" "Worktree:")
                                                 'org-roam-todo-status-header-key))
      (insert (org-roam-todo-status--propertize (car wt-status) (cdr wt-status)))
      (insert "    ")
      (insert (org-roam-todo-status--propertize "Agent: " 'org-roam-todo-status-header-key))
      (insert (org-roam-todo-status--propertize (car agent-status) (cdr agent-status)))
      (insert "\n"))))

(defun org-roam-todo-status--truncate-message (msg max-len)
  "Truncate MSG to MAX-LEN, adding ellipsis if needed.
Full message is stored in help-echo property."
  (if (and msg (> (length msg) max-len))
      (propertize (concat (substring msg 0 (- max-len 3)) "...")
                  'help-echo msg)
    msg))

(defun org-roam-todo-status--validation-display (res-status)
  "Return (indicator . face) for RES-STATUS.
RES-STATUS can be: pass, pending, fail, feedback, or error."
  (pcase res-status
    ('pass (cons "✓" 'org-roam-todo-status-validation-pass))
    ('pending (cons "⧗" 'org-roam-todo-status-validation-pending))
    ('feedback (cons "?" 'org-roam-todo-status-validation-feedback))
    ('fail (cons "✗" 'org-roam-todo-status-validation-fail))
    ('error (cons "!" 'org-roam-todo-status-validation-fail))
    (_ (cons "·" 'font-lock-comment-face))))

(defun org-roam-todo-status--insert-validations (todo workflow)
  "Insert validations section for TODO with WORKFLOW."
  (let* ((statuses (org-roam-todo-workflow-statuses workflow))
         (status (plist-get todo :status))
         (current-idx (cl-position status statuses :test #'equal))
         (next-status (when (and current-idx (< current-idx (1- (length statuses))))
                        (nth (1+ current-idx) statuses))))
    (when next-status
      (let ((results (org-roam-todo-status--run-validations todo workflow next-status)))
        (setq org-roam-todo-status--validation-results results)
        (magit-insert-section (org-roam-todo-status-validations-section nil t)
          (magit-insert-heading
            (org-roam-todo-status--propertize
             (format "Validations for '%s' (%d)" next-status (length results))
             'org-roam-todo-status-section-heading))
          (if (null results)
              (insert "  (no validations required)\n")
            (dolist (result results)
              (let* ((res-status (plist-get result :status))
                     (name (plist-get result :name))
                     (message (plist-get result :message))
                     (display (org-roam-todo-status--validation-display res-status))
                     (indicator (car display))
                     (face (cdr display)))
                (magit-insert-section section (org-roam-todo-status-validation-section)
                  (oset section result result)
                  (insert "  ")
                  (insert (org-roam-todo-status--propertize indicator face))
                  (insert " ")
                  (insert (org-roam-todo-status--propertize name face))
                  (insert "\n")
                  ;; Show message indented if present (for non-pass states)
                  (when (and message (not (eq res-status 'pass)))
                    (insert "    ")
                    (insert (org-roam-todo-status--propertize
                             (org-roam-todo-status--truncate-message message 60)
                             'font-lock-comment-face))
                    (insert "\n")))))))))))

;;; ============================================================
;;; PR Feedback Rendering
;;; ============================================================

(defun org-roam-todo-status--ci-status-display (status)
  "Return (indicator . face) for CI STATUS symbol."
  (pcase status
    ('success (cons "✓" 'org-roam-todo-status-ci-success))
    ('failure (cons "✗" 'org-roam-todo-status-ci-failure))
    ('pending (cons "⧗" 'org-roam-todo-status-ci-pending))
    ('cancelled (cons "⊘" 'font-lock-comment-face))
    ('skipped (cons "−" 'font-lock-comment-face))
    (_ (cons "?" 'font-lock-comment-face))))

(defun org-roam-todo-status--insert-ci-check (check worktree-path)
  "Insert a single CI CHECK item with WORKTREE-PATH for log viewing."
  (let* ((name (plist-get check :name))
         (status (plist-get check :status))
         (log-tail (plist-get check :log-tail))
         (display (org-roam-todo-status--ci-status-display status))
         (indicator (car display))
         (face (cdr display)))
    (magit-insert-section section (org-roam-todo-status-ci-check-section nil (eq status 'failure))
      (oset section check check)
      (oset section worktree-path worktree-path)
      (insert "  ")
      (insert (org-roam-todo-status--propertize indicator face))
      (insert " ")
      (insert (org-roam-todo-status--propertize (or name "Unknown") face))
      (insert "\n")
      ;; Show log tail for failures (collapsed by default, expandable)
      (when (and log-tail (eq status 'failure))
        (magit-insert-heading)
        (insert (org-roam-todo-status--propertize
                 "    Log tail (press TAB to expand, L for full log):\n"
                 'font-lock-comment-face))
        (let ((lines (split-string log-tail "\n" t)))
          (dolist (line (seq-take lines 10))
            (insert "    ")
            (insert (org-roam-todo-status--propertize
                     (truncate-string-to-width line 70 nil nil "…")
                     'org-roam-todo-status-log-tail))
            (insert "\n"))
          (when (> (length lines) 10)
            (insert (org-roam-todo-status--propertize
                     (format "    ... and %d more lines\n" (- (length lines) 10))
                     'font-lock-comment-face))))))))

(defun org-roam-todo-status--insert-ci-section (feedback worktree-path)
  "Insert CI checks section from FEEDBACK with WORKTREE-PATH."
  (let* ((ci-checks (plist-get feedback :ci-checks))
         (summary (org-roam-todo-wf-pr-feedback-summary feedback))
         (failed (plist-get summary :ci-failed-count))
         (pending (plist-get summary :ci-pending-count))
         (success (plist-get summary :ci-success-count))
         (total (plist-get summary :ci-total-count)))
    (when (and ci-checks (> total 0))
      (magit-insert-section section (org-roam-todo-status-ci-section nil t)
        (oset section checks ci-checks)
        (magit-insert-heading
          (org-roam-todo-status--propertize "CI Checks " 'org-roam-todo-status-section-heading)
          (cond
           ((> failed 0)
            (org-roam-todo-status--propertize
             (format "(%d/%d failed)" failed total)
             'org-roam-todo-status-ci-failure))
           ((> pending 0)
            (org-roam-todo-status--propertize
             (format "(%d/%d pending)" pending total)
             'org-roam-todo-status-ci-pending))
           (t
            (org-roam-todo-status--propertize
             (format "(%d passed)" success)
             'org-roam-todo-status-ci-success))))
        ;; Show failed checks first, then pending, then success
        (let ((sorted-checks (sort (copy-sequence ci-checks)
                                   (lambda (a b)
                                     (let ((sa (plist-get a :status))
                                           (sb (plist-get b :status)))
                                       (< (pcase sa ('failure 0) ('pending 1) (_ 2))
                                          (pcase sb ('failure 0) ('pending 1) (_ 2))))))))
          (dolist (check sorted-checks)
            (org-roam-todo-status--insert-ci-check check worktree-path)))))))

(defface org-roam-todo-status-comment-author
  '((((class color) (background dark)) :foreground "#c678dd" :weight bold)
    (((class color) (background light)) :foreground "#a626a4" :weight bold))
  "Face for comment authors."
  :group 'org-roam-todo-status)

(defface org-roam-todo-status-comment-body
  '((((class color) (background dark)) :foreground "#abb2bf")
    (((class color) (background light)) :foreground "#383a42"))
  "Face for comment body text."
  :group 'org-roam-todo-status)

(defface org-roam-todo-status-comment-code
  '((((class color) (background dark)) :foreground "#98c379" :background "#2c323c")
    (((class color) (background light)) :foreground "#50a14f" :background "#f0f0f0"))
  "Face for inline code in comments."
  :group 'org-roam-todo-status)

(defun org-roam-todo-status--render-markdown-line (text)
  "Render basic markdown formatting in TEXT.
Handles inline code (`code`), bold (**bold**), and italic (*italic*)."
  (let ((result text))
    ;; Inline code: `code`
    (setq result
          (replace-regexp-in-string
           "`\\([^`]+\\)`"
           (lambda (match)
             (org-roam-todo-status--propertize
              (match-string 1 match)
              'org-roam-todo-status-comment-code))
           result t t))
    ;; Bold: **text** or __text__
    (setq result
          (replace-regexp-in-string
           "\\*\\*\\([^*]+\\)\\*\\*\\|__\\([^_]+\\)__"
           (lambda (match)
             (let ((content (or (match-string 1 match) (match-string 2 match))))
               (org-roam-todo-status--propertize content '(:weight bold))))
           result t t))
    ;; Italic: *text* or _text_ (but not inside words)
    (setq result
          (replace-regexp-in-string
           "\\(?:^\\|[^*_]\\)\\([*_]\\)\\([^*_\n]+\\)\\1\\(?:[^*_]\\|$\\)"
           (lambda (match)
             (org-roam-todo-status--propertize
              (match-string 2 match)
              '(:slant italic)))
           result t t))
    result))

(defface org-roam-todo-status-diff-hunk
  '((((class color) (background dark)) :foreground "#7c8490" :background "#2c323c" :extend t)
    (((class color) (background light)) :foreground "#606060" :background "#e8e8e8" :extend t))
  "Face for diff hunk context in comments."
  :group 'org-roam-todo-status)

(defface org-roam-todo-status-diff-add
  '((((class color) (background dark)) :foreground "#b5e890" :background "#1e3a1e" :extend t)
    (((class color) (background light)) :foreground "#1a6b1a" :background "#d4ffd4" :extend t))
  "Face for added lines in diff hunks."
  :group 'org-roam-todo-status)

(defface org-roam-todo-status-diff-remove
  '((((class color) (background dark)) :foreground "#f08080" :background "#4a2020" :extend t)
    (((class color) (background light)) :foreground "#a00000" :background "#ffd4d4" :extend t))
  "Face for removed lines in diff hunks."
  :group 'org-roam-todo-status)

(defun org-roam-todo-status--render-diff-line (line)
  "Render a single diff LINE with appropriate face."
  (cond
   ((string-prefix-p "+" line)
    (org-roam-todo-status--propertize line 'org-roam-todo-status-diff-add))
   ((string-prefix-p "-" line)
    (org-roam-todo-status--propertize line 'org-roam-todo-status-diff-remove))
   ((string-prefix-p "@@" line)
    (org-roam-todo-status--propertize line 'font-lock-keyword-face))
   (t
    (org-roam-todo-status--propertize line 'org-roam-todo-status-diff-hunk))))

(defun org-roam-todo-status--insert-comment (comment)
  "Insert a single COMMENT item with markdown rendering.
Comments are displayed expanded by default showing full body.
If the comment has a diff-hunk, shows the code context."
  (let* ((author (plist-get comment :author))
         (body (plist-get comment :body))
         (path (plist-get comment :path))
         (line (plist-get comment :line))
         (diff-hunk (plist-get comment :diff-hunk))
         (state (plist-get comment :state))
         (created-at (plist-get comment :created-at))
         (face (if (eq state 'resolved)
                   'org-roam-todo-status-comment-resolved
                 'org-roam-todo-status-comment-unresolved))
         (indicator (if (eq state 'resolved) "✓" "○")))
    (magit-insert-section section (org-roam-todo-status-comment-section nil nil)
      (oset section comment comment)
      ;; Header line: indicator + author + location
      (insert "  ")
      (insert (org-roam-todo-status--propertize indicator face))
      (insert " ")
      (insert (org-roam-todo-status--propertize (format "@%s" (or author "unknown"))
                                                'org-roam-todo-status-comment-author))
      (when path
        (insert " ")
        (insert (org-roam-todo-status--propertize "on " 'font-lock-comment-face))
        (insert (org-roam-todo-status--propertize
                 (file-name-nondirectory path)
                 'font-lock-string-face))
        (when line
          (insert (org-roam-todo-status--propertize (format ":%d" line) 'font-lock-string-face))))
      (insert "\n")
      ;; Show diff hunk if available (for inline code comments)
      (when diff-hunk
        (let* ((diff-lines (split-string diff-hunk "\n"))
               (display-lines (seq-take (last diff-lines 8) 8))
               (box-width 72))  ; Fixed width for the code box
          ;; Show last few lines of context (most relevant to the comment)
          (dolist (diff-line display-lines)
            (when (and diff-line (not (string-empty-p diff-line)))
              (insert "      ")
              ;; Pad line to fixed width so background extends uniformly
              (let* ((truncated (truncate-string-to-width diff-line (- box-width 2) nil nil "…"))
                     (padded (concat truncated
                                     (make-string (max 0 (- box-width (length truncated))) ?\s))))
                (insert (org-roam-todo-status--render-diff-line padded)))
              (insert "\n")))))
      ;; Comment body with markdown rendering
      (when body
        (let ((lines (split-string body "\n" t "[ \t]+")))
          (dolist (raw-line lines)
            (let ((rendered-line (org-roam-todo-status--render-markdown-line raw-line)))
              (insert "      ")
              (insert rendered-line)
              (insert "\n"))))))))

(defun org-roam-todo-status--insert-comments-section (feedback)
  "Insert comments/reviews section from FEEDBACK.
This includes:
- Review comments (inline code comments)
- PR comments (top-level conversation)
- Review bodies (the actual review feedback text)"
  (let* ((review-comments (or (plist-get feedback :review-comments)
                              (plist-get feedback :discussions)))
         (comments (plist-get feedback :comments))
         (reviews (plist-get feedback :reviews))
         ;; Extract reviews that have body content (the actual review feedback)
         (review-bodies (cl-remove-if-not
                         (lambda (r)
                           (let ((body (plist-get r :body)))
                             (and body (not (string-empty-p body)))))
                         reviews))
         ;; Convert review bodies to comment format for display
         (review-as-comments (mapcar
                              (lambda (r)
                                (list :author (plist-get r :author)
                                      :body (plist-get r :body)
                                      :state (plist-get r :state)
                                      :created-at (plist-get r :submitted-at)))
                              review-bodies))
         (summary (org-roam-todo-wf-pr-feedback-summary feedback))
         (unresolved (plist-get summary :unresolved-count))
         (all-comments (append review-comments comments review-as-comments))
         (total-comments (length all-comments)))
    (when (> total-comments 0)
      (magit-insert-section section (org-roam-todo-status-comments-section nil t)
        (oset section comments all-comments)
        (magit-insert-heading
          (org-roam-todo-status--propertize "Comments " 'org-roam-todo-status-section-heading)
          (if (> unresolved 0)
              (org-roam-todo-status--propertize
               (format "(%d unresolved)" unresolved)
               'org-roam-todo-status-comment-unresolved)
            (org-roam-todo-status--propertize
             (format "(%d)" total-comments)
             'font-lock-comment-face)))
        ;; Show unresolved review comments first
        (dolist (comment review-comments)
          (when (eq (plist-get comment :state) 'unresolved)
            (org-roam-todo-status--insert-comment comment)))
        ;; Then review bodies (most recent first, limit to 5)
        (dolist (comment (seq-take (reverse review-as-comments) 5))
          (org-roam-todo-status--insert-comment comment))
        ;; Then regular comments (most recent first, limit to 5)
        (dolist (comment (seq-take (reverse comments) 5))
          (org-roam-todo-status--insert-comment comment))))))

(defun org-roam-todo-status--insert-reviews-section (feedback)
  "Insert review status section from FEEDBACK."
  (let* ((reviews (plist-get feedback :reviews))
         (summary (org-roam-todo-wf-pr-feedback-summary feedback))
         (review-state (plist-get summary :review-state)))
    (when (and reviews (> (length reviews) 0))
      (magit-insert-section section (org-roam-todo-status-reviews-section nil t)
        (oset section reviews reviews)
        (magit-insert-heading
          (org-roam-todo-status--propertize "Reviews " 'org-roam-todo-status-section-heading)
          (pcase review-state
            (:approved
             (org-roam-todo-status--propertize "Approved" 'org-roam-todo-status-review-approved))
            (:changes-requested
             (org-roam-todo-status--propertize "Changes Requested" 'org-roam-todo-status-review-changes-requested))
            (:reviewed
             (org-roam-todo-status--propertize "Reviewed" 'font-lock-comment-face))
            (_ (org-roam-todo-status--propertize "Pending" 'font-lock-comment-face))))
        ;; Show individual reviews
        (dolist (review reviews)
          (let* ((author (plist-get review :author))
                 (state (plist-get review :state))
                 (face (pcase state
                         ('approved 'org-roam-todo-status-review-approved)
                         ('changes_requested 'org-roam-todo-status-review-changes-requested)
                         (_ 'font-lock-comment-face)))
                 (indicator (pcase state
                              ('approved "✓")
                              ('changes_requested "✗")
                              ('commented "💬")
                              (_ "○"))))
            (insert "  ")
            (insert (org-roam-todo-status--propertize indicator face))
            (insert " ")
            (insert (org-roam-todo-status--propertize (or author "unknown") 'font-lock-keyword-face))
            (insert " - ")
            (insert (org-roam-todo-status--propertize
                     (symbol-name (or state 'pending))
                     face))
            (insert "\n")))))))

(defun org-roam-todo-status--insert-pr-feedback (todo)
  "Insert PR feedback section for TODO if applicable."
  (let* ((worktree-path (plist-get todo :worktree-path))
         (status (plist-get todo :status)))
    ;; Only show PR feedback in review status or when worktree exists
    (when (and worktree-path
               (file-directory-p worktree-path)
               (member status '("review" "active")))
      (condition-case err
          (progn
            (require 'org-roam-todo-wf-pr-feedback)
            (let ((feedback (org-roam-todo-wf-pr-feedback-fetch worktree-path)))
              (when feedback
                (magit-insert-section section (org-roam-todo-status-pr-feedback-section nil t)
                  (oset section feedback feedback)
                  (insert "\n")
                  ;; PR URL header
                  (let ((pr-url (plist-get feedback :pr-url))
                        (pr-number (plist-get feedback :pr-number))
                        (forge (plist-get feedback :forge)))
                    (when pr-number
                      (insert (org-roam-todo-status--propertize
                               (format "%s #%d"
                                       (if (eq forge :gitlab) "MR" "PR")
                                       pr-number)
                               '(:weight bold)))
                      (when pr-url
                        (insert " ")
                        (insert-text-button
                         "[open]"
                         'action (lambda (_) (browse-url pr-url))
                         'help-echo pr-url))
                      (insert "\n\n")))
                  ;; Insert subsections
                  (org-roam-todo-status--insert-ci-section feedback worktree-path)
                  (org-roam-todo-status--insert-reviews-section feedback)
                  (org-roam-todo-status--insert-comments-section feedback)))))
        (error
         (insert (org-roam-todo-status--propertize
                  (format "  (PR feedback unavailable: %s)\n" (error-message-string err))
                  'font-lock-comment-face)))))))

(defun org-roam-todo-status--has-user-approval-validation-p (todo)
  "Return non-nil if the next status for TODO requires user approval.
This checks if the validation hooks for the next status include
`org-roam-todo-wf--require-user-approval'."
  (let* ((workflow (org-roam-todo-wf--get-workflow todo))
         (statuses (org-roam-todo-workflow-statuses workflow))
         (status (plist-get todo :status))
         (current-idx (cl-position status statuses :test #'equal))
         (next-status (when (and current-idx (< current-idx (1- (length statuses))))
                        (nth (1+ current-idx) statuses))))
    (when next-status
      (let* ((hooks (org-roam-todo-workflow-hooks workflow))
             (validate-key (intern (format ":validate-%s" next-status)))
             (fns (cdr (assq validate-key hooks))))
        ;; Handle both old format (list of symbols) and new format (list of (priority . function) cons cells)
        (cl-find 'org-roam-todo-wf--require-user-approval fns
                 :key (lambda (entry)
                        (if (consp entry) (cdr entry) entry)))))))

(defun org-roam-todo-status--needs-review-p (todo)
  "Return non-nil if TODO needs user review.
This checks if the next status has user approval validation AND
the user hasn't already approved (APPROVED property is not set)."
  (and (org-roam-todo-status--has-user-approval-validation-p todo)
       (not (plist-get todo :approved))))

(defun org-roam-todo-status--insert-review-notice (todo)
  "Insert review notice section if TODO needs user review."
  (when (org-roam-todo-status--needs-review-p todo)
    (insert "\n")
    (insert (org-roam-todo-status--propertize "⚠ Awaiting Review" 
                                               '(:foreground "gold" :weight bold)))
    (insert "\n")
    (insert (org-roam-todo-status--propertize 
             "  This PR is ready for your review before requesting external review.\n"
             'font-lock-comment-face))
    (insert "  ")
    (insert (org-roam-todo-status--propertize "v a" 'org-roam-todo-status-action-key))
    (insert " ")
    (insert (org-roam-todo-status--propertize "Approve" 'font-lock-comment-face))
    (insert "  ")
    (insert (org-roam-todo-status--propertize "v r" 'org-roam-todo-status-action-key))
    (insert " ")
    (insert (org-roam-todo-status--propertize "Reject" 'font-lock-comment-face))
    (insert "\n")))

(defun org-roam-todo-status--get-agent-waiting-reason (todo)
  "Get the reason the agent is waiting for user input, if any.
Returns nil if agent is not waiting for user."
  (let* ((worktree-path (plist-get todo :worktree-path)))
    (when worktree-path
      (require 'org-roam-todo-wf-tools nil t)
      (when (fboundp 'org-roam-todo-wf-tools--get-agent-waiting-state)
        (let ((waiting-state (org-roam-todo-wf-tools--get-agent-waiting-state worktree-path)))
          (plist-get waiting-state :reason))))))

(defun org-roam-todo-status--insert-agent-waiting-notice (todo)
  "Insert notice if agent is waiting for user input."
  (when-let ((reason (org-roam-todo-status--get-agent-waiting-reason todo)))
    (insert "\n")
    (insert (org-roam-todo-status--propertize "⚠ Agent Needs Your Input" 
                                               '(:foreground "#e5c07b" :weight bold)))
    (insert "\n")
    (insert (org-roam-todo-status--propertize 
             (format "  %s\n" reason)
             'font-lock-comment-face))
    (insert "  ")
    (insert (org-roam-todo-status--propertize "Switch to agent buffer to respond"
                                               'font-lock-comment-face))
    (insert "\n")))

(defun org-roam-todo-status--insert-sections ()
  "Insert all sections into the buffer."
  (let* ((todo org-roam-todo-status--todo)
         (workflow (org-roam-todo-wf--get-workflow todo)))
    (magit-insert-section (org-roam-todo-status-root-section)
      (org-roam-todo-status--insert-header todo workflow)
      (insert "\n")
      (org-roam-todo-status--insert-validations todo workflow)
      ;; Show PR feedback section (CI checks, reviews, comments)
      (org-roam-todo-status--insert-pr-feedback todo)
      ;; Show agent waiting notice if applicable
      (org-roam-todo-status--insert-agent-waiting-notice todo)
      ;; Show review notice if applicable
      (org-roam-todo-status--insert-review-notice todo)
      (insert "\n")
      ;; Hint line
      (insert (org-roam-todo-status--propertize "RET" 'org-roam-todo-status-action-key))
      (insert " ")
      (insert (org-roam-todo-status--propertize "Visit" 'font-lock-comment-face))
      (insert "  ")
      (insert (org-roam-todo-status--propertize "?" 'org-roam-todo-status-action-key))
      (insert " ")
      (insert (org-roam-todo-status--propertize "Commands" 'font-lock-comment-face))
      (insert "  ")
      (insert (org-roam-todo-status--propertize "g" 'org-roam-todo-status-action-key))
      (insert " ")
      (insert (org-roam-todo-status--propertize "Refresh" 'font-lock-comment-face))
      (insert "  ")
      (insert (org-roam-todo-status--propertize "q" 'org-roam-todo-status-action-key))
      (insert " ")
      (insert (org-roam-todo-status--propertize "Quit" 'font-lock-comment-face))
      (insert "\n"))))

;;; ============================================================
;;; Commands
;;; ============================================================

(defun org-roam-todo-status-refresh (&optional force-refresh)
  "Refresh the TODO status buffer.
With FORCE-REFRESH (prefix arg), also invalidate PR feedback cache."
  (interactive "P")
  (when (derived-mode-p 'org-roam-todo-status-mode)
    ;; Invalidate PR feedback cache if force refresh
    (when (and force-refresh org-roam-todo-status--todo)
      (when-let ((worktree-path (plist-get org-roam-todo-status--todo :worktree-path)))
        (require 'org-roam-todo-wf-pr-feedback nil t)
        (when (fboundp 'org-roam-todo-wf-pr-feedback-invalidate-cache)
          (org-roam-todo-wf-pr-feedback-invalidate-cache worktree-path))))
    ;; Re-read TODO from file to get fresh data
    (when-let* ((file (plist-get org-roam-todo-status--todo :file))
                (fresh-todo (org-roam-todo-status--read-todo-from-file file)))
      (setq org-roam-todo-status--todo fresh-todo))
    (let ((inhibit-read-only t)
          (pos (point)))
      (erase-buffer)
      (org-roam-todo-status--insert-sections)
      (goto-char (min pos (point-max))))))

(defun org-roam-todo-status--read-todo-from-file (file)
  "Read TODO plist from FILE."
  (when (file-exists-p file)
    (list :file file
          :title (org-roam-todo-get-file-property file "TITLE")
          :status (or (org-roam-todo-get-file-property file "STATUS") "draft")
          :project-name (org-roam-todo-get-file-property file "PROJECT_NAME")
          :project-root (org-roam-todo-get-file-property file "PROJECT_ROOT")
          :worktree-path (org-roam-todo-get-file-property file "WORKTREE_PATH")
          :worktree-branch (org-roam-todo-get-file-property file "WORKTREE_BRANCH")
          :approved (org-roam-todo-get-file-property file "APPROVED"))))

(defun org-roam-todo-status-advance ()
  "Advance TODO to the next status.
If the TODO requires user approval, use 'v a' to approve first."
  (interactive)
  (when-let ((todo org-roam-todo-status--todo))
    (let ((result (org-roam-todo-do-advance todo)))
      (org-roam-todo-status-refresh)
      (message "Advanced: %s → %s" (cdr result) (car result)))))

(defun org-roam-todo-status-regress ()
  "Regress TODO to the previous status."
  (interactive)
  (when-let ((todo org-roam-todo-status--todo))
    (let ((result (org-roam-todo-do-regress todo)))
      (org-roam-todo-status-refresh)
      (message "Regressed: %s → %s" (cdr result) (car result)))))

(defun org-roam-todo-status-reject ()
  "Reject/abandon the TODO."
  (interactive)
  (when-let ((todo org-roam-todo-status--todo))
    (when (yes-or-no-p (format "Reject '%s'? " (plist-get todo :title)))
      (let ((reason (read-string "Reason: ")))
        (org-roam-todo-do-reject todo reason)
        (org-roam-todo-status-refresh)
        (message "Rejected: %s (%s)" (plist-get todo :title) reason)))))

(defun org-roam-todo-status-open-todo ()
  "Open the TODO file."
  (interactive)
  (when-let ((todo org-roam-todo-status--todo))
    (org-roam-todo-do-open-todo todo)))

(defun org-roam-todo-status-open-worktree ()
  "Open magit-status in the worktree, creating it if necessary."
  (interactive)
  (unless org-roam-todo-status--todo
    (user-error "No TODO in buffer"))
  (org-roam-todo-do-open-worktree org-roam-todo-status--todo t)
  (org-roam-todo-status-refresh))

(defun org-roam-todo-status-delegate ()
  "Delegate TODO to a Claude agent."
  (interactive)
  (unless org-roam-todo-status--todo
    (user-error "No TODO in buffer"))
  (org-roam-todo-do-delegate org-roam-todo-status--todo t)
  (org-roam-todo-status-refresh))

(defun org-roam-todo-status-review ()
  "View the diff for this TODO's branch against the target branch.
Opens a magit log view showing all commits unique to the branch with diffs.
Use `v a' to approve or `v r' to reject from the status buffer."
  (interactive)
  (unless org-roam-todo-status--todo
    (user-error "No TODO in buffer"))
  (let* ((todo org-roam-todo-status--todo)
         (worktree-path (plist-get todo :worktree-path))
         (workflow (org-roam-todo-wf--get-workflow todo))
         (config (org-roam-todo-workflow-config workflow))
         (target-branch (or (plist-get todo :target-branch)
                            (plist-get config :rebase-target)
                            "origin/main")))
    (unless worktree-path
      (user-error "No worktree exists"))
    (unless (file-directory-p worktree-path)
      (user-error "Worktree not found: %s" worktree-path))
    (let ((default-directory worktree-path))
      (require 'magit-log)
      (magit-log-other (list (format "%s..HEAD" target-branch)) '("--patch")))))

(defun org-roam-todo-status-review-approve ()
  "Approve the TODO for review.
Sets APPROVED property. Use 'a' to advance after approving.
Only available when the next status requires user approval validation."
  (interactive)
  (unless org-roam-todo-status--todo
    (user-error "No TODO in buffer"))
  (let* ((todo org-roam-todo-status--todo)
         (file (plist-get todo :file)))
    (unless (org-roam-todo-status--needs-review-p todo)
      (user-error "This TODO is not awaiting review"))
    ;; Set APPROVED property
    (require 'org-roam-todo-wf-tools)
    (org-roam-todo-wf-tools--set-property file "APPROVED" "t")
    (org-roam-todo-status-refresh)
    (message "Approved. Use 'a' to advance to next status.")))

(defun org-roam-todo-status-review-reject ()
  "Reject the TODO and regress to the previous status for more work.
Optionally records feedback for the rejection.
Only available when the next status requires user approval validation."
  (interactive)
  (unless org-roam-todo-status--todo
    (user-error "No TODO in buffer"))
  (let* ((todo org-roam-todo-status--todo)
         (file (plist-get todo :file)))
    (unless (org-roam-todo-status--needs-review-p todo)
      (user-error "This TODO is not awaiting review"))
    ;; Get optional feedback
    (let ((feedback (read-string "Rejection reason (optional): ")))
      (require 'org-roam-todo-wf-tools)
      (when (and feedback (not (string-empty-p feedback)))
        (org-roam-todo-wf-tools--set-property file "REVIEW_FEEDBACK" feedback))
      ;; Regress to previous status
      (let ((result (org-roam-todo-do-regress todo)))
        (org-roam-todo-status-refresh)
        (message "Rejected and regressed: %s → %s" (cdr result) (car result))))))

(defun org-roam-todo-status-open-list ()
  "Open the TODO list buffer, replacing current window."
  (interactive)
  (require 'org-roam-todo-list)
  (let ((buffer (get-buffer-create "*todo-list*")))
    (with-current-buffer buffer
      (unless (derived-mode-p 'org-roam-todo-list-mode)
        (org-roam-todo-list-mode))
      (setq org-roam-todo-list--project-filter nil)
      (org-roam-todo-list-refresh))
    (switch-to-buffer buffer)))
;;; ============================================================
;;; Git Quick Actions
;;; ============================================================

(defun org-roam-todo-status-git-fetch-rebase ()
  "Fetch and rebase worktree onto target branch."
  (interactive)
  (when-let* ((todo org-roam-todo-status--todo)
              (worktree-path (plist-get todo :worktree-path)))
    (unless (file-directory-p worktree-path)
      (user-error "No worktree found"))
    (let* ((workflow (org-roam-todo-wf--get-workflow todo))
           (config (org-roam-todo-workflow-config workflow))
           (target (or (plist-get todo :target-branch)
                       (plist-get config :rebase-target)
                       "origin/main"))
           (default-directory worktree-path))
      (message "Fetching...")
      (call-process "git" nil nil nil "fetch")
      (message "Rebasing onto %s..." target)
      (let ((result (call-process "git" nil nil nil
                                  "rebase" "--no-gpg-sign" target)))
        (if (= 0 result)
            (progn
              (org-roam-todo-status-refresh)
              (message "Rebased successfully onto %s" target))
          (user-error "Rebase failed - resolve conflicts manually"))))))

(defun org-roam-todo-status-git-fetch-rebase-push ()
  "Fetch, rebase, and force push worktree branch."
  (interactive)
  (when-let* ((todo org-roam-todo-status--todo)
              (worktree-path (plist-get todo :worktree-path))
              (branch (plist-get todo :worktree-branch)))
    (unless (file-directory-p worktree-path)
      (user-error "No worktree found"))
    (unless branch
      (user-error "No branch configured"))
    (let* ((workflow (org-roam-todo-wf--get-workflow todo))
           (config (org-roam-todo-workflow-config workflow))
           (target (or (plist-get todo :target-branch)
                       (plist-get config :rebase-target)
                       "origin/main"))
           (default-directory worktree-path))
      (message "Fetching...")
      (call-process "git" nil nil nil "fetch")
      (message "Rebasing onto %s..." target)
      (let ((result (call-process "git" nil nil nil
                                  "rebase" "--no-gpg-sign" target)))
        (if (= 0 result)
            (progn
              (message "Pushing %s..." branch)
              (let ((push-result (call-process "git" nil nil nil
                                               "push" "--force-with-lease" "origin" branch)))
                (if (= 0 push-result)
                    (progn
                      (org-roam-todo-status-refresh)
                      (message "Rebased and pushed successfully"))
                  (user-error "Push failed"))))
          (user-error "Rebase failed - resolve conflicts manually"))))))

(defun org-roam-todo-status-git-status ()
  "Show git status for the worktree."
  (interactive)
  (when-let* ((todo org-roam-todo-status--todo)
              (worktree-path (plist-get todo :worktree-path)))
    (if (file-directory-p worktree-path)
        (let ((default-directory worktree-path))
          (magit-status))
      (user-error "No worktree found"))))

;;; ============================================================
;;; PR Feedback Commands
;;; ============================================================

(defun org-roam-todo-status-view-ci-log ()
  "View full CI log for the check at point or select from failed checks."
  (interactive)
  (unless org-roam-todo-status--todo
    (user-error "No TODO in buffer"))
  (let* ((todo org-roam-todo-status--todo)
         (worktree-path (plist-get todo :worktree-path))
         (section (magit-current-section))
         (check (and (cl-typep section 'org-roam-todo-status-ci-check-section)
                     (oref section check))))
    (unless worktree-path
      (user-error "No worktree found"))
    (require 'org-roam-todo-wf-pr-feedback)
    (if check
        ;; View log for check at point
        (org-roam-todo-wf-pr-feedback-view-full-log worktree-path
                                                     (plist-get check :name))
      ;; Select from available checks
      (let* ((feedback (org-roam-todo-wf-pr-feedback-fetch worktree-path))
             (checks (plist-get feedback :ci-checks))
             (failed-checks (cl-remove-if-not
                             (lambda (c) (eq (plist-get c :status) 'failure))
                             checks)))
        (if (null failed-checks)
            (user-error "No failed CI checks")
          (let* ((names (mapcar (lambda (c) (plist-get c :name)) failed-checks))
                 (name (completing-read "View log for: " names nil t)))
            (org-roam-todo-wf-pr-feedback-view-full-log worktree-path name)))))))

(defun org-roam-todo-status-open-pr ()
  "Open the PR/MR URL in browser."
  (interactive)
  (unless org-roam-todo-status--todo
    (user-error "No TODO in buffer"))
  (let* ((todo org-roam-todo-status--todo)
         (worktree-path (plist-get todo :worktree-path)))
    (unless worktree-path
      (user-error "No worktree found"))
    (require 'org-roam-todo-wf-pr-feedback)
    (let* ((feedback (org-roam-todo-wf-pr-feedback-fetch worktree-path))
           (pr-url (plist-get feedback :pr-url)))
      (if pr-url
          (browse-url pr-url)
        (user-error "No PR URL found")))))

(defun org-roam-todo-status-visit-comment ()
  "Visit the file/line for the comment at point."
  (interactive)
  (let* ((section (magit-current-section))
         (comment (and (cl-typep section 'org-roam-todo-status-comment-section)
                       (oref section comment)))
         (todo org-roam-todo-status--todo)
         (worktree-path (plist-get todo :worktree-path)))
    (unless comment
      (user-error "No comment at point"))
    (let ((path (plist-get comment :path))
          (line (plist-get comment :line))
          (url (plist-get comment :url)))
      (cond
       ;; If we have file path and line, go to that location
       ((and path worktree-path)
        (let ((full-path (expand-file-name path worktree-path)))
          (if (file-exists-p full-path)
              (progn
                (find-file full-path)
                (when line
                  (goto-char (point-min))
                  (forward-line (1- line))))
            (if url
                (browse-url url)
              (user-error "File not found: %s" path)))))
       ;; Otherwise open URL if available
       (url (browse-url url))
       (t (user-error "No location info for this comment"))))))

;;; ============================================================
;;; Validation Navigation
;;; ============================================================

(defun org-roam-todo-status-visit-validation ()
  "Visit the target associated with the validation at point.
Different validations navigate to different places:
- Git validations: open magit-status or magit-log in worktree
- Acceptance criteria: jump to that section in TODO file
- PR checks: open PR URL in browser"
  (interactive)
  (let* ((section (magit-current-section))
         (result (and (cl-typep section 'org-roam-todo-status-validation-section)
                      (oref section result)))
         (target (plist-get result :target))
         (todo org-roam-todo-status--todo)
         (worktree-path (plist-get todo :worktree-path))
         (project-root (plist-get todo :project-root))
         (file (plist-get todo :file)))
    (unless result
      (user-error "No validation at point"))
    (unless target
      (user-error "This validation has no navigation target"))
    (pcase target
      (:magit
       (if (and worktree-path (file-directory-p worktree-path))
           (let ((default-directory worktree-path))
             (magit-status))
         (user-error "No worktree found")))
      (:magit-log
       (if (and worktree-path (file-directory-p worktree-path))
           (let ((default-directory worktree-path))
             (magit-log-current nil nil))
         (user-error "No worktree found")))
      (:project-magit
       (if (and project-root (file-directory-p project-root))
           (let ((default-directory project-root))
             (magit-status))
         (user-error "No project root found")))
      (:todo-acceptance
       (if file
           (progn
             (find-file file)
             (goto-char (point-min))
             (if (re-search-forward "^\\*+.*Acceptance Criteria" nil t)
                 (progn
                   (org-show-entry)
                   (org-show-children))
               (message "No 'Acceptance Criteria' heading found")))
         (user-error "No TODO file found")))
      (:pr-url
       (let ((pr-url (plist-get todo :pr-url)))
         (if pr-url
             (browse-url pr-url)
           ;; Try to get PR URL from worktree
           (if (and worktree-path (file-directory-p worktree-path))
               (let* ((default-directory worktree-path)
                      (url (string-trim
                            (shell-command-to-string
                             "gh pr view --json url -q .url 2>/dev/null"))))
                 (if (and url (not (string-empty-p url)))
                     (browse-url url)
                   (user-error "No PR found for this branch")))
             (user-error "No PR URL available")))))
      (_ (user-error "Unknown target type: %s" target)))))

;;; ============================================================
;;; Context Detection
;;; ============================================================

(defun org-roam-todo-status--find-todo-by-worktree (worktree-path)
  "Find TODO that has WORKTREE-PATH."
  (let ((expanded (expand-file-name worktree-path)))
    (cl-find-if (lambda (todo)
                  (when-let ((wt (plist-get todo :worktree-path)))
                    (string= (expand-file-name wt) expanded)))
                (org-roam-todo-list--get-entries))))

(defun org-roam-todo-status--find-todo-by-file (file)
  "Find TODO for FILE (a TODO org file)."
  (let ((expanded (expand-file-name file)))
    (cl-find-if (lambda (todo)
                  (string= (expand-file-name (plist-get todo :file)) expanded))
                (org-roam-todo-list--get-entries))))

(defun org-roam-todo-status--infer-todo ()
  "Infer which TODO to show status for.
Priority:
1. If in a *todo-status* buffer, use current TODO
2. If in a Claude buffer, find TODO by worktree path
3. If in a file under a worktree, find TODO by worktree path
4. If viewing a TODO org file, use that
5. Prompt user to select from list"
  (cond
   ;; 1. Already in a status buffer
   ((and (derived-mode-p 'org-roam-todo-status-mode)
         org-roam-todo-status--todo)
    org-roam-todo-status--todo)
   
   ;; 2. In a Claude buffer - check default-directory
   ((string-match-p "^\\*claude:" (buffer-name))
    (org-roam-todo-status--find-todo-by-worktree default-directory))
   
   ;; 3. Current file is under a worktree
   ((and buffer-file-name
         (org-roam-todo-status--find-todo-by-worktree
          (file-name-directory buffer-file-name))))
   
   ;; 4. Current file is a TODO org file
   ((and buffer-file-name
         (string-match-p "/org-roam/.*\\.org$" buffer-file-name))
    (org-roam-todo-status--find-todo-by-file buffer-file-name))
   
   ;; 5. Prompt user
   (t
    (let* ((todos (org-roam-todo-list--get-entries))
           (choices (mapcar (lambda (todo)
                              (cons (format "[%s] %s - %s"
                                            (plist-get todo :status)
                                            (or (plist-get todo :project-name) "?")
                                            (plist-get todo :title))
                                    todo))
                            todos))
           (choice (completing-read "Select TODO: " choices nil t)))
      (cdr (assoc choice choices))))))

;;; ============================================================
;;; Transient Menu
;;; ============================================================

;;;###autoload (autoload 'org-roam-todo-status-dispatch "org-roam-todo-status" nil t)
(transient-define-prefix org-roam-todo-status-dispatch ()
  "Dispatch popup for TODO status actions."
  ["Workflow"
   [("a" "Advance" org-roam-todo-status-advance)
    ("r" "Regress" org-roam-todo-status-regress)
    ("R" "Reject" org-roam-todo-status-reject)]
   [("o" "Open TODO file" org-roam-todo-status-open-todo)
    ("w" "Worktree (magit)" org-roam-todo-status-open-worktree)
    ("d" "Delegate to agent" org-roam-todo-status-delegate)]]
  ["Review"
   [("v a" "Approve review" org-roam-todo-status-review-approve)
    ("v r" "Reject review" org-roam-todo-status-review-reject)
    ("v d" "View diff" org-roam-todo-status-review)]]
  ["Git"
   [("m r" "Fetch & rebase" org-roam-todo-status-git-fetch-rebase)
    ("m p" "Fetch, rebase & push" org-roam-todo-status-git-fetch-rebase-push)
    ("m s" "Git status (magit)" org-roam-todo-status-git-status)]]
  ["PR Feedback"
   [("p p" "Open PR in browser" org-roam-todo-status-open-pr)
    ("p l" "View CI log" org-roam-todo-status-view-ci-log)
    ("p c" "Visit comment" org-roam-todo-status-visit-comment)]]
  ["Buffer"
   [("g" "Refresh" org-roam-todo-status-refresh)
    ("G" "Force refresh (clear cache)" (lambda () (interactive) (org-roam-todo-status-refresh t)))
    ("q" "Quit" quit-window)]])

;;; ============================================================
;;; Keymaps
;;; ============================================================

(defvar org-roam-todo-status-mode-map
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map magit-section-mode-map)
    (define-key map (kbd "?") #'org-roam-todo-status-dispatch)
    (define-key map (kbd "RET") #'org-roam-todo-status-visit-validation)
    (define-key map (kbd "g") #'org-roam-todo-status-refresh)
    (define-key map (kbd "G") (lambda () (interactive) (org-roam-todo-status-refresh t)))
    (define-key map (kbd "a") #'org-roam-todo-status-advance)
    (define-key map (kbd "r") #'org-roam-todo-status-regress)
    (define-key map (kbd "R") #'org-roam-todo-status-reject)
    (define-key map (kbd "o") #'org-roam-todo-status-open-todo)
    (define-key map (kbd "w") #'org-roam-todo-status-open-worktree)
    (define-key map (kbd "d") #'org-roam-todo-status-delegate)
    (define-key map (kbd "l") #'org-roam-todo-status-open-list)
    (define-key map (kbd "q") #'quit-window)
    ;; Review prefix (v a = approve, v r = reject, v d = view diff)
    (define-key map (kbd "v a") #'org-roam-todo-status-review-approve)
    (define-key map (kbd "v r") #'org-roam-todo-status-review-reject)
    (define-key map (kbd "v d") #'org-roam-todo-status-review)
    ;; Git prefix
    (define-key map (kbd "m r") #'org-roam-todo-status-git-fetch-rebase)
    (define-key map (kbd "m p") #'org-roam-todo-status-git-fetch-rebase-push)
    (define-key map (kbd "m s") #'org-roam-todo-status-git-status)
    ;; PR feedback prefix
    (define-key map (kbd "p p") #'org-roam-todo-status-open-pr)
    (define-key map (kbd "p l") #'org-roam-todo-status-view-ci-log)
    (define-key map (kbd "p c") #'org-roam-todo-status-visit-comment)
    (define-key map (kbd "L") #'org-roam-todo-status-view-ci-log)  ; Quick access
    map)
  "Keymap for `org-roam-todo-status-mode'.")

;;; ============================================================
;;; Mode Definition
;;; ============================================================

(define-derived-mode org-roam-todo-status-mode magit-section-mode "TODO-Status"
  "Major mode for viewing and managing TODO workflow status.

\\{org-roam-todo-status-mode-map}"
  :group 'org-roam-todo-status
  (setq-local font-lock-defaults '(nil t))
  (setq-local revert-buffer-function
              (lambda (_ignore-auto _noconfirm)
                (org-roam-todo-status-refresh))))

;; Evil mode support
(with-eval-after-load 'evil
  (when (boundp 'evil-emacs-state-modes)
    (add-to-list 'evil-emacs-state-modes 'org-roam-todo-status-mode)))

;;; ============================================================
;;; Entry Points
;;; ============================================================

;;;###autoload
(defun org-roam-todo-status (todo)
  "Display status buffer for TODO, replacing current window."
  (interactive (list (org-roam-todo-status--infer-todo)))
  (unless todo
    (user-error "No TODO found"))
  (let* ((title (plist-get todo :title))
         (buf-name (format "*todo-status: %s*" (or title "TODO")))
         (buffer (get-buffer-create buf-name)))
    (with-current-buffer buffer
      (unless (derived-mode-p 'org-roam-todo-status-mode)
        (org-roam-todo-status-mode))
      (setq org-roam-todo-status--todo todo)
      (org-roam-todo-status-refresh))
    (switch-to-buffer buffer)))

;;;###autoload
(defun org-roam-todo-status-from-context ()
  "Show TODO status buffer, inferring TODO from context."
  (interactive)
  (org-roam-todo-status (org-roam-todo-status--infer-todo)))

;;;###autoload
(defun org-roam-todo-setup-status-keybinding ()
  "Set up C-x j keybinding for TODO status."
  (global-set-key (kbd "C-x j") #'org-roam-todo-status-from-context))

(provide 'org-roam-todo-status)
;;; org-roam-todo-status.el ends here
