# org-roam-todo Development Guide

## Project Overview

org-roam-todo is an Emacs package that integrates TODO management with org-roam and Claude AI agents. It provides:
- TODO capture and management integrated with org-roam
- Git worktree isolation for each TODO
- MCP tools for Claude agents to manage TODOs autonomously
- Workflow-driven merge processes (local-ff, github-pr)

## Current Refactoring: Hook-Based Workflow System

We are transforming `org-roam-todo-merge.el` into a flexible, hook-based workflow engine. See the full design spec in:
`/home/chadac/org-roam/projects/org-roam-todo/todo-feat_transform_org_roam_todo_merge_el_into_a_hook_based_todo_workflow_system.org`

### Key Design Decisions

1. **Implicit transitions** - No explicit transition map; forward is +1, backward is -1 (if allowed)
2. **Validation hooks** - `:validate-STATUS` hooks can reject transitions with errors
3. **Action hooks** - `:on-enter-STATUS`, `:on-exit-STATUS` run after validation
4. **Human-centric** - Agent delegation via `todo-delegate` is explicit, not automatic
5. **Subtask workflows** - `PARENT_TODO` and `TARGET_BRANCH` properties enable hierarchical tasks

### New Files Being Created

| File | Purpose |
|------|---------|
| `org-roam-todo-wf.el` | Core workflow engine |
| `org-roam-todo-wf-github.el` | GitHub PR workflow |
| `org-roam-todo-wf-local.el` | Local fast-forward workflow |
| `test/org-roam-todo-wf-test-utils.el` | Test utilities with mocker.el |
| `test/org-roam-todo-wf-test.el` | Core engine tests |
| `test/org-roam-todo-wf-validate-test.el` | Validation hook tests |
| `test/org-roam-todo-wf-tools-test.el` | MCP tool tests |
| `test/org-roam-todo-wf-github-test.el` | GitHub workflow tests |
| `test/org-roam-todo-wf-local-test.el` | Local workflow tests |

## Development Requirements

### TDD Approach (MANDATORY)

**All new code must follow Test-Driven Development:**

1. **Write failing tests FIRST** using `mocker.el` for mocking
2. Run tests to confirm they fail
3. Implement minimal code to make tests pass
4. Refactor if needed
5. Repeat

### Running Tests

```bash
# Run all tests
just test

# Run only workflow tests
just test-wf

# Run only unit tests (fast)
just test-unit

# Run integration tests (requires git)
just test-integration

# Run tests matching a pattern
just test-match "wf-test-valid"

# See available test tags
just test-tags
```

### Test Tags

Use ERT tags to categorize tests:
- `:unit` - Unit tests (no external dependencies)
- `:integration` - Integration tests (requires git)
- `:wf` - Workflow engine tests
- `:core` - Core workflow struct/transitions
- `:validation` - Validation hook tests
- `:tools` - MCP tool tests
- `:github` - GitHub PR workflow tests
- `:local` - Local fast-forward workflow tests
- `:git` - Tests requiring git operations

### Mocker.el Usage

We use `mocker.el` for mocking. Key patterns:

```elisp
;; Basic mocking
(mocker-let
    ((function-to-mock (arg1 arg2)
       ((:input '(expected-arg1 expected-arg2)
         :output return-value))))
  ;; test body
  )

;; Input matcher (for flexible matching)
(mocker-let
    ((shell-command-to-string (cmd)
       ((:input-matcher (lambda (c) (string-match-p "git status" c))
         :output ""))))
  ;; test body
  )

;; Output generator (for dynamic responses)
(mocker-let
    ((some-function (arg)
       ((:input-matcher #'always
         :output-generator (lambda (arg) (format "got %s" arg))))))
  ;; test body
  )

;; Multiple call expectations
(mocker-let
    ((function (arg)
       ((:input '("first") :output 1)
        (:input '("second") :output 2))))
  ;; test body - function will return 1 then 2
  )
```

### Test File Structure

Each test file should:

1. Require `ert`, `mocker`, and the module under test
2. Require `org-roam-todo-wf-test-utils` for helpers
3. Group related tests with `;;;; Section Comments`
4. Use descriptive test names: `wf-test-<area>-<behavior>`
5. Tag every test appropriately

Example:
```elisp
(ert-deftest wf-test-valid-forward-transition ()
  "Test that forward +1 transitions are always valid."
  :tags '(:unit :wf :transitions)
  ;; test body
  )
```

## Code Style

### Naming Conventions

- Public functions: `org-roam-todo-wf-<name>`
- Private functions: `org-roam-todo-wf--<name>`
- Workflow-specific: `org-roam-todo-wf-<workflow>--<name>` (e.g., `org-roam-todo-wf-github-pr--push-draft-pr`)
- Test functions: `wf-test-<area>-<behavior>` or `wf-<area>-test-<behavior>`
- Test variables: `org-roam-todo-wf-test--<name>`

### Struct Definitions

Use `cl-defstruct` for data structures:

```elisp
(cl-defstruct org-roam-todo-workflow
  "A TODO workflow definition."
  name           ; Symbol: 'github-pr, 'local-ff
  statuses       ; List of status strings in order
  hooks          ; Alist: ((event-symbol . (functions...)) ...)
  config)        ; Plist of workflow-specific settings
```

### Hook Functions

Hook functions receive an event struct and return:
- `nil` or `'ok` - Success, continue
- `'stop` - Success, skip remaining hooks
- `(signal 'error ...)` - Reject transition

```elisp
(defun org-roam-todo-wf--require-clean-worktree (event)
  "Validate: worktree has no uncommitted changes."
  (let* ((todo (org-roam-todo-event-todo event))
         (worktree-path (plist-get todo :worktree-path)))
    (let ((default-directory worktree-path))
      (unless (string-empty-p (shell-command-to-string "git status --porcelain"))
        (user-error "Worktree has uncommitted changes")))))
```

## Dependencies

### Required
- Emacs 28.1+
- org-roam 2.0+
- cl-lib (built-in)
- ert (built-in, for tests)

### Optional
- mocker.el (for tests) - https://github.com/sigma/mocker.el
- magit (for git UI integration)
- forge (for GitHub PR integration)

### Installing mocker.el

If not already installed:
```elisp
(use-package mocker
  :ensure t)
```

Or via straight.el:
```elisp
(straight-use-package 'mocker)
```

## Workflow Implementation Order

Follow this order for TDD implementation:

1. `test/org-roam-todo-wf-test-utils.el` - Test utilities
2. `test/org-roam-todo-wf-test.el` + `org-roam-todo-wf.el` - Core engine
3. `test/org-roam-todo-wf-validate-test.el` - Validation hooks
4. `test/org-roam-todo-wf-tools-test.el` - MCP tools
5. `test/org-roam-todo-wf-github-test.el` + `org-roam-todo-wf-github.el` - GitHub workflow
6. `test/org-roam-todo-wf-local-test.el` + `org-roam-todo-wf-local.el` - Local workflow

## Git Workflow

This worktree is for the workflow refactoring feature. Commits should:
- Be focused on one logical change
- Include test updates with implementation changes
- Reference the TODO file in commit messages when relevant

## Questions?

Refer to the design spec document for detailed architecture decisions and code examples.
