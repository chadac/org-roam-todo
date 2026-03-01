;;; .org-todo-config.el --- org-roam-todo project validations -*- lexical-binding: t; -*-

;; Per-project validations for org-roam-todo development.
;; These run before TODO status transitions to ensure code quality.

;;; Code:

;; ============================================================
;; Async Validations (run in background, cached by commit SHA)
;; ============================================================

(defun org-roam-todo--validate-tests-pass (event)
  "Validate: all unit tests pass before entering review.
Runs `just test` asynchronously. Results are cached per commit SHA."
  (when-let ((worktree-path (org-roam-todo-prop event "WORKTREE_PATH")))
    (org-roam-todo-async-validation
     :command '("just" "test")
     :directory worktree-path
     :name "tests"
     :message "Running tests...")))

(defun org-roam-todo--validate-byte-compile (event)
  "Validate: elisp files byte-compile without warnings.
Runs `just compile` asynchronously. Results are cached per commit SHA."
  (when-let ((worktree-path (org-roam-todo-prop event "WORKTREE_PATH")))
    (org-roam-todo-async-validation
     :command '("just" "compile")
     :directory worktree-path
     :name "compile"
     :message "Byte-compiling...")))

(defun org-roam-todo--validate-no-circular-deps (event)
  "Validate: no circular dependencies between modules.
Runs `just check-deps` asynchronously. Results are cached per commit SHA."
  (when-let ((worktree-path (org-roam-todo-prop event "WORKTREE_PATH")))
    (org-roam-todo-async-validation
     :command '("just" "check-deps")
     :directory worktree-path
     :name "check-deps"
     :message "Checking dependencies...")))

(defun org-roam-todo--validate-all-modules-required (event)
  "Validate: all modules are required somewhere (no orphans).
Runs `just check-requires` asynchronously. Results are cached per commit SHA."
  (when-let ((worktree-path (org-roam-todo-prop event "WORKTREE_PATH")))
    (org-roam-todo-async-validation
     :command '("just" "check-requires")
     :directory worktree-path
     :name "check-requires"
     :message "Checking module requires...")))

;; Register validations
(org-roam-todo-project-validations
 ;; Before entering review: run tests and compile
 :validate-review (org-roam-todo--validate-tests-pass
                   org-roam-todo--validate-byte-compile)
 ;; Before entering done: also check dependencies
 :validate-done (org-roam-todo--validate-tests-pass
                 org-roam-todo--validate-byte-compile
                 org-roam-todo--validate-no-circular-deps
                 org-roam-todo--validate-all-modules-required))

;;; .org-todo-config.el ends here
