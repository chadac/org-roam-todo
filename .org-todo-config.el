;;; .org-todo-config.el --- org-roam-todo project validations -*- lexical-binding: t; -*-

;; Per-project validations for org-roam-todo development.
;; These run before TODO status transitions to ensure code quality.

;;; Code:

(defun org-roam-todo--validate-tests-pass (event)
  "Validate: all unit tests pass before entering review.
Runs `just test` which executes the full test suite."
  (let ((worktree-path (org-roam-todo-prop event "WORKTREE_PATH")))
    (when worktree-path
      (let ((default-directory worktree-path))
        (message "Running tests in %s..." worktree-path)
        (let ((result (call-process "just" nil nil nil "test")))
          (unless (= 0 result)
            (user-error "Tests failed! Run 'just test-verbose' to see details.

HOW TO FIX:
1. Run tests locally: just test-verbose
2. Fix any failing tests
3. Try advancing again")))))))

(defun org-roam-todo--validate-byte-compile (event)
  "Validate: elisp files byte-compile without warnings."
  (let ((worktree-path (org-roam-todo-prop event "WORKTREE_PATH")))
    (when worktree-path
      (let ((default-directory worktree-path))
        (message "Byte-compiling in %s..." worktree-path)
        (let ((result (call-process "just" nil nil nil "compile")))
          (unless (= 0 result)
            (user-error "Byte-compilation failed!

HOW TO FIX:
1. Run: just compile
2. Fix any compilation warnings/errors
3. Try advancing again")))))))

(defun org-roam-todo--validate-no-circular-deps (event)
  "Validate: no circular dependencies between modules."
  (let ((worktree-path (org-roam-todo-prop event "WORKTREE_PATH")))
    (when worktree-path
      (let ((default-directory worktree-path))
        (message "Checking dependencies in %s..." worktree-path)
        (let ((result (call-process "just" nil nil nil "check-deps")))
          (unless (= 0 result)
            (user-error "Circular dependency detected!

HOW TO FIX:
1. Run: just check-deps
2. Refactor to eliminate circular requires
3. Try advancing again")))))))

(defun org-roam-todo--validate-all-modules-required (event)
  "Validate: all modules are required somewhere (no orphans)."
  (let ((worktree-path (org-roam-todo-prop event "WORKTREE_PATH")))
    (when worktree-path
      (let ((default-directory worktree-path))
        (message "Checking module requires in %s..." worktree-path)
        (let ((result (call-process "just" nil nil nil "check-requires")))
          (unless (= 0 result)
            (user-error "Orphaned module detected!

HOW TO FIX:
1. Run: just check-requires
2. Add missing (require 'module-name) to org-roam-todo.el or another module
3. Try advancing again")))))))

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
