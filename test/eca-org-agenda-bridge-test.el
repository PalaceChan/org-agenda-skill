;;; eca-org-agenda-bridge-test.el --- ERT tests for Org agenda bridge -*- lexical-binding: t; -*-

(require 'cl-lib)
(require 'ert)
(require 'org)
(require 'org-id)

(defconst eca-org-agenda-test--file
  (or load-file-name buffer-file-name)
  "Absolute path to this test file.")

(defconst eca-org-agenda-test--root-dir
  (file-name-directory
   (directory-file-name
    (file-name-directory eca-org-agenda-test--file)))
  "Repository root for the org-agenda skill project.")

(defconst eca-org-agenda-test--bridge-file
  (expand-file-name "scripts/eca-org-agenda-bridge.el" eca-org-agenda-test--root-dir)
  "Absolute path to the bridge file under test.")

(defconst eca-org-agenda-test--fixtures-dir
  (expand-file-name "test/fixtures" eca-org-agenda-test--root-dir)
  "Directory containing golden Org fixtures.")

(load-file eca-org-agenda-test--bridge-file)

(defun eca-org-agenda-test--fixture-contents (name)
  "Return the contents of fixture NAME as a string."
  (with-temp-buffer
    (insert-file-contents (expand-file-name name eca-org-agenda-test--fixtures-dir))
    (buffer-string)))

(defun eca-org-agenda-test--workspace-file (name)
  "Return absolute path for NAME in the current test workspace."
  (expand-file-name name org-directory))

(defun eca-org-agenda-test--read-workspace-file (name)
  "Return the contents of workspace file NAME as a string."
  (with-temp-buffer
    (insert-file-contents (eca-org-agenda-test--workspace-file name))
    (buffer-string)))

(defun eca-org-agenda-test--write-workspace-file (dir relative-path content)
  "Write CONTENT to RELATIVE-PATH under DIR and return the absolute path."
  (let ((path (expand-file-name relative-path dir)))
    (make-directory (file-name-directory path) t)
    (with-temp-file path
      (insert content))
    path))

(defun eca-org-agenda-test--kill-buffers-under (dir)
  "Kill file-visiting buffers rooted under DIR."
  (let ((root (file-truename dir)))
    (dolist (buffer (buffer-list))
      (let ((file (buffer-file-name buffer)))
        (when (and file
                   (string-prefix-p root (file-truename file)))
          (kill-buffer buffer))))))

(defun eca-org-agenda-test--count-matches (regexp string)
  "Count non-overlapping matches for REGEXP in STRING."
  (let ((count 0)
        (start 0))
    (while (string-match regexp string start)
      (setq count (1+ count)
            start (match-end 0)))
    count))

(cl-defun eca-org-agenda-test--call-with-temp-workspace (fn &key files agenda-files (add-id nil))
  "Call FN inside an isolated temporary Org workspace.
FILES is an alist of relative file paths to contents. AGENDA-FILES may be nil
(use all created files), :none (use fallback behavior), or a list of relative
file paths. When ADD-ID is non-nil, allow bridge-created IDs."
  (let* ((tempdir (make-temp-file "eca-org-agenda-test-" t))
         (default-directory tempdir)
         (org-directory tempdir)
         (org-agenda-files nil)
         (org-id-locations-file (expand-file-name ".org-id-locations" tempdir))
         (org-id-locations (make-hash-table :test #'equal))
         (org-id-track-globally t)
         (org-id-extra-files nil)
         (org-archive-location "%s_archive::")
         (org-log-done nil)
         (org-log-into-drawer nil)
         (org-tags-column 0)
         (org-todo-keywords '((sequence "TODO" "DONE")))
         (eca-org-agenda-add-id add-id))
    (unwind-protect
        (let* ((created-paths
                (mapcar (lambda (spec)
                          (eca-org-agenda-test--write-workspace-file
                           tempdir (car spec) (cdr spec)))
                        files))
               (org-agenda-files
                (pcase agenda-files
                  (:none nil)
                  ((pred null) created-paths)
                  (_ (mapcar (lambda (path)
                               (expand-file-name path tempdir))
                             agenda-files)))))
          (funcall fn))
      (ignore-errors (delete-file org-id-locations-file))
      (eca-org-agenda-test--kill-buffers-under tempdir)
      (ignore-errors (delete-directory tempdir t)))))

(cl-defmacro eca-org-agenda-test--with-temp-workspace ((&key files agenda-files (add-id nil)) &body body)
  "Evaluate BODY inside an isolated temporary Org workspace."
  (declare (indent 1) (debug (sexp body)))
  `(eca-org-agenda-test--call-with-temp-workspace
    (lambda () ,@body)
    :files ,files
    :agenda-files ,agenda-files
    :add-id ,add-id))

(ert-deftest eca-org-agenda-bridge-test-fallback-files-default ()
  (should (equal eca-org-agenda-fallback-files '("todo.org"))))

(ert-deftest eca-org-agenda-bridge-test-agenda-files-fall-back-to-todo-org ()
  (eca-org-agenda-test--with-temp-workspace
      (:files '(("todo.org" . "#+title: todo\n"))
       :agenda-files :none)
    (should (equal (eca-org-agenda--agenda-files)
                   (list (eca-org-agenda-test--workspace-file "todo.org"))))))

(ert-deftest eca-org-agenda-bridge-test-normalize-planning-input ()
  (should (equal (eca-org-agenda--normalize-planning-input "<2026-03-15 Sat>")
                 "<2026-03-15 Sat>"))
  (should (equal (eca-org-agenda--normalize-planning-input "[2026-03-15 Sat]")
                 "<2026-03-15 Sat>"))
  (should (equal (eca-org-agenda--normalize-planning-input "2026-03-15")
                 "2026-03-15"))
  (should-not (eca-org-agenda--normalize-planning-input "   ")))

(ert-deftest eca-org-agenda-bridge-test-normalize-heading-path ()
  (should (equal (eca-org-agenda--normalize-heading-path " /foo/bar/ ")
                 '("foo" "bar")))
  (should (equal (eca-org-agenda--normalize-heading-path '(" foo " "bar"))
                 '("foo" "bar")))
  (should-error (eca-org-agenda--normalize-heading-path "") :type 'user-error)
  (should-error (eca-org-agenda--normalize-heading-path '("foo" 1)) :type 'user-error))

(ert-deftest eca-org-agenda-bridge-test-normalize-tags-list ()
  (should (equal (eca-org-agenda--normalize-tags-list ":foo:bar:")
                 '("foo" "bar")))
  (should (equal (eca-org-agenda--normalize-tags-list "foo, bar foo")
                 '("foo" "bar")))
  (should (equal (eca-org-agenda--normalize-tags-list '(" foo " "bar" "foo"))
                 '("foo" "bar")))
  (should-not (eca-org-agenda--normalize-tags-list "   ")))

(ert-deftest eca-org-agenda-bridge-test-format-tags-preserves-preformatted-blocks ()
  (should (equal (eca-org-agenda--format-tags ":foo:")
                 " :foo:"))
  (should (equal (eca-org-agenda--format-tags ":foo:bar:")
                 " :foo:bar:"))
  (should (equal (eca-org-agenda--format-tags "foo bar")
                 " :foo:bar:")))

(ert-deftest eca-org-agenda-bridge-test-dedupe-items-preserves-first-seen-order ()
  (let* ((first-file (list :file "todo.org" :pos 10 :title "first"))
         (second-file (list :file "todo.org" :pos 10 :title "duplicate"))
         (first-id (list :id "abc" :file "todo.org" :pos 20 :title "id-first"))
         (second-id (list :id "abc" :file "todo.org" :pos 30 :title "id-duplicate")))
    (should (equal (eca-org-agenda--dedupe-items
                    (list first-file second-file first-id second-id))
                   (list first-file first-id)))))

(ert-deftest eca-org-agenda-bridge-test-capture-task-creates-top-level-todo ()
  (eca-org-agenda-test--with-temp-workspace
      (:files nil :agenda-files :none :add-id nil)
    (let ((result (eca-org-agenda-capture-task
                   "Write tests"
                   "<2026-03-15 Sat>"
                   "<2026-03-20 Thu>"
                   "Line 1\\nLine 2"
                   "todo.org")))
      (should (equal (plist-get result :title) "Write tests"))
      (should (equal (plist-get result :todo) "TODO"))
      (should (equal (plist-get result :path) '("Write tests")))
      (should (equal (eca-org-agenda-test--read-workspace-file "todo.org")
                     "#+title: todo\n\n* TODO Write tests\nSCHEDULED: <2026-03-15 Sat>\nDEADLINE: <2026-03-20 Thu>\nLine 1\nLine 2\n")))))

(ert-deftest eca-org-agenda-bridge-test-find-heading-by-path-is-exact ()
  (eca-org-agenda-test--with-temp-workspace
      (:files '(("todo.org" . "#+title: todo\n\n* Project\n** Plan\n* Other\n** Plan\n")))
    (let ((match (eca-org-agenda-find-heading-by-path "Project/Plan" "todo.org")))
      (should (equal (plist-get match :title) "Plan"))
      (should (equal (plist-get match :path) '("Project" "Plan"))))
    (should-error (eca-org-agenda-find-heading-in-file "todo.org" "Plan")
                  :type 'user-error)
    (should-error (eca-org-agenda-find-heading-by-path "Project/Missing" "todo.org")
                  :type 'user-error)))

(ert-deftest eca-org-agenda-bridge-test-ensure-child-heading-by-path-is-idempotent ()
  (eca-org-agenda-test--with-temp-workspace
      (:files '(("todo.org" . "#+title: todo\n\n* Project\nInitial parent body\n")))
    (let ((first (eca-org-agenda-ensure-child-heading-by-path "Project" "Plan" :file "todo.org"))
          (second (eca-org-agenda-ensure-child-heading-by-path "Project" "Plan" :file "todo.org")))
      (should (equal (plist-get first :title) "Plan"))
      (should (equal (plist-get first :pos) (plist-get second :pos))))
    (should (= 1 (eca-org-agenda-test--count-matches
                  "^\\*\\* Plan$"
                  (eca-org-agenda-test--read-workspace-file "todo.org"))))))

(ert-deftest eca-org-agenda-bridge-test-get-body-by-path-excludes-child-subtree ()
  (eca-org-agenda-test--with-temp-workspace
      (:files '(("todo.org" . "#+title: todo\n\n* Project\nLine 1\nLine 2\n** Child\nChild line\n")))
    (let ((result (eca-org-agenda-get-body-by-path "Project" :file "todo.org")))
      (should (equal (plist-get result :body) "Line 1\nLine 2"))
      (should-not (string-match-p "Child" (plist-get result :body))))))

(ert-deftest eca-org-agenda-bridge-test-replace-body-by-path-preserves-structure ()
  (eca-org-agenda-test--with-temp-workspace
      (:files `(("todo.org" . ,(eca-org-agenda-test--fixture-contents "replace-body-before.org"))))
    (eca-org-agenda-replace-body-by-path "Project" "New line 1\\nNew line 2" :file "todo.org")
    (should (equal (eca-org-agenda-test--read-workspace-file "todo.org")
                   (eca-org-agenda-test--fixture-contents "replace-body-after.org")))))

(ert-deftest eca-org-agenda-bridge-test-append-body-by-path-handles-newlines ()
  (eca-org-agenda-test--with-temp-workspace
      (:files `(("todo.org" . ,(eca-org-agenda-test--fixture-contents "append-body-before.org"))))
    (eca-org-agenda-append-body-by-path "With Body" "Added line" :file "todo.org")
    (eca-org-agenda-append-body-by-path "Empty Body" "First inserted line" :file "todo.org")
    (should (equal (eca-org-agenda-test--read-workspace-file "todo.org")
                   (eca-org-agenda-test--fixture-contents "append-body-after.org")))))

(ert-deftest eca-org-agenda-bridge-test-task-state-and-planning-roundtrip ()
  (eca-org-agenda-test--with-temp-workspace
      (:files '(("todo.org" . "#+title: todo\n\n* TODO Task\n")))
    (let* ((item (eca-org-agenda-find-heading-in-file "todo.org" "Task"))
           (file (plist-get item :file))
           (pos (plist-get item :pos))
           (done (eca-org-agenda-set-todo-at file pos "DONE"))
           (scheduled (eca-org-agenda-schedule-at file pos "[2026-04-02 Thu]"))
           (deadline (eca-org-agenda-deadline-at file pos "[2026-04-10 Fri]")))
      (should (equal (plist-get done :todo) "DONE"))
      (should (equal (plist-get scheduled :scheduled) "<2026-04-02 Thu>"))
      (should (equal (plist-get deadline :deadline) "<2026-04-10 Fri>"))
      (let ((text (eca-org-agenda-test--read-workspace-file "todo.org")))
        (should (string-match-p "\\* DONE Task" text))
        (should (string-match-p "SCHEDULED: <2026-04-02 Thu>" text))
        (should (string-match-p "DEADLINE: <2026-04-10 Fri>" text))))))

(ert-deftest eca-org-agenda-bridge-test-tag-mutation-roundtrip ()
  (eca-org-agenda-test--with-temp-workspace
      (:files '(("todo.org" . "#+title: todo\n\n* TODO Tagged :one:\n")))
    (let* ((item (eca-org-agenda-find-heading-in-file "todo.org" "Tagged"))
           (file (plist-get item :file))
           (pos (plist-get item :pos))
           (set-result (eca-org-agenda-set-tags-at file pos "one two"))
           (_added (eca-org-agenda-add-tags-at file pos '("three" "two")))
           (removed (eca-org-agenda-remove-tags-at file pos '("one"))))
      (should (equal (plist-get set-result :tags) '("one" "two")))
      (should (equal (plist-get removed :tags) '("two" "three")))
      (should (string-match-p "\\* TODO Tagged[[:space:]]+:two:three:" 
                              (eca-org-agenda-test--read-workspace-file "todo.org"))))))

(ert-deftest eca-org-agenda-bridge-test-find-id-and-set-todo-id ()
  (eca-org-agenda-test--with-temp-workspace
      (:files '(("todo.org" . "#+title: todo\n\n* TODO Identified Task\n:PROPERTIES:\n:ID: 11111111-2222-3333-4444-555555555555\n:END:\n")))
    (let* ((id "11111111-2222-3333-4444-555555555555")
           (found (eca-org-agenda-find-id id))
           (updated (eca-org-agenda-set-todo-id id "DONE")))
      (should (equal (plist-get found :id) id))
      (should (equal (plist-get found :title) "Identified Task"))
      (should (equal (plist-get updated :todo) "DONE"))
      (should (string-match-p "^\\* DONE Identified Task$"
                              (eca-org-agenda-test--read-workspace-file "todo.org"))))))

(ert-deftest eca-org-agenda-bridge-test-refile-id-to-file-moves-subtree ()
  (eca-org-agenda-test--with-temp-workspace
      (:files '(("todo.org" . "#+title: todo\n\n* TODO Move Me\n:PROPERTIES:\n:ID: refile-source-11111111-2222-3333-4444-555555555555\n:END:\nSource body\n** Child\nChild line\n\n* Keep Me\n")
                ("target.org" . "#+title: target\n\n")))
    (let* ((id "refile-source-11111111-2222-3333-4444-555555555555")
           (result (eca-org-agenda-refile-id-to-file id "target.org"))
           (relocated (eca-org-agenda-find-id id))
           (source-text (eca-org-agenda-test--read-workspace-file "todo.org"))
           (target-text (eca-org-agenda-test--read-workspace-file "target.org")))
      (should (plist-get result :refiled))
      (should (equal (plist-get relocated :file)
                     (eca-org-agenda-test--workspace-file "target.org")))
      (should (equal (plist-get relocated :path) '("Move Me")))
      (should-not (string-match-p "^\\* TODO Move Me$" source-text))
      (should (string-match-p "^\\* Keep Me$" source-text))
      (should (string-match-p "^\\* TODO Move Me$" target-text))
      (should (string-match-p "^\\*\\* Child$" target-text)))))

(ert-deftest eca-org-agenda-bridge-test-refile-id-to-id-moves-subtree-under-target ()
  (eca-org-agenda-test--with-temp-workspace
      (:files '(("todo.org" . "#+title: todo\n\n* TODO Source\n:PROPERTIES:\n:ID: source-11111111-2222-3333-4444-555555555555\n:END:\nSource body\n\n* Target\n:PROPERTIES:\n:ID: target-aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee\n:END:\nTarget body\n\n* After\n")))
    (let* ((source-id "source-11111111-2222-3333-4444-555555555555")
           (target-id "target-aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee")
           (result (eca-org-agenda-refile-id-to-id source-id target-id))
           (relocated (eca-org-agenda-find-id source-id))
           (text (eca-org-agenda-test--read-workspace-file "todo.org")))
      (should (plist-get result :refiled))
      (should (equal (plist-get relocated :path) '("Target" "Source")))
      (should-not (string-match-p "^\\* TODO Source$" text))
      (should (= 1 (eca-org-agenda-test--count-matches "^\\*\\* TODO Source$" text)))
      (should (string-match-p "^\\* After$" text)))))

(ert-deftest eca-org-agenda-bridge-test-refile-id-to-id-errors-on-own-subtree ()
  (eca-org-agenda-test--with-temp-workspace
      (:files '(("todo.org" . "#+title: todo\n\n* TODO Parent\n:PROPERTIES:\n:ID: parent-11111111-2222-3333-4444-555555555555\n:END:\n** Child\n:PROPERTIES:\n:ID: child-aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee\n:END:\n")))
    (let ((before (eca-org-agenda-test--read-workspace-file "todo.org")))
      (should-error
       (eca-org-agenda-refile-id-to-id
        "parent-11111111-2222-3333-4444-555555555555"
        "child-aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee")
       :type 'user-error)
      (should (equal before (eca-org-agenda-test--read-workspace-file "todo.org"))))))

(ert-deftest eca-org-agenda-bridge-test-archive-id-moves-subtree-to-archive-file ()
  (eca-org-agenda-test--with-temp-workspace
      (:files '(("todo.org" . "#+title: todo\n\n* TODO Archive Me\n:PROPERTIES:\n:ID: archive-11111111-2222-3333-4444-555555555555\n:END:\nArchived body\n\n* Keep Me\n")
                ("archive.org" . "#+title: archive\n\n")))
    (let* ((org-archive-location "archive.org::")
           (id "archive-11111111-2222-3333-4444-555555555555")
           (result (eca-org-agenda-archive-id id))
           (source-text (eca-org-agenda-test--read-workspace-file "todo.org"))
           (archive-text (eca-org-agenda-test--read-workspace-file "archive.org")))
      (should (plist-get result :archived))
      (should (equal (plist-get result :title) "Archive Me"))
      (should-not (string-match-p "^\\* TODO Archive Me$" source-text))
      (should (string-match-p "^\\* Keep Me$" source-text))
      (should (string-match-p "Archive Me" archive-text))
      (should (string-match-p id archive-text)))))

(ert-deftest eca-org-agenda-bridge-test-summary-buckets-items-by-date ()
  (eca-org-agenda-test--with-temp-workspace
      (:files '(("todo.org" . "#+title: todo\n\n* TODO Overdue\nSCHEDULED: <2026-04-08 Wed>\n\n* TODO Today\nDEADLINE: <2026-04-10 Fri>\n\n* TODO Upcoming\nSCHEDULED: <2026-04-12 Sun>\n\n* TODO Unscheduled\n")))
    (let* ((summary (eca-org-agenda-summary 7 "2026-04-10" nil))
           (counts (plist-get summary :counts)))
      (should (equal (plist-get summary :reference-day) "2026-04-10"))
      (should (= 1 (plist-get counts :overdue)))
      (should (= 1 (plist-get counts :today)))
      (should (= 1 (plist-get counts :upcoming)))
      (should (= 1 (plist-get counts :unscheduled)))
      (should (equal (mapcar (lambda (item) (plist-get item :title))
                             (plist-get summary :overdue))
                     '("Overdue")))
      (should (equal (mapcar (lambda (item) (plist-get item :title))
                             (plist-get summary :today))
                     '("Today")))
      (should (equal (mapcar (lambda (item) (plist-get item :title))
                             (plist-get summary :upcoming))
                     '("Upcoming")))
      (should (equal (mapcar (lambda (item) (plist-get item :title))
                             (plist-get summary :unscheduled))
                     '("Unscheduled"))))))

(provide 'eca-org-agenda-bridge-test)
;;; eca-org-agenda-bridge-test.el ends here
