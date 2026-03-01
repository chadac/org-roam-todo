# org-roam-todo

Org-roam based TODO management with optional Claude AI integration.

## Features

- Create TODO nodes linked to projectile projects
- Track TODO status: draft → active → review → done/rejected
- Git worktree isolation for each TODO task
- Integration with Claude AI agents for autonomous task execution
- Customizable merge workflows (local-rebase, github-pr)

## Installation

Add to your load-path and require:

```elisp
(use-package org-roam-todo
  :load-path "~/.emacs.d/lisp/org-roam-todo"
  :after org-roam
  :config
  (org-roam-todo-setup-global-keybindings))
```

## Dependencies

- Emacs 28.1+
- org-roam 2.0+
- projectile (optional, for project detection)
- magit (optional, for git operations)
- claude-agent (optional, for AI integration)

## Usage

### Key Bindings (after setup)

- `C-c n t t` - Capture new TODO for a project
- `C-c n t l` - List all TODOs
- `C-c n t c` - Start Claude on selected TODO

### From a TODO buffer

- `C-c c t` - Send to main Claude session
- `C-c c w` - Create worktree + spawn Claude agent

### TODO List Buffer

- `RET` - Open TODO org file
- `w` - Create/open worktree
- `c` - Spawn Claude agent
- `m` - Run merge workflow
- `d/a/r/u` - Mark as done/active/rejected/draft

## Configuration

### Global Project Settings

Per-project settings via `org-roam-todo-project-config` in your init.el:

```elisp
(setq org-roam-todo-project-config
      '(("my-project" . (:merge-workflow local-rebase
                         :rebase-target "main"
                         :branch-prefix "feat"))))
```

### Per-Project Custom Validations

You can define custom validations that run before TODO status transitions.
Create a `.org-todo-config.el` file in your project root:

```elisp
;; ~/.emacs.d/lisp/my-project/.org-todo-config.el

;; Define a validation function
(defun my-project-run-tests (event)
  "Ensure tests pass before entering review."
  (let ((worktree-path (org-roam-todo-prop event "WORKTREE_PATH")))
    (when worktree-path
      (let* ((default-directory worktree-path)
             (result (call-process "npm" nil nil nil "test")))
        (unless (= 0 result)
          (user-error "Tests failed! Run 'npm test' to see details."))))))

;; Register validations
(org-roam-todo-project-validations
 ;; Run before ANY status transition
 :global (my-project-lint-check)
 ;; Run only before entering "review" status
 :validate-review (my-project-run-tests)
 ;; Multiple validations for "done"
 :validate-done (my-project-check-coverage
                 my-project-check-docs))
```

Validation functions receive an `event` parameter and should:
- Return `nil` or `:pass` on success
- Signal `user-error` on failure (with a helpful message)
- Return `(:pending "message")` for async validations

The config file is automatically loaded when processing TODOs for that project.
You can choose to commit it (shared with team) or add it to `.gitignore` (personal only).

## License

MIT
