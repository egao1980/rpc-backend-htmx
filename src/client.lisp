(in-package #:rpc-backend-htmx)

;;; HTMX-CLIENT: calls a Clack app in process the way a browser running htmx
;;; would (tests, H4h-2 snapshots, agents checking fragments). It is also an
;;; rpc-protocol transport, so RPC-CALL / RPC-NOTIFY / RPC-CALL-STREAM work on it.
;;;
;;; (HTMX-REQUEST client method params &key http-method encoding hx-request
;;;               target trigger trigger-name current-url boosted accept headers)
;;;   Builds the env with ENCODE-REQUEST-USING-CODEC on the client's codec.
;;;   PARAMS as that method takes them: strings, integers, and (0.2.0) file
;;;   values (:filename F :content C :content-type T) or lists of them, which
;;;   need :HTTP-METHOD :POST :ENCODING :MULTIPART and are sent as raw binary
;;;   parts the way a browser sends a form with a file input (codec.lisp,
;;;   File values). Other combinations → HTMX-ERROR before the app is called.
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
;;;   Every request of the client goes through it (HTMX-REQUEST and
;;;   HTMX-REQUEST-URL build their env, then call it), so the cookie jar and
;;;   the client address below apply to all of them.
;;;
;;; Cookie jar and client address (0.5.0, #19 #15).
;;; (MAKE-HTMX-CLIENT app &key codec prefix cookies remote-addr)
;;;   COOKIES: NIL (default) — no jar: a Set-Cookie is not kept, and a request
;;;     carries only the Cookie header its caller sends (0.4.0; the token gate
;;;     tests send theirs by hand). T — the client keeps its own cookie jar, as
;;;     a browser does: every reply's Set-Cookie headers go in, every request
;;;     carries the cookies that apply, so a test walks a multi-request flow
;;;     (the gate's exchange, then a session across pages).
;;;   REMOTE-ADDR: NIL (default) — each env keeps the :REMOTE-ADDR it has
;;;     ("127.0.0.1" from the codec's env builder; a hand-made env its own). A
;;;     non-empty string — every env the client sends gets that :REMOTE-ADDR:
;;;     a browser at that address, or the proxy in front of the app (then
;;;     X-Forwarded-For goes in :HEADERS).
;;;   Anything else → TYPE-ERROR (CHECK-TYPE). Readers:
;;;   HTMX-CLIENT-REMOTE-ADDR → NIL or that string.
;;;   (HTMX-CLIENT-COOKIES client) → NIL without a jar; else a fresh alist
;;;     ((name . value) …) of the cookies the jar holds, in the order they were
;;;     last set, expired ones left out.
;;;   (HTMX-CLIENT-COOKIE client name) → the value of the jar's cookie NAME
;;;     (STRING=), or NIL (no jar, no such cookie).
;;; With a jar or a REMOTE-ADDR, HTMX-REQUEST-ENV wraps the call of the app:
;;;   1. Out. The jar's cookies for the request — (CL-COOKIE:COOKIE-JAR-HOST-COOKIES
;;;      jar host path :securep s), HOST the env's :SERVER-NAME ("localhost"
;;;      when absent), PATH its :PATH-INFO, S true when its :URL-SCHEME is
;;;      "https" (STRING-EQUAL), so a Secure cookie never goes over http — are
;;;      sent as one "cookie" header, (CL-COOKIE:WRITE-COOKIE-HEADER cookies):
;;;      "a=1; b=2", in jar order. None → no Cookie header from the jar. An
;;;      explicit Cookie header (HTMX-REQUEST :headers, or one in a hand-made
;;;      env's :HEADERS) replaces the jar's for that request. With REMOTE-ADDR
;;;      the env's :REMOTE-ADDR is that string. The caller's env and its
;;;      :HEADERS table are not modified: the client calls the app with a new
;;;      plist whose first keys are :HEADERS (a fresh table: the env's entries
;;;      plus the jar's "cookie") and :REMOTE-ADDR, followed by the env (GETF
;;;      finds the new keys first).
;;;   2. The app is called as before (CALL-SSE-APP: a streamed reply's head
;;;      counts like a list reply's headers).
;;;   3. In. Each "set-cookie" header of the reply, in order, is read with
;;;      (CL-COOKIE:PARSE-SET-COOKIE-HEADER value host path), HOST and PATH as
;;;      in 1, and merged into the jar (CL-COOKIE:MERGE-COOKIES: a cookie of
;;;      the same name, host or domain, and path replaces the one held). A
;;;      cookie whose Max-Age is 0 or less is removed at once (RFC 6265 §5.3
;;;      step 3: the earliest expiry; cl-cookie's EXPIRED-COOKIE-P keeps a
;;;      Max-Age=0 cookie for up to a second). Cookies expire by the real
;;;      clock (cl-cookie), never by a server's injected one: a test that
;;;      moves a session manager's clock past the idle TTL still sends the old
;;;      cookie, as a browser whose clock disagrees would. A Set-Cookie
;;;      cl-cookie cannot read signals cl-cookie's own error (the apps under
;;;      test never send one).
;;;   The jar is per client and not synchronized: one client is one browser,
;;;   driven by one thread. The stack has no cookie-jar protocol, so the jar is
;;;   cl-cookie's (the one dexador uses); session-protocol writes its
;;;   Set-Cookie with cl-cookie too.
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
   (codec :initarg :codec :reader htmx-client-codec)
   (jar :initarg :jar :initform nil :reader %client-jar
        :documentation "NIL or this client's CL-COOKIE:COOKIE-JAR (0.5.0).")
   (remote-addr :initarg :remote-addr :initform nil :reader htmx-client-remote-addr
                :documentation "NIL or the :REMOTE-ADDR of every env this client sends (0.5.0)."))
  (:documentation "In-process browser stand-in for a Clack app."))

(defun %remote-addr-p (object)
  "True for a non-empty string."
  (and (stringp object) (plusp (length object))))

(defun make-htmx-client (app &key (codec nil codec-p) (prefix "/") cookies remote-addr)
  "Client for the Clack APP. CODEC defaults to (make-htmx-codec :prefix PREFIX);
pass the server transport's codec to share its prefix. COOKIES T keeps a cookie
jar; REMOTE-ADDR a string sets every env's :REMOTE-ADDR (file header)."
  (check-type app function)
  (check-type cookies boolean)
  (check-type remote-addr (or null (satisfies %remote-addr-p)) "NIL or a non-empty string")
  (make-instance 'htmx-client
                 :app app
                 :codec (if (and codec-p codec) codec (make-htmx-codec :prefix prefix))
                 :jar (and cookies (cl-cookie:make-cookie-jar))
                 :remote-addr remote-addr))

(defun htmx-client-cookies (client)
  "NIL without a jar, else a fresh alist of the cookies CLIENT's jar holds (file
header, Cookie jar)."
  (if (%client-jar client)
      (%s1-pending "HTMX-CLIENT-COOKIES (the cookie jar)")
      nil))

