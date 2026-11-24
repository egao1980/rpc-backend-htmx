(in-package #:rpc-backend-htmx)

;;; Conditions (CLHS 9). Every error rpc-backend-htmx signals on purpose is an
;;; RPC-PROTOCOL:RPC-ERROR: either one of rpc-protocol's own
;;; (RPC-METHOD-NOT-FOUND, RPC-INVALID-PARAMS) or an HTMX-ERROR, which carries
;;; the HTTP status the server answers with. The server never lets a condition
;;; escape a request: HTMX-ERROR-RESPONSE turns it into a status + error
;;; fragment (see server.lisp). Extension point: methods on
;;; HTMX-CONDITION-STATUS / HTMX-ERROR-RESPONSE, not a private error dialect.
;;;
;;; 0.3.0 adds three: HTMX-UNKNOWN-PARAM (400, a param the handler's key set
;;; refuses: handlers.lisp, Key sets), HTMX-TOO-MANY-PARAMS (413, more fields
;;; than the codec's MAX-PARAMS: codec.lisp) and HTMX-FORBIDDEN (403, the token
;;; gate: server.lisp). Their slots and reports are final; each is signalled
;;; where it is detected (%ACCEPT-PARAMS, %CHECK-PARAM-COUNT / %JSON-PAIRS, the
;;; token gate).

(define-condition htmx-error (rpc-protocol:rpc-error)
  ((status :initarg :status :initform 500 :reader htmx-error-status
           :documentation "HTTP status the server answers with."))
  (:default-initargs :code rpc-protocol:+internal-error+)
  (:report (lambda (c s)
             (format s "htmx error ~D~@[: ~A~]"
                     (htmx-error-status c) (rpc-protocol:rpc-error-message c)))))

(define-condition htmx-bad-request (htmx-error) ()
  (:default-initargs :status 400 :code rpc-protocol:+invalid-request+
                     :message "Bad request")
  (:documentation "Malformed query string, form body, percent-escape or UTF-8."))

(define-condition htmx-unknown-param (htmx-bad-request)
  ((name :initarg :name :initform nil :reader htmx-unknown-param-name
         :documentation "The refused param name, downcased (handlers.lisp, Accepting a request)."))
  (:default-initargs :code rpc-protocol:+invalid-params+ :message "Unknown param")
  (:documentation "A request param the handler's key set does not accept (#2, #3).
400 over htmx; code -32602 (invalid params) over JSON-RPC. The signaller passes
:message \"Unknown param <name>\"."))

(define-condition htmx-forbidden (htmx-error) ()
  (:default-initargs :status 403 :code rpc-protocol:+invalid-request+
                     :message "Forbidden")
  (:documentation "The token gate refused the request (#4): no valid session cookie, a
wrong or already used bootstrap token. server.lisp, Token gate."))

(define-condition htmx-method-not-allowed (htmx-error) ()
  (:default-initargs :status 405 :code rpc-protocol:+invalid-request+
                     :message "Method not allowed (GET or POST)"))

(define-condition htmx-not-acceptable (htmx-error) ()
  (:default-initargs :status 406 :code rpc-protocol:+invalid-request+
                     :message "A :call-stream method needs Accept: text/event-stream"))

(define-condition htmx-body-too-large (htmx-error)
  ((limit :initarg :limit :reader htmx-body-limit
          :documentation "The max-body-bytes in force.")
   (size :initarg :size :initform nil :reader htmx-body-size
         :documentation "Content-Length when the request declared one, else NIL."))
  (:default-initargs :status 413 :code rpc-protocol:+invalid-request+
                     :message "Request body too large"))

(define-condition htmx-too-many-params (htmx-error)
  ((limit :initarg :limit :reader htmx-params-limit
          :documentation "The max-params in force."))
  (:default-initargs :status 413 :code rpc-protocol:+invalid-request+
                     :message "Too many request params")
  (:documentation "More fields in one request than the codec's MAX-PARAMS (#2):
codec.lisp, Params. JSON-RPC: more members than that."))

(define-condition htmx-unsupported-media-type (htmx-error)
  ((content-type :initarg :content-type :initform nil :reader htmx-error-content-type))
  (:default-initargs :status 415 :code rpc-protocol:+invalid-request+
                     :message "Unsupported media type (urlencoded or multipart/form-data)"))
