(in-package #:rpc-backend-htmx)

;;; HTMX-CLIENT: calls a Clack app in process the way a browser running htmx
;;; would (tests, H4h-2 snapshots, agents checking fragments). It is also an
;;; rpc-protocol transport, so RPC-CALL / RPC-NOTIFY / RPC-CALL-STREAM work on it.
;;;
;;; (HTMX-REQUEST client method params &key http-method encoding hx-request
;;;               target trigger trigger-name current-url boosted accept headers)
;;;   Builds the env with ENCODE-REQUEST-USING-CODEC on the client's codec.
;;;   HX-REQUEST (default T) sends "HX-Request: true"; TARGET, TRIGGER,
;;;   TRIGGER-NAME, CURRENT-URL, BOOSTED (T → "true") the matching HX-* header;
;;;   ACCEPT an Accept header; HEADERS extra (name . value) pairs.
;;;   → HTMX-REPLY, via HTMX-REQUEST-ENV.
;;; (HTMX-REQUEST-URL client url &rest keys) → HTMX-REPLY for a URL string as a
;;;   resolver builds it ("/prefix/PKG::NAME?k=v", path percent-encoded, query raw);
;;;   KEYS as HTMX-REQUEST (method and params come from the URL; a POST sends the
;;;   query as given and no body).
;;; (HTMX-REQUEST-ENV client env) → HTMX-REPLY: calls the app on a hand-made env.
;;;   The app's response may be a list (status headers body) or a Clack
;;;   streaming function; drive it with SSE-BACKEND-CLACK:CALL-SSE-APP.
;;;
;;; HTMX-REPLY:
;;;   status (integer); headers: alist of (lowercase name . value) in response
;;;   order; (htmx-reply-header reply name) case-insensitive, NIL if absent;
;;;   body: a string (concatenated), or the octet vector when the app answered
;;;   with one (assets); (htmx-reply-fragment reply) → html-protocol PARSE of the
;;;   body (needs STACK-HTML:*HTML-BACKEND*); (htmx-reply-events reply) → for a
;;;   text/event-stream reply, a list of (event-type . data) read with
;;;   sse-protocol (COLLECT-SSE-EVENTS; keepalives skipped; an event without a
;;;   type is "message"), else NIL.
;;;
;;; rpc-protocol methods on HTMX-CLIENT:
;;;   BACKEND-RPC-CALL (client method params &key timeout id) → the body string
;;;     of a 2xx GET reply; BACKEND-RPC-NOTIFY → POST, T on 2xx;
;;;   BACKEND-RPC-CALL-STREAM → an rpc-stream whose RPC-RECV returns each
;;;     (event-type . data) pair, then :EOF.
;;;   A non-2xx reply signals: 404 → RPC-METHOD-NOT-FOUND, 422 →
;;;   RPC-INVALID-PARAMS, otherwise HTMX-ERROR with that status; each with
;;;   :data the HTMX-REPLY and :message the reply body.

(defclass htmx-client (rpc-protocol:rpc-transport)
  ((app :initarg :app :reader htmx-client-app)
   (codec :initarg :codec :reader htmx-client-codec))
  (:documentation "In-process browser stand-in for a Clack app."))

(defun make-htmx-client (app &key (codec nil codec-p) (prefix "/"))
  "Client for the Clack APP. CODEC defaults to (make-htmx-codec :prefix PREFIX);
pass the server transport's codec to share its prefix."
  (declare (ignore app codec codec-p prefix))
  (%htmx0-pending 'make-htmx-client))

(defclass htmx-reply ()
  ((status :initarg :status :reader htmx-reply-status)
   (headers :initarg :headers :initform nil :reader htmx-reply-headers)
   (body :initarg :body :initform "" :reader htmx-reply-body))
  (:documentation "One response, as the client saw it."))

(defun htmx-reply-header (reply name)
  (declare (ignore reply name))
  (%htmx0-pending 'htmx-reply-header))

(defun htmx-reply-fragment (reply)
  (declare (ignore reply))
  (%htmx0-pending 'htmx-reply-fragment))

(defun htmx-reply-events (reply)
  (declare (ignore reply))
  (%htmx0-pending 'htmx-reply-events))

(defun htmx-request-env (client env)
  (declare (ignore client env))
  (%htmx0-pending 'htmx-request-env))

(defun htmx-request (client method params &key (http-method :get) (encoding :urlencoded)
                                              (hx-request t) target trigger trigger-name
                                              current-url boosted accept headers)
  (declare (ignore client method params http-method encoding hx-request target trigger
                   trigger-name current-url boosted accept headers))
  (%htmx0-pending 'htmx-request))

(defun htmx-request-url (client url &rest keys &key &allow-other-keys)
  (declare (ignore client url keys))
  (%htmx0-pending 'htmx-request-url))

(defmethod rpc-protocol:backend-rpc-call ((client htmx-client) method params &key timeout id)
  (declare (ignore method params timeout id))
  (%htmx0-pending 'backend-rpc-call))

(defmethod rpc-protocol:backend-rpc-notify ((client htmx-client) method params)
  (declare (ignore method params))
  (%htmx0-pending 'backend-rpc-notify))

(defmethod rpc-protocol:backend-rpc-call-stream ((client htmx-client) method params
                                                 &key timeout id metadata)
  (declare (ignore method params timeout id metadata))
  (%htmx0-pending 'backend-rpc-call-stream))
