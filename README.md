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

Per-project settings via `org-roam-todo-project-config`:

```elisp
(setq org-roam-todo-project-config
      '(("my-project" . (:merge-workflow local-rebase
                         :rebase-target "main"
                         :branch-prefix "feat"))))
```

## License

MIT
