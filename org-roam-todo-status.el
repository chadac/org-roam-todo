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
    (org-roam-todo-wf-pr--require-user-approval
     :name "User approval"
     :target :pr-url)
    (org-roam-todo-wf-pr--require-pr-merged
     :name "PR merged"
     :target :pr-url)
    (org-roam-todo-wf--only-human
     :name "Human action required"
     :target nil)
    (org-roam-todo-wf--only-ai
     :name "Automated action only"
     :target nil))
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



;;; ============================================================
;;; Validation Runner
;;; ============================================================

(defun org-roam-todo-status--run-validations (todo workflow next-status)
  "Run validation hooks for NEXT-STATUS and return results list.
TODO is the todo plist, WORKFLOW is the workflow struct."
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
      (let ((result (condition-case err
                        (progn (funcall fn event) 'pass)
                      (user-error (cons 'fail (cadr err)))
                      (error (cons 'error (error-message-string err))))))
        (push (list :hook fn
                    :status (if (eq result 'pass) 'pass (car result))
                    :message (when (consp result) (cdr result))
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
                     (indicator (if (eq res-status 'pass) "✓" "✗"))
                     (face (if (eq res-status 'pass)
                               'org-roam-todo-status-validation-pass
                             'org-roam-todo-status-validation-fail)))
                (magit-insert-section section (org-roam-todo-status-validation-section)
                  (oset section result result)
                  (insert "  ")
                  (insert (org-roam-todo-status--propertize indicator face))
                  (insert " ")
                  (insert (org-roam-todo-status--propertize name face))
                  (insert "\n")
                  ;; Show error message indented if failed
                  (when (and message (not (eq res-status 'pass)))
                    (insert "    ")
                    (insert (org-roam-todo-status--propertize
                             (org-roam-todo-status--truncate-message message 60)
                             'font-lock-comment-face))
                    (insert "\n")))))))))))


(defun org-roam-todo-status--insert-sections ()
  "Insert all sections into the buffer."
  (let* ((todo org-roam-todo-status--todo)
         (workflow (org-roam-todo-wf--get-workflow todo)))
    (magit-insert-section (org-roam-todo-status-root-section)
      (org-roam-todo-status--insert-header todo workflow)
      (insert "\n")
      (org-roam-todo-status--insert-validations todo workflow)
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

(defun org-roam-todo-status-refresh ()
  "Refresh the TODO status buffer."
  (interactive)
  (when (derived-mode-p 'org-roam-todo-status-mode)
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
          :worktree-branch (org-roam-todo-get-file-property file "WORKTREE_BRANCH"))))

(defun org-roam-todo-status-advance ()
  "Advance TODO to the next status."
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
  (when-let* ((todo org-roam-todo-status--todo)
              (file (plist-get todo :file)))
    (find-file file)))

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
  ["Git"
   [("m r" "Fetch & rebase" org-roam-todo-status-git-fetch-rebase)
    ("m p" "Fetch, rebase & push" org-roam-todo-status-git-fetch-rebase-push)
    ("m s" "Git status (magit)" org-roam-todo-status-git-status)]]
  ["Buffer"
   [("g" "Refresh" org-roam-todo-status-refresh)
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
    (define-key map (kbd "a") #'org-roam-todo-status-advance)
    (define-key map (kbd "r") #'org-roam-todo-status-regress)
    (define-key map (kbd "R") #'org-roam-todo-status-reject)
    (define-key map (kbd "o") #'org-roam-todo-status-open-todo)
    (define-key map (kbd "w") #'org-roam-todo-status-open-worktree)
    (define-key map (kbd "d") #'org-roam-todo-status-delegate)
    (define-key map (kbd "l") #'org-roam-todo-status-open-list)
    (define-key map (kbd "q") #'quit-window)
    ;; Git prefix
    (define-key map (kbd "m r") #'org-roam-todo-status-git-fetch-rebase)
    (define-key map (kbd "m p") #'org-roam-todo-status-git-fetch-rebase-push)
    (define-key map (kbd "m s") #'org-roam-todo-status-git-status)
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
