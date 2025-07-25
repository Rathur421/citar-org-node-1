;;; citar-org-node.el --- Citar integration with org-node  -*- lexical-binding: t; -*-

;; Copyright (C) 2025  Kristoffer Balintona

;; Author: Kristoffer Balintona <krisbalintona@gmail.com>
;; URL: https://github.com/krisbalintona/citar-org-node
;; Keywords: tools
;; Package-Version: 0.2.6
;; Package-Requires: ((emacs "26.1") (citar "1.1") (org-node "3.0.0") (ht "1.6"))

;; This program is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see <https://www.gnu.org/licenses/>.

;;; Commentary:

;; This package integrates org-node, a note-taking package, with citar, a
;; popular bibliographic references management package.  To use, enable the
;; global minor mode, `citar-org-node-mode', and use citar as normal!

;; Org-node associates nodes to bibliographic references using the "ROAM_REFS"
;; property (stored in org-mode's property drawers).  With
;; `citar-org-node-mode', citar will become aware of org-node nodes with a
;; corresponding bibliographic reference.  Such nodes will become the associated
;; "note" for that reference.  (References can have multiple notes.)

;; For more information on the available features of this package, call
;;
;;     M-x customize-group citar-org-node RET
;;
;; For more information on how this package affects citar variables, read the
;; docstring of `citar-org-node-mode'.

;; Citar-org-node also offers several commands useful for managing and creating
;; nodes.  Notably, among them are `citar-org-node-open-resource' and
;; `citar-org-node-add-refs'.  View their docstrings to learn about their
;; purposes.

;; If you would like to see a certain feature not already present in the package
;; or discover a bug, please open an issue in the project page or reach out to
;; the package author's email.

;;; Code:
(require 'citar)
(require 'org-node)
(require 'ht)
(require 'org-capture)

;;; Options
(defgroup citar-org-node nil
  "Integration between org-node and citar."
  :prefix "citar-org-node-"
  :group 'org)

(defcustom citar-org-node-new-node-title-template
  (or (cdr (assq 'note citar-templates)) "${title} by ${author}")
  "The citar formatting template for titles of newly created nodes.

The default value of this option is the value of the \"note\" template
in `citar-templates'.  See `citar-templates'for an example of what this
string should look like.

Citar fields (which correspond to bibliography file fields) can also be
included in the value of this option.  For example, \"${title}\" will
expand to the value of the \"title\" field in corresponding
bibliographic entry of the bibliographic (.bib) file.

See also `citar-org-node-fallback-org-capture-template-key'."
  :type 'string)

(defcustom citar-org-node-fallback-org-capture-template-key nil
  "Key used in the `org-capture' menu for the fallback template.

This should be a single letter string like that used in
`org-capture-templates'.  This key will be assigned to the fallback
capture template of citar-org-node: a basic call to
`org-node-capture-target', which creates a new file with a title
determined by `citar-org-node-new-node-title-template'.

If this variable is nil, then a key that is not taken will automatically
be chosen (see `citar-org-node--available-org-capture-key')."
  :type '(choice (const :tag "Off" nil)
                 (string :tag "Your own choice of key")))

;;; Variables
(defconst citar-org-node-notes-config
  (list :name "Org-node Notes"
        :category 'org-node-node
        :hasitems #'citar-org-node-has-notes
        :items #'citar-org-node--get-candidates
        :open #'citar-org-node-open-note
        :create #'citar-org-node--create-capture-note)
  "Org-node configuration for citar notes backend.

See `citar-notes-sources' for more details on configuration keys.")

;;; Functions
(defun citar-org-node--get-citekey-refs (&optional citekeys)
  "Return `org-node--ref-path<>ref-type' with only citekeys.

`org-node--ref-path<>ref-type' stores refs of any type (e.g., citekeys,
https).  This function removes (non-destructively) non-citekey pairs
from the hash table, returning the resulting hash table.

The optional argument CITEKEYS should be a list of org-node
ref-paths (i.e. citekeys).  If non-nil, only the keys-value pairs whose
keys are in this list will be included in the final hash table."
  (when (and citekeys (not (listp citekeys)))
    (error "CITEKEYS should be a list"))
  (ht-select (lambda (ref-path ref-type)
               ;; 2025-04-02: Org-node v3 changed the ref-path and ref-type
               ;; format of citations in `org-node--ref-path<>ref-type'.
               ;; Formally, the ref-path would be the citekey and the ref-type
               ;; would be the citekey prepended with a "@".  As of writing
               ;; this, the ref-path is unchanged (citekeys) but the ref-type is
               ;; now nil for citations.
               (and (member ref-path citekeys)
                    ;; 2025-04-02: Currently, the ref-type of citations is nil.
                    ;; This clause ensures that the ref-path of a non-citation
                    ;; is not identical to a citekey of ours.  This should be
                    ;; possible, though unlikely.
                    (not ref-type)))
             org-mem--roam-ref<>type))

