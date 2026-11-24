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
;;;   File params (0.2.0) have no JSON-RPC form: JSON-RPC handlers never see a
;;;   MIME-ENTITY. A value that is not a string or an integer (an object such
;;;   as {"filename": …, "content": …}, an array, a number with a fraction,
;;;   true, false, null) → RPC-INVALID-PARAMS whose message is exactly
;;;     Param <name> must be a string or an integer; JSON-RPC carries no file params
;;;   (<name> the JSON key as sent). A string stays a string, so a handler's
;;;   COERCE-PARAM :file refuses it ("<field> must be a file"). Uploads go
;;;   through the htmx multipart route.

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
  (make-instance 'htmx-transport
                 :codec (make-htmx-codec :prefix prefix :max-body-bytes max-body-bytes)
                 :error-target error-target
                 :error-swap error-swap))

(defun htmx-transport-prefix (transport)
  "The codec prefix."
  (htmx-codec-prefix (htmx-transport-codec transport)))

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
  (check-type transport htmx-transport)
  (check-type handler (or htmx-handlers function null))
  (check-type stream-handler (or function null))
  (lambda (env)
    (htmx-handle-request transport handler stream-handler env)))

;;; ---------------------------------------------------------------------------
;;; Condition boundaries
;;;
;;; The app's contract is that no ERROR escapes it. That overrides the usual
;;; "no catch-all ERROR in library code" rule at exactly two sites: the request
;;; boundary (%WITH-ERROR-RESPONSE) and the stream boundary (%STREAM-BOUNDARY,
;;; inside the streaming writer, which runs after HTMX-HANDLE-REQUEST returned).
;;; Inner handlers win: a handler's own HANDLER-BIND / restarts (canvas
;;; COERCE-FORM's USE-VALUE) and the codec's translations run first. Warnings
;;; pass through.
;;; ---------------------------------------------------------------------------

(defparameter +fallback-error-fragment+ (%error-fragment "Internal server error")
  "Serialized once at load time, so the fallback cannot fail.")

(defun %fallback-error-response (transport)
  "500 response built without calling any extension method: the last resort when
HTMX-ERROR-RESPONSE itself fails."
  (list 500
        (list :content-type "text/html; charset=utf-8"
              :hx-retarget (htmx-transport-error-target transport)
              :hx-reswap (htmx-transport-error-swap transport))
        (list +fallback-error-fragment+)))

(defun %safe-error-response (transport condition)
  "(HTMX-ERROR-RESPONSE transport condition), or the fallback 500 when that signals.
Called from inside a HANDLER-BIND handler, where only outer handlers are active
(CLHS 9.1.4.1), so the error response needs its own guard."
  (handler-case (htmx-error-response transport condition)
    (error () (%fallback-error-response transport))))

