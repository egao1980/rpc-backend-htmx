(in-package #:rpc-backend-htmx)

;;; Conditions (CLHS 9). Every error rpc-backend-htmx signals on purpose is an
;;; RPC-PROTOCOL:RPC-ERROR: either one of rpc-protocol's own
;;; (RPC-METHOD-NOT-FOUND, RPC-INVALID-PARAMS) or an HTMX-ERROR, which carries
;;; the HTTP status the server answers with. The server never lets a condition
;;; escape a request: HTMX-ERROR-RESPONSE turns it into a status + error
;;; fragment (see server.lisp). Extension point: methods on
;;; HTMX-CONDITION-STATUS / HTMX-ERROR-RESPONSE, not a private error dialect.

(define-condition htmx0-pending (error)
  ((name :initarg :name :reader htmx0-pending-name))
  (:report (lambda (c s)
             (format s "H4h-1b pending: ~A is not implemented yet" (htmx0-pending-name c)))))

(defun %htmx0-pending (name)
  "Stub marker for the H4h-1b team-solve run. Not an HTMX-ERROR on purpose."
  (error 'htmx0-pending :name name))

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

(define-condition htmx-unsupported-media-type (htmx-error)
  ((content-type :initarg :content-type :initform nil :reader htmx-error-content-type))
  (:default-initargs :status 415 :code rpc-protocol:+invalid-request+
                     :message "Unsupported media type (urlencoded or multipart/form-data)"))