(defun citar-org-node--get-candidates (&optional citekeys)
  "Return hash table mapping of CITEKEYS to completion candidates.

Return hash table whose CITEKEYS are elements of CITEKEYS and values are
the propertized candidate used for completion.  (Note: this text will be
the raw candidate text, but citar completion menus will show other
text.)

If CITEKEYS is nil, then return a hash table for all existent CITEKEYS
with their files.

See `citar-file--get-notes' for an example implementation.

See also `citar-org-node-notes-config'."
  (let ((node-info (ht-map (lambda (ref-path _ref-type)
                             ;; 2025-04-02: There is no org-node alias for
                             ;; `indexed-roam--ref<>id'; is it a mistake to use
                             ;; an indexed-specific variable?
                             (let* ((id (gethash (concat "@" ref-path) org-mem--roam-ref<>id))
                                    (node (org-mem-entry-by-id id))
                                    (title (org-mem-entry-title node)))
                               ;; Final list elements are:
                               (list id ref-path title)))
                           (citar-org-node--get-citekey-refs citekeys)))
        (cands (make-hash-table :test #'equal)))
    (pcase-dolist (`(,id ,citekey ,title) node-info)
      (push
       (concat
        (propertize id 'invisible t) " ["
        (propertize citekey 'face 'citar-highlight)
        (truncate-string-to-width "] " (- 60 (length citekey)) nil 32)
        (propertize title 'face 'citar))
       (gethash citekey cands)))
    cands))

(defun citar-org-node-has-notes ()
  "Return function to check for notes.

The returned function, when given a citekey, will return non-nil if
there's an associated note.

See also `citar-org-node-notes-config'."
  (let ((hasnotes (make-hash-table :test 'equal)))
    (dolist (citekey (org-mem-all-roam-refs))
      (puthash citekey t hasnotes))
    (lambda (ref-path)
      (gethash (concat "@" ref-path) hasnotes))))

(defun citar-org-node-open-note (candidate-string)
  "Open org-node node for CANDIDATE-STRING.

CANDIDATE-STRING is the completion candidate returned by
`citar-org-node--get-candidates'.

See also `citar-org-node-notes-config'."
  ;; We get the ID because, according to the return value of
  ;; `citar-org-node--get-candidates', it is the set of characters before the
  ;; first space
  (let ((id (substring-no-properties
             (car (split-string candidate-string)))))
    (org-node--goto (org-mem-entry-by-id id))))

(defun citar-org-node--available-org-capture-key ()
  "Returns a key available for being bound in the `org-capture' menu.

A \"key\" will be a single-letter string.

Meant for use in `citar-org-node--create-capture-note' to dynamically
create a template and assign it a key that is guaranteed to be
available.

If the keys already occupied by the user in `org-capture-templates'
remains the same, then the key returned by this function will also
remain the same."
  (let* ((taken-keys (cl-loop for template in org-capture-templates
                              when (stringp (car template))
                              collect (string-to-char (car template))))
         ;; TODO 2025-03-24: We keep this to the alphabet for simplicity, but
         ;; technically if a user has a capture template for on every letter,
         ;; this fails
         (all-letters (append (number-sequence ?a ?z) (number-sequence ?A ?Z)))
         (available-keys (seq-difference all-letters taken-keys))
         (sorted-available-keys (sort available-keys #'<))
         (hash-value (abs (sxhash (prin1-to-string taken-keys))))
         (index (mod hash-value (length sorted-available-keys))))
    (char-to-string (nth index sorted-available-keys))))

;;;###autoload
(defun citar-org-node-add-refs (citekey-or-citekeys)
  "Add CITEKEY-OR-CITEKEYS to the nearest relevant property drawer.

CITEKEY-OR-CITEKEYS can either be a list of citekeys or a single
citekey.  If it is a citekey it will be added to the value of the
\"ROAM_REFS\" property.  If it is a list, each of those citekeys will be
added to that property.

If called interactively, select CITEKEY-OR-CITEKEYS using
`citar-select-refs'."
  (interactive (list (citar-select-refs)) org-mode)
  (pcase citekey-or-citekeys
    ((pred listp)
     (dolist (citekey citekey-or-citekeys)
       (org-node--add-to-property-keep-space "ROAM_REFS" (concat "@" citekey))))
    ((pred stringp)
     (org-node--add-to-property-keep-space "ROAM_REFS" (concat "@" citekey-or-citekeys)))
    (_ (error "CITEKEY-OR-CITEKEYS should be a string or a list of strings"))))

;; TODO 2025-03-24: Have a way for predefined user templates to have access to
;; citar template fields
(defun citar-org-node--create-capture-note (citekey entry)
  "Open or create org-node node for CITEKEY and ENTRY.

This function calls `org-capture'.  Users can configure
`org-capture-templates' to define the capture templates they prefer.
After inserting the capture template, the \"ROAM_REFS\" property of the
node will automatically be set.

Additionally, in the `org-capture' menu is a fallback capture template:
a basic template that calls `org-node-capture-target', which creates a
new file.  The title of this org file is determined by
`citar-org-node-new-node-title-template'.  The template will
automatically be assigned to an available key if
`citar-org-node-fallback-org-capture-template-key' is nil; otherwise,
the value of that option will be used instead as the key."
  (let* ((fallback-org-capture-key
          (if (and citar-org-node-fallback-org-capture-template-key
                   (stringp citar-org-node-fallback-org-capture-template-key)
                   (= (length citar-org-node-fallback-org-capture-template-key) 1))
              citar-org-node-fallback-org-capture-template-key
            (citar-org-node--available-org-capture-key)))
         (org-node-proposed-title
          (citar-format--entry citar-org-node-new-node-title-template entry))
         (org-node-proposed-id (org-id-new))
         (org-capture-templates
          (append org-capture-templates
                  `((,fallback-org-capture-key "Citar-org-node: Simple capture into new file"
                                               plain (function org-node-capture-target) nil
                                               :empty-lines 1
                                               ;; TODO 2025-03-25: Ideally, we
                                               ;; give users the option for
                                               ;; :immediate-finish nil and
                                               ;; :jump-to-captured nil.
                                               ;; However, without these
                                               ;; settings, because
                                               ;; `org-node-capture-target'
                                               ;; calls `find-file' directly,
                                               ;; the buffer where this function
                                               ;; is called in ends up changing
                                               ;; to the new file, as well as a
                                               ;; new window (depending on the
                                               ;; user's `display-buffer-alist')
                                               ;; popping up.  Hence, these
                                               ;; settings are a workaround.
                                               :immediate-finish t
                                               :jump-to-captured t)))))
    (org-capture)
    ;; TODO 2025-03-24: Check that calling this after `org-capture' ensures the
    ;; property is set as expected.  If the point ends up outside the heading
    ;; after `org-capture', perhaps we have to use capture hooks to ensure the
    ;; property is set.
    (citar-org-node-add-refs citekey)))

;;;###autoload
(defun citar-org-node-open-resource (&optional prefix)
  "Call `citar-open' on all citar citekeys associated with the node at point.

If PREFIX is non-nil, prompts to select one or more of the citekeys to
call `citar-open' on instead."
  (interactive "P")
  (if-let* ((citar-open-prompt t)
            (node (org-node-at-point))
            (refs (mapcar (lambda (s) (string-remove-prefix "@" s))
                          (org-mem-roam-refs node))))
      (citar-open (if prefix
                      (citar-select-refs :filter (lambda (key) (member key refs)))
                    refs))
    (message "No ROAM_REFS or related resources for node at point")))

;;; Minor mode
(defvar citar-org-node--orig-source citar-notes-source)

(defun citar-org-node--setup ()
  "Register and select the citar-org-node notes backend.

Register the citar-org-node notes source backend using
`citar-register-notes-source' and setting `citar-notes-source'."
  (org-node-cache-ensure)     ; Ensure org-node is loaded and its cache is ready
  (citar-register-notes-source 'citar-org-node citar-org-node-notes-config)
  (setq citar-notes-source 'citar-org-node))

(defun citar-org-node--teardown ()
  "Restore citar notes backend to what is what before.

Remove the citar-org-node backend using and restore the value of
`citar-notes-source' before `citar-org-node-mode' was enabled (or
`citar-org-node--setup' was called)."
  (setq citar-notes-source citar-org-node--orig-source)
  (citar-remove-notes-source 'citar-org-node))

;;;###autoload
(define-minor-mode citar-org-node-mode
  "Toggle org-node integration with citar.

When enabling this mode, the citar-org-node notes source backend is
registered.  When disabling this mode, the notes source backend is
removed and the previous notes source backend is restored.  (For more
information on how this is accomplished, visit `citar-org-node--setup'
and `citar-org-node--teardown'.)

Org-node associates nodes to bibliographic references using the
\"ROAM_REFS\" property (stored in org-mode's property drawers).  With
this minor mode, citar will become aware of org-node nodes with a
corresponding bibliographic reference.  Such nodes will become the
associated \"note\" for that reference.  References can have multiple
notes."
  :global t
  :group 'org-node
  :lighter " citar-org-node"
  (if citar-org-node-mode
      (citar-org-node--setup)
    (citar-org-node--teardown)))

;;; Provide
(provide 'citar-org-node)
;;; citar-org-node.el ends here
