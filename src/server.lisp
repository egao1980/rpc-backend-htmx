(in-package #:rpc-backend-htmx)

;;; Server transport: a Clack app (http-server-protocol's app contract).
;;;
;;; (HTMX-APP transport handler &key stream-handler) → (lambda (env) → response)
;;;   HANDLER: an HTMX-HANDLERS table, a function (method params) → (values result
;;;   response-headers) as rpc-protocol's BACKEND-RPC-SERVE takes, or NIL.
;;;   STREAM-HANDLER: a function (mode method params stream), as
;;;   BACKEND-RPC-SERVE-STREAM takes, or NIL. The app calls
;;;   (HTMX-HANDLE-REQUEST transport handler stream-handler env).
;;;
;;; HTMX-HANDLE-REQUEST (default method), per request:
;;; 1. Decode ENV with the transport's codec. Any condition → step 5.
;;; 2. Pick the callee:
;;;    - table: FIND-HTMX-HANDLER on the method; absent → RPC-METHOD-NOT-FOUND
;;;      (404, nothing called). The entry's mode decides the response kind; a
;;;      :call-stream entry requested without Accept: text/event-stream →
;;;      HTMX-NOT-ACCEPTABLE (406). Accept is otherwise ignored.
;;;    - function: message mode :call-stream → STREAM-HANDLER (absent → 404),
;;;      else HANDLER (absent → 404). The function signals RPC-METHOD-NOT-FOUND
;;;      itself for methods it does not know.
;;; 3. Call it with *HTMX-REQUEST* bound to the message (calling convention:
;;;    handlers.lisp). A function handler is called (funcall handler method params).
;;; 4. Respond:
;;;    :call-response → 200, body from HTMX-RESULT-NODES of the result, passed
;;;      through HTMX-FULL-PAGE when the request is a GET without HX-Request;
;;;      second value = response metadata headers (ENCODE-RESPONSE-USING-CODEC).
;;;    :notify → 204, no body, the response metadata headers, no content-type.
;;;    :call-stream → text/event-stream through sse-backend-clack
;;;      (MAKE-SSE-STREAM-APP with a writer; its headers), the callee gets an
;;;      HTMX-EVENT-STREAM over the response stream; returning (or RPC-CLOSE)
;;;      ends the response. A condition after the stream opened → one event
;;;      named +STREAM-ERROR-EVENT+ whose data is the error fragment, then close.
;;;      The writer runs after HTMX-HANDLE-REQUEST returned (the server calls
;;;      the streaming function), so it re-establishes the request's dynamic
;;;      context itself: *HTMX-REQUEST*, the condition boundary (the error
;;;      fragment is the body of HTMX-ERROR-RESPONSE; nothing escapes the
;;;      writer), and any specials a transport's :around bound (canvas resolver).
;;;      The stream is open once the writer starts: a condition before the
;;;      first event is still 200 + that single error event.
;;; 5. A condition before a response started → (HTMX-ERROR-RESPONSE transport c).
;;;    Conditions never escape the app (ERROR only; warnings pass through).
;;;
;;; HTMX-RESULT-NODES (transport result) → fresh list of html-protocol nodes.
;;;   Default: NIL → NIL; html-node → (node); string → one html-text node;
;;;   list → each element's nodes, flattened in order; anything else → HTMX-ERROR.
;;;   rpc-backend-htmx/canvas adds canvas-protocol RENDER.
;;; HTMX-FULL-PAGE (transport nodes message) → nodes or an html-document.
;;;   Default: NODES unchanged (fragment). /canvas wraps in canvas PAGE.
;;; HTMX-CONDITION-STATUS (transport condition) → HTTP status:
;;;   HTMX-ERROR → its status; RPC-METHOD-NOT-FOUND 404; RPC-INVALID-PARAMS 422;
;;;   any other condition 500.
;;; HTMX-ERROR-RESPONSE (transport condition) → Clack response:
;;;   ENCODE-ERROR-RESPONSE-USING-CODEC with that status, the condition's report
;;;   (PRINC-TO-STRING) as the message, the transport's error target and swap.
;;;   HTMX-METHOD-NOT-ALLOWED adds :allow "GET, POST".
;;;
;;; HTMX-EVENT-STREAM: an rpc-stream (mode :call-stream) writing SSE to OUTPUT.
;;;   (rpc-send stream message): MESSAGE is (event-name . result) or a
;;;   STACK-SSE:SSE-EVENT (e.g. canvas-protocol FRAGMENT-EVENT). A pair becomes an
;;;   event of type EVENT-NAME whose data is the serialized HTMX-RESULT-NODES of
;;;   RESULT (the transport's; plain defaults when the stream has no transport).
;;;   Event names (a pair's or an sse-event's type) must match [A-Za-z0-9_.:-]+,
;;;   else HTMX-ERROR. Data: CR LF and lone CR become LF before
;;;   STACK-SSE:ENCODE-SSE-EVENT, so data cannot end a line early (sse-protocol's
;;;   encoder splits on LF only — https://github.com/egao1980/sse-protocol/issues/10).
;;;   Each event is written with STACK-SSE:WRITE-SSE-EVENT and flushed.
;;;   Sending on a closed stream is rpc-protocol's RPC-ERROR.
;;;   (HTMX-STREAM-KEEPALIVE stream) writes one sse-protocol keepalive
;;;   (STACK-SSE:WRITE-SSE-KEEPALIVE, comment style) and flushes; for long
;;;   handlers between events.
;;;
;;; rpc-protocol GFs:
;;;   BACKEND-RPC-SERVE (htmx-transport handler &key host port backend stream-handler)
;;;   → (HTTP-SERVER-PROTOCOL:SERVE (htmx-app …) :host :port :backend), the server.
;;;   BACKEND-RPC-SERVE-STREAM (htmx-transport handler &key host port backend)
;;;   → the same with HANDLER as the stream handler and no unary handler.
;;;   Defaults: host "127.0.0.1", port 8080, backend HTTP-SERVER-PROTOCOL:*HTTP-SERVER-BACKEND*.
;;;
;;; JSONRPC-HANDLER (transport handlers) → (lambda (method params) → string), for
;;;   any JSON-RPC server (rpc-backend-http MAKE-RPC-APP, …). Same table, same
;;;   functions, same fragments: the result is the exact body string the htmx
;;;   :call-response would send (a fragment; never a full page). PARAMS: NIL, an
;;;   empty vector or a JSON object (hash table, string keys); values strings or
;;;   integers (→ decimal); anything else → RPC-INVALID-PARAMS. Unknown method or
;;;   a :call-stream entry → RPC-METHOD-NOT-FOUND. A :notify entry → "".
;;;   *HTMX-REQUEST* is bound to a message with no metadata.

(defparameter +stream-error-event+ "canvas-error"
  "SSE event name for an error after a stream opened.")

(defvar *htmx-request* nil
  "The HTMX-MESSAGE being handled, bound while a handler runs.")

(defclass htmx-transport (rpc-protocol:rpc-transport)
  ((codec :initarg :codec :reader htmx-transport-codec)
   (error-target :initarg :error-target :initform +error-fragment-target+
                 :reader htmx-transport-error-target)
   (error-swap :initarg :error-swap :initform +error-fragment-swap+
               :reader htmx-transport-error-swap))
  (:documentation "htmx server transport: an HTMX-CODEC plus error-fragment placement."))

(defun make-htmx-transport (&key (prefix "/") (max-body-bytes +default-max-body-bytes+)
                              (error-target +error-fragment-target+)
                              (error-swap +error-fragment-swap+))
  (declare (ignore prefix max-body-bytes error-target error-swap))
  (%htmx0-pending 'make-htmx-transport))

(defun htmx-transport-prefix (transport)
  "The codec prefix."
  (declare (ignore transport))
  (%htmx0-pending 'htmx-transport-prefix))

(defgeneric htmx-handle-request (transport handler stream-handler env)
  (:documentation "Clack response for ENV. See the file header."))

(defgeneric htmx-result-nodes (transport result)
  (:documentation "RESULT → fresh list of html-protocol nodes."))

(defgeneric htmx-full-page (transport nodes message)
  (:documentation "NODES for a GET without HX-Request → nodes or an html-document."))

(defgeneric htmx-condition-status (transport condition)
  (:documentation "HTTP status for CONDITION."))

(defgeneric htmx-error-response (transport condition)
  (:documentation "Clack response for CONDITION (status + error fragment + HX headers)."))

(defun htmx-app (transport handler &key stream-handler)
  "Clack app serving HANDLER / STREAM-HANDLER through TRANSPORT."
  (declare (ignore transport handler stream-handler))
  (%htmx0-pending 'htmx-app))

(defmethod htmx-handle-request ((transport htmx-transport) handler stream-handler env)
  (declare (ignore handler stream-handler env))
  (%htmx0-pending 'htmx-handle-request))

(defmethod htmx-result-nodes ((transport t) result)
  (declare (ignore result))
  (%htmx0-pending 'htmx-result-nodes))

(defmethod htmx-full-page ((transport htmx-transport) nodes message)
  (declare (ignore message))
  nodes)

(defmethod htmx-condition-status ((transport htmx-transport) condition)
  (declare (ignore condition))
  (%htmx0-pending 'htmx-condition-status))

(defmethod htmx-error-response ((transport htmx-transport) condition)
  (declare (ignore condition))
  (%htmx0-pending 'htmx-error-response))

(defclass htmx-event-stream (rpc-protocol:rpc-stream)
  ((output :initarg :output :reader htmx-event-stream-output
           :documentation "Character output stream of the event-stream response.")
   (owner :initarg :owner :initform nil :reader htmx-event-stream-owner
          :documentation "The HTMX-TRANSPORT (for HTMX-RESULT-NODES), or NIL."))
  (:default-initargs :mode :call-stream :transport nil :method nil)
  (:documentation "Server side of a :call-stream: RPC-SEND writes one SSE event."))

(defun make-htmx-event-stream (output &key method transport)
  "An HTMX-EVENT-STREAM writing to the character stream OUTPUT."
  (declare (ignore output method transport))
  (%htmx0-pending 'make-htmx-event-stream))

(defmethod rpc-protocol:backend-rpc-send ((stream htmx-event-stream) message &key)
  (declare (ignore message))
  (%htmx0-pending 'backend-rpc-send))

(defun htmx-stream-keepalive (stream)
  "Write one sse-protocol keepalive on STREAM and flush."
  (declare (ignore stream))
  (%htmx0-pending 'htmx-stream-keepalive))

(defmethod rpc-protocol:backend-rpc-serve
    ((transport htmx-transport) handler &key (host "127.0.0.1") (port 8080)
                                          (backend http-server-protocol:*http-server-backend*)
                                          stream-handler)
  (declare (ignore handler host port backend stream-handler))
  (%htmx0-pending 'backend-rpc-serve))

(defmethod rpc-protocol:backend-rpc-serve-stream
    ((transport htmx-transport) handler &key (host "127.0.0.1") (port 8080)
                                          (backend http-server-protocol:*http-server-backend*))
  (declare (ignore handler host port backend))
  (%htmx0-pending 'backend-rpc-serve-stream))

(defun jsonrpc-handler (transport handlers)
  "JSON-RPC handler over the same HANDLERS table. See the file header."
  (declare (ignore transport handlers))
  (%htmx0-pending 'jsonrpc-handler))
