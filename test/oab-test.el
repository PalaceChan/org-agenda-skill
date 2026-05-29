;;; oab-test.el --- ERT tests for Org agenda bridge -*- lexical-binding: t; -*-

(require 'cl-lib)
(require 'ert)
(require 'org)
(require 'org-id)

(defconst oab-test--file
  (or load-file-name buffer-file-name)
  "Absolute path to this test file.")

(defconst oab-test--root-dir
  (file-name-directory
   (directory-file-name
    (file-name-directory oab-test--file)))
  "Repository root for the org-agenda skill project.")

(defconst oab-test--bridge-file
  (expand-file-name "scripts/oab.el" oab-test--root-dir)
  "Absolute path to the bridge file under test.")

(defconst oab-test--fixtures-dir
  (expand-file-name "test/fixtures" oab-test--root-dir)
  "Directory containing golden Org fixtures.")

(load-file oab-test--bridge-file)

(defun oab-test--fixture-contents (name)
  "Return the contents of fixture NAME as a string."
  (with-temp-buffer
    (insert-file-contents (expand-file-name name oab-test--fixtures-dir))
    (buffer-string)))

(defun oab-test--workspace-file (name)
  "Return absolute path for NAME in the current test workspace."
  (expand-file-name name org-directory))

(defun oab-test--read-workspace-file (name)
  "Return the contents of workspace file NAME as a string."
  (with-temp-buffer
    (insert-file-contents (oab-test--workspace-file name))
    (buffer-string)))

(defun oab-test--write-workspace-file (dir relative-path content)
  "Write CONTENT to RELATIVE-PATH under DIR and return the absolute path."
  (let ((path (expand-file-name relative-path dir)))
    (make-directory (file-name-directory path) t)
    (with-temp-file path
      (insert content))
    path))

(defun oab-test--kill-buffers-under (dir)
  "Kill file-visiting buffers rooted under DIR."
  (let ((root (file-truename dir)))
    (dolist (buffer (buffer-list))
      (let ((file (buffer-file-name buffer)))
        (when (and file
                   (string-prefix-p root (file-truename file)))
          (kill-buffer buffer))))))

(defun oab-test--count-matches (regexp string)
  "Count non-overlapping matches for REGEXP in STRING."
  (let ((count 0)
        (start 0))
    (while (string-match regexp string start)
      (setq count (1+ count)
            start (match-end 0)))
    count))

(cl-defun oab-test--call-with-temp-workspace (fn &key files agenda-files (add-id nil))
  "Call FN inside an isolated temporary Org workspace.
FILES is an alist of relative file paths to contents. AGENDA-FILES may be nil
(use all created files), :none (use fallback behavior), or a list of relative
file paths. When ADD-ID is non-nil, allow bridge-created IDs."
  (let* ((tempdir (make-temp-file "oab-test-" t))
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
         (oab-add-id add-id))
    (unwind-protect
        (let* ((created-paths
                (mapcar (lambda (spec)
                          (oab-test--write-workspace-file
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
      (oab-test--kill-buffers-under tempdir)
      (ignore-errors (delete-directory tempdir t)))))

(cl-defmacro oab-test--with-temp-workspace ((&key files agenda-files (add-id nil)) &body body)
  "Evaluate BODY inside an isolated temporary Org workspace."
  (declare (indent 1) (debug (sexp body)))
  `(oab-test--call-with-temp-workspace
    (lambda () ,@body)
    :files ,files
    :agenda-files ,agenda-files
    :add-id ,add-id))

(ert-deftest oab-test-fallback-files-default ()
  (should (equal oab-fallback-files '("todo.org"))))

(ert-deftest oab-test-agenda-files-fall-back-to-todo-org ()
  (oab-test--with-temp-workspace
      (:files '(("todo.org" . "#+title: todo\n"))
       :agenda-files :none)
    (should (equal (oab--agenda-files)
                   (list (oab-test--workspace-file "todo.org"))))))

(ert-deftest oab-test-normalize-planning-input ()
  (should (equal (oab--normalize-planning-input "<2026-03-15 Sat>")
                 "<2026-03-15 Sat>"))
  (should (equal (oab--normalize-planning-input "[2026-03-15 Sat]")
                 "<2026-03-15 Sat>"))
  (should (equal (oab--normalize-planning-input "2026-03-15")
                 "2026-03-15"))
  (should-not (oab--normalize-planning-input "   ")))

(ert-deftest oab-test-normalize-heading-path ()
  (should (equal (oab--normalize-heading-path " /foo/bar/ ")
                 '("foo" "bar")))
  (should (equal (oab--normalize-heading-path '(" foo " "bar"))
                 '("foo" "bar")))
  (should-error (oab--normalize-heading-path "") :type 'user-error)
  (should-error (oab--normalize-heading-path '("foo" 1)) :type 'user-error))

(ert-deftest oab-test-normalize-tags-list ()
  (should (equal (oab--normalize-tags-list ":foo:bar:")
                 '("foo" "bar")))
  (should (equal (oab--normalize-tags-list "foo, bar foo")
                 '("foo" "bar")))
  (should (equal (oab--normalize-tags-list '(" foo " "bar" "foo"))
                 '("foo" "bar")))
  (should-not (oab--normalize-tags-list "   ")))

(ert-deftest oab-test-format-tags-preserves-preformatted-blocks ()
  (should (equal (oab--format-tags ":foo:")
                 " :foo:"))
  (should (equal (oab--format-tags ":foo:bar:")
                 " :foo:bar:"))
  (should (equal (oab--format-tags "foo bar")
                 " :foo:bar:"))
  (should (equal (oab--format-tags ":foo::")
                 " :foo:"))
  (should (equal (oab--format-tags ":foo: bar:")
                 " :foo:bar:")))

(ert-deftest oab-test-dedupe-items-preserves-first-seen-order ()
  (let* ((first-file (list :file "todo.org" :pos 10 :title "first"))
         (second-file (list :file "todo.org" :pos 10 :title "duplicate"))
         (first-id (list :id "abc" :file "todo.org" :pos 20 :title "id-first"))
         (second-id (list :id "abc" :file "todo.org" :pos 30 :title "id-duplicate")))
    (should (equal (oab--dedupe-items
                    (list first-file second-file first-id second-id))
                   (list first-file first-id)))))

(ert-deftest oab-test-capture-task-creates-top-level-todo ()
  (oab-test--with-temp-workspace
      (:files nil :agenda-files :none :add-id nil)
    (let ((result (oab-capture-task
                   "Write tests"
                   "<2026-03-15 Sat>"
                   "<2026-03-20 Thu>"
                   "Line 1\\nLine 2"
                   "todo.org")))
      (should (equal (plist-get result :title) "Write tests"))
      (should (equal (plist-get result :todo) "TODO"))
      (should (equal (plist-get result :path) '("Write tests")))
      (should (equal (oab-test--read-workspace-file "todo.org")
                     "#+title: todo\n\n* TODO Write tests\nSCHEDULED: <2026-03-15 Sat>\nDEADLINE: <2026-03-20 Thu>\nLine 1\nLine 2\n")))))

(ert-deftest oab-test-find-heading-by-path-is-exact ()
  (oab-test--with-temp-workspace
      (:files '(("todo.org" . "#+title: todo\n\n* Project\n** Plan\n* Other\n** Plan\n")))
    (let ((match (oab-find-heading-by-path "Project/Plan" "todo.org")))
      (should (equal (plist-get match :title) "Plan"))
      (should (equal (plist-get match :path) '("Project" "Plan"))))
    (should-error (oab-find-heading-in-file "todo.org" "Plan")
                  :type 'user-error)
    (should-error (oab-find-heading-by-path "Project/Missing" "todo.org")
                  :type 'user-error)))

(ert-deftest oab-test-ensure-child-heading-by-path-is-idempotent ()
  (oab-test--with-temp-workspace
      (:files '(("todo.org" . "#+title: todo\n\n* Project\nInitial parent body\n")))
    (let ((first (oab-ensure-child-heading-by-path "Project" "Plan" :file "todo.org"))
          (second (oab-ensure-child-heading-by-path "Project" "Plan" :file "todo.org")))
      (should (equal (plist-get first :title) "Plan"))
      (should (equal (plist-get first :pos) (plist-get second :pos))))
    (should (= 1 (oab-test--count-matches
                  "^\\*\\* Plan$"
                  (oab-test--read-workspace-file "todo.org"))))))

(ert-deftest oab-test-get-body-by-path-excludes-child-subtree ()
  (oab-test--with-temp-workspace
      (:files '(("todo.org" . "#+title: todo\n\n* Project\nLine 1\nLine 2\n** Child\nChild line\n")))
    (let ((result (oab-get-body-by-path "Project" :file "todo.org")))
      (should (equal (plist-get result :body) "Line 1\nLine 2"))
      (should-not (string-match-p "Child" (plist-get result :body))))))

(ert-deftest oab-test-entry-metadata-includes-body-subtree-and-child-size ()
  (oab-test--with-temp-workspace
      (:files '(("todo.org" . "#+title: todo\n\n* Project\nLine 1\nLine 2\n** Child\nChild line\n")))
    (let ((result (oab-find-heading-by-path "Project" "todo.org")))
      (should (eq (plist-get result :has-children) t))
      (should (= 1 (plist-get result :child-count)))
      (should (= 2 (plist-get result :body-lines)))
      (should (= 14 (plist-get result :body-chars)))
      (should (= 5 (plist-get result :subtree-lines)))
      (should (= 44 (plist-get result :subtree-chars))))))

(ert-deftest oab-test-get-body-can-return-metadata-only ()
  (oab-test--with-temp-workspace
      (:files '(("todo.org" . "#+title: todo\n\n* Project\nLine 1\nLine 2\n** Child\nChild line\n")))
    (let ((result (oab-get-body-by-path
                   "Project"
                   :file "todo.org"
                   :return-body nil)))
      (should-not (plist-member result :body))
      (should (eq (plist-get result :has-children) t))
      (should (= 1 (plist-get result :child-count)))
      (should (= 2 (plist-get result :body-lines))))))

(ert-deftest oab-test-replace-body-by-path-preserves-structure ()
  (oab-test--with-temp-workspace
      (:files `(("todo.org" . ,(oab-test--fixture-contents "replace-body-before.org"))))
    (oab-replace-body-by-path "Project" "New line 1\\nNew line 2" :file "todo.org")
    (should (equal (oab-test--read-workspace-file "todo.org")
                   (oab-test--fixture-contents "replace-body-after.org")))))

(ert-deftest oab-test-append-body-by-path-handles-newlines ()
  (oab-test--with-temp-workspace
      (:files `(("todo.org" . ,(oab-test--fixture-contents "append-body-before.org"))))
    (oab-append-body-by-path "With Body" "Added line" :file "todo.org")
    (oab-append-body-by-path "Empty Body" "First inserted line" :file "todo.org")
    (should (equal (oab-test--read-workspace-file "todo.org")
                   (oab-test--fixture-contents "append-body-after.org")))))

(ert-deftest oab-test-body-mutations-can-omit-returned-body ()
  (oab-test--with-temp-workspace
      (:files '(("todo.org" . "#+title: todo\n\n* Task\nOld\n")))
    (let ((default-result (oab-replace-body-by-path
                           "Task" "New" :file "todo.org")))
      (should (plist-member default-result :body))
      (should (equal (plist-get default-result :body) "New")))
    (let ((metadata-result (oab-append-body-by-path
                            "Task" "More" :file "todo.org" :return-body nil)))
      (should-not (plist-member metadata-result :body))
      (should (= 2 (plist-get metadata-result :body-lines))))
    (let ((quiet-result (oab-replace-body-by-path
                         "Task" "Quiet" :file "todo.org" :quiet t)))
      (should-not (plist-member quiet-result :body))
      (should (= 1 (plist-get quiet-result :body-lines))))
    (should (equal (plist-get (oab-get-body-by-path "Task" :file "todo.org")
                              :body)
                   "Quiet"))))

(ert-deftest oab-test-body-from-file-helpers-default-to-metadata-only ()
  (oab-test--with-temp-workspace
      (:files '(("todo.org" . "#+title: todo\n\n* Task\n:PROPERTIES:\n:ID: from-file-task-11111111-2222-3333-4444-555555555555\n:END:\nOld\n")))
    (let* ((id "from-file-task-11111111-2222-3333-4444-555555555555")
           (replace-path-file (oab-test--write-workspace-file
                               org-directory "replace-path-body.org" "Path line 1\nPath line 2\n"))
           (append-path-file (oab-test--write-workspace-file
                              org-directory "append-path-body.org" "Path line 3\n"))
           (replace-id-file (oab-test--write-workspace-file
                             org-directory "replace-id-body.org" "ID line 1\n"))
           (append-id-file (oab-test--write-workspace-file
                            org-directory "append-id-body.org" "ID line 2\n"))
           (replace-path (oab-replace-body-by-path-from-file
                          "Task" replace-path-file :file "todo.org"))
           (append-path (oab-append-body-by-path-from-file
                         "Task" append-path-file :file "todo.org"))
           (replace-id (oab-replace-body-id-from-file id replace-id-file))
           (append-id (oab-append-body-id-from-file id append-id-file)))
      (dolist (result (list replace-path append-path replace-id append-id))
        (should-not (plist-member result :body)))
      (should (= 2 (plist-get append-id :body-lines)))
      (should (equal (plist-get (oab-get-body-id id) :body)
                     "ID line 1\nID line 2")))))

(ert-deftest oab-test-subtree-readers-support-metadata-only-and-heading-control ()
  (oab-test--with-temp-workspace
      (:files '(("todo.org" . "#+title: todo\n\n* Project\n:PROPERTIES:\n:ID: subtree-project-11111111-2222-3333-4444-555555555555\n:END:\nParent body\n** Child\nChild body\n*** Grandchild\nDeep body\n** Child 2\n")))
    (let* ((id "subtree-project-11111111-2222-3333-4444-555555555555")
           (by-id (oab-get-subtree-id id))
           (without-heading (oab-get-subtree-by-path
                             "Project" :file "todo.org" :include-heading nil))
           (metadata (oab-get-subtree-by-path
                      "Project" :file "todo.org" :return-subtree nil))
           (at (oab-get-subtree-at
                (plist-get metadata :file)
                (plist-get metadata :pos)
                :return-subtree nil)))
      (should (plist-member by-id :subtree))
      (should (string-prefix-p "* Project\n" (plist-get by-id :subtree)))
      (should (plist-member without-heading :subtree))
      (should-not (string-prefix-p "* Project" (plist-get without-heading :subtree)))
      (should (string-match-p "Parent body" (plist-get without-heading :subtree)))
      (should-not (plist-member metadata :subtree))
      (should-not (plist-member at :subtree))
      (should (eq (plist-get metadata :has-children) t))
      (should (= 2 (plist-get metadata :child-count)))
      (should (= 2 (plist-get at :child-count))))))

(ert-deftest oab-test-task-state-and-planning-roundtrip ()
  (oab-test--with-temp-workspace
      (:files '(("todo.org" . "#+title: todo\n\n* TODO Task\n")))
    (let* ((item (oab-find-heading-in-file "todo.org" "Task"))
           (file (plist-get item :file))
           (pos (plist-get item :pos))
           (done (oab-set-todo-at file pos "DONE"))
           (scheduled (oab-schedule-at file pos "[2026-04-02 Thu]"))
           (deadline (oab-deadline-at file pos "[2026-04-10 Fri]")))
      (should (equal (plist-get done :todo) "DONE"))
      (should (equal (plist-get scheduled :scheduled) "<2026-04-02 Thu>"))
      (should (equal (plist-get deadline :deadline) "<2026-04-10 Fri>"))
      (let ((text (oab-test--read-workspace-file "todo.org")))
        (should (string-match-p "\\* DONE Task" text))
        (should (string-match-p "SCHEDULED: <2026-04-02 Thu>" text))
        (should (string-match-p "DEADLINE: <2026-04-10 Fri>" text))))))

(ert-deftest oab-test-tag-mutation-roundtrip ()
  (oab-test--with-temp-workspace
      (:files '(("todo.org" . "#+title: todo\n\n* TODO Tagged :one:\n")))
    (let* ((item (oab-find-heading-in-file "todo.org" "Tagged"))
           (file (plist-get item :file))
           (pos (plist-get item :pos))
           (set-result (oab-set-tags-at file pos "one two"))
           (_added (oab-add-tags-at file pos '("three" "two")))
           (removed (oab-remove-tags-at file pos '("one"))))
      (should (equal (plist-get set-result :tags) '("one" "two")))
      (should (equal (plist-get removed :tags) '("two" "three")))
      (should (string-match-p "\\* TODO Tagged[[:space:]]+:two:three:" 
                              (oab-test--read-workspace-file "todo.org"))))))

(ert-deftest oab-test-find-id-and-set-todo-id ()
  (oab-test--with-temp-workspace
      (:files '(("todo.org" . "#+title: todo\n\n* TODO Identified Task\n:PROPERTIES:\n:ID: 11111111-2222-3333-4444-555555555555\n:END:\n")))
    (let* ((id "11111111-2222-3333-4444-555555555555")
           (found (oab-find-id id))
           (updated (oab-set-todo-id id "DONE")))
      (should (equal (plist-get found :id) id))
      (should (equal (plist-get found :title) "Identified Task"))
      (should (equal (plist-get updated :todo) "DONE"))
      (should (string-match-p "^\\* DONE Identified Task$"
                              (oab-test--read-workspace-file "todo.org"))))))

(ert-deftest oab-test-refile-id-to-file-moves-subtree ()
  (oab-test--with-temp-workspace
      (:files '(("todo.org" . "#+title: todo\n\n* TODO Move Me\n:PROPERTIES:\n:ID: refile-source-11111111-2222-3333-4444-555555555555\n:END:\nSource body\n** Child\nChild line\n\n* Keep Me\n")
                ("target.org" . "#+title: target\n\n")))
    (let* ((id "refile-source-11111111-2222-3333-4444-555555555555")
           (result (oab-refile-id-to-file id "target.org"))
           (relocated (oab-find-id id))
           (source-text (oab-test--read-workspace-file "todo.org"))
           (target-text (oab-test--read-workspace-file "target.org")))
      (should (plist-get result :refiled))
      (should (equal (plist-get relocated :file)
                     (oab-test--workspace-file "target.org")))
      (should (equal (plist-get relocated :path) '("Move Me")))
      (should-not (string-match-p "^\\* TODO Move Me$" source-text))
      (should (string-match-p "^\\* Keep Me$" source-text))
      (should (string-match-p "^\\* TODO Move Me$" target-text))
      (should (string-match-p "^\\*\\* Child$" target-text)))))

(ert-deftest oab-test-refile-id-to-id-moves-subtree-under-target ()
  (oab-test--with-temp-workspace
      (:files '(("todo.org" . "#+title: todo\n\n* TODO Source\n:PROPERTIES:\n:ID: source-11111111-2222-3333-4444-555555555555\n:END:\nSource body\n\n* Target\n:PROPERTIES:\n:ID: target-aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee\n:END:\nTarget body\n\n* After\n")))
    (let* ((source-id "source-11111111-2222-3333-4444-555555555555")
           (target-id "target-aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee")
           (result (oab-refile-id-to-id source-id target-id))
           (relocated (oab-find-id source-id))
           (text (oab-test--read-workspace-file "todo.org")))
      (should (plist-get result :refiled))
      (should (equal (plist-get relocated :path) '("Target" "Source")))
      (should-not (string-match-p "^\\* TODO Source$" text))
      (should (= 1 (oab-test--count-matches "^\\*\\* TODO Source$" text)))
      (should (string-match-p "^\\* After$" text)))))

(ert-deftest oab-test-refile-id-to-id-errors-on-own-subtree ()
  (oab-test--with-temp-workspace
      (:files '(("todo.org" . "#+title: todo\n\n* TODO Parent\n:PROPERTIES:\n:ID: parent-11111111-2222-3333-4444-555555555555\n:END:\n** Child\n:PROPERTIES:\n:ID: child-aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee\n:END:\n")))
    (let ((before (oab-test--read-workspace-file "todo.org")))
      (should-error
       (oab-refile-id-to-id
        "parent-11111111-2222-3333-4444-555555555555"
        "child-aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee")
       :type 'user-error)
      (should (equal before (oab-test--read-workspace-file "todo.org"))))))

(ert-deftest oab-test-archive-id-moves-subtree-to-archive-file ()
  (oab-test--with-temp-workspace
      (:files '(("todo.org" . "#+title: todo\n\n* TODO Archive Me\n:PROPERTIES:\n:ID: archive-11111111-2222-3333-4444-555555555555\n:END:\nArchived body\n\n* Keep Me\n")
                ("archive.org" . "#+title: archive\n\n")))
    (let* ((org-archive-location "archive.org::")
           (id "archive-11111111-2222-3333-4444-555555555555")
           (result (oab-archive-id id))
           (source-text (oab-test--read-workspace-file "todo.org"))
           (archive-text (oab-test--read-workspace-file "archive.org")))
      (should (plist-get result :archived))
      (should (equal (plist-get result :title) "Archive Me"))
      (should-not (string-match-p "^\\* TODO Archive Me$" source-text))
      (should (string-match-p "^\\* Keep Me$" source-text))
      (should (string-match-p "Archive Me" archive-text))
      (should (string-match-p id archive-text)))))

(ert-deftest oab-test-summary-buckets-items-by-date ()
  (oab-test--with-temp-workspace
      (:files '(("todo.org" . "#+title: todo\n\n* TODO Overdue\nSCHEDULED: <2026-04-08 Wed>\n\n* TODO Today\nDEADLINE: <2026-04-10 Fri>\n\n* TODO Upcoming\nSCHEDULED: <2026-04-12 Sun>\n\n* TODO Unscheduled\n")))
    (let* ((summary (oab-summary 7 "2026-04-10" nil))
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

(provide 'oab-test)
;;; oab-test.el ends here
