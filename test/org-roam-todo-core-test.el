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

(provide 'org-roam-todo-core-test)
;;; org-roam-todo-core-test.el ends here
