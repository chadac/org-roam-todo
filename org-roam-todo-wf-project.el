;;; org-roam-todo-wf-project.el --- Per-project workflow configuration -*- lexical-binding: t; -*-

;; Author: Claude Code
;; Version: 0.1.0
;; Package-Requires: ((emacs "28.1"))

;;; Commentary:
;; Per-project workflow configuration for org-roam-todo.
;;
;; This module allows projects to define custom validations that run
;; before TODO status transitions.  Validations are defined in a
;; `.org-todo-config.el' file in the project root.
;;
;; Example .org-todo-config.el:
;;
;;   ;; Custom validation: ensure tests pass before review
;;   (defun my-project-run-tests (event)
;;     "Validate: all unit tests pass."
;;     (let ((worktree-path (org-roam-todo-prop event "WORKTREE_PATH")))
;;       (when worktree-path
;;         (let* ((default-directory worktree-path)
;;                (result (call-process "npm" nil nil nil "test")))
;;           (unless (= 0 result)
;;             (user-error "Unit tests failed"))))))
;;
;;   ;; Register validations
;;   (org-roam-todo-project-validations
;;    :validate-review (my-project-run-tests))
;;
;; Validations follow the same contract as built-in workflow validations:
;; - Return nil or :pass on success
;; - Signal user-error on failure (with helpful message)
;; - Can return (:pending "message") for async validations

;;; Code:

(require 'cl-lib)

;;; ============================================================
;;; Configuration
;;; ============================================================

(defcustom org-roam-todo-project-config-file ".org-todo-config.el"
  "Name of the per-project configuration file.
This file is looked for in PROJECT_ROOT when processing TODO transitions."
  :type 'string
  :group 'org-roam-todo)

;;; ============================================================
;;; Config Cache
;;; ============================================================

(defvar org-roam-todo-wf-project--config-cache (make-hash-table :test 'equal)
  "Cache of loaded project configurations.
Key: project-root path (string)
Value: plist (:mtime modification-time :validations validation-plist)")

(defvar org-roam-todo-wf-project--current-validations nil
  "Temporary variable to capture validations during config file load.")

;;; ============================================================
;;; Validation Registration Macro
;;; ============================================================

(defmacro org-roam-todo-project-validations (&rest args)
  "Register project validations for the current project.
This macro is used in `.org-todo-config.el' files.

ARGS is a plist with keys:
  :global          - Validations to run before ANY status transition
  :validate-STATUS - Validations to run before entering STATUS

Each value is a list of function symbols.

