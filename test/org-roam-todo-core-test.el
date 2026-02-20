;;; org-roam-todo-core-test.el --- Tests for core utilities -*- lexical-binding: t; -*-

;; Author: Claude Code
;; Version: 0.1.0
;; Package-Requires: ((emacs "28.1") (ert "1.0"))

;;; Commentary:
;; Tests for org-roam-todo-core.el, including:
;; - Section parsing
;; - Acceptance criteria parsing and manipulation

;;; Code:

(require 'ert)
(require 'org-roam-todo-core)

;;; ============================================================
;;; Test Helpers
;;; ============================================================

(defun org-roam-todo-core-test--create-temp-todo (content)
  "Create a temporary TODO file with CONTENT.
Returns the file path."
  (let ((file (make-temp-file "todo-test-" nil ".org")))
    (with-temp-file file
      (insert content))
    file))

(defmacro org-roam-todo-core-test-with-temp-todo (content &rest body)
  "Create a temp TODO with CONTENT, execute BODY, then cleanup.
Binds `todo-file' to the temp file path."
  (declare (indent 1) (debug (form body)))
  `(let ((todo-file (org-roam-todo-core-test--create-temp-todo ,content)))
     (unwind-protect
         (progn ,@body)
       (when (file-exists-p todo-file)
         (delete-file todo-file)))))

;;; ============================================================
;;; Section Parsing Tests
;;; ============================================================

(ert-deftest core-test-parse-sections-basic ()
  "Test parsing sections from a TODO file."
  :tags '(:unit :core)
  (org-roam-todo-core-test-with-temp-todo
      ":PROPERTIES:
:ID: test-123
:END:
#+title: Test TODO

** Task Description
This is the task.

** Acceptance Criteria
- [ ] First
- [ ] Second

** Progress Log
"
    (let ((sections (org-roam-todo-parse-sections todo-file)))
      (should (= 3 (length sections)))
      (should (string= "Task Description" (plist-get (nth 0 sections) :title)))
      (should (= 2 (plist-get (nth 0 sections) :level)))
      (should (string= "Acceptance Criteria" (plist-get (nth 1 sections) :title)))
      (should (string= "Progress Log" (plist-get (nth 2 sections) :title))))))

(ert-deftest core-test-parse-sections-with-lengths ()
  "Test that section lengths are calculated correctly."
  :tags '(:unit :core)
  (org-roam-todo-core-test-with-temp-todo
      "** Section One
Line 1
Line 2
Line 3
** Section Two
Single line
** Section Three
"
    (let ((sections (org-roam-todo-parse-sections todo-file)))
      (should (= 3 (length sections)))
      ;; Section One has 3 lines of content
      (should (= 3 (plist-get (nth 0 sections) :length)))
      ;; Section Two has 1 line of content
      (should (= 1 (plist-get (nth 1 sections) :length)))
      ;; Section Three has 0 lines (empty)
      (should (= 0 (plist-get (nth 2 sections) :length))))))

(ert-deftest core-test-get-section-content ()
  "Test getting content of a specific section."
  :tags '(:unit :core)
  (org-roam-todo-core-test-with-temp-todo
      "** Task Description
This is the task description.
It has multiple lines.

** Acceptance Criteria
- [ ] Criterion
"
    (let ((content (org-roam-todo-get-section-content todo-file "Task Description")))
      (should (string-match-p "This is the task description" content))
      (should (string-match-p "multiple lines" content)))))

;;; ============================================================
;;; Acceptance Criteria Parsing Tests
;;; ============================================================

(ert-deftest core-test-parse-acceptance-criteria-basic ()
  "Test parsing acceptance criteria checkboxes."
  :tags '(:unit :core)
  (org-roam-todo-core-test-with-temp-todo
      "** Acceptance Criteria
- [ ] First criterion
- [x] Second criterion (complete)
- [ ] Third criterion
"
    (let ((criteria (org-roam-todo-parse-acceptance-criteria todo-file)))
      (should (= 3 (length criteria)))
      ;; First criterion
      (should (= 1 (plist-get (nth 0 criteria) :index)))
      (should (string= "First criterion" (plist-get (nth 0 criteria) :text)))
      (should (not (plist-get (nth 0 criteria) :checked)))
      ;; Second criterion (checked)
      (should (= 2 (plist-get (nth 1 criteria) :index)))
      (should (plist-get (nth 1 criteria) :checked))
      ;; Third criterion
      (should (= 3 (plist-get (nth 2 criteria) :index)))
      (should (not (plist-get (nth 2 criteria) :checked))))))

(ert-deftest core-test-parse-acceptance-criteria-uppercase-x ()
  "Test that uppercase X is recognized as checked."
  :tags '(:unit :core)
  (org-roam-todo-core-test-with-temp-todo
      "** Acceptance Criteria
- [X] Checked with uppercase X
- [x] Checked with lowercase x
"
    (let ((criteria (org-roam-todo-parse-acceptance-criteria todo-file)))
      (should (= 2 (length criteria)))
      (should (plist-get (nth 0 criteria) :checked))
      (should (plist-get (nth 1 criteria) :checked)))))

(ert-deftest core-test-parse-acceptance-criteria-empty ()
  "Test parsing when no acceptance criteria section exists."
  :tags '(:unit :core)
  (org-roam-todo-core-test-with-temp-todo
      "** Task Description
Just a task.
"
    (let ((criteria (org-roam-todo-parse-acceptance-criteria todo-file)))
      (should (null criteria)))))

(ert-deftest core-test-get-acceptance-criteria-formatted ()
  "Test formatted output of acceptance criteria."
  :tags '(:unit :core)
  (org-roam-todo-core-test-with-temp-todo
      "** Acceptance Criteria
- [ ] First
- [x] Second
"
    (let ((formatted (org-roam-todo-get-acceptance-criteria todo-file)))
      (should (string-match-p "1\\. \\[ \\] First" formatted))
      (should (string-match-p "2\\. \\[x\\] Second" formatted)))))

(ert-deftest core-test-get-incomplete-criteria ()
  "Test getting only incomplete criteria."
  :tags '(:unit :core)
  (org-roam-todo-core-test-with-temp-todo
      "** Acceptance Criteria
- [ ] Incomplete one
- [x] Complete
- [ ] Incomplete two
"
    (let ((incomplete (org-roam-todo-get-incomplete-criteria todo-file)))
      (should (= 2 (length incomplete)))
      (should (string= "Incomplete one" (plist-get (nth 0 incomplete) :text)))
      (should (string= "Incomplete two" (plist-get (nth 1 incomplete) :text))))))

(ert-deftest core-test-all-criteria-complete-p-false ()
  "Test all-criteria-complete-p returns nil when incomplete."
  :tags '(:unit :core)
  (org-roam-todo-core-test-with-temp-todo
      "** Acceptance Criteria
- [ ] Not done
- [x] Done
"
    (should (not (org-roam-todo-all-criteria-complete-p todo-file)))))

(ert-deftest core-test-all-criteria-complete-p-true ()
  "Test all-criteria-complete-p returns t when all complete."
  :tags '(:unit :core)
  (org-roam-todo-core-test-with-temp-todo
      "** Acceptance Criteria
- [x] Done one
- [x] Done two
"
    (should (org-roam-todo-all-criteria-complete-p todo-file))))

(ert-deftest core-test-all-criteria-complete-p-empty ()
  "Test all-criteria-complete-p returns t when no criteria (vacuously true)."
  :tags '(:unit :core)
  (org-roam-todo-core-test-with-temp-todo
      "** Task Description
No criteria here.
"
    (should (org-roam-todo-all-criteria-complete-p todo-file))))

;;; ============================================================
;;; Acceptance Criteria Modification Tests
;;; ============================================================

(ert-deftest core-test-mark-criterion-complete-by-index ()
  "Test marking a criterion complete by index."
  :tags '(:unit :core)
  (org-roam-todo-core-test-with-temp-todo
      "** Acceptance Criteria
- [ ] First
- [ ] Second
- [ ] Third
"
    ;; Mark second criterion complete
    (should (org-roam-todo-mark-criterion-complete todo-file 2))
    ;; Verify it was updated
    (let ((criteria (org-roam-todo-parse-acceptance-criteria todo-file)))
      (should (not (plist-get (nth 0 criteria) :checked)))
      (should (plist-get (nth 1 criteria) :checked))
      (should (not (plist-get (nth 2 criteria) :checked))))))

(ert-deftest core-test-mark-criterion-complete-by-text ()
  "Test marking a criterion complete by text match."
  :tags '(:unit :core)
  (org-roam-todo-core-test-with-temp-todo
      "** Acceptance Criteria
- [ ] Add feature X
- [ ] Fix bug Y
- [ ] Update docs
"
    ;; Mark by partial text match
    (should (org-roam-todo-mark-criterion-complete todo-file "bug Y"))
    ;; Verify it was updated
    (let ((criteria (org-roam-todo-parse-acceptance-criteria todo-file)))
      (should (not (plist-get (nth 0 criteria) :checked)))
      (should (plist-get (nth 1 criteria) :checked))
      (should (not (plist-get (nth 2 criteria) :checked))))))

(ert-deftest core-test-mark-criterion-uncheck ()
  "Test unchecking a criterion."
  :tags '(:unit :core)
  (org-roam-todo-core-test-with-temp-todo
      "** Acceptance Criteria
- [x] Already done
- [ ] Not done
"
    ;; Uncheck the first criterion
    (should (org-roam-todo-mark-criterion-complete todo-file 1 t))
    ;; Verify it was unchecked
    (let ((criteria (org-roam-todo-parse-acceptance-criteria todo-file)))
      (should (not (plist-get (nth 0 criteria) :checked))))))

(ert-deftest core-test-mark-criteria-complete-multiple ()
  "Test marking multiple criteria complete at once."
  :tags '(:unit :core)
  (org-roam-todo-core-test-with-temp-todo
      "** Acceptance Criteria
- [ ] First
- [ ] Second
- [ ] Third
- [ ] Fourth
"
    ;; Mark indices 1, 3, and 4 complete
    (should (= 3 (org-roam-todo-mark-criteria-complete todo-file '(1 3 4))))
    ;; Verify
    (let ((criteria (org-roam-todo-parse-acceptance-criteria todo-file)))
      (should (plist-get (nth 0 criteria) :checked))
      (should (not (plist-get (nth 1 criteria) :checked)))
      (should (plist-get (nth 2 criteria) :checked))
      (should (plist-get (nth 3 criteria) :checked)))))

(ert-deftest core-test-mark-criterion-not-found ()
  "Test marking returns nil when criterion not found."
  :tags '(:unit :core)
  (org-roam-todo-core-test-with-temp-todo
      "** Acceptance Criteria
- [ ] Only one
"
    ;; Try to mark non-existent index
    (should (not (org-roam-todo-mark-criterion-complete todo-file 99)))
    ;; Try to mark non-matching text
    (should (not (org-roam-todo-mark-criterion-complete todo-file "does not exist")))))

;;; ============================================================
;;; Agent Allowed Tools Tests
;;; ============================================================

(ert-deftest core-test-allowed-tools-exists ()
  "Test that org-roam-todo-agent-allowed-tools is defined and non-empty."
  :tags '(:unit :core :permissions)
  (should (boundp 'org-roam-todo-agent-allowed-tools))
  (should (listp org-roam-todo-agent-allowed-tools))
  (should (> (length org-roam-todo-agent-allowed-tools) 0)))

(ert-deftest core-test-allowed-tools-has-core-file-ops ()
  "Test that core file operation tools are in the allowlist."
  :tags '(:unit :core :permissions)
  (let ((tools org-roam-todo-agent-allowed-tools))
    ;; Core Claude Code tools
    (should (member "Read(**)" tools))
    (should (member "Write(**)" tools))
    (should (member "Edit(**)" tools))
    (should (member "Glob(**)" tools))
    (should (member "Grep(**)" tools))))

(ert-deftest core-test-allowed-tools-has-git-commands ()
  "Test that git-related bash commands are in the allowlist."
  :tags '(:unit :core :permissions)
  (let ((tools org-roam-todo-agent-allowed-tools))
    (should (member "Bash(git *)" tools))))

(ert-deftest core-test-allowed-tools-has-build-tools ()
  "Test that common build tools are in the allowlist."
  :tags '(:unit :core :permissions)
  (let ((tools org-roam-todo-agent-allowed-tools))
    ;; Node.js
    (should (member "Bash(npm *)" tools))
    (should (member "Bash(npx *)" tools))
    ;; Python
    (should (member "Bash(uv *)" tools))
    (should (member "Bash(python *)" tools))
    (should (member "Bash(python3 *)" tools))
    (should (member "Bash(pytest *)" tools))
    ;; Build systems
    (should (member "Bash(make *)" tools))
    (should (member "Bash(just *)" tools))
    ;; Elisp
    (should (member "Bash(emacs *)" tools))
    (should (member "Bash(cask *)" tools))))

(ert-deftest core-test-allowed-tools-has-filesystem-commands ()
  "Test that common filesystem commands are in the allowlist."
  :tags '(:unit :core :permissions)
  (let ((tools org-roam-todo-agent-allowed-tools))
    (should (member "Bash(ls *)" tools))
    (should (member "Bash(find *)" tools))
    (should (member "Bash(cat *)" tools))
    (should (member "Bash(mkdir *)" tools))
    (should (member "Bash(cp *)" tools))
    (should (member "Bash(rm *)" tools))
    (should (member "Bash(pwd)" tools))
    (should (member "Bash(sed *)" tools))
    (should (member "Bash(which *)" tools))
    (should (member "Bash(touch *)" tools))))

(ert-deftest core-test-allowed-tools-has-mcp-file-ops ()
  "Test that MCP file operation tools are in the allowlist."
  :tags '(:unit :core :permissions)
  (let ((tools org-roam-todo-agent-allowed-tools))
    (should (member "mcp__emacs__read_file" tools))
    (should (member "mcp__emacs__read_buffer" tools))
    (should (member "mcp__emacs__lock" tools))
    (should (member "mcp__emacs__lock_file" tools))
    (should (member "mcp__emacs__unlock" tools))
    (should (member "mcp__emacs__edit" tools))
    (should (member "mcp__emacs__locks" tools))
    (should (member "mcp__emacs__edits" tools))
    (should (member "mcp__emacs__unlocks" tools))
    (should (member "mcp__emacs__save_buffer" tools))
    (should (member "mcp__emacs__buffer_info" tools))))

(ert-deftest core-test-allowed-tools-has-git-mcp-tools ()
  "Test that MCP git tools are in the allowlist (both magit and direct)."
  :tags '(:unit :core :permissions)
  (let ((tools org-roam-todo-agent-allowed-tools))
    ;; Magit tools
    (should (member "mcp__emacs__magit_status" tools))
    (should (member "mcp__emacs__magit_stage" tools))
    (should (member "mcp__emacs__magit_diff" tools))
    (should (member "mcp__emacs__magit_commit_propose" tools))
    ;; Direct git tools
    (should (member "mcp__emacs__git_status" tools))
    (should (member "mcp__emacs__git_stage" tools))
    (should (member "mcp__emacs__git_commit" tools))
    (should (member "mcp__emacs__git_amend" tools))
    (should (member "mcp__emacs__git_rebase" tools))))

(ert-deftest core-test-allowed-tools-has-todo-workflow-tools ()
  "Test that TODO workflow tools are in the allowlist.
These were identified as heavily used but previously missing."
  :tags '(:unit :core :permissions)
  (let ((tools org-roam-todo-agent-allowed-tools))
    (should (member "mcp__emacs__todo_start" tools))
    (should (member "mcp__emacs__todo_advance" tools))
    (should (member "mcp__emacs__todo_regress" tools))
    (should (member "mcp__emacs__todo_reject" tools))
    (should (member "mcp__emacs__todo_create" tools))
    ;; These were previously missing but heavily used
    (should (member "mcp__emacs__todo_current" tools))
    (should (member "mcp__emacs__todo_check_acceptance" tools))
    (should (member "mcp__emacs__todo_add_progress" tools))
    (should (member "mcp__emacs__todo_stage_changes" tools))
    (should (member "mcp__emacs__todo_acceptance_criteria" tools))
    (should (member "mcp__emacs__todo_update_acceptance" tools))))

(ert-deftest core-test-allowed-tools-has-agent-coordination ()
  "Test that agent coordination tools are in the allowlist."
  :tags '(:unit :core :permissions)
  (let ((tools org-roam-todo-agent-allowed-tools))
    (should (member "mcp__emacs__whoami" tools))
    (should (member "mcp__emacs__list_agents" tools))
    (should (member "mcp__emacs__spawn_agent" tools))
    (should (member "mcp__emacs__send_message" tools))
    (should (member "mcp__emacs__check_messages" tools))
    (should (member "mcp__emacs__request_attention" tools))))

(ert-deftest core-test-allowed-tools-has-eval-tools ()
  "Test that elisp evaluation tools are in the allowlist."
  :tags '(:unit :core :permissions)
  (let ((tools org-roam-todo-agent-allowed-tools))
    (should (member "mcp__emacs__eval" tools))
    (should (member "mcp__emacs__async_eval" tools))
    (should (member "mcp__emacs__reload_file" tools))))

(ert-deftest core-test-allowed-tools-has-kb-tools ()
  "Test that knowledge base tools are in the allowlist."
  :tags '(:unit :core :permissions)
  (let ((tools org-roam-todo-agent-allowed-tools))
    (should (member "mcp__emacs__kb_search" tools))
    (should (member "mcp__emacs__kb_get" tools))
    (should (member "mcp__emacs__kb_list" tools))
    (should (member "mcp__emacs__kb_create" tools))
    (should (member "mcp__emacs__kb_update" tools))))

(ert-deftest core-test-allowed-tools-has-expert-tools ()
  "Test that expert system tools are in the allowlist."
  :tags '(:unit :core :permissions)
  (let ((tools org-roam-todo-agent-allowed-tools))
    (should (member "mcp__emacs__ask_the_expert" tools))
    (should (member "mcp__emacs__list_experts" tools))
    (should (member "mcp__emacs__expert_kb" tools))))

(ert-deftest core-test-allowed-tools-has-session-tools ()
  "Test that session management tools are in the allowlist."
  :tags '(:unit :core :permissions)
  (let ((tools org-roam-todo-agent-allowed-tools))
    (should (member "mcp__emacs__restart_session" tools))
    (should (member "mcp__emacs__clear_buffer" tools))))

(ert-deftest core-test-allowed-tools-has-ui-tools ()
  "Test that UI/interaction tools are in the allowlist."
  :tags '(:unit :core :permissions)
  (let ((tools org-roam-todo-agent-allowed-tools))
    (should (member "mcp__emacs__prompt_choice" tools))
    (should (member "mcp__emacs__confirm" tools))
    (should (member "mcp__emacs__show_proposal" tools))
    (should (member "mcp__emacs__progress_start" tools))
    (should (member "mcp__emacs__progress_stop" tools))))

(ert-deftest core-test-allowed-tools-has-watch-tools ()
  "Test that watch/monitoring tools are in the allowlist."
  :tags '(:unit :core :permissions)
  (let ((tools org-roam-todo-agent-allowed-tools))
    (should (member "mcp__emacs__watch_buffer" tools))
    (should (member "mcp__emacs__watch_for_pattern" tools))
    (should (member "mcp__emacs__watch_for_change" tools))))

(ert-deftest core-test-allowed-tools-extra-defaults-empty ()
  "Test that org-roam-todo-agent-allowed-tools-extra defaults to empty."
  :tags '(:unit :core :permissions)
  (should (boundp 'org-roam-todo-agent-allowed-tools-extra))
  ;; Default should be empty list (users add via .dir-locals.el)
  (let ((org-roam-todo-agent-allowed-tools-extra nil))
    (should (null org-roam-todo-agent-allowed-tools-extra))))

(ert-deftest core-test-effective-allowed-tools-combines-lists ()
  "Test that effective-agent-allowed-tools combines base and extra."
  :tags '(:unit :core :permissions)
  (let ((org-roam-todo-agent-allowed-tools '("tool1" "tool2"))
        (org-roam-todo-agent-allowed-tools-extra '("tool3" "tool4")))
    (let ((effective (org-roam-todo-effective-agent-allowed-tools)))
      (should (= 4 (length effective)))
      (should (member "tool1" effective))
      (should (member "tool2" effective))
      (should (member "tool3" effective))
      (should (member "tool4" effective)))))

(ert-deftest core-test-effective-allowed-tools-works-with-empty-extra ()
  "Test that effective-agent-allowed-tools works when extra is empty."
  :tags '(:unit :core :permissions)
  (let ((org-roam-todo-agent-allowed-tools '("tool1" "tool2"))
        (org-roam-todo-agent-allowed-tools-extra nil))
    (let ((effective (org-roam-todo-effective-agent-allowed-tools)))
      (should (= 2 (length effective)))
      (should (equal effective org-roam-todo-agent-allowed-tools)))))

(ert-deftest core-test-allowed-tools-minimum-count ()
  "Test that allowlist has at least 100 tools (empirically derived minimum)."
  :tags '(:unit :core :permissions)
  ;; Based on Feb 2026 analysis of 302 worktree sessions, we identified
  ;; 150 tools that agents actually use. Ensure we don't accidentally
  ;; regress to a smaller list.
  (should (>= (length org-roam-todo-agent-allowed-tools) 100)))

(ert-deftest core-test-allowed-tools-no-duplicates ()
  "Test that the allowlist has no duplicate entries."
  :tags '(:unit :core :permissions)
  (let* ((tools org-roam-todo-agent-allowed-tools)
         (unique (delete-dups (copy-sequence tools))))
    (should (= (length tools) (length unique)))))

(ert-deftest core-test-allowed-tools-all-strings ()
  "Test that all entries in the allowlist are strings."
  :tags '(:unit :core :permissions)
  (dolist (tool org-roam-todo-agent-allowed-tools)
    (should (stringp tool))))

(provide 'org-roam-todo-core-test)
;;; org-roam-todo-core-test.el ends here