(defun htmx-client-cookie (client name)
  "The value of CLIENT's jar cookie NAME, or NIL (file header, Cookie jar)."
  (if (%client-jar client)
      (%s1-pending "HTMX-CLIENT-COOKIE (the cookie jar)")
      (progn (check-type name string) nil)))

(defun %client-env (client env)
  "ENV as CLIENT sends it: the jar's Cookie and the client's :REMOTE-ADDR in
front (file header, Cookie jar, step 1); ENV itself without a jar and an address."
  ;; S1 contract stub: a 0.4.0 client (no jar, no address) is unchanged.
  (if (or (%client-jar client) (htmx-client-remote-addr client))
      (%s1-pending "the cookie jar and :REMOTE-ADDR of HTMX-CLIENT")
      env))

(defun %keep-cookies (client env headers)
  "Merge the Set-Cookie entries of the reply HEADERS (a Clack plist) into
CLIENT's jar, ENV the request's (file header, Cookie jar, step 3)."
  (declare (ignore env headers))
  ;; S1 contract stub: nothing to keep without a jar.
  (when (%client-jar client)
    (%s1-pending "the cookie jar of HTMX-CLIENT")))

(defclass htmx-reply ()
  ((status :initarg :status :reader htmx-reply-status)
   (headers :initarg :headers :initform nil :reader htmx-reply-headers)
   (body :initarg :body :initform "" :reader htmx-reply-body))
  (:documentation "One response, as the client saw it."))