Example:
  (org-roam-todo-project-validations
   :global (check-lint)
   :validate-review (run-tests)
   :validate-done (check-coverage check-docs))"
  `(setq org-roam-todo-wf-project--current-validations ',args))

;;; ============================================================
;;; Config Loading
;;; ============================================================

(defun org-roam-todo-wf-project--config-path (project-root)
  "Return the path to the config file in PROJECT-ROOT."
  (when project-root
    (expand-file-name org-roam-todo-project-config-file project-root)))

(defun org-roam-todo-wf-project--config-exists-p (project-root)
  "Return non-nil if a config file exists in PROJECT-ROOT."
  (when-let ((path (org-roam-todo-wf-project--config-path project-root)))
    (file-exists-p path)))

(defun org-roam-todo-wf-project--config-mtime (project-root)
  "Return the modification time of the config file in PROJECT-ROOT."
  (when-let ((path (org-roam-todo-wf-project--config-path project-root)))
    (when (file-exists-p path)
      (file-attribute-modification-time (file-attributes path)))))

(defun org-roam-todo-wf-project--cache-valid-p (project-root)
  "Return non-nil if the cached config for PROJECT-ROOT is still valid."
  (when-let ((cached (gethash project-root org-roam-todo-wf-project--config-cache)))
    (let ((cached-mtime (plist-get cached :mtime))
          (current-mtime (org-roam-todo-wf-project--config-mtime project-root)))
      (and cached-mtime current-mtime
           (equal cached-mtime current-mtime)))))

(defun org-roam-todo-wf-project--load-config (project-root)
  "Load the config file from PROJECT-ROOT.
Returns the validations plist or nil if no config file exists.
Results are cached based on file modification time."
  (when (and project-root (org-roam-todo-wf-project--config-exists-p project-root))
    ;; Check cache first
    (if (org-roam-todo-wf-project--cache-valid-p project-root)
        (plist-get (gethash project-root org-roam-todo-wf-project--config-cache)
                   :validations)
      ;; Load fresh
      (let ((config-path (org-roam-todo-wf-project--config-path project-root))
            (org-roam-todo-wf-project--current-validations nil))
        (condition-case err
            (progn
              (load config-path nil t t)
              ;; Cache the result
              (puthash project-root
                       (list :mtime (org-roam-todo-wf-project--config-mtime project-root)
                             :validations org-roam-todo-wf-project--current-validations)
                       org-roam-todo-wf-project--config-cache)
              org-roam-todo-wf-project--current-validations)
          (error
           (message "Error loading %s: %s" config-path (error-message-string err))
           nil))))))

(defun org-roam-todo-wf-project-clear-cache (&optional project-root)
  "Clear the config cache.
If PROJECT-ROOT is provided, only clear that project's cache.
Otherwise, clear all cached configs."
  (interactive)
  (if project-root
      (remhash project-root org-roam-todo-wf-project--config-cache)
    (clrhash org-roam-todo-wf-project--config-cache))
  (message "Project config cache cleared"))

;;; ============================================================
;;; Validation Retrieval
;;; ============================================================

(defun org-roam-todo-wf-project--parse-validations (validations-plist)
  "Parse VALIDATIONS-PLIST into an alist of (event-type . functions).
Handles both single functions and lists of functions."
  (let ((result '())
        (plist validations-plist))
    (while plist
      (let* ((key (pop plist))
             (value (pop plist))
             ;; Normalize to list
             (fns (if (and (listp value) (not (functionp value)))
                      value
                    (list value))))
        (push (cons key fns) result)))
    (nreverse result)))

(defun org-roam-todo-wf-project-get-validations (project-root event-type)
  "Get project validations for PROJECT-ROOT that apply to EVENT-TYPE.
EVENT-TYPE is a keyword like :validate-review.
Returns a list of validation functions.

Global validations (:global) are included for all :validate-* event types."
  (when-let ((config (org-roam-todo-wf-project--load-config project-root)))
    (let ((parsed (org-roam-todo-wf-project--parse-validations config))
          (result '()))
      ;; Add global validations for any :validate-* event
      (when (and (keywordp event-type)
                 (string-prefix-p ":validate-" (symbol-name event-type)))
        (when-let ((global-fns (cdr (assq :global parsed))))
          (setq result (append result global-fns))))
      ;; Add event-specific validations
      (when-let ((specific-fns (cdr (assq event-type parsed))))
        (setq result (append result specific-fns)))
      result)))

;;; ============================================================
;;; Integration Hook
;;; ============================================================

(defun org-roam-todo-wf-project-get-hooks (project-root event-type)
  "Get all project hooks for PROJECT-ROOT and EVENT-TYPE.
This is the main entry point used by org-roam-todo-wf.el.
Returns a list of functions to call for the given event."
  (org-roam-todo-wf-project-get-validations project-root event-type))

;;; ============================================================
;;; Async Validation Infrastructure
;;; ============================================================

(defvar org-roam-todo-wf-project--async-results (make-hash-table :test 'equal)
  "Cache of async validation results.
Key: (project-root validation-name commit-sha).
Value: plist with :status, :message, and :timestamp.")

(defvar org-roam-todo-wf-project--async-processes (make-hash-table :test 'equal)
  "Active async validation processes.
Key: (project-root validation-name commit-sha)
Value: process object")

(defvar org-roam-todo-wf-project--worktree-hash-cache (make-hash-table :test 'equal)
  "Short-lived cache for worktree hashes to avoid repeated git calls.
Key: directory
Value: (timestamp . hash)")

(defconst org-roam-todo-wf-project--worktree-hash-ttl 2.0
  "Time-to-live in seconds for cached worktree hashes.")

(defun org-roam-todo-wf-project--get-head-sha (directory)
  "Get the HEAD commit SHA for git repo at DIRECTORY."
  (when (and directory (file-directory-p directory))
    (let ((default-directory directory))
      (string-trim
       (shell-command-to-string "git rev-parse HEAD 2>/dev/null")))))

(defun org-roam-todo-wf-project--worktree-dirty-p (directory)
  "Return non-nil if the worktree at DIRECTORY has uncommitted changes."
  (when (and directory (file-directory-p directory))
    (let ((default-directory directory))
      (not (string-empty-p
            (string-trim
             (shell-command-to-string "git status --porcelain 2>/dev/null")))))))

(defun org-roam-todo-wf-project--get-worktree-hash (directory)
  "Get a hash representing the current worktree state at DIRECTORY.
Returns \"clean\" if no uncommitted changes, otherwise returns a hash
of the diff output. This allows caching validation results that account
for uncommitted changes.

Results are cached briefly (2 seconds) to avoid repeated git calls
during a single status buffer refresh."
  (when (and directory (file-directory-p directory))
    ;; Check short-term cache first
    (let* ((cached (gethash directory org-roam-todo-wf-project--worktree-hash-cache))
           (cache-time (car cached))
           (cache-hash (cdr cached))
           (now (float-time)))
      (if (and cache-time
               (< (- now cache-time) org-roam-todo-wf-project--worktree-hash-ttl))
          ;; Return cached value
          cache-hash
        ;; Compute fresh hash
        (let ((default-directory directory)
              (hash (if (org-roam-todo-wf-project--worktree-dirty-p directory)
                        ;; Hash the diff to create a unique key for this worktree state
                        (let ((diff (shell-command-to-string "git diff HEAD 2>/dev/null")))
                          (if (string-empty-p diff)
                              ;; Only untracked files - hash the status instead
                              (secure-hash 'sha1 (shell-command-to-string "git status --porcelain 2>/dev/null"))
                            (secure-hash 'sha1 diff)))
                      "clean")))
          ;; Cache the result
          (puthash directory (cons now hash) org-roam-todo-wf-project--worktree-hash-cache)
          hash)))))

(defun org-roam-todo-wf-project--async-cache-key (project-root validation-name commit-sha worktree-hash)
  "Create cache key for async validation result.
WORKTREE-HASH is \"clean\" for committed state, or a hash of uncommitted changes."
  (list project-root validation-name commit-sha worktree-hash))

(defun org-roam-todo-wf-project--get-async-result (project-root validation-name commit-sha worktree-hash)
  "Get cached async result for validation, if any."
  (gethash (org-roam-todo-wf-project--async-cache-key project-root validation-name commit-sha worktree-hash)
           org-roam-todo-wf-project--async-results))

(defun org-roam-todo-wf-project--set-async-result (project-root validation-name commit-sha worktree-hash status &optional message)
  "Set cached async result for validation."
  (puthash (org-roam-todo-wf-project--async-cache-key project-root validation-name commit-sha worktree-hash)
           (list :status status :message message :timestamp (current-time))
           org-roam-todo-wf-project--async-results))

(defun org-roam-todo-wf-project--process-running-p (project-root validation-name commit-sha worktree-hash)
  "Check if an async process is already running for this validation."
  (when-let ((proc (gethash (org-roam-todo-wf-project--async-cache-key project-root validation-name commit-sha worktree-hash)
                            org-roam-todo-wf-project--async-processes)))
    (process-live-p proc)))

(defun org-roam-todo-wf-project--start-async-process (project-root validation-name commit-sha worktree-hash command directory message)
  "Start an async process for validation.
COMMAND is a list like (\"just\" \"test\").
DIRECTORY is where to run the command.
MESSAGE is displayed while pending."
  (let* ((cache-key (org-roam-todo-wf-project--async-cache-key project-root validation-name commit-sha worktree-hash))
         (output-buffer (generate-new-buffer (format " *async-validation-%s*" validation-name)))
         (default-directory directory)
         (proc (make-process
                :name (format "async-validation-%s" validation-name)
                :buffer output-buffer
                :command command
                :sentinel (lambda (proc event)
                            (org-roam-todo-wf-project--async-sentinel
                             proc event project-root validation-name commit-sha worktree-hash output-buffer)))))
    ;; Store process reference
    (puthash cache-key proc org-roam-todo-wf-project--async-processes)
    ;; Mark as running
    (org-roam-todo-wf-project--set-async-result project-root validation-name commit-sha worktree-hash :running message)
    proc))

(defvar org-roam-todo-wf-project--debug nil
  "Set to t to enable debug logging for async validations.")

(defun org-roam-todo-wf-project--debug-log (format-string &rest args)
  "Log debug message if debugging is enabled."
  (when org-roam-todo-wf-project--debug
    (apply #'message (concat "[async-val %s] " format-string)
           (format-time-string "%H:%M:%S.%3N") args)))

(defun org-roam-todo-wf-project--async-sentinel (proc event project-root validation-name commit-sha worktree-hash output-buffer)
  "Handle async process completion."
  (org-roam-todo-wf-project--debug-log "Sentinel called for %s: %s" validation-name (string-trim event))
  (when (memq (process-status proc) '(exit signal))
    (let* ((cache-key (org-roam-todo-wf-project--async-cache-key project-root validation-name commit-sha worktree-hash))
           (exit-code (process-exit-status proc))
           (output (with-current-buffer output-buffer
                     (buffer-string))))
      (org-roam-todo-wf-project--debug-log "Process %s finished with exit code %d" validation-name exit-code)
      ;; Remove from running processes
      (remhash cache-key org-roam-todo-wf-project--async-processes)
      ;; Store result based on exit code
      (if (= exit-code 0)
          (org-roam-todo-wf-project--set-async-result
           project-root validation-name commit-sha worktree-hash :pass "Passed")
        (org-roam-todo-wf-project--set-async-result
         project-root validation-name commit-sha worktree-hash :fail
         (format "Failed (exit %d):\n\n%s" exit-code (string-trim output))))
      ;; Clean up buffer
      (kill-buffer output-buffer)
      ;; Refresh only the relevant status buffer for this project
      (org-roam-todo-wf-project--debug-log "About to refresh status buffer for project %s" project-root)
      (org-roam-todo-wf-project--refresh-status-buffer-for-project project-root)
      (org-roam-todo-wf-project--debug-log "Done refreshing status buffer"))))

(defun org-roam-todo-wf-project--refresh-status-buffer-for-project (project-root)
  "Refresh only the status buffer for PROJECT-ROOT.
This avoids refreshing all status buffers, which is expensive."
  (org-roam-todo-wf-project--debug-log "Looking for status buffer matching project %s" project-root)
  (dolist (buf (buffer-list))
    (when (buffer-live-p buf)
      (with-current-buffer buf
        (when (and (eq major-mode 'org-roam-todo-status-mode)
                   (boundp 'org-roam-todo-status--current-todo)
                   org-roam-todo-status--current-todo)
          ;; Check if this buffer's TODO matches the project
          ;; The project-root could be either PROJECT_ROOT or WORKTREE_PATH
          (let ((todo-project-root (plist-get org-roam-todo-status--current-todo :project-root))
                (todo-worktree-path (plist-get org-roam-todo-status--current-todo :worktree-path)))
            (when (or (and todo-project-root (string-prefix-p (expand-file-name project-root) (expand-file-name todo-project-root)))
                      (and todo-worktree-path (string-prefix-p (expand-file-name project-root) (expand-file-name todo-worktree-path)))
                      (and todo-project-root (string-prefix-p (expand-file-name todo-project-root) (expand-file-name project-root)))
                      (and todo-worktree-path (string-prefix-p (expand-file-name todo-worktree-path) (expand-file-name project-root))))
              (org-roam-todo-wf-project--debug-log "Found matching buffer: %s" (buffer-name buf))
              (when (fboundp 'org-roam-todo-status-refresh)
                (org-roam-todo-status-refresh)))))))))

(cl-defun org-roam-todo-async-validation (&key command directory name message)
  "Run an async validation and return appropriate status.
COMMAND is a list like (\"just\" \"test\").
DIRECTORY is where to run the command (usually worktree path).
NAME is a unique identifier for this validation (used for caching).
MESSAGE is displayed while the validation is running.

Returns:
- :pass if cached result shows success for current commit
- (:fail \"message\") if cached result shows failure
- (:pending \"message\") if validation is running or needs to start

Example usage in .org-todo-config.el:
  (defun my-run-tests (event)
    (org-roam-todo-async-validation
     :command \\='(\"just\" \"test\")
     :directory (org-roam-todo-prop event \"WORKTREE_PATH\")
     :name \"tests\"
     :message \"Running tests...\"))"
  (unless directory
    (user-error "org-roam-todo-async-validation: :directory is required"))
  (unless command
    (user-error "org-roam-todo-async-validation: :command is required"))
  (let* ((project-root directory)  ; Use directory as project root for caching
         (validation-name (or name (format "%s" command)))
         (commit-sha (org-roam-todo-wf-project--get-head-sha directory))
         (worktree-hash (org-roam-todo-wf-project--get-worktree-hash directory))
         (pending-message (or message (format "Running %s..." validation-name))))
    (unless commit-sha
      (user-error "Could not determine git HEAD in %s" directory))
    ;; Check for cached result at this commit + worktree state
    (let ((cached (org-roam-todo-wf-project--get-async-result project-root validation-name commit-sha worktree-hash)))
      (if cached
          (pcase (plist-get cached :status)
            (:pass :pass)
            (:fail (list :fail (plist-get cached :message)))
            (:running (list :pending pending-message))
            (:pending (list :pending pending-message)))
        ;; No cached result - start async process if not already running
        (unless (org-roam-todo-wf-project--process-running-p project-root validation-name commit-sha worktree-hash)
          (org-roam-todo-wf-project--start-async-process
           project-root validation-name commit-sha worktree-hash command directory pending-message))
        (list :pending pending-message)))))

(defun org-roam-todo-wf-project-clear-async-cache (&optional project-root)
  "Clear async validation cache.
If PROJECT-ROOT is provided, only clear that project's cache.
Otherwise, clear all cached results."
  (interactive)
  (if project-root
      (maphash (lambda (key _val)
                 (when (equal (car key) project-root)
                   (remhash key org-roam-todo-wf-project--async-results)))
               org-roam-todo-wf-project--async-results)
    (clrhash org-roam-todo-wf-project--async-results))
  (message "Async validation cache cleared"))

(provide 'org-roam-todo-wf-project)
;;; org-roam-todo-wf-project.el ends here
