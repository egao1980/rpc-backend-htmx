(in-package #:rpc-backend-htmx)

;;; The handler table IS the allowlist: a request whose method is not in it is
;;; answered 404 (RPC-METHOD-NOT-FOUND) and nothing is called. There is no
;;; "every fbound symbol" fallback, ever.
;;;
;;; Method names: "<PACKAGE-NAME>::<SYMBOL-NAME>" exactly as the names are
;;; (case-sensitive, no case folding), e.g. "CL-USER::PEOPLE". HTMX-METHOD-NAME
;;; makes one from a symbol (non-keyword, interned; else HTMX-ERROR).
;;;
;;; MAKE-HTMX-HANDLERS entries, in order:
;;;   SYMBOL                         → name from the symbol, function = the symbol
;;;   (SYMBOL &key mode)             → same, with a mode
;;;   (NAME-STRING FUNCTION &key mode) → explicit name (must contain "::" with
;;;                                    non-empty sides) and a function object
;;; A symbol entry is called through the symbol (FUNCALL 'sym), so redefining
;;; the function in the image takes effect on the next request.
;;; MODE is one of +HTMX-HANDLER-MODES+, default :CALL-RESPONSE. Anything else,
;;; a malformed entry or a duplicate name → HTMX-ERROR (status 500).
;;;
;;; Calling convention (the server does this; see server.lisp):
;;;   :call-response (apply fn :allow-other-keys t params)
;;;                  → (values result response-headers)
;;;   :notify        (apply fn :allow-other-keys t params)
;;;                  → (values ignored response-headers); answered 204, no body
;;;   :call-stream   (apply fn stream :allow-other-keys t params), STREAM an
;;;                  HTMX-EVENT-STREAM; the function RPC-SENDs events; returning
;;;                  ends the stream.
;;; PARAMS is the keyword → value plist the codec decoded: strings, and (0.2.0)
;;; for multipart file parts a STACK-MIME:MIME-ENTITY or a list of them
;;; (codec.lisp, Multipart parts). A handler that wants an upload calls
;;; canvas-protocol COERCE-PARAM :file on it, or reads the entity itself.

(defparameter +htmx-handler-modes+ '(:call-response :notify :call-stream)
  "Modes a handler-table entry may have. Mode mapping (locked): hx-get / hx-post →
:call-response; HX-Trigger with no swap → :notify (204 + HX-Trigger headers); the htmx
SSE extension → :call-stream (one HTML fragment per SSE event, named by its event name).")

(defclass htmx-handlers ()
  ((entries :initarg :entries :initform nil
            :documentation "Implementation-defined; read through FIND-HTMX-HANDLER / HTMX-HANDLER-NAMES."))
  (:documentation "Method name → (function, mode). The server's allowlist."))

;;; ENTRIES slot: a simple-vector of (name function-or-symbol mode) in
;;; registration order. Lookup is a linear STRING= search: tables are small,
;;; and there is no hash table whose iteration order could reach output.

(defun %method-symbol-p (object)
  "True for an interned, non-keyword symbol (one that can name a method)."
  (and object (symbolp object) (not (keywordp object))
       (symbol-package object) t))

(defun %method-name-p (object)
  "True for a string \"<pkg>::<name>\" with both sides non-empty."
  (and (stringp object)
       (let ((sep (search "::" object)))
         (and sep (plusp sep) (< (+ sep 2) (length object))))))

(defun %bad-entry (control &rest args)
  (error 'htmx-error :status 500
                     :message (apply #'format nil control args)))

(defun htmx-method-name (symbol)
  "\"<PACKAGE>::<NAME>\" for SYMBOL."
  (unless (%method-symbol-p symbol)
    (error 'htmx-error :status 500
                       :message (format nil "Not a method symbol: ~S" symbol)))
  (concatenate 'string (package-name (symbol-package symbol)) "::" (symbol-name symbol)))

(defun %entry-mode (options)
  "Mode from an entry's option tail (:mode m), default :CALL-RESPONSE."
  (unless (and (listp options)
               (null (cdr (last options)))
               (evenp (length options))
               (loop for (key) on options by #'cddr always (eq key :mode)))
    (%bad-entry "Handler options must be (:mode m): ~S" options))
  (let ((mode (getf options :mode :call-response)))
    (unless (member mode +htmx-handler-modes+)
      (%bad-entry "Unknown handler mode ~S (one of ~S)" mode +htmx-handler-modes+))
    mode))

(defun %parse-entry (entry)
  "ENTRY → (name function-or-symbol mode), or HTMX-ERROR."
  (cond ((%method-symbol-p entry)
         (list (htmx-method-name entry) entry :call-response))
        ((and (consp entry) (%method-symbol-p (car entry)))
         (list (htmx-method-name (car entry)) (car entry) (%entry-mode (cdr entry))))
        ((and (consp entry) (stringp (car entry)) (consp (cdr entry)))
         (let ((name (first entry)) (fn (second entry)))
           (unless (%method-name-p name)
             (%bad-entry "Handler name must be \"PKG::NAME\": ~S" name))
           (unless (functionp fn)
             (%bad-entry "Handler for ~A is not a function: ~S" name fn))
           (list name fn (%entry-mode (cddr entry)))))
        (t (%bad-entry "Malformed handler entry ~S" entry))))

(defun make-htmx-handlers (&rest entries)
  "A handler table from ENTRIES (see the file header)."
  (let ((parsed '()))
    (dolist (entry entries)
      (let ((e (%parse-entry entry)))
        (when (find (first e) parsed :key #'first :test #'string=)
          (%bad-entry "Duplicate handler name ~A" (first e)))
        (push e parsed)))
    (make-instance 'htmx-handlers :entries (coerce (nreverse parsed) 'simple-vector))))

(defun %handler-entries (handlers)
  (check-type handlers htmx-handlers)
  (slot-value handlers 'entries))

(defun find-htmx-handler (handlers name)
  "(values function mode) for the method NAME (a string) in HANDLERS, or NIL."
  (let ((entry (and (stringp name)
                    (find name (%handler-entries handlers) :key #'first :test #'string=))))
    (if entry
        (values (second entry) (third entry))
        nil)))

(defun htmx-handler-names (handlers)
  "Method names in HANDLERS, in registration order (fresh list)."
  (map 'list #'first (%handler-entries handlers)))