(defmacro %with-error-response ((transport) &body body)
  "Run BODY; an ERROR not handled inside it becomes (HTMX-ERROR-RESPONSE transport c).
HANDLER-BIND, so the error response is built in the signaller's dynamic
environment (*HTMX-REQUEST*, a transport's specials), then unwinds."
  (let ((boundary (gensym "BOUNDARY")) (tx (gensym "TRANSPORT")))
    `(let ((,tx ,transport))
       (block ,boundary
         (handler-bind ((error (lambda (c)
                                 (return-from ,boundary (%safe-error-response ,tx c)))))
           ,@body)))))

;;; ---------------------------------------------------------------------------
;;; Request flow
;;; ---------------------------------------------------------------------------

(defun %resolve-callee (handler stream-handler message)
  "→ (values thunk mode). THUNK takes no argument (:call-response, :notify) or
the event stream (:call-stream) and applies the callee's calling convention."
  (let ((name (htmx-message-method message))
        (params (htmx-message-params message))
        (streamp (eq (htmx-message-mode message) :call-stream)))
    (etypecase handler
      (htmx-handlers
       (multiple-value-bind (fn mode) (find-htmx-handler handler name)
         (cond ((null fn) (%method-not-found name))
               ((and (eq mode :call-stream) (not streamp))
                (error 'htmx-not-acceptable))
               ((eq mode :call-stream)
                (values (lambda (stream) (apply fn stream :allow-other-keys t params))
                        mode))
               (t
                (values (lambda () (apply fn :allow-other-keys t params)) mode)))))
      ((or function null)
       (let ((fn (if streamp stream-handler handler)))
         (unless fn (%method-not-found name))
         (if streamp
             (values (lambda (stream) (funcall fn :call-stream name params stream))
                     :call-stream)
             (values (lambda () (funcall fn name params)) :call-response)))))))

(defun %plain-get-p (message)
  "A GET without HX-Request: the browser wants a page."
  (and (eq (htmx-message-http-method message) :get)
       (not (getf (htmx-message-metadata message) :request))))

(defun %respond-call (transport thunk message)
  (let ((*htmx-request* message))
    (multiple-value-bind (result headers) (funcall thunk)
      (let ((nodes (htmx-result-nodes transport result)))
        (rpc-protocol:encode-response-using-codec
         (htmx-transport-codec transport)
         (if (%plain-get-p message) (htmx-full-page transport nodes message) nodes)
         :headers headers)))))

(defun %respond-notify (transport thunk message)
  (declare (ignore transport))
  (let ((*htmx-request* message))
    (multiple-value-bind (result headers) (funcall thunk)
      (declare (ignore result))
      (list 204 (%hx-header-plist headers) '()))))

;;; A separate, NOTINLINE function on purpose: ECL 26.5.5 miscompiles
;;; (let ((c (block b (handler-bind ((error (lambda (x) (return-from b x)))) …))))
;;;   (when c …))
;;; — after the non-local exit C is bound to the condition, but the WHEN test
;;; takes the NIL branch, so the error event was never written. Returning the
;;; condition from its own function avoids it.
(declaim (notinline %run-capturing-error))
(defun %run-capturing-error (thunk stream)
  "Call THUNK on STREAM. → the ERROR it did not handle (unwound), or NIL."
  (block run
    (handler-bind ((error (lambda (c) (return-from run c))))
      (funcall thunk stream)
      nil)))

(defun %stream-boundary (transport stream thunk)
  "Run THUNK on STREAM. An ERROR it does not handle becomes one
+STREAM-ERROR-EVENT+ event carrying HTMX-ERROR-RESPONSE's fragment (the second
contract boundary; the response is already open)."
  (let ((condition (%run-capturing-error thunk stream)))
    (when (and condition (not (rpc-protocol:rpc-stream-closed-p stream)))
      (handler-case
          (rpc-protocol:rpc-send
           stream
           (stack-sse:make-sse-event
            :event +stream-error-event+
            :data (format nil "~{~A~}" (third (%safe-error-response transport condition)))))
        ;; The peer may be gone: nothing escapes the writer.
        (error () nil)))))

(defun %respond-stream (transport thunk message env)
  "text/event-stream response through sse-backend-clack. The writer runs later,
under the server (or CALL-SSE-APP), so it re-binds *HTMX-REQUEST* and has its
own condition boundary."
  (funcall (sse-backend-clack:make-sse-stream-app
            (lambda (env)
              (declare (ignore env))
              (lambda (out)
                (let* ((*htmx-request* message)
                       (stream (make-htmx-event-stream out :method (htmx-message-method message)
                                                           :transport transport)))
                  (%stream-boundary transport stream thunk)
                  (rpc-protocol:rpc-close stream)))))
           env))

(defmethod htmx-handle-request ((transport htmx-transport) handler stream-handler env)
  (%with-error-response (transport)
    (let ((message (rpc-protocol:decode-message-using-codec
                    (htmx-transport-codec transport) env)))
      (multiple-value-bind (thunk mode) (%resolve-callee handler stream-handler message)
        (ecase mode
          (:call-response (%respond-call transport thunk message))
          (:notify (%respond-notify transport thunk message))
          (:call-stream (%respond-stream transport thunk message env)))))))

(defmethod htmx-result-nodes ((transport t) result)
  (%plain-nodes result))

(defmethod htmx-full-page ((transport htmx-transport) nodes message)
  (declare (ignore message))
  nodes)

(defmethod htmx-condition-status ((transport htmx-transport) condition)
  (declare (ignore condition))
  500)

(defmethod htmx-condition-status ((transport htmx-transport) (condition htmx-error))
  (htmx-error-status condition))

(defmethod htmx-condition-status ((transport htmx-transport)
                                  (condition rpc-protocol:rpc-method-not-found))
  404)

(defmethod htmx-condition-status ((transport htmx-transport)
                                  (condition rpc-protocol:rpc-invalid-params))
  422)

(defmethod htmx-error-response ((transport htmx-transport) condition)
  (rpc-protocol:encode-error-response-using-codec
   (htmx-transport-codec transport)
   (htmx-condition-status transport condition)
   (princ-to-string condition)
   :target (htmx-transport-error-target transport)
   :swap (htmx-transport-error-swap transport)))

(defmethod htmx-error-response ((transport htmx-transport) (condition htmx-method-not-allowed))
  (destructuring-bind (status headers body) (call-next-method)
    (list status (append headers (list :allow "GET, POST")) body)))

;;; ---------------------------------------------------------------------------
;;; Event stream
;;; ---------------------------------------------------------------------------

(defclass htmx-event-stream (rpc-protocol:rpc-stream)
  ((output :initarg :output :reader htmx-event-stream-output
           :documentation "Character output stream of the event-stream response.")
   (owner :initarg :owner :initform nil :reader htmx-event-stream-owner
          :documentation "The HTMX-TRANSPORT (for HTMX-RESULT-NODES), or NIL."))
  (:default-initargs :mode :call-stream :transport nil :method nil)
  (:documentation "Server side of a :call-stream: RPC-SEND writes one SSE event."))

(defun make-htmx-event-stream (output &key method transport)
  "An HTMX-EVENT-STREAM writing to the character stream OUTPUT."
  (make-instance 'htmx-event-stream :output output :owner transport
                                    :transport transport :method method))

(defun %event-name-char-p (char)
  (or (char<= #\a char #\z) (char<= #\A char #\Z) (char<= #\0 char #\9)
      (member char '(#\_ #\. #\: #\-))))

(defun %event-name (name)
  "NAME when it matches [A-Za-z0-9_.:-]+, else HTMX-ERROR."
  (unless (and (stringp name) (plusp (length name)) (every #'%event-name-char-p name))
    (error 'htmx-error :message (format nil "Refused SSE event name ~S" name)))
  name)

(defun %lf (string)
  "CR LF and lone CR → LF, so data cannot end an SSE line early
(sse-protocol's encoder splits on LF only: sse-protocol#10)."
  (if (not (find #\Return string))
      string
      (with-output-to-string (out)
        (loop with n = (length string)
              for i from 0 below n
              for char = (char string i)
              do (cond ((char/= char #\Return) (write-char char out))
                       (t (write-char #\Linefeed out)
                          (when (and (< (1+ i) n) (char= (char string (1+ i)) #\Linefeed))
                            (incf i))))))))

(defun %no-newline (value)
  (when (and value (find-if (lambda (c) (member c '(#\Return #\Linefeed))) (princ-to-string value)))
    (error 'htmx-error :message (format nil "Refused SSE field ~S" value)))
  value)

(defmethod rpc-protocol:backend-rpc-send ((stream htmx-event-stream) message &key)
  (let ((event
          (etypecase message
            (stack-sse:sse-event
             ;; A copy: the caller's event is never mutated.
             (let ((type (stack-sse:sse-event-type message))
                   (comment (stack-sse:sse-event-comment message)))
               (stack-sse:make-sse-event
                :event (and type (%event-name type))
                :data (%lf (or (stack-sse:sse-event-data message) ""))
                :id (%no-newline (stack-sse:sse-event-id message))
                :retry (%no-newline (stack-sse:sse-event-retry message))
                :comment (and comment (%lf comment)))))
            (cons
             (stack-sse:make-sse-event
              :event (%event-name (car message))
              :data (%lf (%html-string
                          (htmx-result-nodes (htmx-event-stream-owner stream)
                                             (cdr message)))))))))
    (stack-sse:write-sse-event (htmx-event-stream-output stream) event :flush t)
    message))

(defun htmx-stream-keepalive (stream)
  "Write one sse-protocol keepalive on STREAM and flush."
  (stack-sse:write-sse-keepalive (htmx-event-stream-output stream) :style :comment :flush t)
  stream)

;;; ---------------------------------------------------------------------------
;;; Serve, JSON-RPC parity
;;; ---------------------------------------------------------------------------

(defmethod rpc-protocol:backend-rpc-serve
    ((transport htmx-transport) handler &key (host "127.0.0.1") (port 8080)
                                          (backend http-server-protocol:*http-server-backend*)
                                          stream-handler)
  (http-server-protocol:serve (htmx-app transport handler :stream-handler stream-handler)
                              :host host :port port :backend backend))

(defmethod rpc-protocol:backend-rpc-serve-stream
    ((transport htmx-transport) handler &key (host "127.0.0.1") (port 8080)
                                          (backend http-server-protocol:*http-server-backend*))
  (http-server-protocol:serve (htmx-app transport nil :stream-handler handler)
                              :host host :port port :backend backend))

(defun %json-param-value (key value)
  "One JSON-RPC param VALUE under the JSON KEY → string; file params have no
JSON-RPC form (file header)."
  (typecase value
    (string value)
    (integer (format nil "~D" value))
    (t (error 'rpc-protocol:rpc-invalid-params
              :message (format nil "Param ~A must be a string or an integer; JSON-RPC carries no file params"
                               key)))))

(defun %json-params-plist (params)
  "JSON-RPC PARAMS (NIL, an empty vector or an object) → keyword plist, keys sorted."
  (cond ((null params) '())
        ((and (vectorp params) (not (stringp params)) (zerop (length params))) '())
        ((hash-table-p params)
         (let ((keys '()))
           (maphash (lambda (k v) (declare (ignore v)) (push k keys)) params)
           (unless (every #'stringp keys)
             (error 'rpc-protocol:rpc-invalid-params :message "Param names must be strings"))
           ;; Sorted: hash-table order never reaches the handler.
           (loop for key in (sort keys #'string<)
                 unless (zerop (length key))
                   collect (intern (string-upcase key) :keyword)
                   and collect (%json-param-value key (gethash key params)))))
        (t (error 'rpc-protocol:rpc-invalid-params
                  :message "Params must be an object of strings or integers"))))

(defun jsonrpc-handler (transport handlers)
  "JSON-RPC handler over the same HANDLERS table. See the file header."
  (check-type transport htmx-transport)
  (check-type handlers htmx-handlers)
  (lambda (method params)
    (let ((plist (%json-params-plist params)))
      (multiple-value-bind (fn mode) (find-htmx-handler handlers method)
        (when (or (null fn) (eq mode :call-stream))
          (%method-not-found method))
        (let ((*htmx-request* (make-instance 'htmx-message :method method :params plist
                                                           :mode :call-response
                                                           :http-method :post)))
          (multiple-value-bind (result headers) (apply fn :allow-other-keys t plist)
            (if (eq mode :notify)
                ""
                (format nil "~{~A~}"
                        (third (rpc-protocol:encode-response-using-codec
                                (htmx-transport-codec transport)
                                (htmx-result-nodes transport result)
                                :headers headers))))))))))
