;;; org-roam-todo-core.el --- Core utilities for org-roam-todo -*- lexical-binding: t; -*-

;; Author: chadac <chad@cacrawford.org>
;; Version: 0.2.0
;; Package-Requires: ((emacs "28.1") (org-roam "2.0"))
;; Keywords: org-roam todo
;; URL: https://github.com/chadac/org-roam-todo
;; SPDX-License-Identifier: MIT

;;; Commentary:

;; Core utilities for org-roam-todo.  This module provides:
;; - Customization variables (worktree-directory, project-config, etc.)
;; - Project/worktree path utilities (slugify, calc-worktree-path, etc.)
;; - TODO querying (query-todos, get-property, set-property)
;; - Capture templates (capture, capture-project)
;; - Agent configuration (allowed-tools, worktree-copy-patterns)
;;
;; This is the foundational module required by all other org-roam-todo modules.

;;; Code:

(require 'cl-lib)

;; Soft dependency on org-roam - only needed for capture and query
(declare-function org-roam-db-query "org-roam-db")
(declare-function org-roam-capture "org-roam-capture")
(defvar org-roam-directory)
(defvar org-roam-capture-templates)

;; Forward declarations for optional features
(declare-function projectile-project-root "projectile")
(declare-function projectile-known-projects "projectile")

;;;; Customization

(defgroup org-roam-todo nil
  "Org-roam TODO management with Claude integration."
  :group 'org-roam
  :group 'tools)

(defcustom org-roam-todo-worktree-directory
  (expand-file-name "worktrees" (or (getenv "XDG_DATA_HOME") "~/.local/share"))
  "Base directory for storing worktrees.
Worktrees are created as {this-dir}/{project-name}/{branch-slug}/"
  :type 'directory
  :group 'org-roam-todo)

(defcustom org-roam-todo-branch-prefix "feat"
  "Prefix for generated branch names.
Branch names are formatted as {prefix}/{slug}.
For example, with prefix \"chadac\", a TODO titled \"Add feature\"
would create branch \"chadac/add_feature\".

Preferred: use `:branch-prefix' in `org-roam-todo-project-config' instead."
  :type 'string
  :group 'org-roam-todo)

(defcustom org-roam-todo-project-config nil
  "Per-project configuration alist.
Each entry is (PROJECT-NAME . PLIST) where PLIST can contain:
  :merge-workflow      - Symbol: workflow name or function
  :rebase-target       - String: branch to rebase onto
  :base-branch         - String: ref for new worktree branches
  :branch-prefix       - String: prefix for branch names
  :fetch-before-create - Boolean: fetch before creating worktree
  :cleanup-after-merge - Boolean: clean up worktree after merge"
  :type '(alist :key-type string
                :value-type (plist :key-type keyword :value-type sexp))
  :group 'org-roam-todo)

(defun org-roam-todo-project-config-get (project-name key &optional default)
  "Get config KEY for PROJECT-NAME from `org-roam-todo-project-config'.
Returns the value associated with KEY in the project's plist, or DEFAULT
if the project has no entry or the key is not set.

Uses `plist-member' to distinguish between a key set to nil and a key
that is absent (falling back to DEFAULT only when absent)."
  (let ((entry (cdr (assoc project-name org-roam-todo-project-config))))
    (if (and entry (plist-member entry key))
        (plist-get entry key)
      default)))

(defcustom org-roam-todo-worktree-base-branch nil
  "Base branch/ref for new worktree branches.
When non-nil, new branches are created from this ref (e.g. \"origin/main\").
When nil, branches from the current HEAD.
Can be set per-project via .dir-locals.el.

Preferred: use `:base-branch' in `org-roam-todo-project-config' instead."
  :type '(choice (const :tag "Current HEAD" nil) string)
  :group 'org-roam-todo)

(defcustom org-roam-todo-worktree-fetch-before-create t
  "Whether to run `git fetch' before creating a worktree.
When non-nil, fetches from the remote before creating the worktree
to ensure the base branch is up-to-date.
Can be set per-project via .dir-locals.el.

Preferred: use `:fetch-before-create' in `org-roam-todo-project-config' instead."
  :type 'boolean
  :group 'org-roam-todo)

(defcustom org-roam-todo-agent-allowed-tools
  '("Read(**)"
    "Glob(**)"
    "Grep(**)"
    "Bash(git *)"
    "Bash(npm *)"
    "Bash(npx *)"
    "Bash(yarn *)"
    "Bash(pnpm *)"
    "Bash(make *)"
    "Bash(cargo *)"
    "Bash(uv *)"
    "Bash(pytest *)"
    "Bash(python *)"
    "Bash(ruff *)"
    "Bash(ls *)"
    "Bash(find *)"
    "Bash(cat *)"
    "Bash(head *)"
    "Bash(tail *)"
    "Bash(grep *)"
    "Bash(rg *)"
    "Bash(wc *)"
    "Bash(diff *)"
    "Bash(tree *)"
    "mcp__emacs__read_file"
    "mcp__emacs__read_buffer"
    "mcp__emacs__magit_status"
    "mcp__emacs__magit_diff"
    "mcp__emacs__magit_log"
    "mcp__emacs__magit_stage"
    "mcp__emacs__magit_commit_propose"
    "mcp__emacs__todo_start"
    "mcp__emacs__todo_advance"
    "mcp__emacs__todo_regress"
    "mcp__emacs__todo_reject"
    "mcp__emacs__kb_search"
    "mcp__emacs__kb_get"
    "mcp__emacs__edit"
    "mcp__emacs__unlock"
    "mcp__emacs__request_attention")
  "Base list of tools to pre-authorize for TODO worktree agents.
These are combined with `org-roam-todo-agent-allowed-tools-extra' at runtime.
Uses Claude Code permission pattern syntax:
- ToolName(**) for recursive file access
- Bash(pattern*) for specific bash commands
- mcp__server__tool for MCP tools"
  :type '(repeat string)
  :group 'org-roam-todo)

(defcustom org-roam-todo-agent-allowed-tools-extra '()
  "Additional allowed tools, appended to `org-roam-todo-agent-allowed-tools'.
Intended for use in .dir-locals.el so worktree-specific tools can be
added without overwriting the base list."
  :type '(repeat string)
  :safe #'listp
  :group 'org-roam-todo)

(defun org-roam-todo-effective-agent-allowed-tools ()
  "Return the effective allowed tools list (base + extra).
Combines `org-roam-todo-agent-allowed-tools' and
`org-roam-todo-agent-allowed-tools-extra'."
  (append org-roam-todo-agent-allowed-tools
          org-roam-todo-agent-allowed-tools-extra))

(defcustom org-roam-todo-worktree-copy-patterns
  '(".claude/settings.local.json" ".dir-locals.el" ".envrc")
  "List of file paths (relative to project root) to copy to new worktrees.
These files are copied after worktree creation to preserve permissions
and settings.  Supports glob patterns like \".claude/*.json\"."
  :type '(repeat string)
  :group 'org-roam-todo)

;;;; Status Order

(defconst org-roam-todo-status-order
  '("draft" "active" "review" "done" "rejected")
  "Default order of TODO statuses for sorting.")

;;;; Project Utilities

(defun org-roam-todo--worktree-main-repo (dir)
  "If DIR is a git worktree, return the main repository path.
Otherwise return nil."
  (let ((git-dir (expand-file-name ".git" dir)))
    (when (file-regular-p git-dir)
      ;; .git is a file, meaning this is a worktree
      (with-temp-buffer
        (insert-file-contents git-dir)
        (when (re-search-forward "gitdir: \\(.+\\)" nil t)
          (let ((gitdir (match-string 1)))
            ;; gitdir points to .git/worktrees/<name>
            (when (string-match "/\\.git/worktrees/" gitdir)
              (let ((main-git-dir (substring gitdir 0 (match-beginning 0))))
                (expand-file-name main-git-dir)))))))))

(defun org-roam-todo-infer-project ()
  "Infer the current project from context.
Checks for worktrees and maps them back to the main repository."
  (let* ((current-dir (or (and (fboundp 'projectile-project-root)
                               (projectile-project-root))
                          default-directory))
         (main-repo (org-roam-todo--worktree-main-repo current-dir)))
    (or main-repo current-dir)))

(defun org-roam-todo-project-name (project-root)
  "Get short project name from PROJECT-ROOT."
  (file-name-nondirectory (directory-file-name project-root)))

;;;; Slug and Branch Helpers

(defun org-roam-todo-slugify (text)
  "Convert TEXT to a branch-safe slug."
  (let* ((slug (downcase text))
         (slug (replace-regexp-in-string "[^a-z0-9]+" "-" slug))
         (slug (replace-regexp-in-string "^-\\|-$" "" slug)))
    slug))

(defun org-roam-todo-default-branch-name (title &optional project-name)
  "Generate default branch name from TITLE.
When PROJECT-NAME is non-nil, checks `org-roam-todo-project-config'
for a `:branch-prefix' override before using `org-roam-todo-branch-prefix'."
  (let* ((prefix (if project-name
                     (org-roam-todo-project-config-get
                      project-name :branch-prefix org-roam-todo-branch-prefix)
                   org-roam-todo-branch-prefix))
         (slug (org-roam-todo-slugify title)))
    (format "%s/%s" prefix slug)))

;;;; Worktree Path Utilities

(defun org-roam-todo-calc-worktree-path (project-root branch-name)
  "Calculate worktree path for PROJECT-ROOT and BRANCH-NAME."
  (let* ((project-name (org-roam-todo-project-name project-root))
         (branch-slug (org-roam-todo-slugify branch-name)))
    (expand-file-name
     (concat project-name "/" branch-slug)
     org-roam-todo-worktree-directory)))

(defun org-roam-todo-worktree-exists-p (worktree-path)
  "Return non-nil if WORKTREE-PATH exists and is a git worktree."
  (and (file-directory-p worktree-path)
       (file-exists-p (expand-file-name ".git" worktree-path))))

(defun org-roam-todo-branch-exists-p (project-root branch-name)
  "Return non-nil if BRANCH-NAME exists in PROJECT-ROOT."
  (let ((default-directory project-root))
    (= 0 (call-process "git" nil nil nil "rev-parse" "--verify" branch-name))))

(defun org-roam-todo-working-directory (todo)
  "Get the working directory for TODO.
Resolution order:
1. TODO's own worktree path (if it exists)
2. Parent TODO's worktree path (if :parent-todo is set and has worktree)
3. Project root as fallback"
  (or
   ;; 1. TODO's own worktree
   (let ((worktree-path (plist-get todo :worktree-path)))
     (when (and worktree-path (org-roam-todo-worktree-exists-p worktree-path))
       worktree-path))
   ;; 2. Parent TODO's worktree
   (when-let ((parent-file (plist-get todo :parent-todo)))
     (when (file-exists-p parent-file)
       (with-temp-buffer
         (insert-file-contents parent-file)
         (when (re-search-forward "^:WORKTREE_PATH:\\s-*\\(.+\\)" nil t)
           (let ((path (string-trim (match-string 1))))
             (when (file-directory-p path)
               path))))))
   ;; 3. Project root fallback
   (plist-get todo :project-root)))

;;;; Node Property Helpers
(declare-function org-entry-get "org" (pom property &optional inherit literal-nil))
(declare-function org-set-property "org" (property value))

(defun org-roam-todo-get-property (property)
  "Get PROPERTY from the current org-roam node."
  (org-entry-get (point-min) property))

(defun org-roam-todo-set-property (property value)
  "Set PROPERTY to VALUE in the current org-roam node."
  (save-excursion
    (goto-char (point-min))
    (org-set-property property value)))

(defun org-roam-todo-node-p ()
  "Return non-nil if current buffer is an org-roam TODO node."
  (and (derived-mode-p 'org-mode)
       (buffer-file-name)
       (save-excursion
         (goto-char (point-min))
         (re-search-forward "^:PROJECT_ROOT:" nil t))))

(defun org-roam-todo-set-file-property (file property value)
  "Set PROPERTY to VALUE in TODO FILE.
Opens the file, sets the property in the PROPERTIES drawer, and saves."
  (when (and file (file-exists-p file))
    (with-current-buffer (find-file-noselect file)
      (save-excursion
        (goto-char (point-min))
        (if (re-search-forward (format "^:%s:.*$" (regexp-quote property)) nil t)
            (replace-match (format ":%s: %s" property value))
          ;; Property doesn't exist, add it after :PROPERTIES:
          (goto-char (point-min))
          (when (re-search-forward "^:PROPERTIES:" nil t)
            (forward-line 1)
            (insert (format ":%s: %s\n" property value)))))
      (save-buffer))))

(defun org-roam-todo-get-file-property (file property)
  "Get PROPERTY value from TODO FILE.
PROPERTY can be a property drawer property (e.g. \"PROJECT_ROOT\")
or \"TITLE\" to get the #+title: value.
Returns nil if property not found."
  (when (and file (file-exists-p file))
    (with-temp-buffer
      (insert-file-contents file nil 0 2000)
      (goto-char (point-min))
      (if (string= property "TITLE")
          ;; Special case: read #+title: line
          (when (re-search-forward "^#\\+title:\\s-*\\(.+\\)$" nil t)
            (string-trim (match-string 1)))
        ;; Normal case: read from property drawer
        (when (re-search-forward (format "^:%s:\\s-*\\(.+\\)$" (regexp-quote property)) nil t)
          (string-trim (match-string 1)))))))

(defun org-roam-todo-get-file-section (file heading)
  "Get content of section with HEADING from TODO FILE.
HEADING is the section name without the asterisks (e.g. \"Acceptance Criteria\").
Returns the section content as a string, or nil if not found.
Searches for both level-1 (* Heading) and level-2 (** Heading) sections.
Content stops at the next same-level or higher heading."
  (when (and file (file-exists-p file))
    (with-temp-buffer
      (insert-file-contents file)
      (goto-char (point-min))
      ;; Find the heading at level 1 or 2
      (when (re-search-forward (format "^\\(\\*\\*?\\) %s\\s-*$" (regexp-quote heading)) nil t)
        (let ((level (length (match-string 1))))
          (forward-line 1)
          (let ((start (point))
                ;; Stop at next heading of same level or higher (fewer or equal stars)
                (end (or (save-excursion
                           (when (re-search-forward (format "^\\*\\{1,%d\\} " level) nil t)
                             (line-beginning-position)))
                         (point-max))))
            (string-trim (buffer-substring-no-properties start end))))))))

(defun org-roam-todo-get-first-section (file)
  "Get the first section content from TODO FILE.
Returns a cons of (heading . content) for the first heading found.
Searches for both level-1 and level-2 headings."
  (when (and file (file-exists-p file))
    (with-temp-buffer
      (insert-file-contents file)
      (goto-char (point-min))
      ;; Find first heading (level 1 or 2)
      (when (re-search-forward "^\\(\\*\\*?\\) \\(.+\\)$" nil t)
        (let ((level (length (match-string 1)))
              (heading (match-string 2)))
          (forward-line 1)
          (let ((start (point))
                ;; Stop at next heading of same level or higher
                (end (or (save-excursion
                           (when (re-search-forward (format "^\\*\\{1,%d\\} " level) nil t)
                             (line-beginning-position)))
                         (point-max))))
            (cons heading (string-trim (buffer-substring-no-properties start end)))))))))

(defun org-roam-todo--resolve-file (source)
  "Extract the TODO file path from SOURCE.
SOURCE can be:
- A string (file path) - returned as-is
- A plist with :file key - extracts :file
- An org-roam-todo-event struct - extracts file from the todo plist"
  (cond
   ((stringp source) source)
   ((and (listp source) (plist-get source :file))
    (plist-get source :file))
   ((org-roam-todo-event-p source)
    (plist-get (org-roam-todo-event-todo source) :file))
   (t nil)))

(defun org-roam-todo-prop (source property)
  "Get PROPERTY from TODO SOURCE, reading fresh from file.
SOURCE can be a file path, plist with :file, or org-roam-todo-event.
PROPERTY is the property name (string, e.g. \"WORKTREE_PATH\").
Always reads from the file to get current values."
  (when-let ((file (org-roam-todo--resolve-file source)))
    (org-roam-todo-get-file-property file property)))

(defun org-roam-todo-set-prop (source property value)
  "Set PROPERTY to VALUE in TODO SOURCE.
SOURCE can be a file path, plist with :file, or org-roam-todo-event.
PROPERTY is the property name (string).
VALUE is the value to set."
  (when-let ((file (org-roam-todo--resolve-file source)))
    (org-roam-todo-set-file-property file property value)))

;;;; TODO Querying

(defun org-roam-todo--status-sort-key (status)
  "Return sort key for STATUS (lower = first)."
  (or (cl-position (or status "draft") org-roam-todo-status-order :test #'string=) 99))

(defun org-roam-todo-query-todos (&optional project-filter)
  "Query all TODO nodes from org-roam, optionally filtered by PROJECT-FILTER.
Returns a list of plists with :id, :title, :project, :project-name,
:project-root, :status, :file, :created, :worktree-path, :worktree-branch,
:worktree-model."
  (let* ((todos '())
         (nodes (org-roam-db-query
                 [:select [nodes:id nodes:file nodes:title]
                  :from nodes
                  :where (and (like nodes:file "%/todo-%.org")
                              (= nodes:level 0))])))
    (dolist (row nodes)
      (let* ((id (nth 0 row))
             (file (nth 1 row))
             (title (nth 2 row)))
        (when (file-exists-p file)
          (with-temp-buffer
            (insert-file-contents file nil 0 3000)
            (let ((project (when (re-search-forward "^:PROJECT_NAME:\\s-*\\(.+\\)$" nil t)
                             (match-string 1)))
                  (project-root (progn
                                  (goto-char (point-min))
                                  (when (re-search-forward "^:PROJECT_ROOT:\\s-*\\(.+\\)$" nil t)
                                    (match-string 1))))
                  (status (progn
                            (goto-char (point-min))
                            (when (re-search-forward "^:STATUS:\\s-*\\(.+\\)$" nil t)
                              (match-string 1))))
                  (created (progn
                             (goto-char (point-min))
                             (when (re-search-forward "^:CREATED:\\s-*\\(.+\\)$" nil t)
                               (match-string 1))))
                  (worktree-path (progn
                                   (goto-char (point-min))
                                   (when (re-search-forward "^:WORKTREE_PATH:\\s-*\\(.+\\)$" nil t)
                                     (match-string 1))))
                  (worktree-branch (progn
                                     (goto-char (point-min))
                                     (when (re-search-forward "^:WORKTREE_BRANCH:\\s-*\\(.+\\)$" nil t)
                                       (match-string 1))))
                  (worktree-model (progn
                                    (goto-char (point-min))
                                    (when (re-search-forward "^:WORKTREE_MODEL:\\s-*\\(.+\\)$" nil t)
                                      (match-string 1))))
                  (claude-session (progn
                                    (goto-char (point-min))
                                    (when (re-search-forward "^:CLAUDE_SESSION_ID:\\s-*\\(.+\\)$" nil t)
                                      (match-string 1)))))
              (when (and project
                         (or (null project-filter)
                             (string= project project-filter)
                             (string= project
                                      (file-name-nondirectory
                                       (directory-file-name (expand-file-name project-filter))))
                             (and project-root
                                  (string= (directory-file-name (expand-file-name project-root))
                                           (directory-file-name (expand-file-name project-filter))))))
                (push (list :id id
                            :title title
                            :project project
                            :project-name project
                            :project-root project-root
                            :status (or status "draft")
                            :file file
                            :created (or created "")
                            :worktree-path worktree-path
                            :worktree-branch worktree-branch
                            :worktree-model worktree-model
                            :claude-session claude-session)
                      todos)))))))
    ;; Sort by status order, then by created date (newest first)
    (sort todos
          (lambda (a b)
            (let ((status-a (org-roam-todo--status-sort-key (plist-get a :status)))
                  (status-b (org-roam-todo--status-sort-key (plist-get b :status))))
              (if (= status-a status-b)
                  (string> (plist-get a :created) (plist-get b :created))
                (< status-a status-b)))))))

(defun org-roam-todo-read-commit-message (file)
  "Read the commit message from TODO FILE's Commit Message section.
Returns the content between #+begin_src and #+end_src, or nil if not found."
  (when (file-exists-p file)
    (with-temp-buffer
      (insert-file-contents file)
      (goto-char (point-min))
      (when (re-search-forward "^\\*\\* Commit Message" nil t)
        (when (re-search-forward "^#\\+begin_src" nil t)
          (forward-line 1)
          (let ((start (point)))
            (when (re-search-forward "^#\\+end_src" nil t)
              (string-trim (buffer-substring-no-properties start (line-beginning-position))))))))))

(defun org-roam-todo-get-full-content (file)
  "Get the full content of a TODO FILE after the filetags line."
  (when (and file (file-exists-p file))
    (with-temp-buffer
      (insert-file-contents file)
      (goto-char (point-min))
      (when (re-search-forward "^#\\+filetags:" nil t)
        (forward-line 1)
        (string-trim (buffer-substring-no-properties (point) (point-max)))))))

;;;; TODO Section Parsing

(defun org-roam-todo-parse-sections (file)
  "Parse sections from TODO FILE.
Returns a list of plists, each with:
  :title      - Section heading text (without stars)
  :level      - Heading level (number of stars)
  :start-line - Line number where section starts (1-indexed)
  :end-line   - Line number where section ends (1-indexed, exclusive)
  :length     - Number of lines in section body"
  (when (and file (file-exists-p file))
    (with-temp-buffer
      (insert-file-contents file)
      (let ((sections '())
            (line-num 0)
            (prev-section nil))
        (goto-char (point-min))
        (while (not (eobp))
          (setq line-num (1+ line-num))
          (when (looking-at "^\\(\\*+\\)\\s-+\\(.+\\)$")
            ;; Close previous section
            (when prev-section
              (plist-put prev-section :end-line line-num)
              (plist-put prev-section :length
                         (- line-num (plist-get prev-section :start-line) 1)))
            ;; Start new section
            (let ((level (length (match-string 1)))
                  (title (match-string 2)))
              (setq prev-section
                    (list :title title
                          :level level
                          :start-line line-num
                          :end-line nil
                          :length nil))
              (push prev-section sections)))
          (forward-line 1))
        ;; Close final section
        (when prev-section
          (plist-put prev-section :end-line (1+ line-num))
          (plist-put prev-section :length
                     (- (1+ line-num) (plist-get prev-section :start-line) 1)))
        (nreverse sections)))))

(defun org-roam-todo-get-section-content (file section-title)
  "Get content of SECTION-TITLE from TODO FILE.
Returns the text between the section heading and the next heading."
  (when (and file (file-exists-p file))
    (with-temp-buffer
      (insert-file-contents file)
      (goto-char (point-min))
      (when (re-search-forward (format "^\\*+\\s-+%s\\s-*$"
                                       (regexp-quote section-title))
                               nil t)
        (forward-line 1)
        (let ((start (point)))
          (if (re-search-forward "^\\*" nil t)
              (progn
                (beginning-of-line)
                (string-trim (buffer-substring-no-properties start (point))))
            (string-trim (buffer-substring-no-properties start (point-max)))))))))

;;;; Acceptance Criteria Parsing

(defun org-roam-todo-parse-acceptance-criteria (file)
  "Parse acceptance criteria from TODO FILE.
Returns a list of plists, each with:
  :index   - 1-based index of the criterion
  :text    - The criterion text (without checkbox)
  :checked - Whether the criterion is complete (t or nil)
  :line    - Line number (1-indexed)"
  (when (and file (file-exists-p file))
    (with-temp-buffer
      (insert-file-contents file)
      (goto-char (point-min))
      ;; Find the Acceptance Criteria section
      (when (re-search-forward "^\\*+\\s-+Acceptance Criteria\\s-*$" nil t)
        (forward-line 1)
        (let ((criteria '())
              (index 0)
              (section-end (save-excursion
                             (if (re-search-forward "^\\*" nil t)
                                 (line-beginning-position)
                               (point-max)))))
          (while (and (< (point) section-end)
                      (not (eobp)))
            (when (looking-at "^\\s-*-\\s-+\\(\\[\\([Xx ]\\)\\]\\)\\s-+\\(.+\\)$")
              (setq index (1+ index))
              (let ((checked (string-match-p "[Xx]" (match-string 2)))
                    (text (string-trim (match-string 3)))
                    (line (line-number-at-pos)))
                (push (list :index index
                            :text text
                            :checked (if checked t nil)
                            :line line)
                      criteria)))
            (forward-line 1))
          (nreverse criteria))))))

(defun org-roam-todo-get-acceptance-criteria (file)
  "Get acceptance criteria from TODO FILE as formatted string.
Returns a numbered list suitable for display, e.g.:
  1. [x] First criterion
  2. [ ] Second criterion"
  (let ((criteria (org-roam-todo-parse-acceptance-criteria file)))
    (if criteria
        (mapconcat
         (lambda (c)
           (format "%d. [%s] %s"
                   (plist-get c :index)
                   (if (plist-get c :checked) "x" " ")
                   (plist-get c :text)))
         criteria
         "\n")
      "No acceptance criteria found.")))

(defun org-roam-todo-get-incomplete-criteria (file)
  "Get incomplete acceptance criteria from TODO FILE.
Returns a list of plists for criteria where :checked is nil."
  (seq-filter (lambda (c) (not (plist-get c :checked)))
              (org-roam-todo-parse-acceptance-criteria file)))

(defun org-roam-todo-all-criteria-complete-p (file)
  "Return non-nil if all acceptance criteria in FILE are complete.
Returns t if no criteria exist (vacuously true)."
  (let ((criteria (org-roam-todo-parse-acceptance-criteria file)))
    (or (null criteria)
        (seq-every-p (lambda (c) (plist-get c :checked)) criteria))))

(defun org-roam-todo-mark-criterion-complete (file index-or-text &optional uncheck)
  "Mark acceptance criterion in FILE as complete.
INDEX-OR-TEXT can be:
  - An integer: the 1-based index of the criterion
  - A string: partial match against criterion text
If UNCHECK is non-nil, marks it as incomplete instead.
Returns t on success, nil if criterion not found."
  (when (and file (file-exists-p file))
    (let ((criteria (org-roam-todo-parse-acceptance-criteria file))
          (target-line nil))
      ;; Find the criterion to update
      (cond
       ((integerp index-or-text)
        (when-let ((c (seq-find (lambda (c) (= (plist-get c :index) index-or-text))
                                criteria)))
          (setq target-line (plist-get c :line))))
       ((stringp index-or-text)
        (when-let ((c (seq-find (lambda (c)
                                  (string-match-p (regexp-quote index-or-text)
                                                  (plist-get c :text)))
                                criteria)))
          (setq target-line (plist-get c :line)))))
      ;; Update the file
      (when target-line
        (with-current-buffer (find-file-noselect file)
          (save-excursion
            (goto-char (point-min))
            (forward-line (1- target-line))
            (when (looking-at "^\\(\\s-*-\\s-+\\)\\[\\([Xx ]\\)\\]")
              (replace-match (concat (match-string 1)
                                     (if uncheck "[ ]" "[x]")))
              (save-buffer)
              t)))))))

(defun org-roam-todo-mark-criteria-complete (file indices)
  "Mark multiple acceptance criteria in FILE as complete.
INDICES is a list of 1-based indices to mark complete.
Returns the number of criteria successfully marked."
  (let ((count 0))
    (dolist (idx indices)
      (when (org-roam-todo-mark-criterion-complete file idx)
        (setq count (1+ count))))
    count))

;;;; TODO Capture

(defun org-roam-todo--org-roam-projects-dir ()
  "Return the expanded path to the org-roam projects directory."
  (expand-file-name "projects" org-roam-directory))

(defun org-roam-todo--is-org-roam-projects-path-p (path)
  "Return non-nil if PATH is inside the org-roam projects directory."
  (let ((expanded (directory-file-name (expand-file-name path)))
        (projects-dir (directory-file-name (org-roam-todo--org-roam-projects-dir))))
    (string-prefix-p (concat projects-dir "/") (concat expanded "/"))))

(defun org-roam-todo--find-project-root-from-todos (project-name)
  "Search existing TODOs for PROJECT-NAME and return a valid PROJECT_ROOT."
  (let ((nodes (org-roam-db-query
                [:select [nodes:file]
                 :from nodes
                 :where (and (like nodes:file "%/todo-%.org")
                             (= nodes:level 0))])))
    (cl-loop for (file) in nodes
             when (file-exists-p file)
             do (with-temp-buffer
                  (insert-file-contents file nil 0 2000)
                  (let ((name (when (re-search-forward "^:PROJECT_NAME:\\s-*\\(.+\\)$" nil t)
                                (string-trim (match-string 1))))
                        (root (progn
                                (goto-char (point-min))
                                (when (re-search-forward "^:PROJECT_ROOT:\\s-*\\(.+\\)$" nil t)
                                  (string-trim (match-string 1))))))
                    (when (and name root
                               (string= name project-name)
                               (not (org-roam-todo--is-org-roam-projects-path-p root))
                               (file-directory-p (expand-file-name ".git" root)))
                      (cl-return (expand-file-name root))))))))

(defun org-roam-todo--find-project-root-from-projectile (project-name)
  "Search projectile known projects for one matching PROJECT-NAME."
  (when (and (fboundp 'projectile-known-projects)
             (projectile-known-projects))
    (cl-loop for proj in (projectile-known-projects)
             when (and (string= (file-name-nondirectory (directory-file-name proj))
                                project-name)
                       (file-directory-p (expand-file-name ".git" proj)))
             return (expand-file-name proj))))

(defun org-roam-todo-resolve-project-root (project-root)
  "Resolve PROJECT-ROOT to an actual git repository path.
If PROJECT-ROOT points to an org-roam projects directory, attempt
to find the real git repository root."
  (let* ((expanded (expand-file-name project-root))
         (is-org-roam-path (org-roam-todo--is-org-roam-projects-path-p expanded)))
    (if (and is-org-roam-path
             (not (file-directory-p (expand-file-name ".git" expanded))))
        (let* ((project-name (file-name-nondirectory (directory-file-name expanded)))
               (resolved (or (org-roam-todo--find-project-root-from-todos project-name)
                             (org-roam-todo--find-project-root-from-projectile project-name))))
          (if resolved
              (progn
                (message "Resolved project root: %s -> %s" expanded resolved)
                resolved)
            (display-warning 'org-roam-todo
                             (format "Could not resolve org-roam project path %s to a real git repo"
                                     expanded)
                             :warning)
            expanded))
      expanded)))

(defun org-roam-todo--select-project ()
  "Prompt user to select a git project."
  (let* ((inferred (org-roam-todo-infer-project))
         (projects (when (and (fboundp 'projectile-known-projects)
                              (projectile-known-projects))
                     (seq-filter
                      (lambda (p)
                        (file-directory-p (expand-file-name ".git" p)))
                      (projectile-known-projects)))))
    (if projects
        (let ((ordered (if inferred
                           (cons inferred (seq-remove
                                           (lambda (p)
                                             (string= (file-truename (expand-file-name p))
                                                      (file-truename (expand-file-name inferred))))
                                           projects))
                         projects)))
          (completing-read "Project: " ordered nil t nil nil inferred))
      (read-directory-name "Git project root: " inferred))))

;;;###autoload
(defun org-roam-todo-capture (&optional project-root)
  "Capture a new TODO for a projectile project.
If PROJECT-ROOT is nil, prompts for project selection."
  (interactive)
  (unless (featurep 'org-roam)
    (require 'org-roam))
  (let* ((project-root (org-roam-todo-resolve-project-root
                        (or project-root (org-roam-todo--select-project))))
         (project-name (org-roam-todo-project-name project-root))
         (project-dir (expand-file-name (concat "projects/" project-name) org-roam-directory))
         (id-timestamp (format "%s%04x" (format-time-string "%Y%m%dT%H%M%S") (random 65536)))
         (date-stamp (format-time-string "%Y-%m-%d")))
    (unless (file-directory-p project-dir)
      (make-directory project-dir t))
    (let ((org-roam-capture-templates
           `(("t" "Project TODO" plain "%?"
              :target (file+head
                       ,(concat "projects/" project-name "/todo-${slug}.org")
                       ,(format ":PROPERTIES:
:ID: %s
:PROJECT_NAME: %s
:PROJECT_ROOT: %s
:STATUS: draft
:WORKTREE_MODEL: opus
:CREATED: %s
:END:
#+title: ${title}
#+filetags: :todo:%s:

** Task Description

** Acceptance Criteria
- [ ]

** Progress Log

" id-timestamp project-name project-root date-stamp project-name))
              :unnarrowed t))))
      (org-roam-capture))))

;;;###autoload
(defun org-roam-todo-capture-project ()
  "Capture a new TODO for the current project."
  (interactive)
  (org-roam-todo-capture (org-roam-todo-infer-project)))

;;;; Path Normalization

(defun org-roam-todo-normalize-path (path)
  "Normalize PATH by expanding, resolving symlinks, and removing trailing slash."
  (directory-file-name (file-truename (expand-file-name path))))

;;;; Backward Compatibility Aliases

;; These aliases maintain backward compatibility with code using the old names
(defalias 'org-roam-todo--slugify 'org-roam-todo-slugify)
(defalias 'org-roam-todo--project-name 'org-roam-todo-project-name)
(defalias 'org-roam-todo--infer-project 'org-roam-todo-infer-project)
(defalias 'org-roam-todo--default-branch-name 'org-roam-todo-default-branch-name)
(defalias 'org-roam-todo--worktree-path 'org-roam-todo-calc-worktree-path)
(defalias 'org-roam-todo--worktree-exists-p 'org-roam-todo-worktree-exists-p)
(defalias 'org-roam-todo--branch-exists-p 'org-roam-todo-branch-exists-p)
(defalias 'org-roam-todo--get-property 'org-roam-todo-get-property)
(defalias 'org-roam-todo--set-property 'org-roam-todo-set-property)
(defalias 'org-roam-todo--node-p 'org-roam-todo-node-p)
(defalias 'org-roam-todo--query-todos 'org-roam-todo-query-todos)
(defalias 'org-roam-todo--read-commit-message 'org-roam-todo-read-commit-message)
(defalias 'org-roam-todo--get-full-content 'org-roam-todo-get-full-content)
(defalias 'org-roam-todo--resolve-project-root 'org-roam-todo-resolve-project-root)
(defalias 'org-roam-todo--normalize-path 'org-roam-todo-normalize-path)
(defalias 'org-roam-todo--effective-agent-allowed-tools 'org-roam-todo-effective-agent-allowed-tools)

;;; ============================================================
;;; Shared TODO Operations
;;; ============================================================
;;
;; These functions implement the core logic for TODO operations.
;; They are called by both org-roam-todo-list and org-roam-todo-status.
;; Each function takes a TODO plist and performs the action.

;; Forward declarations for workflow module (loaded on demand)
(declare-function org-roam-todo-wf--get-workflow "org-roam-todo-wf")
(declare-function org-roam-todo-wf--change-status "org-roam-todo-wf")
(declare-function org-roam-todo-wf--next-statuses "org-roam-todo-wf")
(declare-function org-roam-todo-workflow-statuses "org-roam-todo-wf")

;; Forward declarations for wf-tools module
(declare-function org-roam-todo-wf-tools-start "org-roam-todo-wf-tools")

;; Forward declarations for claude-agent integration
(declare-function claude-agent-run "claude-agent-repl")
(declare-function claude-agent--dispatch-user-message "claude-agent-repl")
(defvar claude-agent--session-info)
(defvar claude-agent--process)

(defun org-roam-todo-do-advance (todo)
  "Advance TODO to the next status in the workflow.
Returns (NEW-STATUS . OLD-STATUS) on success, signals error on failure."
  (require 'org-roam-todo-wf)
  (let* ((workflow (org-roam-todo-wf--get-workflow todo))
         (current-status (plist-get todo :status))
         (statuses (org-roam-todo-workflow-statuses workflow))
         (current-idx (cl-position current-status statuses :test #'equal))
         (next-status (when (and current-idx (< current-idx (1- (length statuses))))
                        (nth (1+ current-idx) statuses))))
    (if next-status
        (progn
          (org-roam-todo-wf--change-status todo next-status)
          (cons next-status current-status))
      (user-error "Cannot advance from '%s' - already at terminal status" current-status))))

(defun org-roam-todo-do-regress (todo)
  "Regress TODO to the previous status in the workflow.
Returns (NEW-STATUS . OLD-STATUS) on success, signals error on failure."
  (require 'org-roam-todo-wf)
  (let* ((workflow (org-roam-todo-wf--get-workflow todo))
         (current-status (plist-get todo :status))
         (next-statuses (org-roam-todo-wf--next-statuses workflow current-status))
         (statuses (org-roam-todo-workflow-statuses workflow))
         (current-idx (cl-position current-status statuses :test #'equal))
         (prev-status (when (and current-idx (> current-idx 0))
                        (nth (1- current-idx) statuses))))
    (if (and prev-status (member prev-status next-statuses))
        (progn
          (org-roam-todo-wf--change-status todo prev-status)
          (cons prev-status current-status))
      (user-error "Cannot regress from '%s'" current-status))))

(defun org-roam-todo-do-reject (todo &optional reason)
  "Reject/abandon TODO with optional REASON.
Returns OLD-STATUS on success, signals error on failure."
  (require 'org-roam-todo-wf)
  (let ((current-status (plist-get todo :status)))
    (if (string= current-status "rejected")
        (user-error "TODO is already rejected")
      ;; TODO: store reason in progress log
      (ignore reason)
      (org-roam-todo-wf--change-status todo "rejected")
      current-status)))

(defun org-roam-todo-do-open-worktree (todo &optional create-if-draft)
  "Open magit-status in the worktree for TODO.
If CREATE-IF-DRAFT is non-nil and TODO is in draft status, start it first.
Returns the worktree path on success, signals error if no worktree."
  (let* ((status (plist-get todo :status))
         (file (plist-get todo :file))
         (worktree-path (plist-get todo :worktree-path)))
    (when (and create-if-draft (string= status "draft"))
      (require 'org-roam-todo-wf-tools)
      (org-roam-todo-wf-tools-start file)
      (setq worktree-path (org-roam-todo-get-file-property file "WORKTREE_PATH")))
    (if (and worktree-path (file-directory-p worktree-path))
        (let ((default-directory worktree-path))
          (magit-status)
          worktree-path)
      (user-error "No worktree found"))))

(defun org-roam-todo--find-agent-buffer (worktree-path)
  "Find an existing Claude agent buffer for WORKTREE-PATH.
Returns the buffer if found and has a live process, nil otherwise."
  (let ((buf-name (format "*claude:%s*"
                          (file-name-nondirectory
                           (directory-file-name (expand-file-name worktree-path))))))
    (when-let ((buf (get-buffer buf-name)))
      (when (buffer-live-p buf)
        (with-current-buffer buf
          (when (and (boundp 'claude-agent--process)
                     claude-agent--process
                     (process-live-p claude-agent--process))
            buf))))))

(defun org-roam-todo--build-initial-message (file title)
  "Build initial message for agent from TODO FILE with TITLE."
  (let* ((first-section (org-roam-todo-get-first-section file))
         (task-heading (car first-section))
         (task-content (cdr first-section))
         (acceptance (org-roam-todo-get-file-section file "Acceptance Criteria")))
    (concat
     "I'm delegating the following task to you:\n\n"
     "* " title "\n\n"
     "TODO file: " file "\n\n"
     (when (and task-heading task-content)
       (format "** %s\n\n%s\n\n" task-heading task-content))
     (when acceptance
       (format "** Acceptance Criteria\n\n%s\n\n" acceptance))
     "** Workflow Tools\n\n"
     "You have access to =mcp__emacs__todo_*= tools for managing this task:\n\n"
     "- =mcp__emacs__todo_advance= - Advance the TODO to the next workflow status\n"
     "- =mcp__emacs__todo_reject= - If the task cannot be completed, reject it with a reason\n\n"
     "Please review the task and acceptance criteria, then begin working on it.")))

(defun org-roam-todo-do-delegate (todo &optional start-if-draft)
  "Delegate TODO to a Claude agent.
If an agent is already running for this TODO's worktree, switches to it.
If START-IF-DRAFT is non-nil and TODO is in draft status, starts it first.
Returns the agent buffer on success."
  (let* ((status (plist-get todo :status))
         (file (plist-get todo :file))
         (title (plist-get todo :title)))
    (when (and start-if-draft (string= status "draft"))
      (require 'org-roam-todo-wf-tools)
      (org-roam-todo-wf-tools-start file))
    (let* ((worktree-path (org-roam-todo-get-file-property file "WORKTREE_PATH"))
           (model (org-roam-todo-get-file-property file "WORKTREE_MODEL"))
           (saved-session (org-roam-todo-get-file-property file "CLAUDE_SESSION_ID"))
           (allowed-tools (org-roam-todo-effective-agent-allowed-tools)))
      (unless (and worktree-path (file-directory-p worktree-path))
        (user-error "No worktree found for this TODO"))
      (if-let ((existing-buf (org-roam-todo--find-agent-buffer worktree-path)))
          (progn
            (message "Switching to existing agent session...")
            (pop-to-buffer existing-buf)
            existing-buf)
        (require 'claude-agent-repl nil t)
        (unless (fboundp 'claude-agent-run)
          (user-error "claude-agent-repl not available"))
        (let* ((buffer (if saved-session
                           (progn
                             (message "Resuming Claude session %s..." (substring saved-session 0 8))
                             (claude-agent-run worktree-path saved-session nil nil model allowed-tools))
                         (message "Starting new Claude session for %s..." title)
                         (claude-agent-run worktree-path nil nil nil model allowed-tools))))
          (unless saved-session
            (when buffer
              (let ((initial-msg (org-roam-todo--build-initial-message file title)))
                (run-with-timer
                 2 nil
                 (lambda (buf todo-file msg)
                   (when (buffer-live-p buf)
                     (with-current-buffer buf
                       (when-let ((session-id (plist-get claude-agent--session-info :session-id)))
                         (org-roam-todo-set-file-property todo-file "CLAUDE_SESSION_ID" session-id)
                         (message "Saved session ID %s to TODO" (substring session-id 0 8)))
                       (when (and claude-agent--process
                                  (process-live-p claude-agent--process))
                         (claude-agent--dispatch-user-message msg)))))
                 buffer file initial-msg))))
          (when buffer
            (pop-to-buffer buffer))
          buffer)))))

;; Provide functions needed by org-roam-todo-list.el
(defun org-roam-todo-list--get-entries ()
  "Get entries for the TODO list."
  (org-roam-todo-query-todos))

(defun org-roam-todo-do-open-todo (todo)
  "Open the TODO file for TODO."
  (let ((file (plist-get todo :file)))
    (unless file
      (user-error "No file associated with this TODO"))
    (find-file file)))

;; Compatibility alias
(defun org-roam-todo--open-todo-file (file)
  "Open the TODO FILE."
  (find-file file))

(provide 'org-roam-todo-core)
;;; org-roam-todo-core.el ends here
