;;; orb-pdf-scrapper.el --- Orb Roam BibTeX: PDF reference scrapper -*- coding: utf-8; lexical-binding: t -*-

;; Copyright © 2020 Mykhailo Shevchuk <mail@mshevchuk.com>
;; Copyright © 2020 Leo Vivier <leo.vivier+dev@gmail.com>

;; Author: Mykhailo Shevchuk <mail@mshevchuk.com>
;;         Leo Vivier <leo.vivier+dev@gmail.com>
;; URL: https://github.com/org-roam/org-roam-bibtex
;; Keywords: org-mode, roam, convenience, bibtex, helm-bibtex, ivy-bibtex, org-ref
;; Version: 0.2.3

;; This file is NOT part of GNU Emacs.

;; This program is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation; either version 3, or (at your option)
;; any later version.
;;
;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.
;;
;; You should have received a copy of the GNU General Public License
;; along with GNU Emacs; see the file COPYING.  If not, write to the
;; Free Software Foundation, Inc., 51 Franklin Street, Fifth Floor,
;; Boston, MA 02110-1301, USA.

;; N.B. This file contains code snippets adopted from other
;; open-source projects. These snippets are explicitly marked as such
;; in place. They are not subject to the above copyright and
;; authorship claims.

;;; Commentary:
;;

;;; Code:
;; * Library requires

