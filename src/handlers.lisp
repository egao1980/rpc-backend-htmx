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
;;; PARAMS is the keyword → string plist the codec decoded.

(defparameter +htmx-handler-modes+ '(:call-response :notify :call-stream)
  "Modes a handler-table entry may have. Mode mapping (locked): hx-get / hx-post →
:call-response; HX-Trigger with no swap → :notify (204 + HX-Trigger headers); the htmx
SSE extension → :call-stream (one HTML fragment per SSE event, named by its event name).")

(defclass htmx-handlers ()
  ((entries :initarg :entries :initform nil
            :documentation "Implementation-defined; read through FIND-HTMX-HANDLER / HTMX-HANDLER-NAMES."))
  (:documentation "Method name → (function, mode). The server's allowlist."))

(defun htmx-method-name (symbol)
  "\"<PACKAGE>::<NAME>\" for SYMBOL."
  (declare (ignore symbol))
  (%htmx0-pending 'htmx-method-name))

(defun make-htmx-handlers (&rest entries)
  "A handler table from ENTRIES (see the file header)."
  (declare (ignore entries))
  (%htmx0-pending 'make-htmx-handlers))

(defun find-htmx-handler (handlers name)
  "(values function mode) for the method NAME (a string) in HANDLERS, or NIL."
  (declare (ignore handlers name))
  (%htmx0-pending 'find-htmx-handler))

(defun htmx-handler-names (handlers)
  "Method names in HANDLERS, in registration order (fresh list)."
  (declare (ignore handlers))
  (%htmx0-pending 'htmx-handler-names))
