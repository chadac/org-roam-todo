;;; org-roam-todo-wf-watch.el --- Async polling watchers for workflows -*- lexical-binding: t; -*-

;; Author: Claude Code
;; Version: 0.1.0
;; Package-Requires: ((emacs "28.1") (org-roam "2.0"))

;;; Commentary:
;; Async polling system for workflows that can automatically check external
;; state (CI status, PR merge status, buffer modifications, etc.) and trigger
;; status transitions when conditions are met.
;;
;; Use Cases:
;; - CI Monitoring: When in "ci" status, poll for CI completion, auto-advance to "ready"
;; - PR Merge Monitoring: When in "review" status, detect merge, auto-advance to "done"
;; - Buffer Modification: When in "ci"/"review", detect file edits, regress to "active"
;; - Failure Detection: If CI fails, optionally regress to "active" for fixes
;;
;; Watchers are defined in workflow :config under :watchers key.
;; Each watcher specifies:
;; - :status - which status to watch
;; - :poll-fn - function returning 'success, 'failure, or 'pending
;; - :interval - seconds between polls (default 60)
;; - :on-success - action on success, e.g., (:advance "ready")
;; - :on-failure - optional action on failure
;; - :timeout - optional max seconds to poll
;;
;; Buffer watchers are special and use :type 'buffer-change instead of :poll-fn.

;;; Code:

(require 'cl-lib)
(require 'org-roam-todo-wf)

;; Forward declarations
(declare-function org-roam-todo-wf-tools--get-todo "org-roam-todo-wf-tools" (todo-id))

;;; ============================================================
;;; Customization
;;; ============================================================

(defgroup org-roam-todo-wf-watch nil
  "Async watcher settings for org-roam-todo workflows."
  :group 'org-roam-todo)

(defcustom org-roam-todo-wf-watch-default-interval 60
  "Default polling interval in seconds for watchers."
  :type 'integer
  :group 'org-roam-todo-wf-watch)

(defcustom org-roam-todo-wf-watch-default-timeout 3600
  "Default timeout in seconds for watchers (1 hour).
Set to nil to disable timeout."
  :type '(choice integer (const nil))
  :group 'org-roam-todo-wf-watch)

(defcustom org-roam-todo-wf-watch-ci-check-function nil
  "Custom function to check CI status for a TODO.
When set, called instead of the built-in CI check.
Should accept a TODO plist and return \\='success, \\='failure, or \\='pending.
Can be set per-project via .dir-locals.el."
  :type '(choice (const :tag "Use built-in" nil)
                 (function :tag "Custom function"))
  :group 'org-roam-todo-wf-watch)

;;; ============================================================
;;; Timer Management
;;; ============================================================

(defvar org-roam-todo-wf-watch--timers (make-hash-table :test 'equal)
  "Hash table: TODO-ID -> list of active timers.")

(defvar org-roam-todo-wf-watch--buffer-hooks (make-hash-table :test 'equal)
  "Hash table: TODO-ID -> list of (buffer . hook-fn) pairs for cleanup.")

(defun org-roam-todo-wf-watch--start-watchers (todo)
  "Start all watchers for TODO based on its current status.
Reads the workflow's :watchers config and starts timers for
watchers matching the current status."
  (let* ((workflow (org-roam-todo-wf--get-workflow todo))
         (config (org-roam-todo-workflow-config workflow))
         (watchers (plist-get config :watchers))
         (status (plist-get todo :status))
         (todo-id (plist-get todo :id)))
    ;; Cancel any existing timers for this TODO
    (org-roam-todo-wf-watch--stop-watchers todo-id)
    ;; Start watchers for current status
    (dolist (watcher watchers)
      (when (string= (plist-get watcher :status) status)
        (org-roam-todo-wf-watch--start-watcher todo watcher)))))

(defun org-roam-todo-wf-watch--start-watcher (todo watcher)
  "Start a single WATCHER for TODO.
WATCHER is a plist with :status, :poll-fn or :type, :interval, etc."
  (let ((watcher-type (plist-get watcher :type)))
    (cond
     ;; Buffer change watcher (special type)
     ((eq watcher-type 'buffer-change)
      (org-roam-todo-wf-watch--start-buffer-watcher todo watcher))
     ;; Regular polling watcher
     (t
      (org-roam-todo-wf-watch--start-poll-watcher todo watcher)))))

(defun org-roam-todo-wf-watch--start-poll-watcher (todo watcher)
  "Start a polling WATCHER for TODO.
Sets up a timer to periodically call the poll function."
  (let* ((todo-id (plist-get todo :id))
         (interval (or (plist-get watcher :interval)
                       org-roam-todo-wf-watch-default-interval))
         (start-time (current-time))
         timer)
    (setq timer
          (run-with-timer
           interval interval
           (lambda ()
             (org-roam-todo-wf-watch--poll todo-id watcher start-time))))
    ;; Store timer for cleanup
    (push timer (gethash todo-id org-roam-todo-wf-watch--timers))))

(defun org-roam-todo-wf-watch--poll (todo-id watcher start-time)
  "Execute a poll check for TODO-ID using WATCHER config.
START-TIME is when the watcher was started, for timeout calculation."
  (let* ((todo (org-roam-todo-wf-watch--get-todo todo-id))
         (poll-fn (plist-get watcher :poll-fn))
         (timeout (or (plist-get watcher :timeout)
                      org-roam-todo-wf-watch-default-timeout))
         (on-success (plist-get watcher :on-success))
         (on-failure (plist-get watcher :on-failure)))
    (cond
     ;; TODO no longer exists or status changed - stop watching
     ((or (null todo)
          (not (string= (plist-get todo :status)
                        (plist-get watcher :status))))
      (org-roam-todo-wf-watch--stop-watchers todo-id))

     ;; Timeout reached
     ((and timeout
           (> (float-time (time-subtract (current-time) start-time))
              timeout))
      (org-roam-todo-wf-watch--stop-watchers todo-id)
      (message "org-roam-todo: Watcher timeout for TODO %s" todo-id))

     ;; Normal poll
     (t
      (condition-case err
          (pcase (funcall poll-fn todo)
            ('success
             (org-roam-todo-wf-watch--stop-watchers todo-id)
             (org-roam-todo-wf-watch--handle-action todo on-success))
            ('failure
             (when on-failure
               (org-roam-todo-wf-watch--stop-watchers todo-id)
               (org-roam-todo-wf-watch--handle-action todo on-failure)))
            ('pending nil))  ; continue polling
        (error
         (message "org-roam-todo: Watcher error for %s: %s" todo-id err)))))))

(defun org-roam-todo-wf-watch--handle-action (todo action)
  "Execute ACTION for TODO.
ACTION is a plist like (:advance \"ready\") or (:regress \"active\")."
  (cond
   ((plist-get action :advance)
    (org-roam-todo-wf--change-status todo (plist-get action :advance)))
   ((plist-get action :regress)
    (org-roam-todo-wf--change-status todo (plist-get action :regress)))))

(defun org-roam-todo-wf-watch--stop-watchers (todo-id)
  "Cancel all active watchers for TODO-ID.
Stops both timers and buffer hooks."
  ;; Cancel timers
  (dolist (timer (gethash todo-id org-roam-todo-wf-watch--timers))
    (when (timerp timer)
      (cancel-timer timer)))
  (remhash todo-id org-roam-todo-wf-watch--timers)
  ;; Remove buffer hooks
  (dolist (entry (gethash todo-id org-roam-todo-wf-watch--buffer-hooks))
    (let ((buf (car entry))
          (hook-fn (cdr entry)))
      (when (buffer-live-p buf)
        (with-current-buffer buf
          (remove-hook 'after-change-functions hook-fn t)))))
  (remhash todo-id org-roam-todo-wf-watch--buffer-hooks)
  ;; Remove find-file hook for this TODO
  (org-roam-todo-wf-watch--remove-find-file-hook todo-id))

;;; ============================================================
;;; Buffer Change Watchers
;;; ============================================================

(defun org-roam-todo-wf-watch--start-buffer-watcher (todo watcher)
  "Start a buffer change WATCHER for TODO.
Monitors buffers in the worktree for modifications."
  (let* ((todo-id (plist-get todo :id))
         (worktree-path (plist-get todo :worktree-path))
         (on-change (plist-get watcher :on-change)))
    (when (and worktree-path on-change)
      ;; Add hooks to existing buffers
      (dolist (buf (buffer-list))
        (when-let* ((file (buffer-file-name buf))
                    (_ (string-prefix-p (file-truename worktree-path)
                                        (file-truename file))))
          (org-roam-todo-wf-watch--add-buffer-hook todo-id buf on-change)))
      ;; Watch for new buffers being opened
      (org-roam-todo-wf-watch--add-find-file-hook todo-id worktree-path on-change))))

(defun org-roam-todo-wf-watch--add-buffer-hook (todo-id buffer action)
  "Add change hook to BUFFER for TODO-ID that triggers ACTION."
  (let ((hook-fn (lambda (_beg _end _len)
                   (org-roam-todo-wf-watch--on-buffer-change todo-id action))))
    (with-current-buffer buffer
      (add-hook 'after-change-functions hook-fn nil t))
    ;; Store for cleanup
    (push (cons buffer hook-fn)
          (gethash todo-id org-roam-todo-wf-watch--buffer-hooks))))

(defvar org-roam-todo-wf-watch--find-file-hooks nil
  "Alist of (todo-id . hook-fn) for find-file-hook cleanup.")

(defun org-roam-todo-wf-watch--add-find-file-hook (todo-id worktree-path action)
  "Add find-file-hook to watch for new files in WORKTREE-PATH for TODO-ID."
  (let ((hook-fn (lambda ()
                   (when-let* ((file (buffer-file-name))
                               (_ (string-prefix-p (file-truename worktree-path)
                                                   (file-truename file))))
                     (org-roam-todo-wf-watch--add-buffer-hook
                      todo-id (current-buffer) action)))))
    (add-hook 'find-file-hook hook-fn)
    (push (cons todo-id hook-fn) org-roam-todo-wf-watch--find-file-hooks)))

(defun org-roam-todo-wf-watch--remove-find-file-hook (todo-id)
  "Remove find-file-hook for TODO-ID."
  (when-let ((entry (assoc todo-id org-roam-todo-wf-watch--find-file-hooks)))
    (remove-hook 'find-file-hook (cdr entry))
    (setq org-roam-todo-wf-watch--find-file-hooks
          (assq-delete-all todo-id org-roam-todo-wf-watch--find-file-hooks))))

(defvar org-roam-todo-wf-watch--pending-changes (make-hash-table :test 'equal)
  "Hash table: TODO-ID -> timer for debouncing buffer changes.")

(defun org-roam-todo-wf-watch--on-buffer-change (todo-id action)
  "Handle buffer change for TODO-ID, debouncing rapid changes.
ACTION is executed after a short delay to avoid triggering on every keystroke."
  ;; Cancel any pending timer
  (when-let ((timer (gethash todo-id org-roam-todo-wf-watch--pending-changes)))
    (cancel-timer timer))
  ;; Set new timer (debounce for 2 seconds)
  (puthash todo-id
           (run-with-timer
            2 nil
            (lambda ()
              (remhash todo-id org-roam-todo-wf-watch--pending-changes)
              (when-let ((todo (org-roam-todo-wf-watch--get-todo todo-id)))
                ;; Only trigger if still in the watched status
                (org-roam-todo-wf-watch--stop-watchers todo-id)
                (org-roam-todo-wf-watch--handle-action todo action))))
           org-roam-todo-wf-watch--pending-changes))

;;; ============================================================
;;; TODO Resolution
;;; ============================================================

(defun org-roam-todo-wf-watch--get-todo (todo-id)
  "Get TODO plist by TODO-ID.
Uses org-roam-todo-wf-tools--get-todo if available."
  (if (fboundp 'org-roam-todo-wf-tools--get-todo)
      (org-roam-todo-wf-tools--get-todo todo-id)
    ;; Fallback: search through org-roam-todo--query-todos if available
    (when (fboundp 'org-roam-todo--query-todos)
      (cl-find-if (lambda (todo)
                    (string= (plist-get todo :id) todo-id))
                  (org-roam-todo--query-todos)))))

;;; ============================================================
;;; Status Change Hook
;;; ============================================================

(defun org-roam-todo-wf-watch--on-status-changed (event)
  "Start watchers after status change if applicable.
EVENT is the workflow event with the new status."
  (let ((todo (org-roam-todo-event-todo event)))
    (org-roam-todo-wf-watch--start-watchers todo)))

;;; ============================================================
;;; Cleanup on Emacs Exit
;;; ============================================================

(defun org-roam-todo-wf-watch--cleanup-all ()
  "Cancel all active watchers.
Called on Emacs exit to clean up timers."
  ;; Cancel all timers
  (maphash (lambda (_todo-id timers)
             (dolist (timer timers)
               (when (timerp timer)
                 (cancel-timer timer))))
           org-roam-todo-wf-watch--timers)
  (clrhash org-roam-todo-wf-watch--timers)
  ;; Remove all buffer hooks
  (maphash (lambda (_todo-id entries)
             (dolist (entry entries)
               (let ((buf (car entry))
                     (hook-fn (cdr entry)))
                 (when (buffer-live-p buf)
                   (with-current-buffer buf
                     (remove-hook 'after-change-functions hook-fn t))))))
           org-roam-todo-wf-watch--buffer-hooks)
  (clrhash org-roam-todo-wf-watch--buffer-hooks)
  ;; Remove find-file hooks
  (dolist (entry org-roam-todo-wf-watch--find-file-hooks)
    (remove-hook 'find-file-hook (cdr entry)))
  (setq org-roam-todo-wf-watch--find-file-hooks nil)
  ;; Cancel pending change timers
  (maphash (lambda (_id timer)
             (cancel-timer timer))
           org-roam-todo-wf-watch--pending-changes)
  (clrhash org-roam-todo-wf-watch--pending-changes))

;; Register cleanup on Emacs exit
(add-hook 'kill-emacs-hook #'org-roam-todo-wf-watch--cleanup-all)

;;; ============================================================
;;; Interactive Commands
;;; ============================================================

(defun org-roam-todo-wf-watch-list ()
  "List all active watchers."
  (interactive)
  (let ((count 0))
    (maphash (lambda (todo-id timers)
               (setq count (+ count (length timers)))
               (message "TODO %s: %d timer(s)" todo-id (length timers)))
             org-roam-todo-wf-watch--timers)
    (maphash (lambda (todo-id entries)
               (setq count (+ count (length entries)))
               (message "TODO %s: %d buffer hook(s)" todo-id (length entries)))
             org-roam-todo-wf-watch--buffer-hooks)
    (if (= count 0)
        (message "No active watchers")
      (message "Total: %d active watcher(s)" count))))

(defun org-roam-todo-wf-watch-stop-all ()
  "Stop all active watchers."
  (interactive)
  (org-roam-todo-wf-watch--cleanup-all)
  (message "All watchers stopped"))

(provide 'org-roam-todo-wf-watch)
;;; org-roam-todo-wf-watch.el ends here