(require 'orb-core)
(require 'orb-anystyle)

(require 'bibtex)
(require 'rx)
(require 'cl-extra)

(eval-when-compile
  (require 'cl-lib)
  (require 'cl-macs)
  (require 'subr-x))

(declare-function bibtex-set-field "org-ref" (field value &optional nodelim))
;; * Customize definitions

;; TODO: make these defcustom

(defvar orb-pdf-scrapper-refsection-headings
  '((parent . ("References"))
    (in-roam . ("In Org Roam database" list))
    (in-bib . ("In BibTeX file" list))
    (valid . ("Valid citation keys" table))
    (invalid . ("Invalid citation keys" table))))

(defvar orb-pdf-scrapper-bibkey-set-fields
  '(("pages" . orb-pdf-scrapper--fix-or-invalidate-range)
    ("author" . orb-pdf-scrapper--invalidate-nil-value)
    ("title" . orb-pdf-scrapper--invalidate-nil-value)
    ("journal" . orb-pdf-scrapper--invalidate-nil-value)
    ("date" . orb-pdf-scrapper--invalidate-nil-value)
    ("volume" . orb-pdf-scrapper--invalidate-nil-value)))

(defvar orb-pdf-scrapper-bibkey-export-fields
  '("author" "journal" "date" "volume" "pages"))

(defvar orb-pdf-scrapper-invalid-key-pattern "\\`.*N/A.*\\'")

;; * Helper functions: citekey generation

(defvar orb-pdf-scrapper--refs nil)

(defun orb-pdf-scrapper--invalidate-nil-value (field entry)
  "Return value of FIELD or `orb-autokey-invalid-field-token' if it is nil.
ENTRY is a BibTeX entry."
  (bibtex-completion-get-value field entry orb-autokey-invalid-field-token))

(defun orb-pdf-scrapper--fix-or-invalidate-range (field entry)
  "Replace missing or non-standard delimiter between two strings with \"--\".
FIELD is the name of a BibTeX field from ENTRY.  Return
`orb-autokey-invalid-field-token' if the value is nil.

This function is primarily intended for fixing anystyle parsing
artefacts such as those often encountered in \"pages\" field,
where two numbers have only spaces between them."
  (replace-regexp-in-string "\\`[[:alnum:]]\\([ –-]+\\)[[:alnum:]]\\'"
                            "--"
                            (bibtex-completion-get-value
                             field entry orb-autokey-invalid-field-token)
                            nil nil 1))

(defun orb-pdf-scrapper--compose-entry (entry &optional collect-only)
  "Compile information from and about the BibTeX ENTRY for further use.
Take a bibtex entry as returned by `bibtex-completion-get-entry'\
and return a plist with the following keys set:

:key            |string | citekey generated with `orb-autokey-generate-key'
:validp         |boolean| according to `orb-pdf-scrapper-invalid-key-pattern'
:set-fields     |(cons) | as per `orb-pdf-scrapper-bibkey-set-fields'
:export-fields  |(cons) | as per `orb-pdf-scrapper-bibkey-export-fields'

Each element of `:set-fields' and `:export-fields' lists is a
a cons cell (FIELD . VALUE).

If optional COLLECT-ONLY is non-nil, do not generate the key,
`:set-fields' is set to nil."
  (let (key validp set-fields export-fields ;; return values
            ;; internal variable
            fields)
    ;; when requested to collect keys, just do that
    (if collect-only
        (setq key (bibtex-completion-get-value "=key=" entry)
              fields entry)
    ;; otherwise
    ;; prepare fields for setting
    (dolist (field orb-pdf-scrapper-bibkey-set-fields)
      (let ((name (car field))
            (fn (cdr field)))
        (cl-pushnew (cons name
                          (if fn
                              (funcall fn name entry)
                            (bibtex-completion-get-value name entry)))
                    set-fields)))
    ;; prioritize fields from set-fields over entry fields
    ;; for autokey generation
      (let ((-compare-fn (lambda (x y)
                           (string= (car x) (car y)))))
        (setq fields (-union set-fields entry)
              key (orb-autokey-generate-key fields))))
    ;; validate the new shiny key (or the old existing one)
    ;; not sure if save-match-data is needed here
    ;; but it seems to be always a good choice
    (save-match-data
      (setq validp (and (not (string-match-p
                              orb-pdf-scrapper-invalid-key-pattern key))
                        t)))
    ;; list fields for org export
    (dolist (field orb-pdf-scrapper-bibkey-export-fields)
      ;; truncate author list to first three names, append et.al instead
      ;; of the remaining names
      ;; This is a hard-coded "reasonable default"
      ;; and it may be replaced with something more
      ;; flexible in the future
      (let ((value (or (cdr (assoc field fields))
                       "")))
        (setq value (s-replace-regexp "{\\(.*?\\)}" "\\1" value))
        (when (or (string= field "author")
                  (string= field "editor"))
          (setq value (split-string value " and " t "[ ,.;:-]+")
                value (if (> (length value) 3)
                          (append (-take 3 value) '("et.al."))
                        value)
                value (concat (mapconcat #'identity value "; "))))
        (push (cons field value) export-fields)))
    ;; return the entry
    (list :key key
          :validp validp
          :set-fields set-fields
          :export-fields (nreverse export-fields))))

(defun orb-pdf-scrapper--update-record-at-point (&optional collect-only)
  "Generate citation key and update the BibTeX record at point.
Calls `orb-pdf-scrapper--compose-entry' to get information about
BibTeX record at point and updates it accordingly.  If optionaly
COLLECT-ONLY is non-nil, do not generate the key and do not set
fields.

This is an auxiliary function for commands
`orb-pdf-scrapper-generate-keys'."
  (let* ((entry (parsebib-read-entry (parsebib-find-next-item)))
         (key-plist (orb-pdf-scrapper--compose-entry entry collect-only))
         (new-key (plist-get key-plist :key))
         (validp (plist-get key-plist :validp))
         (fields-to-set (plist-get key-plist :set-fields))
         (formatted-entry (plist-get key-plist :export-fields)))
    (unless collect-only
      (save-excursion
        ;; update citekey
        ;; adjusted from bibtex-clean-entry
        (bibtex-beginning-of-entry)
        (re-search-forward bibtex-entry-maybe-empty-head)
        (if (match-beginning bibtex-key-in-head)
            (delete-region (match-beginning bibtex-key-in-head)
                           (match-end bibtex-key-in-head)))
        (insert new-key)
        ;; set the bibtex fields
        (when fields-to-set
          (dolist (field fields-to-set)
            (bibtex-set-field (car field) (cdr field))))))
    ;; return the result ((NEW-KEY . ENTRY) . VALIDP)
    ;; TODO: for testing until implemented
    (cons new-key (cons formatted-entry validp))))

(defun orb-pdf-scrapper--sort-refs (refs)
  "Sort references REFS.
Auxiliary function for `orb-pdf-scrapper-generate-keys'.
REFS should be an alist of form ((CITEKEY . FORMATTED-ENTRY) . VALIDP).

References marked valid by `orb-pdf-scrapper-keygen-function' function
are further sorted into four groups:

'in-roam - available in the `org-roam' database;
'in-bib  - available in `bibtex-completion-bibliography' file(s);
'valid   - marked valid by the keygen function but are not
available in the user databases;
'invalid - marked invalid by the keygen function."
  (let* ((bibtex-completion-bibliography (orb-pdf-scrapper--get :global-bib))
         ;; When using a quoted list here, sorted-refs is not erased
         ;; upon consecutive runs
         (sorted-refs (list (list 'in-roam) (list 'in-bib)
                            (list 'valid) (list 'invalid)))
         (spaces (-repeat (length orb-pdf-scrapper-bibkey-export-fields) (cons nil " "))))
    (dolist (ref refs)
      (cond ((org-roam-db-query [:select [ref]
                                 :from refs
                                 :where (= ref $s1)]
                                (format "%s" (car ref)))
             (push
              (cons (format "cite:%s" (car ref)) spaces)
              (cdr (assoc 'in-roam sorted-refs))))
            ((bibtex-completion-get-entry (car ref))
             (push
              (cons (format "cite:%s" (car ref)) spaces)
              (cdr (assoc 'in-bib sorted-refs))))
            ((cddr ref)
             (push
              (cons (format "cite:%s" (car ref)) (cadr ref))
              (cdr (assoc 'valid sorted-refs))))
            (t
             (push
              (cons " " (cadr ref))
              (cdr (assoc 'invalid sorted-refs))))))
    sorted-refs))

;; * Helper functions: dispatcher

(defvar orb-pdf-scrapper--plist nil
  "Communication channel for Orb PDF Scrapper.")

(defvar orb-pdf-scrapper--buffer "*Orb PDF Scrapper*"
  "Orb PDF Scrapper special buffer.")

(defmacro orb--with-scrapper-buffer! (&rest body)
  "Execute BODY with `orb-pdf-scrapper--buffer' as current.
If the buffer does not exist it will be created."
  (declare (indent 0) (debug t))
  `(save-current-buffer
     (set-buffer (get-buffer-create orb-pdf-scrapper--buffer))
     ,@body))

(defmacro orb--when-current-context! (context &rest body)
  "Execute BODY if CONTEXT is current context.
Run `orb-pdf-scrapper-keygen-function' with `error' context
otherwise.  If CONTEXT is a list then current context must be a
member of that list."
  (declare (indent 1) (debug t))
  `(if (not (orb-pdf-scrapper--current-context-p ,context))
       (orb-pdf-scrapper-dispatcher 'error)
     ,@body))

(defun orb-pdf-scrapper--current-context-p (context)
  "Return t if CONTEXT is current context.
CONTEXT can also be a list, in which case t is returned when
current context is its memeber."
  (if (listp context)
      (memq (orb-pdf-scrapper--get :context) context)
    (eq (orb-pdf-scrapper--get :context) context)))

(defun orb-pdf-scrapper--refresh-mode (mode)
  "Restart `orb-pdf-scrapper-mode' with new major MODE."
  (cl-case mode
    ('txt
     (text-mode)
     (orb-pdf-scrapper--put :callee 'edit-bib
                            :context 'start
                            :caller 'edit-txt))
    ('bib
     (bibtex-mode)
     (bibtex-set-dialect 'BibTeX t)
     (orb-pdf-scrapper--put :callee 'edit-org
                            :context 'start
                            :caller 'edit-bib))
    ('org
     (org-mode)
     (orb-pdf-scrapper--put :callee 'checkout
                            :context 'start
                            :caller 'edit-org))
    ('xml
     (xml-mode)
     (cl-case (orb-pdf-scrapper--get :context)
       ;; since :callee is not used in training session, we set :callee here to
       ;; the original :caller, so that we can return to the editing mode we
       ;; were called from if the training session is to be cancelled
       ('start
        (orb-pdf-scrapper--put :callee (orb-pdf-scrapper--get :caller)
                               :context 'start
                               :caller 'edit-xml))
       ('edit-master
        (orb-pdf-scrapper--put :context 'edit-master
                               :caller 'edit-xml))))
    ('train
     (fundamental-mode)
     (cl-case (orb-pdf-scrapper--get :context)
       ('train
        (orb-pdf-scrapper--put :context 'train
                               :caller 'train))
       ;; Since the session was not cancelled, we return to text, as everything
       ;; else should be regenerated anyway.
       ('finished
        (orb-pdf-scrapper--put :callee 'edit-txt
                               :context 'continue
                               :caller 'train))))
    (t
     (unwind-protect
         (error "Oops...something went wrong.  \
Pressing the RED button, just in case")
       (orb-pdf-scrapper-dispatcher 'error))))
  (set-buffer-modified-p nil)
  (setq mark-active nil)
  (orb-pdf-scrapper-mode -1)
  (orb-pdf-scrapper-mode +1)
  (goto-char (point-min)))

(defun orb-pdf-scrapper--edit-txt ()
  "Edit text references in `orb-pdf-scrapper--buffer'."
  ;; callee will be overridden in case of error
  (cl-case (orb-pdf-scrapper--get :context)
    ;; parse pdf file and switch to text editing mode
    ('start
     (let ((temp-txt (orb--temp-file "orb-pdf-scrapper-" ".txt"))
           (pdf-file (orb-pdf-scrapper--get :pdf-file)))
       (orb-pdf-scrapper--put :temp-txt temp-txt)
       (let ((same-window-buffer-names (list orb-pdf-scrapper--buffer)))
         (pop-to-buffer orb-pdf-scrapper--buffer))
       (setq buffer-file-name nil)
       (orb--with-message! (format "Scrapping %s.pdf" (f-base pdf-file))
         (erase-buffer)
         (orb-anystyle 'find
           :format 'ref
           :layout nil
           :finder-model orb-anystyle-finder-model
           :input pdf-file
           :stdout t
           :buffer orb-pdf-scrapper--buffer))
       (setq buffer-undo-list nil)
       (orb-pdf-scrapper--refresh-mode 'txt)))
    ;; read the previously generated text file
    ('continue
     (if-let ((temp-txt (orb-pdf-scrapper--get :temp-txt))
              (f-exists? temp-txt))
         (progn
           (pop-to-buffer orb-pdf-scrapper--buffer)
           (erase-buffer)
           (insert-file-contents temp-txt)
           (setq buffer-undo-list (orb-pdf-scrapper--get :txt-undo-list))
           (orb-pdf-scrapper--refresh-mode 'txt))
       (orb-pdf-scrapper-dispatcher 'error)))
    (t
     (orb-pdf-scrapper-dispatcher 'error))))

(defun orb-pdf-scrapper--edit-bib ()
  "Generate and edit BibTeX data in `orb-pdf-scrapper--buffer'."
  (pop-to-buffer orb-pdf-scrapper--buffer)
  (cl-case (orb-pdf-scrapper--get :context)
    ('start
     (let* ((temp-bib (or (orb-pdf-scrapper--get :temp-bib)
                          (orb--temp-file "orb-pdf-scrapper-" ".bib"))))
       (orb-pdf-scrapper--put :temp-bib temp-bib)
       ;; save previous progress in txt buffer
       (write-region (orb--buffer-string)
                     nil (orb-pdf-scrapper--get :temp-txt) nil -1)
       (orb-pdf-scrapper--put :txt-undo-list (copy-tree buffer-undo-list))
       (orb--with-message! "Generating BibTeX data"
         ;; Starting from Emacs 27, whether shell-command erases buffer
         ;; is controlled by `shell-command-dont-erase-buffer', so we
         ;; make sure the buffer is clean
         (erase-buffer)
         (orb-anystyle 'parse
           :format 'bib
           :parser-model orb-anystyle-parser-model
           :input (orb-pdf-scrapper--get :temp-txt)
           :stdout t
           :buffer orb-pdf-scrapper--buffer)
         (write-region (orb--buffer-string) nil temp-bib nil -1))
       (setq buffer-undo-list nil))
     (orb-pdf-scrapper--refresh-mode 'bib))
    ('continue
     (if-let ((temp-bib (orb-pdf-scrapper--get :temp-bib))
              (f-exists? temp-bib))
         (progn
           (erase-buffer)
           (insert-file-contents temp-bib)
           (setq buffer-undo-list (orb-pdf-scrapper--get :bib-undo-list))
           (orb-pdf-scrapper--refresh-mode 'bib))
       (orb-pdf-scrapper-dispatcher 'error)))
    (t
     (orb-pdf-scrapper-dispatcher 'error))))

(defun orb-pdf-scrapper--insert-org-as-list (ref-alist)
  "Insert REF-ALIST as Org-mode list."
  (dolist (ref ref-alist)
    (insert "- " (car ref) "\n" )))

(defun orb-pdf-scrapper--insert-org-as-table (ref-alist)
  "Insert REF-ALIST as Org-mode table."
  (insert
   (concat "|citekey|"
           (mapconcat #'identity
                      orb-pdf-scrapper-bibkey-export-fields "|")
           "|\n"))
  (forward-line -1)
  (org-table-insert-hline)
  (forward-line 2)
  (dolist (ref ref-alist)
    (insert (concat "|" (car ref) "|"
                    (mapconcat (lambda (value)
                                 (format "%s" (cdr value)))
                               (cdr ref) "|")
                    "|\n")))
  (forward-line -1)
  (org-table-align)
  (org-back-to-heading nil))

(defun orb-pdf-scrapper--edit-org ()
  "Edit generated Org-mode data."
  (pop-to-buffer orb-pdf-scrapper--buffer)
  (cl-case (orb-pdf-scrapper--get :context)
    ('start
     ;; if the BibTeX buffer was modified, save it and maybe generate keys
     (orb-pdf-scrapper-generate-keys
      nil
      (if (buffer-modified-p)
          ;; TODO: it's clumsy
          ;; not "yes" means generate
          ;; not "no" means collect only
          (not (y-or-n-p "Generate BibTeX keys? "))
        t))
     (when (> (cl-random 100) 98)
       (orb--with-message! "Pressing the RED button"))
     (write-region (orb--buffer-string)
                   nil (orb-pdf-scrapper--get :temp-bib) nil 1)
     (orb-pdf-scrapper--put :bib-undo-list (copy-tree buffer-undo-list))
     ;; generate Org-mode buffer
     (let* ((temp-org (or (orb-pdf-scrapper--get :temp-org)
                          (orb--temp-file "orb-pdf-scrapper-" ".org"))))
       (orb-pdf-scrapper--put :temp-org temp-org
                              :caller 'edit-org)
       ;; we must change the mode in the beginning to get all the Org-mode
       ;; facilities
       (orb-pdf-scrapper--refresh-mode 'org)
       (orb--with-message! "Generating Org data"
         (erase-buffer)
         ;; insert parent heading
         (org-insert-heading nil nil t)
         (insert
          (concat
           (cadr (assoc 'parent orb-pdf-scrapper-refsection-headings))
           " (retrieved by Orb PDF Scrapper from "
           (f-filename (orb-pdf-scrapper--get :pdf-file)) ")"))
         (org-end-of-subtree)
         ;; insert child headings: in-roam, in-bib, valid, invalid
         (dolist (ref-group
                  (orb-pdf-scrapper--sort-refs orb-pdf-scrapper--refs))
           (when-let* ((group (car ref-group))
                       (refs (cdr ref-group))
                       (heading
                        (cdr (assoc group
                                    orb-pdf-scrapper-refsection-headings)))
                       (title (car heading))
                       (type (cadr heading)))
             (org-insert-heading '(16) nil t)
             ;; insert heading
             (insert (format "%s\n" title))
             (org-demote)
             (org-end-of-subtree)
             ;; insert references
             (insert (format "\n#+name: %s\n" group))
             (cl-case type
               ('list
                (orb-pdf-scrapper--insert-org-as-list refs))
               ('table
                (orb-pdf-scrapper--insert-org-as-table refs)))))
         (write-region (orb--buffer-string) nil temp-org nil -1)
         (setq buffer-undo-list nil)
         (set-buffer-modified-p nil)
         (goto-char (point-min)))))
    ('continue
     (if-let ((temp-org (orb-pdf-scrapper--get :temp-org))
              (f-exists? temp-org))
         (progn
           (erase-buffer)
           (insert-file-contents temp-org)
           (setq buffer-undo-list (orb-pdf-scrapper--get :org-undo-list))
           (orb-pdf-scrapper--refresh-mode 'org))
       (orb-pdf-scrapper-dispatcher 'error)))))

(defun orb-pdf-scrapper--edit-xml ()
  "Edit XML data."
  (pop-to-buffer orb-pdf-scrapper--buffer)
  (cl-case (orb-pdf-scrapper--get :context)
    ('start
     (let* ((temp-xml (or (orb-pdf-scrapper--get :temp-xml)
                          (orb--temp-file "orb-pdf-scrapper-" ".xml"))))
       (orb-pdf-scrapper--put :temp-xml temp-xml)
       (orb--with-message! "Generating XML data"
         ;; save progress in text mode when called from there if called from
         ;; anywhere else, text mode progress is already saved, other data will
         ;; be re-generated anyway
         (when (eq (orb-pdf-scrapper--get :caller) 'edit-txt)
           (write-region (orb--buffer-string)
                         nil (orb-pdf-scrapper--get :temp-txt) nil -1)
           (orb-pdf-scrapper--put :txt-undo-list (copy-tree buffer-undo-list)))
         (erase-buffer)
         (orb-anystyle 'parse
           :format 'xml
           :parser-model orb-anystyle-parser-model
           :input (orb-pdf-scrapper--get :temp-txt)
           :stdout t
           :buffer orb-pdf-scrapper--buffer)
         (write-region (orb--buffer-string) nil temp-xml nil -1)
         (setq buffer-undo-list nil)
         (orb-pdf-scrapper--refresh-mode 'xml))))
    ('edit-master
     (progn
       (erase-buffer)
       (insert-file-contents orb-anystyle-parser-training-set)
       (setq buffer-file-name orb-anystyle-parser-training-set)
       (setq buffer-undo-list nil)
       (orb-pdf-scrapper--refresh-mode 'xml)))
    (t
     (orb-pdf-scrapper-dispatcher 'error))))

(defun orb-pdf-scrapper--update-master-file ()
  "Append generated XML data to `orb-anystyle-parser-training-set'."
  (orb--with-scrapper-buffer!
    (orb--with-message! (format "Appending to master training set %s"
                                orb-anystyle-parser-training-set)
      ;; save any progress in XML mode
      (write-region (orb--buffer-string) nil
                    (orb-pdf-scrapper--get :temp-xml) nil -1)
      (let (new-data)
        ;; strip down the header and footer tokens from our data
        (save-excursion
          (save-match-data
            (let* (beg end)
              (goto-char (point-min))
              (re-search-forward "\\(^[ \t]*<dataset>[ \t]*\n\\)" nil t)
              (setq beg (or (match-end 1)
                            (point-min)))
              (re-search-forward "\\(^[ \t]*</dataset>[ \t]*\n\\)" nil t)
              (setq end (or (match-beginning 1)
                            (point-max)))
              (setq new-data (orb--buffer-string beg end)))))
        ;; append our data to the master file
        (with-temp-buffer
          (insert-file-contents orb-anystyle-parser-training-set)
          (goto-char (point-max))
          (forward-line -1)
          (insert new-data)
          (write-region (orb--buffer-string) nil
                        orb-anystyle-parser-training-set nil -1))))))

(defun orb-pdf-scrapper--train (&optional review)
  "Update parser training set and run anystyle train.
If optional REVIEW is non-nil, run `orb-pdf-scrapper--edit-xml'
in `:edit-master' context."
  (pop-to-buffer orb-pdf-scrapper--buffer)
  ;; edit the master file or proceed to training
  (if review
      ;; we've been requested to review the master file
      (progn
        (orb-pdf-scrapper--update-master-file)
        (orb-pdf-scrapper--put :context 'edit-master)
        (orb-pdf-scrapper--edit-xml))
    ;; start the training process otherwise
    (orb-pdf-scrapper--update-master-file)
    (message "Training anystyle parser model...")
    (when buffer-file-name
      (save-buffer))
    (setq buffer-file-name nil)
    (erase-buffer)
    (orb-pdf-scrapper--put :context 'train)
    (orb-pdf-scrapper--refresh-mode 'train)
    (insert (format "\
This can take several minutes depending on the size of your training set.
You can continue your work meanwhile and return here later.\n
Training set => %s
Parser model => %s\n
anystyle output:
=====================\n"
                    orb-anystyle-parser-model
                    orb-anystyle-parser-training-set))
    (goto-char (point-min))
    ;; normally, anystyle runs with `shell-command', anystyle train, however,
    ;; can take minutes on large files, so it runs in a shell sub-process
    (let ((training-process
           (orb-anystyle 'train
             :stdout t
             :overwrite t
             :input orb-anystyle-parser-training-set
             :output orb-anystyle-parser-model
             :buffer orb-pdf-scrapper--buffer)))
      (orb-pdf-scrapper--put :training-process training-process)
      ;; finalize
      (set-process-sentinel
       training-process
       (lambda (_p result)
         (if (string= result "finished\n")
             (progn
               (goto-char (point-max))
               (insert "=====================\n\nDone!")
               (message "Training anystyle parser model...done")
               (orb-pdf-scrapper--put :context 'finished
                                      :training-process nil)
               (orb-pdf-scrapper--refresh-mode 'train))
           (orb-pdf-scrapper--put :context 'error
                                  :training-process nil)))))))

(defun orb-pdf-scrapper--checkout ()
  "Finalize Orb PDF Scrapper process.
Insert generated Org data into the note buffer that started the
process."
  (cl-case (orb-pdf-scrapper--get :context)
    ('start
     (pop-to-buffer (orb-pdf-scrapper--get :original-buffer))
     (save-restriction
       (save-excursion
         (widen)
         (goto-char (point-max))
         (insert-file-contents (orb-pdf-scrapper--get :temp-org))))
     (orb-pdf-scrapper-dispatcher 'kill))
    (t
     (orb-pdf-scrapper-dispatcher 'error))))

(defun orb-pdf-scrapper--cleanup ()
  "Clean up before and after Orb Pdf Scrapper process."
  (setq orb-pdf-scrapper--refs ())
  (dolist (prop (list :running :callee :context :caller
                      :current-key :prevent-concurring
                      :temp-txt :temp-bib :temp-org :temp-xml
                      :pdf-file :global-bib
                      :txt-undo-list :bib-undo-list :org-undo-list
                      :training-process :window-conf :original-buffer))
    (orb-pdf-scrapper--put prop nil)))


;; * Minor mode

;;; Code in this section was adopted from org-capture.el
;;
;; Copyright (C) 2010-2020 Free Software Foundation, Inc.
;; Author: Carsten Dominik <carsten at orgmode dot org>
(defvar orb-pdf-scrapper-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map "\C-c\C-k" #'orb-pdf-scrapper-kill)
    map)
  "Keymap for `orb-pdf-scrapper-mode' minor mode."
  )

(defvar orb-pdf-scrapper-mode-hook nil
  "Hook for the `orb-pdf-scrapper-mode' minor mode.")

(define-minor-mode orb-pdf-scrapper-mode
  "Minor mode for special key bindings in a orb-pdf-scrapper buffer.
Turning on this mode runs the normal hook `orb-pdf-scrapper-mode-hook'."
  nil " OPS" orb-pdf-scrapper-mode-map
  (when orb-pdf-scrapper-mode
    (orb-pdf-scrapper--update-keymap)
    (setq-local
     header-line-format
     (orb-pdf-scrapper--format-header-line))))

(defun orb-pdf-scrapper--put (&rest props)
  "Add properties PROPS to `orb-pdf-scrapper--plist'.
Returns the new plist."
  (while props
    (setq orb-pdf-scrapper--plist
          (plist-put orb-pdf-scrapper--plist
                     (pop props)
                     (pop props)))))

(defun orb-pdf-scrapper--get (prop)
  "Get PROP from `orb-pdf-scrapper--plist'."
  (plist-get orb-pdf-scrapper--plist prop))
;;;
;;; End of code adopted from org-capture.el

;; TODO combine `orb-pdf-scrapper--format-header-line'
;; and `orb-pdf-scrapper--update-keymap' into one
;; function and use a macro to generate each entry
(defun orb-pdf-scrapper--format-header-line ()
  "Return formatted buffer header line depending on context."
  (substitute-command-keys
   (format "\\<orb-pdf-scrapper-mode-map>Orb PDF Scrapper: %s.  %s"
           (orb-pdf-scrapper--get :current-key)
           (cl-case (orb-pdf-scrapper--get :caller)
             ('edit-txt
              "\
Generate BibTeX `\\[orb-pdf-scrapper-dispatcher]', \
sanitize text `\\[orb-pdf-scrapper-sanitize-text]', \
train parser `\\[orb-pdf-scrapper-training-session], \
abort `\\[orb-pdf-scrapper-kill]'.")
             ('edit-bib
              "\
Generate Org `\\[orb-pdf-scrapper-dispatcher]', \
generate keys `\\[orb-pdf-scrapper-generate-keys]', \
return to text `\\[orb-pdf-scrapper-cancel]', \
train parser `\\[orb-pdf-scrapper-training-session], \
abort `\\[orb-pdf-scrapper-kill]'.")
             ('edit-org
              "\
Finish `\\[orb-pdf-scrapper-dispatcher]', \
return to BibTeX `\\[orb-pdf-scrapper-cancel]', \
abort `\\[orb-pdf-scrapper-kill]'.")
             ('edit-xml
              (cl-case (orb-pdf-scrapper--get :context)
                ('start
                 (format "\
Train `\\[orb-pdf-scrapper-training-session]', \
review %s `\\[orb-pdf-scrapper-review-master-file]', \
cancel `\\[orb-pdf-scrapper-cancel], \
abort `\\[orb-pdf-scrapper-kill]'."
                      (file-name-nondirectory
                       orb-anystyle-parser-training-set)))
                ('edit-master
                 "\
Train `\\[orb-pdf-scrapper-training-session]', \
cancel `\\[orb-pdf-scrapper-cancel], \
abort `\\[orb-pdf-scrapper-kill]'.")))
             ('train
              (cl-case (orb-pdf-scrapper--get :context)
                ('train
                 "\
Abort `\\[orb-pdf-scrapper-kill]'.")
                ('continue
                 "\
Finish `\\[orb-pdf-scrapper-dispatcher]', \
abort `\\[orb-pdf-scrapper-kill]'.")))
             (t
              "\
Press the RED button `\\[orb-pdf-scrapper-kill]'.")))))

(defun orb-pdf-scrapper--update-keymap ()
  "Update `orb-pdf-scrapper-mode-map' according to current editing mode.
Context is read from `orb-pdf-scrapper--plist' property `:context'."
  (let ((map orb-pdf-scrapper-mode-map))
    (cl-case (orb-pdf-scrapper--get :caller)
      ;;
      ('edit-txt
       (define-key map "\C-c\C-c" #'orb-pdf-scrapper-dispatcher)
       (define-key map "\C-c\C-u" #'orb-pdf-scrapper-sanitize-text)
       (define-key map "\C-C\C-t" #'orb-pdf-scrapper-training-session)
       (define-key map "\C-c\C-r" nil))
      ;;
      ('edit-bib
       (define-key map "\C-c\C-c" #'orb-pdf-scrapper-dispatcher)
       (define-key map "\C-c\C-u" #'orb-pdf-scrapper-generate-keys)
       (define-key map "\C-C\C-t" #'orb-pdf-scrapper-training-session)
       (define-key map "\C-c\C-r" #'orb-pdf-scrapper-cancel))
      ;;
      ('edit-org
       (define-key map "\C-c\C-c" #'orb-pdf-scrapper-dispatcher)
       (define-key map "\C-c\C-u" nil)
       (define-key map "\C-C\C-t" nil)
       (define-key map "\C-c\C-r" #'orb-pdf-scrapper-cancel))
      ('edit-xml
       (cl-case (orb-pdf-scrapper--get :context)
         ('start
          (define-key map "\C-c\C-c" #'orb-pdf-scrapper-training-session)
          (define-key map "\C-c\C-u" nil)
          (define-key map "\C-C\C-t" #'orb-pdf-scrapper-review-master-file)
          (define-key map "\C-c\C-r" #'orb-pdf-scrapper-cancel))
         ('edit-master
          (define-key map "\C-c\C-c" #'orb-pdf-scrapper-training-session)
          (define-key map "\C-c\C-u" nil)
          (define-key map "\C-C\C-t" nil)
          (define-key map "\C-c\C-r" #'orb-pdf-scrapper-cancel))))
      ('train
       (cl-case (orb-pdf-scrapper--get :context)
         ('train
          (define-key map "\C-c\C-c" nil)
          (define-key map "\C-c\C-r" nil)
          (define-key map "\C-c\C-u" nil)
          (define-key map "\C-c\C-t" nil))
         ('continue
          (define-key map "\C-c\C-c" #'orb-pdf-scrapper-dispatcher))))
      (t
       (define-key map "\C-c\C-u" nil)
       (define-key map "\C-c\C-t" nil)
       (define-key map "\C-c\C-r" nil)))))

;; * Interactive functions

(defun orb-pdf-scrapper-generate-keys (&optional at-point collect-only)
  "Generate BibTeX citation keys in the current buffer.
\\<orb-pdf-scrapper-mode-map>
While the Orb PDF Scrapper interactive process, when editing
BibTeX data, press \\[orb-pdf-scrapper-generate-keys] to generate
citation keys using the function specified in
`orb-pdf-scrapper-keygen-function'.  When called interactively
with a \\[universal-argument] prefix argument AT-POINT, generate
key only for the record at point.

When called from Lisp, if optional COLLECT-ONLY is non-nil, do
not generate the key and update the records, just collect records
for future use."
  (interactive "P")
  (orb--with-message! "Generating citation keys"
    (let ((bibtex-help-message nil)
          (bibtex-contline-indentation 2)
          (bibtex-text-indentation 2))
      (save-excursion
        (if (equal at-point '(4))
            ;; generate key at point
            (progn
              (bibtex-beginning-of-entry)
              (let* ((old-key (save-excursion
                                (re-search-forward
                                 bibtex-entry-maybe-empty-head)
                                (bibtex-key-in-head)))
                     (old-ref (assoc old-key orb-pdf-scrapper--refs))
                     (new-ref (orb-pdf-scrapper--update-record-at-point
                               collect-only)))
                (if old-ref
                    (setf (car old-ref) (car new-ref)
                          (cdr old-ref) (cdr new-ref))
                  (cl-pushnew new-ref orb-pdf-scrapper--refs :test 'equal))))
          ;; generate keys in buffer otherwise
          (let ((refs ()))
            (goto-char (point-min))
            (bibtex-skip-to-valid-entry)
            (while (not (eobp))
              (cl-pushnew (orb-pdf-scrapper--update-record-at-point
                           collect-only)
                          refs)
              (bibtex-skip-to-valid-entry))
            (setq orb-pdf-scrapper--refs refs)))))
    (write-region (orb--buffer-string) nil
                  (orb-pdf-scrapper--get :temp-bib) nil -1)
    (set-buffer-modified-p nil)))

(defun orb-pdf-scrapper-sanitize-text (&optional contents)
  "Run string processing in current buffer.
Try to get every reference onto newline.  Return this buffer's
contents (`orb--buffer-string').

If optional string CONTENTS was specified, run processing on this
string instead.  Return modified CONTENTS."
  (interactive)
  (let* ((rx1 '(and "(" (** 1 2 (any "0-9")) ")"))
         (rx2 '(and "[" (** 1 2 (any "0-9")) "]"))
         (rx3 '(and "(" (any "a-z") (opt (any space)) ")"))
         (rx4 '(and " " (any "a-z") ")"))
         (regexp (rx-to-string
                  `(group-n 1 (or (or (and ,rx1 " " ,rx3)
                                      (and ,rx2 " " ,rx3))
                                  (or (and ,rx1 " " ,rx4)
                                      (and ,rx2 " " ,rx4))
                                  (or ,rx1 ,rx2)
                                  (or ,rx3 ,rx4))) t)))
    (if contents
        (--> contents
             (s-replace "\n" " " it)
             (s-replace-regexp regexp "\n\\1" it))
      (goto-char (point-min))
      (while (re-search-forward "\n" nil t)
        (replace-match " " nil nil))
      (goto-char (point-min))
      (while (re-search-forward regexp nil t)
        (replace-match "\n\\1" nil nil))
      (goto-char (point-min))
      (orb--buffer-string))))

(defun orb-pdf-scrapper-training-session (&optional context)
  "Run training session subroutines depending on CONTEXT.
If context is not provided, it will be read from
`orb-pdf-scrapper--plist''s `:context'."
  (interactive)
  (pop-to-buffer orb-pdf-scrapper--buffer)
  (let ((context (or context (orb-pdf-scrapper--get :context))))
    (orb-pdf-scrapper--put :context context)
    (cl-case context
      ('start
       ;; generate xml
       (orb-pdf-scrapper--edit-xml))
      ('edit-master
       (orb-pdf-scrapper--train))
      ('finished
       (orb-pdf-scrapper-dispatcher 'edit-txt 'continue))
      (t (orb-pdf-scrapper-dispatcher 'error)))))

(defun orb-pdf-scrapper-review-master-file ()
  "Review parser training set (master file)."
  (interactive)
  (orb-pdf-scrapper--train t))

(defun orb-pdf-scrapper-dispatcher (&optional callee context)
  "Call Orb PDF Scrapper subroutine CALLEE in context CONTEXT.
CALLEE and CONTEXT can be passed directly as optional variables,
or they will be read from `orb-pdf-scrapper--plist''s
respectively `:collee' and `:context' properties.

Recognized CALLEEs are:
==========
'edit-txt - `orb-pdf-scrapper--edit-txt'
'edit-bib - `orb-pdf-scrapper--edit-bib'
'edit-org - `orb-pdf-scrapper--edit-org'
'train    - `orb-pdf-scrapper-training-session'
'checkout - `orb-pdf-scrapper--checkout'

Passing or setting any other CALLEE will kill the process.

This function also checks `:prevent-concurring' property in
`orb-pdf-scrapper--plist' and will suggest to restart the process
if its value is non-nil."
  ;; TODO: check for whether the user killed any of the buffers
  (interactive)
  (let ((callee (or callee (orb-pdf-scrapper--get :callee)))
        (context (or context (orb-pdf-scrapper--get :context))))
    ;; in case context was passed as an argument
    (orb-pdf-scrapper--put :callee callee
                           :context context)
    (if
        ;; Prevent another Orb PDF Scrapper process from running
        ;; Ask user whether to kill the currently running process
        (orb-pdf-scrapper--get :prevent-concurring)
        (if (y-or-n-p
             (format "Another Orb PDF Scrapper process is running: %s.  \
Kill it and start a new one %s? "
                     (orb-pdf-scrapper--get :current-key)
                     (orb-pdf-scrapper--get :new-key)))
            ;; Kill the process and start a new one
            (progn
              (orb--with-message! "Killing current process"
                (orb-pdf-scrapper--cleanup))
              (orb-pdf-scrapper-run (orb-pdf-scrapper--get :new-key)))
          ;; Do nothing
          (orb-pdf-scrapper--put :prevent-concurring nil))
      ;; Finilize the requested context otherwise
      (cl-case callee
        ('edit-txt
         (orb-pdf-scrapper--edit-txt))
        ('edit-bib
         (orb-pdf-scrapper--edit-bib))
        ;; edit org
        ('edit-org
         (orb-pdf-scrapper--edit-org))
        ('train
         (orb-pdf-scrapper-training-session))
        ('checkout
         ;; currently, this is unnecessary but may be useful
         ;; if some recovery options are implemented
         (orb--with-scrapper-buffer!
           (write-region (orb--buffer-string)
                         nil (orb-pdf-scrapper--get :temp-org) nil 1))
         (orb-pdf-scrapper--checkout))
        (t
         ;; 1 in 100 should not be too annoying
         (when (> (cl-random 100) 98)
           (message "Oops...")
           (sleep-for 1)
           (message "Oops...Did you just ACCIDENTALLY press the RED button?")
           (sleep-for 1)
           (message "Activating self-destruction subroutine...")
           (sleep-for 1)
           (message "Activating self-destruction subroutine...Bye-bye")
           (sleep-for 1))
         (let ((kill-buffer-query-functions nil))
           (and (get-buffer orb-pdf-scrapper--buffer)
                (kill-buffer orb-pdf-scrapper--buffer)))
         (set-window-configuration (orb-pdf-scrapper--get :window-conf))
         (orb-pdf-scrapper--cleanup))))))

(defun orb-pdf-scrapper-cancel ()
  "Discard edits and return to previous editing mode."
  (interactive)
  (cl-case (orb-pdf-scrapper--get :caller)
    ('edit-bib
     (orb--with-scrapper-buffer!
       (orb-pdf-scrapper--put :bib-undo-list nil))
     (orb-pdf-scrapper-dispatcher 'edit-txt 'continue))
    ('edit-org
     (orb-pdf-scrapper-dispatcher 'edit-bib 'continue))
    ('edit-xml
     (orb-pdf-scrapper-dispatcher (orb-pdf-scrapper--get :callee) 'continue))
    (t
     (orb-pdf-scrapper-dispatcher 'error))))

(defun orb-pdf-scrapper-kill ()
  "Kill the interactive Orb PDF Scrapper process."
  (interactive)
  (when-let (process (orb-pdf-scrapper--get :training-process))
    (kill-process process))
  (orb-pdf-scrapper-dispatcher 'kill))


;; * Main functions

;; entry point

;;;###autoload
(defun orb-pdf-scrapper-run (key)
  "Run Orb PDF Scrapper interactive process.
KEY is note's citation key."
  (interactive)
  (if (orb-pdf-scrapper--get :running)
      (progn
        (orb-pdf-scrapper--put :prevent-concurring t
                               :new-key key)
        (orb-pdf-scrapper-dispatcher))
    ;; in case previous process was not killed properly
    (orb-pdf-scrapper--cleanup)
    (orb-pdf-scrapper--put :callee 'edit-txt
                           :context 'start
                           :caller 'run
                           :current-key key
                           :new-key nil
                           :pdf-file (file-truename
                                      (orb-process-file-field key))
                           :running t
                           :prevent-concurring nil
                           :global-bib bibtex-completion-bibliography
                           :original-buffer (current-buffer)
                           :window-conf (current-window-configuration))
    (orb-pdf-scrapper-dispatcher)))

(provide 'orb-pdf-scrapper)
;;; orb-pdf-scrapper.el ends here
;; Local Variables:
;; fill-column: 79
;; End:
