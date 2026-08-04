;;; nelisp-apps-sdk-schema.el --- Apps SDK manifest and ABI validator -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Phase 1 static schema validator for the NeLisp apps SDK.  This file
;; validates:
;;
;; - app manifests supplied as JSON strings
;; - host ABI declarations supplied as Elisp plists
;;
;; Runtime sandboxing and host function implementation are explicitly out
;; of scope here.

;;; Code:

(require 'cl-lib)
(require 'nelisp-json)

(defconst nelisp-apps-sdk--permission-tags
  '(time storage bytes-string record)
  "Allowed manifest and ABI permission tags.")

(defconst nelisp-apps-sdk--abi-type-tags
  '(i64 f64 string record bool)
  "Allowed ABI argument and return type tags.")

(defconst nelisp-apps-sdk--manifest-required-fields
  '("app-id" "name" "version" "abi-version" "permissions" "entrypoints")
  "Required top-level manifest fields.")

(defun nelisp-apps-sdk--manifest-key (field)
  "Return plist keyword for JSON object FIELD."
  (intern (concat ":" field)))

(defun nelisp-apps-sdk--manifest-get (manifest field)
  "Return MANIFEST value for JSON FIELD."
  (plist-get manifest (nelisp-apps-sdk--manifest-key field)))

(defun nelisp-apps-sdk--error-result (errors)
  "Return invalid result plist from ERRORS."
  (list :valid nil :errors (nreverse errors)))

(defun nelisp-apps-sdk--ok-result ()
  "Return success result plist."
  '(:valid t))

(defun nelisp-apps-sdk--plist-object-string-values-p (value)
  "Return non-nil when VALUE is a plist object with string values."
  (and (listp value)
       (catch 'invalid
         (let ((cursor value))
           (while cursor
             (unless (and (consp cursor)
                          (keywordp (car cursor))
                          (consp (cdr cursor))
                          (stringp (cadr cursor)))
               (throw 'invalid nil))
             (setq cursor (cddr cursor))))
         t)))

(defun nelisp-apps-sdk--validate-manifest-required-fields (manifest errors)
  "Append missing required field errors for MANIFEST onto ERRORS."
  (dolist (field nelisp-apps-sdk--manifest-required-fields errors)
    (unless (memq (nelisp-apps-sdk--manifest-key field) manifest)
      (push (format "missing required field: %s" field) errors))))

(defun nelisp-apps-sdk--validate-manifest-string-field (manifest field errors)
  "Validate string FIELD in MANIFEST, appending failures onto ERRORS."
  (let ((value (nelisp-apps-sdk--manifest-get manifest field)))
    (when (and (memq (nelisp-apps-sdk--manifest-key field) manifest)
               (not (stringp value)))
      (push (format "%s must be a string" field) errors)))
  errors)

(defun nelisp-apps-sdk--validate-manifest-permissions (manifest errors)
  "Validate MANIFEST permissions, appending failures onto ERRORS."
  (let ((permissions (nelisp-apps-sdk--manifest-get manifest "permissions")))
    (when (memq :permissions manifest)
      (cond
       ((not (listp permissions))
        (push "permissions must be a list" errors))
       (t
        (dolist (permission permissions)
          (cond
           ((not (stringp permission))
            (push "permissions must contain only string tags" errors))
           ((not (memq (intern permission) nelisp-apps-sdk--permission-tags))
            (push (format "unknown permission tag: %s" permission) errors))))))))
  errors)

(defun nelisp-apps-sdk--validate-manifest-entrypoints (manifest errors)
  "Validate MANIFEST entrypoints, appending failures onto ERRORS."
  (let ((entrypoints (nelisp-apps-sdk--manifest-get manifest "entrypoints")))
    (when (memq :entrypoints manifest)
      (cond
       ((not (listp entrypoints))
        (push "entrypoints must be an object" errors))
       ((not (nelisp-apps-sdk--plist-object-string-values-p entrypoints))
        (push "entrypoints must map names to string values" errors)))))
  errors)

(defun nelisp-apps-sdk--known-abi-type-tag-p (value)
  "Return non-nil if VALUE is a known ABI type tag."
  (memq value nelisp-apps-sdk--abi-type-tags))

(defun nelisp-apps-sdk--known-permission-tag-p (value)
  "Return non-nil if VALUE is a known permission tag."
  (memq value nelisp-apps-sdk--permission-tags))

;;;###autoload
(defun nelisp-apps-sdk-validate-manifest (json-string)
  "Validate app manifest JSON-STRING.

Return `(:valid t)' on success or
`(:valid nil :errors (LIST-OF-ERROR-STRINGS))' on failure."
  (condition-case err
      (let ((manifest (nelisp-json-parse-string
                       json-string
                       :object-type 'plist
                       :array-type 'list))
            errors)
        (cond
         ((not (listp manifest))
          (nelisp-apps-sdk--error-result
           '("manifest root must be an object")))
         (t
          (setq errors
                (nelisp-apps-sdk--validate-manifest-required-fields
                 manifest errors))
          (dolist (field '("app-id" "name" "version" "abi-version" "description"))
            (setq errors
                  (nelisp-apps-sdk--validate-manifest-string-field
                   manifest field errors)))
          (setq errors
                (nelisp-apps-sdk--validate-manifest-permissions
                 manifest errors))
          (setq errors
                (nelisp-apps-sdk--validate-manifest-entrypoints
                 manifest errors))
          (if errors
              (nelisp-apps-sdk--error-result errors)
            (nelisp-apps-sdk--ok-result)))))
    (error
     (list :valid nil
           :errors (list (format "malformed JSON: %s"
                                 (error-message-string err)))))))

;;;###autoload
(defun nelisp-apps-sdk-validate-abi-decl (decl)
  "Validate one ABI declaration plist DECL.

Return `(:valid t)' on success or
`(:valid nil :errors (LIST-OF-ERROR-STRINGS))' on failure."
  (let (errors
        (name (plist-get decl :name))
        (args (plist-get decl :args))
        (return-type (plist-get decl :return))
        (permission (plist-get decl :permission)))
    (unless (stringp name)
      (push "name must be a string" errors))
    (cond
     ((not (listp args))
      (push "args must be a list" errors))
     (t
      (dolist (arg args)
        (unless (nelisp-apps-sdk--known-abi-type-tag-p arg)
          (push (format "unknown ABI arg type tag: %s" arg) errors)))))
    (unless (nelisp-apps-sdk--known-abi-type-tag-p return-type)
      (push (format "unknown ABI return type tag: %s" return-type) errors))
    (unless (nelisp-apps-sdk--known-permission-tag-p permission)
      (push (format "unknown permission tag: %s" permission) errors))
    (if errors
        (nelisp-apps-sdk--error-result errors)
      (nelisp-apps-sdk--ok-result))))

(provide 'nelisp-apps-sdk-schema)

;;; nelisp-apps-sdk-schema.el ends here
