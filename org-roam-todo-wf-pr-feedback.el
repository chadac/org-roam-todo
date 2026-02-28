;;; org-roam-todo-wf-pr-feedback.el --- PR feedback viewing -*- lexical-binding: t; -*-

;; Author: Claude Code
;; Version: 0.1.0
;; Package-Requires: ((emacs "28.1") (org-roam "2.0"))

;;; Commentary:
;; PR feedback viewing and management for org-roam-todo workflows.
;;
;; This module provides:
;; - Fetching PR comments/reviews (GitHub and GitLab)
;; - Fetching CI check details with log tails
;; - Data structures for feedback display
;; - Integration points for status buffer display
;;
;; Designed to be forge-agnostic, supporting both GitHub (gh CLI) and
;; GitLab (glab CLI).

;;; Code:

(require 'cl-lib)
(require 'json)

;;; ============================================================
;;; Customization
;;; ============================================================

(defgroup org-roam-todo-wf-pr-feedback nil
  "PR feedback settings for org-roam-todo."
  :group 'org-roam-todo)

(defcustom org-roam-todo-wf-pr-feedback-ci-log-lines 50
  "Number of lines to fetch from CI log tails."
  :type 'integer
  :group 'org-roam-todo-wf-pr-feedback)

(defcustom org-roam-todo-wf-pr-feedback-cache-ttl 300
  "Time-to-live for cached feedback data in seconds.
Set to 0 to disable caching."
  :type 'integer
  :group 'org-roam-todo-wf-pr-feedback)

;;; ============================================================
;;; Data Structures
;;; ============================================================

;; PR Feedback is a plist with:
;; :pr-number - PR number
;; :pr-state - 'open, 'merged, 'closed
;; :pr-url - URL to the PR
;; :comments - list of comment plists
;; :reviews - list of review plists
;; :ci-checks - list of CI check plists
;; :timestamp - when feedback was fetched

;; Comment plist:
;; :id - unique identifier
;; :author - username
;; :body - comment text
;; :path - file path (for review comments)
;; :line - line number (for review comments)
;; :state - 'resolved, 'unresolved, 'outdated (for review comments)
;; :created-at - timestamp
;; :url - link to comment

;; Review plist:
;; :id - unique identifier
;; :author - username
;; :state - 'approved, 'changes_requested, 'commented, 'pending
;; :body - review body
;; :comments - list of inline comments
;; :submitted-at - timestamp

;; CI Check plist:
;; :name - check name
;; :status - 'success, 'failure, 'pending, 'cancelled, 'skipped
;; :url - link to check details
;; :conclusion - detailed conclusion
;; :started-at - timestamp
;; :completed-at - timestamp
;; :log-tail - last N lines of log output (for failures)
;; :run-id - workflow run ID (for fetching full logs)

;;; ============================================================
;;; Forge Type Detection
;;; ============================================================

(defun org-roam-todo-wf-pr-feedback--detect-forge (worktree-path)
  "Detect the forge type for WORKTREE-PATH.
Returns :github, :gitlab, or nil if unknown."
  (when worktree-path
    (let ((default-directory worktree-path))
      (let ((remote-url (string-trim
                         (shell-command-to-string
                          "git remote get-url origin 2>/dev/null"))))
        (cond
         ((string-match-p "github\\.com" remote-url) :github)
         ((string-match-p "gitlab\\." remote-url) :gitlab)
         ((string-match-p "gitlab-" remote-url) :gitlab)
         ;; Try to detect by checking which CLI is available and works
         ((= 0 (call-process "gh" nil nil nil "auth" "status")) :github)
         ((= 0 (call-process "glab" nil nil nil "auth" "status")) :gitlab)
         (t nil))))))

;;; ============================================================
;;; GitHub Feedback Fetching
;;; ============================================================

(defun org-roam-todo-wf-pr-feedback--gh-get-pr-info (worktree-path)
  "Get basic PR info from GitHub using gh CLI.
Returns plist with :number, :state, :url, or nil if no PR."
  (let ((default-directory worktree-path))
    (condition-case nil
        (let* ((json-str (shell-command-to-string
                          "gh pr view --json number,state,url 2>/dev/null"))
               (data (json-read-from-string json-str)))
          (when data
            (list :number (alist-get 'number data)
                  :state (intern (downcase (alist-get 'state data)))
                  :url (alist-get 'url data))))
      (error nil))))

(defun org-roam-todo-wf-pr-feedback--gh-get-comments (worktree-path)
  "Get PR comments from GitHub using gh CLI.
Returns list of comment plists."
  (let ((default-directory worktree-path))
    (condition-case nil
        (let* ((json-str (shell-command-to-string
                          "gh pr view --json comments 2>/dev/null"))
               (data (json-read-from-string json-str))
               (comments (alist-get 'comments data)))
          (mapcar (lambda (c)
                    (list :id (alist-get 'id c)
                          :author (alist-get 'login (alist-get 'author c))
                          :body (alist-get 'body c)
                          :created-at (alist-get 'createdAt c)
                          :url (alist-get 'url c)))
                  comments))
      (error nil))))

(defun org-roam-todo-wf-pr-feedback--gh-get-reviews (worktree-path)
  "Get PR reviews from GitHub using gh CLI.
Returns list of review plists with inline comments."
  (let ((default-directory worktree-path))
    (condition-case nil
        (let* ((json-str (shell-command-to-string
                          "gh pr view --json reviews,reviewDecision 2>/dev/null"))
               (data (json-read-from-string json-str))
               (reviews (alist-get 'reviews data)))
          (mapcar (lambda (r)
                    (list :id (alist-get 'id r)
                          :author (alist-get 'login (alist-get 'author r))
                          :state (intern (downcase (or (alist-get 'state r) "pending")))
                          :body (alist-get 'body r)
                          :submitted-at (alist-get 'submittedAt r)))
                  reviews))
      (error nil))))

(defun org-roam-todo-wf-pr-feedback--gh-get-review-comments (worktree-path)
  "Get inline review comments from GitHub using gh CLI.
Returns list of comment plists with file/line info and diff context."
  (let ((default-directory worktree-path))
    (condition-case nil
        ;; First get PR number, then fetch comments
        (let* ((pr-number (string-trim
                           (shell-command-to-string
                            "gh pr view --json number -q .number 2>/dev/null")))
               (json-str (when (and pr-number (not (string-empty-p pr-number)))
                           (shell-command-to-string
                            (format "gh api repos/:owner/:repo/pulls/%s/comments 2>/dev/null"
                                    pr-number))))
               (comments (when json-str (json-read-from-string json-str))))
          (when (vectorp comments)
            (mapcar (lambda (c)
                      (list :id (alist-get 'id c)
                            :author (alist-get 'login (alist-get 'user c))
                            :body (alist-get 'body c)
                            :path (alist-get 'path c)
                            :line (or (alist-get 'line c)
                                      (alist-get 'original_line c))
                            :diff-hunk (alist-get 'diff_hunk c)
                            :state (if (alist-get 'in_reply_to_id c)
                                       'reply
                                     (if (string= "RESOLVED"
                                                  (alist-get 'state
                                                             (alist-get 'subject c)))
                                         'resolved
                                       'unresolved))
                            :created-at (alist-get 'created_at c)
                            :url (alist-get 'html_url c)))
                    comments)))
      (error nil))))

(defun org-roam-todo-wf-pr-feedback--gh-get-ci-checks (worktree-path)
  "Get CI check status from GitHub using gh CLI.
Returns list of CI check plists."
  (let ((default-directory worktree-path))
    (condition-case nil
        (let* ((json-str (shell-command-to-string
                          "gh pr checks --json name,state,detailsUrl,description,startedAt,completedAt,workflowName 2>/dev/null"))
               (checks (json-read-from-string json-str)))
          (when (vectorp checks)
            (mapcar (lambda (c)
                      (let* ((state-str (downcase (or (alist-get 'state c) "pending")))
                             (status (pcase state-str
                                       ("success" 'success)
                                       ("pass" 'success)
                                       ("failure" 'failure)
                                       ("fail" 'failure)
                                       ("pending" 'pending)
                                       ("queued" 'pending)
                                       ("in_progress" 'pending)
                                       ("cancelled" 'cancelled)
                                       ("skipped" 'skipped)
                                       (_ 'unknown))))
                        (list :name (or (alist-get 'name c)
                                        (alist-get 'workflowName c))
                              :status status
                              :url (alist-get 'detailsUrl c)
                              :conclusion (alist-get 'description c)
                              :started-at (alist-get 'startedAt c)
                              :completed-at (alist-get 'completedAt c))))
                    checks)))
      (error nil))))

(defun org-roam-todo-wf-pr-feedback--gh-get-failed-run-logs (worktree-path run-id num-lines)
  "Get the last NUM-LINES of failed logs for RUN-ID.
Uses gh CLI to fetch workflow run logs."
  (let ((default-directory worktree-path))
    (condition-case nil
        (let ((output (shell-command-to-string
                       (format "gh run view %s --log-failed 2>/dev/null | tail -n %d"
                               run-id num-lines))))
          (unless (string-empty-p output)
            output))
      (error nil))))

(defun org-roam-todo-wf-pr-feedback--gh-get-run-id-for-check (worktree-path check-name)
  "Get the workflow run ID for CHECK-NAME.
Returns the run ID as a string, or nil if not found."
  (let ((default-directory worktree-path))
    (condition-case nil
        (let* ((json-str (shell-command-to-string
                          "gh run list --json databaseId,name,status,conclusion -L 20 2>/dev/null"))
               (runs (json-read-from-string json-str)))
          (when (vectorp runs)
            (cl-loop for run across runs
                     when (string-match-p (regexp-quote check-name)
                                          (or (alist-get 'name run) ""))
                     return (number-to-string (alist-get 'databaseId run)))))
      (error nil))))

;;; ============================================================
;;; GitLab Feedback Fetching
;;; ============================================================

(defun org-roam-todo-wf-pr-feedback--glab-get-mr-info (worktree-path)
  "Get basic MR info from GitLab using glab CLI.
Returns plist with :number (iid), :state, :url, or nil if no MR."
  (let ((default-directory worktree-path))
    (condition-case nil
        (let* ((json-str (shell-command-to-string
                          "glab mr view --output json 2>/dev/null"))
               (data (json-read-from-string json-str)))
          (when data
            (list :number (alist-get 'iid data)
                  :state (intern (downcase (or (alist-get 'state data) "open")))
                  :url (alist-get 'web_url data))))
      (error nil))))

(defun org-roam-todo-wf-pr-feedback--glab-get-comments (worktree-path)
  "Get MR comments from GitLab using glab CLI.
Returns list of comment plists."
  (let ((default-directory worktree-path))
    (condition-case nil
        (let* ((json-str (shell-command-to-string
                          "glab mr view --output json 2>/dev/null"))
               (data (json-read-from-string json-str))
               (notes (alist-get 'notes data)))
          (when notes
            (mapcar (lambda (n)
                      (list :id (alist-get 'id n)
                            :author (alist-get 'username (alist-get 'author n))
                            :body (alist-get 'body n)
                            :created-at (alist-get 'created_at n)
                            :url nil  ; GitLab notes don't have direct URLs in API
                            :system (alist-get 'system n)))
                    (seq-filter (lambda (n) (not (alist-get 'system n))) notes))))
      (error nil))))

(defun org-roam-todo-wf-pr-feedback--glab-get-discussions (worktree-path)
  "Get MR discussions (review threads) from GitLab.
Returns list of discussion plists with notes."
  (let ((default-directory worktree-path))
    (condition-case nil
        (let* ((mr-iid (plist-get (org-roam-todo-wf-pr-feedback--glab-get-mr-info worktree-path)
                                   :number))
               (json-str (when mr-iid
                           (shell-command-to-string
                            (format "glab api projects/:id/merge_requests/%s/discussions 2>/dev/null"
                                    mr-iid))))
               (discussions (when json-str (json-read-from-string json-str))))
          (when (vectorp discussions)
            (cl-loop for d across discussions
                     for notes = (alist-get 'notes d)
                     when (and notes (> (length notes) 0))
                     collect (let ((first-note (aref notes 0)))
                               (list :id (alist-get 'id d)
                                     :author (alist-get 'username (alist-get 'author first-note))
                                     :body (alist-get 'body first-note)
                                     :path (alist-get 'new_path (alist-get 'position first-note))
                                     :line (alist-get 'new_line (alist-get 'position first-note))
                                     :state (if (alist-get 'resolved d) 'resolved 'unresolved)
                                     :created-at (alist-get 'created_at first-note)
                                     :notes-count (length notes))))))
      (error nil))))

(defun org-roam-todo-wf-pr-feedback--glab-get-ci-pipelines (worktree-path)
  "Get CI pipeline status from GitLab using glab CLI.
Returns list of CI check plists."
  (let ((default-directory worktree-path))
    (condition-case nil
        (let* ((json-str (shell-command-to-string
                          "glab ci status --output json 2>/dev/null"))
               (data (json-read-from-string json-str))
               (jobs (alist-get 'jobs data)))
          (when (vectorp jobs)
            (mapcar (lambda (j)
                      (let* ((status-str (downcase (or (alist-get 'status j) "pending")))
                             (status (pcase status-str
                                       ("success" 'success)
                                       ("passed" 'success)
                                       ("failed" 'failure)
                                       ("running" 'pending)
                                       ("pending" 'pending)
                                       ("created" 'pending)
                                       ("canceled" 'cancelled)
                                       ("cancelled" 'cancelled)
                                       ("skipped" 'skipped)
                                       (_ 'unknown))))
                        (list :name (alist-get 'name j)
                              :status status
                              :url (alist-get 'web_url j)
                              :started-at (alist-get 'started_at j)
                              :completed-at (alist-get 'finished_at j)
                              :job-id (alist-get 'id j))))
                    jobs)))
      (error nil))))

(defun org-roam-todo-wf-pr-feedback--glab-get-job-logs (worktree-path job-id num-lines)
  "Get the last NUM-LINES of logs for JOB-ID.
Uses glab CLI to fetch job trace."
  (let ((default-directory worktree-path))
    (condition-case nil
        (let ((output (shell-command-to-string
                       (format "glab ci trace %s 2>/dev/null | tail -n %d"
                               job-id num-lines))))
          (unless (string-empty-p output)
            output))
      (error nil))))

;;; ============================================================
;;; Unified Feedback Interface
;;; ============================================================

(defvar org-roam-todo-wf-pr-feedback--cache (make-hash-table :test 'equal)
  "Cache for PR feedback data.
Key: worktree-path, Value: (timestamp . feedback-plist)")

(defun org-roam-todo-wf-pr-feedback--cache-valid-p (worktree-path)
  "Check if cached feedback for WORKTREE-PATH is still valid."
  (when-let ((entry (gethash worktree-path org-roam-todo-wf-pr-feedback--cache)))
    (and (> org-roam-todo-wf-pr-feedback-cache-ttl 0)
         (< (- (float-time) (car entry))
            org-roam-todo-wf-pr-feedback-cache-ttl))))

(defun org-roam-todo-wf-pr-feedback--cache-get (worktree-path)
  "Get cached feedback for WORKTREE-PATH if valid."
  (when (org-roam-todo-wf-pr-feedback--cache-valid-p worktree-path)
    (cdr (gethash worktree-path org-roam-todo-wf-pr-feedback--cache))))

(defun org-roam-todo-wf-pr-feedback--cache-set (worktree-path feedback)
  "Cache FEEDBACK for WORKTREE-PATH."
  (puthash worktree-path (cons (float-time) feedback)
           org-roam-todo-wf-pr-feedback--cache))

(defun org-roam-todo-wf-pr-feedback-invalidate-cache (&optional worktree-path)
  "Invalidate cached feedback.
If WORKTREE-PATH is provided, only invalidate that entry.
Otherwise, clear the entire cache."
  (if worktree-path
      (remhash worktree-path org-roam-todo-wf-pr-feedback--cache)
    (clrhash org-roam-todo-wf-pr-feedback--cache)))

(defun org-roam-todo-wf-pr-feedback-fetch (worktree-path &optional force-refresh)
  "Fetch PR feedback for WORKTREE-PATH.
Returns a feedback plist with :pr-number, :pr-state, :pr-url,
:comments, :reviews, :review-comments, :ci-checks.

If FORCE-REFRESH is non-nil, bypasses the cache.
Returns nil if WORKTREE-PATH doesn't exist or is not a git repository."
  (when (and worktree-path (file-directory-p worktree-path))
    ;; Check cache first (unless force-refresh)
    (let ((cached (unless force-refresh
                    (org-roam-todo-wf-pr-feedback--cache-get worktree-path))))
      (if cached
          cached
        ;; Not in cache, fetch fresh data
        (let* ((forge (org-roam-todo-wf-pr-feedback--detect-forge worktree-path))
               (feedback
                (pcase forge
                  (:github
                   (let ((pr-info (org-roam-todo-wf-pr-feedback--gh-get-pr-info worktree-path)))
                     (when pr-info
                       (let ((ci-checks (org-roam-todo-wf-pr-feedback--gh-get-ci-checks worktree-path)))
                         ;; Fetch log tails for failed checks
                         (dolist (check ci-checks)
                           (when (eq (plist-get check :status) 'failure)
                             (when-let ((run-id (org-roam-todo-wf-pr-feedback--gh-get-run-id-for-check
                                                 worktree-path (plist-get check :name))))
                               (plist-put check :run-id run-id)
                               (plist-put check :log-tail
                                          (org-roam-todo-wf-pr-feedback--gh-get-failed-run-logs
                                           worktree-path run-id
                                           org-roam-todo-wf-pr-feedback-ci-log-lines)))))
                         (list :forge :github
                               :pr-number (plist-get pr-info :number)
                               :pr-state (plist-get pr-info :state)
                               :pr-url (plist-get pr-info :url)
                               :comments (org-roam-todo-wf-pr-feedback--gh-get-comments worktree-path)
                               :reviews (org-roam-todo-wf-pr-feedback--gh-get-reviews worktree-path)
                               :review-comments (org-roam-todo-wf-pr-feedback--gh-get-review-comments worktree-path)
                               :ci-checks ci-checks
                               :timestamp (current-time))))))

                  (:gitlab
                   (let ((mr-info (org-roam-todo-wf-pr-feedback--glab-get-mr-info worktree-path)))
                     (when mr-info
                       (let ((ci-checks (org-roam-todo-wf-pr-feedback--glab-get-ci-pipelines worktree-path)))
                         ;; Fetch log tails for failed jobs
                         (dolist (check ci-checks)
                           (when (eq (plist-get check :status) 'failure)
                             (when-let ((job-id (plist-get check :job-id)))
                               (plist-put check :log-tail
                                          (org-roam-todo-wf-pr-feedback--glab-get-job-logs
                                           worktree-path job-id
                                           org-roam-todo-wf-pr-feedback-ci-log-lines)))))
                         (list :forge :gitlab
                               :pr-number (plist-get mr-info :number)
                               :pr-state (plist-get mr-info :state)
                               :pr-url (plist-get mr-info :url)
                               :comments (org-roam-todo-wf-pr-feedback--glab-get-comments worktree-path)
                               :discussions (org-roam-todo-wf-pr-feedback--glab-get-discussions worktree-path)
                               :ci-checks ci-checks
                               :timestamp (current-time))))))

                  (_ nil))))
          (when feedback
            (org-roam-todo-wf-pr-feedback--cache-set worktree-path feedback))
          feedback)))))

;;; ============================================================
;;; Feedback Summarization
;;; ============================================================

(defun org-roam-todo-wf-pr-feedback-summary (feedback)
  "Generate a summary of FEEDBACK for display.
Returns a plist with:
  :ci-status - overall CI status (:success, :failure, :pending)
  :ci-failed-count - number of failed checks
  :ci-pending-count - number of pending checks
  :comment-count - total comment count
  :unresolved-count - unresolved review comment count
  :review-state - overall review state"
  (when feedback
    (let* ((ci-checks (plist-get feedback :ci-checks))
           (comments (plist-get feedback :comments))
           (reviews (plist-get feedback :reviews))
           (review-comments (or (plist-get feedback :review-comments)
                                (plist-get feedback :discussions)))
           (ci-failed (cl-count-if (lambda (c) (eq (plist-get c :status) 'failure))
                                   ci-checks))
           (ci-pending (cl-count-if (lambda (c) (eq (plist-get c :status) 'pending))
                                    ci-checks))
           (ci-success (cl-count-if (lambda (c) (eq (plist-get c :status) 'success))
                                    ci-checks))
           (unresolved (cl-count-if (lambda (c) (eq (plist-get c :state) 'unresolved))
                                    review-comments))
           (overall-ci (cond
                        ((> ci-failed 0) :failure)
                        ((> ci-pending 0) :pending)
                        ((> ci-success 0) :success)
                        (t :none)))
           (overall-review (cond
                            ((cl-find 'changes_requested reviews :key (lambda (r) (plist-get r :state)))
                             :changes-requested)
                            ((cl-find 'approved reviews :key (lambda (r) (plist-get r :state)))
                             :approved)
                            ((> (length reviews) 0)
                             :reviewed)
                            (t :none))))
      (list :ci-status overall-ci
            :ci-failed-count ci-failed
            :ci-pending-count ci-pending
            :ci-success-count ci-success
            :ci-total-count (length ci-checks)
            :comment-count (length comments)
            :review-count (length reviews)
            :unresolved-count unresolved
            :review-state overall-review))))

;;; ============================================================
;;; CLI Commands for Full Logs
;;; ============================================================

(defun org-roam-todo-wf-pr-feedback-view-full-log (worktree-path check-name)
  "View full CI log for CHECK-NAME in WORKTREE-PATH.
Opens the log in a new buffer."
  (interactive
   (let* ((todo (org-roam-todo-wf-pr-feedback--current-todo))
          (wt (plist-get todo :worktree-path))
          (feedback (org-roam-todo-wf-pr-feedback-fetch wt))
          (checks (plist-get feedback :ci-checks))
          (check-names (mapcar (lambda (c) (plist-get c :name)) checks))
          (name (completing-read "Check: " check-names nil t)))
     (list wt name)))
  (let* ((default-directory worktree-path)
         (forge (org-roam-todo-wf-pr-feedback--detect-forge worktree-path))
         (buf-name (format "*CI Log: %s*" check-name))
         (buffer (get-buffer-create buf-name)))
    (with-current-buffer buffer
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert (format "=== CI Log: %s ===\n\n" check-name))
        (pcase forge
          (:github
           (let ((run-id (org-roam-todo-wf-pr-feedback--gh-get-run-id-for-check
                          worktree-path check-name)))
             (if run-id
                 (insert (shell-command-to-string
                          (format "gh run view %s --log-failed 2>&1" run-id)))
               (insert "Could not find run ID for this check.\n"))))
          (:gitlab
           (let* ((checks (plist-get (org-roam-todo-wf-pr-feedback-fetch worktree-path) :ci-checks))
                  (check (cl-find check-name checks
                                  :key (lambda (c) (plist-get c :name))
                                  :test #'string=))
                  (job-id (plist-get check :job-id)))
             (if job-id
                 (insert (shell-command-to-string
                          (format "glab ci trace %s 2>&1" job-id)))
               (insert "Could not find job ID for this check.\n"))))
          (_ (insert "Unknown forge type.\n")))
        (goto-char (point-min))
        (special-mode)))
    (pop-to-buffer buffer)))

;;; ============================================================
;;; Helper for Current TODO
;;; ============================================================

(declare-function org-roam-todo-status--todo "org-roam-todo-status")
(defvar org-roam-todo-status--todo)

(defun org-roam-todo-wf-pr-feedback--current-todo ()
  "Get the current TODO from context.
Looks for the TODO in the status buffer or infers from worktree."
  (cond
   ((and (boundp 'org-roam-todo-status--todo)
         org-roam-todo-status--todo)
    org-roam-todo-status--todo)
   (t nil)))

;;; ============================================================
;;; PR Auto-Update on TODO Save
;;; ============================================================

(defcustom org-roam-todo-wf-pr-feedback-auto-update t
  "Whether to automatically update PR title/body when TODO is saved.
When non-nil, saving a TODO file will update the associated PR/MR
if the PR Title or PR Description sections have changed."
  :type 'boolean
  :group 'org-roam-todo-wf-pr-feedback)

(defvar org-roam-todo-wf-pr-feedback--section-cache (make-hash-table :test 'equal)
  "Cache of PR section contents before save.
Key: file path, Value: (pr-title . pr-body)")

;; Forward declarations
(declare-function org-roam-todo-get-file-section "org-roam-todo-core")
(declare-function org-roam-todo-get-file-property "org-roam-todo-core")

(defun org-roam-todo-wf-pr-feedback--get-sections (file)
  "Get PR Title and PR Description sections from FILE.
Returns (title . body) cons cell."
  (when (and file (file-exists-p file))
    (cons (org-roam-todo-get-file-section file "PR Title")
          (org-roam-todo-get-file-section file "PR Description"))))

(defun org-roam-todo-wf-pr-feedback--update-pr-gh (worktree-path title body)
  "Update PR title and body using gh CLI.
WORKTREE-PATH is the git directory.
TITLE is the new PR title.
BODY is the new PR body/description."
  (let ((default-directory worktree-path)
        (args '("pr" "edit")))
    (when title
      (setq args (append args (list "--title" title))))
    (when body
      (setq args (append args (list "--body" body))))
    (apply #'call-process "gh" nil nil nil args)))

(defun org-roam-todo-wf-pr-feedback--update-pr-glab (worktree-path title body)
  "Update MR title and body using glab CLI.
WORKTREE-PATH is the git directory.
TITLE is the new MR title.
BODY is the new MR body/description."
  (let ((default-directory worktree-path)
        (args '("mr" "update")))
    (when title
      (setq args (append args (list "--title" title))))
    (when body
      (setq args (append args (list "--description" body))))
    (apply #'call-process "glab" nil nil nil args)))

(defun org-roam-todo-wf-pr-feedback--update-pr (worktree-path title body)
  "Update PR/MR title and body.
WORKTREE-PATH is the git directory.
TITLE is the new title (or nil to skip).
BODY is the new body/description (or nil to skip).
Automatically detects forge type (GitHub/GitLab)."
  (when (and worktree-path (or title body))
    (let ((forge (org-roam-todo-wf-pr-feedback--detect-forge worktree-path)))
      (pcase forge
        (:github (org-roam-todo-wf-pr-feedback--update-pr-gh worktree-path title body))
        (:gitlab (org-roam-todo-wf-pr-feedback--update-pr-glab worktree-path title body))
        (_ (message "Unknown forge type, cannot update PR"))))))

(defun org-roam-todo-wf-pr-feedback--before-save-hook ()
  "Cache PR sections before save for comparison."
  (when (and org-roam-todo-wf-pr-feedback-auto-update
             buffer-file-name
             (string-match-p "\\.org$" buffer-file-name))
    ;; Check if this is a TODO file with a worktree
    (let ((worktree-path (org-roam-todo-get-file-property buffer-file-name "WORKTREE_PATH"))
          (status (org-roam-todo-get-file-property buffer-file-name "STATUS")))
      ;; Only cache if in review status (PR exists)
      (when (and worktree-path
                 (member status '("review" "ci" "ready")))
        (puthash buffer-file-name
                 (org-roam-todo-wf-pr-feedback--get-sections buffer-file-name)
                 org-roam-todo-wf-pr-feedback--section-cache)))))

(defun org-roam-todo-wf-pr-feedback--after-save-hook ()
  "Update PR if PR Title or PR Description changed."
  (when (and org-roam-todo-wf-pr-feedback-auto-update
             buffer-file-name
             (string-match-p "\\.org$" buffer-file-name))
    (let* ((old-sections (gethash buffer-file-name org-roam-todo-wf-pr-feedback--section-cache))
           (worktree-path (org-roam-todo-get-file-property buffer-file-name "WORKTREE_PATH"))
           (status (org-roam-todo-get-file-property buffer-file-name "STATUS")))
      ;; Only update if in review status and we have cached values
      (when (and old-sections
                 worktree-path
                 (file-directory-p worktree-path)
                 (member status '("review" "ci" "ready")))
        (let* ((new-sections (org-roam-todo-wf-pr-feedback--get-sections buffer-file-name))
               (old-title (car old-sections))
               (old-body (cdr old-sections))
               (new-title (car new-sections))
               (new-body (cdr new-sections))
               (title-changed (not (equal old-title new-title)))
               (body-changed (not (equal old-body new-body))))
          (when (or title-changed body-changed)
            (message "PR sections changed, updating PR...")
            (org-roam-todo-wf-pr-feedback--update-pr
             worktree-path
             (when title-changed (string-trim (or new-title "")))
             (when body-changed (string-trim (or new-body ""))))
            (message "PR updated successfully")
            ;; Invalidate feedback cache since PR was updated
            (org-roam-todo-wf-pr-feedback-invalidate-cache worktree-path))))
      ;; Clean up cache
      (remhash buffer-file-name org-roam-todo-wf-pr-feedback--section-cache))))

(defun org-roam-todo-wf-pr-feedback-setup-auto-update ()
  "Set up hooks for automatic PR updates on TODO save.
Call this once during initialization."
  (add-hook 'before-save-hook #'org-roam-todo-wf-pr-feedback--before-save-hook)
  (add-hook 'after-save-hook #'org-roam-todo-wf-pr-feedback--after-save-hook))

(defun org-roam-todo-wf-pr-feedback-teardown-auto-update ()
  "Remove hooks for automatic PR updates.
Call this to disable auto-update functionality."
  (remove-hook 'before-save-hook #'org-roam-todo-wf-pr-feedback--before-save-hook)
  (remove-hook 'after-save-hook #'org-roam-todo-wf-pr-feedback--after-save-hook))

;; Auto-setup when this file is loaded
(org-roam-todo-wf-pr-feedback-setup-auto-update)

(provide 'org-roam-todo-wf-pr-feedback)
;;; org-roam-todo-wf-pr-feedback.el ends here