(defun htmx-reply-header (reply name)
  (cdr (assoc name (htmx-reply-headers reply) :test #'string-equal)))

(defun htmx-reply-fragment (reply)
  (let ((body (htmx-reply-body reply)))
    (stack-html:parse (if (stringp body) body (%utf8-string body)))))

(defun %event-stream-reply-p (reply)
  (let ((content-type (htmx-reply-header reply "content-type")))
    (and (stringp content-type)
         (search "text/event-stream" content-type :test #'char-equal)
         (stringp (htmx-reply-body reply)))))

(defun htmx-reply-events (reply)
  (when (%event-stream-reply-p reply)
    (mapcar (lambda (event)
              (cons (or (stack-sse:sse-event-type event) "message")
                    (stack-sse:sse-event-data event)))
            (stack-sse:collect-sse-events (make-string-input-stream (htmx-reply-body reply))))))

(defun %header-alist (plist)
  (loop for (name value) on plist by #'cddr
        collect (cons (string-downcase (string name)) value)))

(defun htmx-request-env (client env)
  (let ((sent (%client-env client env)))
    (destructuring-bind (status headers body)
        (sse-backend-clack:call-sse-app (htmx-client-app client) sent)
      (%keep-cookies client sent headers)
      (make-instance 'htmx-reply :status status
                                 :headers (%header-alist headers)
                                 :body (or body "")))))

(defun %client-metadata (hx-request target trigger trigger-name current-url boosted)
  (append (when hx-request (list :request t))
          (when target (list :target target))
          (when trigger (list :trigger trigger))
          (when trigger-name (list :trigger-name trigger-name))
          (when current-url (list :current-url current-url))
          (when boosted (list :boosted t))))

(defun htmx-request (client method params &key (http-method :get) (encoding :urlencoded)
                                              (hx-request t) target trigger trigger-name
                                              current-url boosted accept headers)
  (htmx-request-env
   client
   (rpc-protocol:encode-request-using-codec
    (htmx-client-codec client) method params
    :http-method http-method
    :encoding encoding
    :metadata (%client-metadata hx-request target trigger trigger-name current-url boosted)
    :headers (append (when accept (list (cons "accept" accept))) headers))))

(defun htmx-request-url (client url &rest keys &key &allow-other-keys)
  (destructuring-bind (&key (http-method :get) (hx-request t) target trigger trigger-name
                         current-url boosted accept headers &allow-other-keys)
      keys
    (%request-url client url http-method hx-request target trigger trigger-name
                  current-url boosted accept headers)))

(defun %request-url (client url http-method hx-request target trigger trigger-name
                     current-url boosted accept headers)
  ;; The path is percent-decoded the way Clack hands :PATH-INFO to an app.
  ;; quri:url-decode also maps + to a space; canvas path-resolver
  ;; percent-encodes everything outside the unreserved set, so a resolver URL
  ;; never carries a literal + in its path.
  (let* ((uri (quri:uri url))
         (raw-path (or (quri:uri-path uri) "/"))
         (query (quri:uri-query uri))
         (codec (htmx-client-codec client))
         (path-info (handler-case (%latin1-to-utf8 (quri:url-decode raw-path :encoding :latin-1))
                      (quri:uri-error ()
                        (error 'htmx-bad-request :message "Malformed URL path"))
                      (stack-encoding:encoding-error ()
                        (error 'htmx-bad-request :message "Invalid UTF-8 in URL path")))))
    (htmx-request-env
     client
     (%encode-env codec http-method path-info query nil nil
                  (%client-metadata hx-request target trigger trigger-name current-url boosted)
                  (append (when accept (list (cons "accept" accept))) headers)
                  :request-uri (if query (concatenate 'string raw-path "?" query) raw-path)))))

(defun %check-reply (reply)
  "REPLY when 2xx; else signal the matching rpc-protocol condition."
  (let ((status (htmx-reply-status reply))
        (body (htmx-reply-body reply)))
    (unless (<= 200 status 299)
      (let ((message (if (stringp body) body "")))
        (case status
          (404 (error 'rpc-protocol:rpc-method-not-found :data reply :message message))
          (422 (error 'rpc-protocol:rpc-invalid-params :data reply :message message))
          (t (error 'htmx-error :status status :data reply :message message)))))
    reply))

(defmethod rpc-protocol:backend-rpc-call ((client htmx-client) method params &key timeout id)
  (declare (ignore timeout id))
  (let ((body (htmx-reply-body (%check-reply (htmx-request client method params)))))
    (if (stringp body) body (%utf8-string body))))

(defmethod rpc-protocol:backend-rpc-notify ((client htmx-client) method params)
  (%check-reply (htmx-request client method params :http-method :post))
  t)

(defclass %reply-stream (rpc-protocol:rpc-stream)
  ((events :initarg :events :initform nil :accessor %reply-stream-events))
  (:default-initargs :mode :call-stream)
  (:documentation "Client side of a :call-stream: the reply's events, then :EOF."))

(defmethod rpc-protocol:backend-rpc-recv ((stream %reply-stream) &key timeout)
  (declare (ignore timeout))
  (if (%reply-stream-events stream)
      (pop (%reply-stream-events stream))
      :eof))

(defmethod rpc-protocol:backend-rpc-call-stream ((client htmx-client) method params
                                                 &key timeout id metadata)
  (declare (ignore timeout id))
  (let ((reply (%check-reply
                (htmx-request client method params
                              :accept "text/event-stream"
                              :hx-request (getf metadata :request t)
                              :target (getf metadata :target)
                              :trigger (getf metadata :trigger)
                              :trigger-name (getf metadata :trigger-name)
                              :current-url (getf metadata :current-url)
                              :boosted (getf metadata :boosted)))))
    (make-instance '%reply-stream :transport client
                                  :method (%method-string method)
                                  :events (htmx-reply-events reply))))
