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
;;;   SYMBOL                                 → name from the symbol, function = the symbol
;;;   (SYMBOL &key mode params)              → same, with options
;;;   (NAME-STRING FUNCTION &key mode params) → explicit name (must contain "::" with
;;;                                            non-empty sides) and a function object
;;; A symbol entry is called through the symbol (FUNCALL 'sym), so redefining
;;; the function in the image takes effect on the next request (its key set
;;; too: Key sets, When). The option tail is :MODE / :PARAMS pairs; a repeated
;;; option → the first wins (GETF), as in 0.2.1.
;;; MODE is one of +HTMX-HANDLER-MODES+, default :CALL-RESPONSE. PARAMS (0.3.0)
;;; declares the entry's key set (below). Anything else, a malformed entry or a
;;; duplicate name → HTMX-ERROR (status 500).
;;;
;;; Key sets (0.3.0, rpc-backend-htmx#2 and #3). Each entry accepts a set of
;;; request param keys, its KEY SET: T (any key) or a list of keywords
;;; (possibly empty: no keys at all).
;;; - :PARAMS given: T, or a proper list of keywords (NIL included), used as
;;;   given (order kept, a repeated keyword kept once, first place). The lambda
;;;   list is then never read and no shape is checked. Anything else (a string,
;;;   a lone keyword, a non-keyword symbol or a string in the list, an improper
;;;   list) → HTMX-ERROR 500 at MAKE-HTMX-HANDLERS. Declare :PARAMS for a
;;;   forwarder (a function standing in for a canvas in another image) and
;;;   wherever the implementation reports no lambda list (below).
;;; - Otherwise derived from the function's lambda list as the implementation
;;;   reports it, through one internal function, %FUNCTION-LAMBDA-LIST
;;;   (function) → (values lambda-list reportedp):
;;;     SBCL: a generic function → SB-MOP:GENERIC-FUNCTION-LAMBDA-LIST; any other
;;;       function → SB-KERNEL:%FUN-LAMBDA-LIST, whose :UNKNOWN (code compiled
;;;       with (debug 0)) is "not reported".
;;;     ECL: EXT:FUNCTION-LAMBDA-LIST; a NIL second value is "not reported" (a
;;;       compiled anonymous function, and a compiled function whose lambda
;;;       list is (): ECL cannot tell those apart from missing).
;;;     Any other implementation: not reported.
;;;   A reported lambda list LL gives the key set:
;;;     &ALLOW-OTHER-KEYS in LL, or &REST in LL without &KEY → T;
;;;     &KEY in LL → the key of each &key parameter, in LL order: VAR or (VAR …)
;;;       → (INTERN (SYMBOL-NAME VAR) :KEYWORD) (trusted code; the only INTERN
;;;       left in the server); ((KEY VAR) …) → KEY when it is a keyword, else
;;;       nothing (no request can name a non-keyword key);
;;;     otherwise → NIL: a canvas with no parameters (#3).
;;;   Not reported → NIL, and no shape check: such an entry takes no params
;;;   until it declares :PARAMS. (On every implementation the tests run on, a
;;;   named function compiled from a file with a non-empty lambda list is
;;;   reported.)
;;;   A reported LL must have a shape the server can call (#3), else
;;;   HTMX-ERROR 500 whose message is exactly
;;;     Handler <method name> cannot take request params: <LL>
;;;   <LL> printed by PRIN1 under WITH-STANDARD-IO-SYNTAX with *PACKAGE* the
;;;   COMMON-LISP package and *PRINT-READABLY* NIL, e.g. for (defun f (x) …) in
;;;   CL-USER: "(COMMON-LISP-USER::X)". The shapes:
;;;   :CALL-RESPONSE and :NOTIFY — no required and no &OPTIONAL parameter;
;;;   :CALL-STREAM — exactly one required parameter (the stream), no &OPTIONAL.
;;;   &AUX parameters are ignored.
;;; - When. A function entry, and a symbol entry whose symbol is fbound when the
;;;   table is built, derive in MAKE-HTMX-HANDLERS, so a bad shape fails there.
;;;   A symbol entry derives again whenever (FDEFINITION symbol) is not the
;;;   function its key set came from (EQ) — a redefinition at the REPL, or a
;;;   symbol defined after the table was built — before that request goes on;
;;;   a bad shape then → that HTMX-ERROR 500 for the request, nothing called.
;;;   A symbol unbound at request time → UNDEFINED-FUNCTION (500), as in 0.2.1.
;;;   An entry with :PARAMS never derives.
;;; HTMX-HANDLER-KEYS (handlers name) → (values key-set T): the key set the
;;;   next request to NAME would use (T, or a fresh list in the order above),
;;;   deriving as a request would (so it signals what a request would);
;;;   (values NIL NIL) for a name not in the table.
;;;
;;; Accepting a request (the server and JSONRPC-HANDLER do this before calling
;;; anything). PARAMS is the decoded keyword plist, UNMAPPED the names that
;;; named no keyword (codec.lisp, Params):
;;;   key set T      → accepted: PARAMS passed whole, UNMAPPED dropped;
;;;   a list of keys → accepted when every key of PARAMS is in it and UNMAPPED
;;;                    is empty; else HTMX-UNKNOWN-PARAM (400; -32602 over
;;;                    JSON-RPC) whose NAME is the first key of PARAMS not in the
;;;                    list as (STRING-DOWNCASE (SYMBOL-NAME key)), or else the
;;;                    first of UNMAPPED downcased, and whose message is exactly
;;;                      Unknown param <NAME>
;;; That predicate is the whole rule (no precedence, no table): "unknown keys"
;;; are refused, never dropped, so a typo in a URL or a form field name is a
;;; clear 400 instead of a silently ignored value, and a request never depends
;;; on which keywords happen to exist in the image.
;;;
;;; Calling convention (the server does this; see server.lisp), for an
;;; accepted request:
;;;   :call-response (apply fn params)
;;;                  → (values result response-headers)
;;;   :notify        (apply fn params)
;;;                  → (values ignored response-headers); answered 204, no body
;;;   :call-stream   (apply fn stream params), STREAM an HTMX-EVENT-STREAM; the
;;;                  function RPC-SENDs events; returning ends the stream.
;;; No :ALLOW-OTHER-KEYS is passed. 0.2.1 called (apply fn :allow-other-keys t
;;; params), which a function without &KEY cannot take: (defun dashboard () …)
;;; answered 500 "invalid number of arguments: 2" (#3). A function with no
;;; parameters is now called with none.
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
            :documentation "Implementation-defined; read through FIND-HTMX-HANDLER /
HTMX-HANDLER-NAMES / HTMX-HANDLER-KEYS."))
  (:documentation "Method name → (function, mode, key set). The server's allowlist."))

;;; ENTRIES slot: a simple-vector of %ENTRY structures in registration order.
;;; Lookup is a linear STRING= search: tables are small, and there is no hash
;;; table whose iteration order could reach output. An entry holds its key
;;; set: the :PARAMS one when declared, else the derived one together with the
;;; function it came from (Key sets, When).

(defstruct (%entry (:constructor %make-entry (name callee mode params-p params))
                   (:copier nil) (:predicate nil))
  (name "" :type string :read-only t)
  (callee nil :type (or symbol function) :read-only t) ; the symbol, or a function object
  (mode :call-response :type keyword :read-only t)
  (params-p nil :read-only t)           ; :PARAMS was given
  (params nil :read-only t)             ; that key set
  ;; NIL, or (source-function . key-set): the derived key set and the function
  ;; it came from, in ONE cons replaced by one SETF, so a concurrent request
  ;; never pairs a key set with another function. A failed derivation is never
  ;; stored: the next request derives (and signals) again.
  (derived nil))

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

;;; ---------------------------------------------------------------------------
;;; Key sets (0.3.0)
;;; ---------------------------------------------------------------------------

(defun %params-option (params)
  "An entry's :PARAMS value → its key set (T or a fresh list of keywords), or
HTMX-ERROR 500. See the file header (Key sets)."
  (cond ((eq params t) t)
        ((and (listp params) (null (cdr (last params))) (every #'keywordp params))
         (let ((keys '()))
           (dolist (key params (nreverse keys))
             (pushnew key keys :test #'eq))))  ; a repeated key kept once, first place
        (t (%bad-entry "Handler :params must be T or a proper list of keywords: ~S" params))))

(defun %function-lambda-list (function)
  "(values lambda-list reportedp) for FUNCTION, as the implementation reports
it (SBCL, ECL; elsewhere not reported). See the file header (Key sets)."
  (declare (ignorable function))
  #+sbcl
  (if (typep function 'generic-function)
      (values (sb-mop:generic-function-lambda-list function) t)
      (let ((lambda-list (sb-kernel:%fun-lambda-list function)))
        (if (listp lambda-list)           ; :UNKNOWN under (debug 0)
            (values lambda-list t)
            (values nil nil))))
  #+ecl
  (multiple-value-bind (lambda-list reportedp) (ext:function-lambda-list function)
    (if (and reportedp (listp lambda-list))
        (values lambda-list t)
        (values nil nil)))
  #-(or sbcl ecl)
  (values nil nil))

(defun %lambda-list-key (parameter)
  "The request key of one &key PARAMETER: VAR or (VAR …) → the keyword named
like VAR; ((KEY VAR) …) → KEY when it is a keyword, else NIL (no request can
name it). Interns, on trusted code only: the lambda list a handler was compiled
with, never a request name."
  (let ((head (if (consp parameter) (car parameter) parameter)))
    (cond ((consp head) (and (keywordp (car head)) (car head)))
          ((and head (symbolp head)) (intern (symbol-name head) :keyword))
          (t nil))))

(defun %print-lambda-list (lambda-list)
  "LAMBDA-LIST as the shape error prints it (file header, Key sets)."
  (with-standard-io-syntax
    (let ((*package* (find-package "COMMON-LISP"))
          (*print-readably* nil))
      (prin1-to-string lambda-list))))

(defun %lambda-list-key-set (lambda-list mode name)
  "The key set of a reported LAMBDA-LIST for an entry NAMEd (a method name)
with MODE; a shape the server cannot call → HTMX-ERROR 500 (exact message in
the file header)."
  (let ((state :required) (required 0) (optional 0)
        (rest-p nil) (key-p nil) (other-keys-p nil) (keys '()))
    (dolist (parameter lambda-list)
      (if (member parameter lambda-list-keywords :test #'eq)
          (setf state (case parameter
                        (&optional :optional)
                        ((&rest &body) (setf rest-p t) :ignore)
                        (&key (setf key-p t) :key)
                        (&allow-other-keys (setf other-keys-p t) :ignore)
                        (otherwise :ignore))) ; &aux, and defensively &whole &environment …
          (case state
            (:required (incf required))
            (:optional (incf optional))
            (:key (let ((key (%lambda-list-key parameter)))
                    (when key (push key keys)))))))
    (unless (and (zerop optional)
                 (= required (if (eq mode :call-stream) 1 0)))
      (%bad-entry "Handler ~A cannot take request params: ~A"
                  name (%print-lambda-list lambda-list)))
    (cond ((or other-keys-p (and rest-p (not key-p))) t)
          (key-p (nreverse keys))
          (t nil))))

(defun %accept-params (key-set params unmapped)
  "PARAMS (keyword plist) and UNMAPPED (names that named no keyword) against
KEY-SET: return normally when accepted, else signal HTMX-UNKNOWN-PARAM. See the
file header (Accepting a request)."
  (unless (eq key-set t)
    (let ((refused (or (loop for (key) on params by #'cddr
                             unless (member key key-set :test #'eq)
                               return (string-downcase (symbol-name key)))
                       (and unmapped (string-downcase (first unmapped))))))
      (when refused
        (error 'htmx-unknown-param :name refused
                                   :message (format nil "Unknown param ~A" refused)))))
  (values))

(defun %entry-options (options)
  "(values mode params-option params-p) from an entry's option tail (:mode m
:params p); MODE defaults to :CALL-RESPONSE."
  (unless (and (listp options)
               (null (cdr (last options)))
               (evenp (length options))
               (loop for (key) on options by #'cddr always (member key '(:mode :params))))
    (%bad-entry "Handler options must be (:mode m :params p): ~S" options))
  (let ((mode (getf options :mode :call-response))
        (params-p (and (member :params options) t)))
    (unless (member mode +htmx-handler-modes+)
      (%bad-entry "Unknown handler mode ~S (one of ~S)" mode +htmx-handler-modes+))
    (values mode
            (and params-p (%params-option (getf options :params)))
            params-p)))

(defun %derive-key-set (entry function)
  "The key set FUNCTION's reported lambda list gives ENTRY; NIL when not reported."
  (multiple-value-bind (lambda-list reportedp) (%function-lambda-list function)
    (if reportedp
        (%lambda-list-key-set lambda-list (%entry-mode entry) (%entry-name entry))
        nil)))

(defun %entry-key-set (entry)
  "The key set ENTRY's next call uses: its :PARAMS, or derived (again, for a
symbol entry whose definition changed). See the file header (Key sets, When)."
  (if (%entry-params-p entry)
      (%entry-params entry)
      (let* ((callee (%entry-callee entry))
             ;; Unbound at request time → UNDEFINED-FUNCTION (500), as in 0.2.1.
             (function (if (functionp callee) callee (fdefinition callee)))
             (derived (%entry-derived entry))) ; read once: never a mixed pair
        (if (and derived (eq (car derived) function))
            (cdr derived)
            (let ((key-set (%derive-key-set entry function))) ; a signal leaves DERIVED as it was
              (setf (%entry-derived entry) (cons function key-set))
              key-set)))))

(defun %parse-entry (entry)
  "ENTRY → an %ENTRY, or HTMX-ERROR. A function entry, and a symbol entry whose
symbol is fbound, derive their key set here, so a bad shape fails in
MAKE-HTMX-HANDLERS (file header, When)."
  (multiple-value-bind (name callee options)
      (cond ((%method-symbol-p entry)
             (values (htmx-method-name entry) entry '()))
            ((and (consp entry) (%method-symbol-p (car entry)))
             (values (htmx-method-name (car entry)) (car entry) (cdr entry)))
            ((and (consp entry) (stringp (car entry)) (consp (cdr entry)))
             (let ((name (first entry)) (fn (second entry)))
               (unless (%method-name-p name)
                 (%bad-entry "Handler name must be \"PKG::NAME\": ~S" name))
               (unless (functionp fn)
                 (%bad-entry "Handler for ~A is not a function: ~S" name fn))
               (values name fn (cddr entry))))
            (t (%bad-entry "Malformed handler entry ~S" entry)))
    (multiple-value-bind (mode params params-p) (%entry-options options)
      (let ((parsed (%make-entry name callee mode params-p params)))
        (when (and (not params-p) (or (functionp callee) (fboundp callee)))
          (%entry-key-set parsed))
        parsed))))

(defun make-htmx-handlers (&rest entries)
  "A handler table from ENTRIES (see the file header)."
  (let ((parsed '()))
    (dolist (entry entries)
      (let ((e (%parse-entry entry)))
        (when (find (%entry-name e) parsed :key #'%entry-name :test #'string=)
          (%bad-entry "Duplicate handler name ~A" (%entry-name e)))
        (push e parsed)))
    (make-instance 'htmx-handlers :entries (coerce (nreverse parsed) 'simple-vector))))

(defun %handler-entries (handlers)
  (check-type handlers htmx-handlers)
  (slot-value handlers 'entries))

(defun %find-entry (handlers name)
  (and (stringp name)
       (find name (%handler-entries handlers) :key #'%entry-name :test #'string=)))

(defun find-htmx-handler (handlers name)
  "(values function mode) for the method NAME (a string) in HANDLERS, or NIL."
  (let ((entry (%find-entry handlers name)))
    (if entry
        (values (%entry-callee entry) (%entry-mode entry))
        nil)))

(defun htmx-handler-keys (handlers name)
  "(values key-set T) for the method NAME in HANDLERS, (values NIL NIL) when
NAME is not in it. See the file header (Key sets)."
  (let ((entry (%find-entry handlers name)))
    (if entry
        (let ((key-set (%entry-key-set entry)))
          (values (if (listp key-set) (copy-list key-set) key-set) t))
        (values nil nil))))

(defun htmx-handler-names (handlers)
  "Method names in HANDLERS, in registration order (fresh list)."
  (map 'list #'%entry-name (%handler-entries handlers)))
