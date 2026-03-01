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

(provide 'org-roam-todo-wf-project)
;;; org-roam-todo-wf-project.el ends here
