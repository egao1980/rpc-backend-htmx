(in-package #:rpc-backend-htmx)

;;; Server transport: a Clack app (http-server-protocol's app contract).
;;;
;;; (HTMX-APP transport handler &key stream-handler csp token token-name)
;;;   → (lambda (env) → response)
;;;   HANDLER: an HTMX-HANDLERS table, a function (method params) → (values result
;;;   response-headers) as rpc-protocol's BACKEND-RPC-SERVE takes, or NIL.
;;;   STREAM-HANDLER: a function (mode method params stream), as
;;;   BACKEND-RPC-SERVE-STREAM takes, or NIL.
;;;   CSP, TOKEN, TOKEN-NAME (0.3.0, #4): when supplied (NIL included) they
;;;   replace the transport's (HTMX-TRANSPORT-CSP …) for this app, validated as
;;;   MAKE-HTMX-TRANSPORT validates them (TYPE-ERROR when HTMX-APP is called).
;;;   Per request the app (1) runs the token gate when a token is in force
;;;   (Token gate, below); (2) calls (HTMX-HANDLE-REQUEST transport handler
;;;   stream-handler env) when the gate lets the request through; (3) adds the
;;;   CSP header to whatever (1) or (2) answered (Content-Security-Policy,
;;;   below). HTMX-HANDLE-REQUEST called directly does neither: both belong to
;;;   the app, so they cover the canvas asset route and the canvas :around too.
;;;   With no token and no CSP in force, (1) and (3) change nothing: the app
;;;   answers what HTMX-HANDLE-REQUEST answers, as in 0.2.1.
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
;;;    handlers.lisp). A table entry first takes the entry's key set (deriving
;;;    it again when a symbol was redefined) and accepts the request against it
;;;    (handlers.lisp, Accepting a request): refused → HTMX-UNKNOWN-PARAM, 400,
;;;    nothing called (for a :call-stream entry: before any stream opens, so a
;;;    plain 400 error response, not an SSE reply). 0.3.0 calls (apply fn
;;;    params), never with :allow-other-keys (#3).
;;;    A function handler is called (funcall handler method params): PARAMS as
;;;    decoded, unmapped names left out (they are on the message).
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
;;;   HTMX-ERROR → its status (0.3.0: HTMX-UNKNOWN-PARAM 400, HTMX-FORBIDDEN 403,
;;;   HTMX-TOO-MANY-PARAMS 413); RPC-METHOD-NOT-FOUND 404; RPC-INVALID-PARAMS
;;;   422; any other condition 500.
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
;;;   Both serve the transport's CSP and token (they call HTMX-APP without overrides).
;;;
;;; MAKE-HTMX-TRANSPORT &key prefix max-body-bytes max-params error-target
;;;   error-swap csp token token-name. MAX-PARAMS (0.3.0) goes to the codec
;;;   (codec.lisp, Params). CSP, TOKEN, TOKEN-NAME below; readers
;;;   HTMX-TRANSPORT-CSP, HTMX-TRANSPORT-TOKEN, HTMX-TRANSPORT-TOKEN-NAME.
;;;
;;; Content-Security-Policy (0.3.0, rpc-backend-htmx#4). CSP is:
;;;   NIL (the default of MAKE-HTMX-TRANSPORT) — no header: the core serves
;;;     arbitrary handler HTML, so its policy is opt-in, and every response
;;;     stays byte-identical to 0.2.1, headers included.
;;;   T — +DEFAULT-CSP+, the canvas brief's policy (cl-stack
;;;     docs/capabilities/canvas.md § H4h-2), exactly:
;;;       default-src 'self'; script-src 'self'; style-src 'self'; img-src 'self' data:; connect-src 'self'; frame-ancestors 'none'
;;;   a non-empty string holding no control character (code below 32, or 127)
;;;     — sent as given.
;;;   Anything else → TYPE-ERROR (CHECK-TYPE). HTMX-TRANSPORT-CSP → NIL or the
;;;   policy string (T already resolved). rpc-backend-htmx/canvas defaults it
;;;   to T (canvas.lisp, Security).
;;; With a policy in force the app adds (:content-security-policy POLICY) as
;;; the LAST header of every response it returns, whatever produced it:
;;; fragments, full pages, 204s, every error status (400 403 404 405 406 413
;;; 415 422 500, the fallback 500), the gate's 303 and 403, asset responses
;;; (octet bodies), and streams. A Clack streaming response (a function of a
;;; responder) is wrapped so the (status headers) it hands its responder gets
;;; the header the same way; the events are untouched. Exactly one such header
;;; per response; bodies are never changed.
;;;
;;; Token gate (0.3.0, #4). Two secrets, never the same value:
;;;   the BOOTSTRAP token — TOKEN, the caller's; it travels in the one-time URL,
;;;     and URLs leak (browser history, Referer, proxy and server logs,
;;;     terminal scrollback), so it is good for exactly one exchange;
;;;   the SESSION secret — the app's own, the only value the cookie ever
;;;     carries. Never in a URL, never derived from TOKEN.
;;; TOKEN is:
;;;   NIL (default) — no gate (0.2.1).
;;;   a string, or an HTTP-PROTOCOL:SECRET wrapping one, of 32 to 512
;;;     characters from [A-Za-z0-9_-] (base64url or hex: safe unencoded in a
;;;     URL). The caller makes it from a CSPRNG, once per run (e.g.
;;;     SECRETS-PROTOCOL:TOKEN-URLSAFE 32). Kept as an HTTP-PROTOCOL:SECRET
;;;     (prints redacted); HTMX-TRANSPORT-TOKEN returns that SECRET.
;;;   Anything else → TYPE-ERROR.
;;; The session secret: (SECRETS-PROTOCOL:TOKEN-URLSAFE 32) — 32 octets (256
;;;   bits) from the stack's CSPRNG, base64url without padding (43
;;;   characters) — made by HTMX-APP for each app it builds while a token is in
;;;   force, so a missing secrets backend fails there (SECRETS-PROTOCOL:
;;;   SECRETS-ERROR; loading crypto-backend-ironclad installs one), never at a
;;;   login. Kept as an HTTP-PROTOCOL:SECRET inside the app; sent only in the
;;;   exchange's Set-Cookie. rpc-backend-htmx depends on secrets-protocol, not
;;;   on a backend: the application picks it, as for every stack protocol.
;;; TOKEN-NAME (default +DEFAULT-TOKEN-NAME+, "canvas-token") — the cookie's
;;;   name and the one-time URL's query field: a non-empty string of
;;;   [A-Za-z0-9_-], else TYPE-ERROR. Cookies are not isolated by port (RFC
;;;   6265 §8.5): two gated apps on one host (two runs on 127.0.0.1) need
;;;   distinct names, or the second login replaces the first run's cookie.
;;; (HTMX-TOKEN-URL url token &key (token-name +default-token-name+)) → URL plus
;;;   the field "<token-name>=<token>" ("?" first when URL has no "?", else
;;;   "&"): the one-time URL to open in a browser. URL a string without "#";
;;;   TOKEN and TOKEN-NAME as above; else TYPE-ERROR.
;;; With a token in force every request the app gets is gated FIRST: an
;;; unauthenticated request never has its body read, its params decoded, a
;;; handler or an asset served (403, not 404 / 405 / 413). Reading the request:
;;;   query fields — ENV :QUERY-STRING split raw by quri
;;;     (URL-DECODE-PARAMS :lenient t :percent-decode nil);
;;;   cookies — the "cookie" request header split the same way with
;;;     :delimiter #\;, names trimmed of spaces and tabs;
;;;   values compared raw (no percent-decoding) and in constant time: one
;;;     internal function, %TOKEN= (presented secret), which is
;;;     SECRETS-PROTOCOL:CONSTANT-TIME-EQUAL on the UTF-8 octets of both.
;;;   The cookie is VALID when some cookie named TOKEN-NAME has the SESSION
;;;   secret as its value. A cookie holding TOKEN is not valid.
;;; 1. The query has a field named TOKEN-NAME (exactly, raw) — the exchange:
;;;    a. exactly one such field, its value is TOKEN, and this app's bootstrap
;;;       token is unused → mark it used and answer 303, no body, with
;;;       headers, in this order:
;;;         :location L   :set-cookie C   :cache-control "no-store"
;;;       C is exactly
;;;         <TOKEN-NAME>=<SESSION>; Path=/; HttpOnly; SameSite=Strict
;;;       followed by "; Secure" when ENV :URL-SCHEME is "https" (any case), and
;;;       never otherwise: a loopback bind is plain http, where a Secure cookie
;;;       is not stored. No Domain (host-only), no Max-Age / Expires (a session
;;;       cookie; the secret dies with the run). Path=/ covers the method prefix
;;;       and the asset prefix alike. HttpOnly: no script reads it; SameSite=
;;;       Strict: no other site's page sends it (cross-site request forgery).
;;;    b. anything else → 403 (HTMX-FORBIDDEN): a used bootstrap token, a
;;;       wrong one, the session secret presented as one, the field twice —
;;;       even when the request also carries a valid cookie. A request that
;;;       fails here does not use the bootstrap token.
;;;    L, the clean URL, is the path of ENV :REQUEST-URI (all before "?") and,
;;;    when other fields remain, "?" and those fields raw, in order, each
;;;    "name=value" ("name" alone for a field without "="), joined by "&": the
;;;    token never stays in the address bar or reaches the handler. When that
;;;    path does not start with "/", starts with "//" or "/\", or holds a
;;;    control character or a space → 403 instead of a, so the redirect can
;;;    never leave the origin.
;;; 2. Otherwise: the cookie is valid → the request goes on (step 2 of HTMX-APP);
;;;    else → 403 (HTMX-FORBIDDEN).
;;; The 403 is (HTMX-ERROR-RESPONSE transport condition): the error fragment
;;; with status 403, so a browser shows it in the error target. It never
;;; echoes a value the request sent.
;;; State is per app: each HTMX-APP call has its own session secret and its
;;; own bootstrap use (one transport can back several apps, each with one
;;; exchange; a cookie from one app is not valid on another). The use is
;;; marked under a lock (bordeaux-threads): of concurrent valid exchanges
;;; exactly one gets 1a.
;;; Threat model: a leaked one-time URL is worthless once used (the exchange
;;; consumed it, and it was never the cookie); a leaked unused one gives one
;;; session, so open it at once. The session secret stays in the browser's
;;; HttpOnly cookie jar. JSONRPC-HANDLER is not gated: the JSON-RPC server it
;;; runs in authenticates its own clients.
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
;;;   Keys (0.3.0, #2 #3), in this order: (1) the PARAMS shape, as above;
;;;   (2) more members than the codec's MAX-PARAMS (the transport's) →
;;;   HTMX-TOO-MANY-PARAMS; (3) each member in sorted name order, empty names
;;;   dropped, its value checked as above; (4) the method: unknown or a
;;;   :call-stream entry → RPC-METHOD-NOT-FOUND; (5) names map to keywords as
;;;   the codec maps them (FIND-SYMBOL, never INTERN; unmapped names kept
;;;   apart) and the entry's key set accepts them (handlers.lisp, Accepting a
;;;   request): refused → HTMX-UNKNOWN-PARAM (code -32602, message
;;;   "Unknown param <name>"). The call is (apply fn plist), no
;;;   :allow-other-keys, so a canvas with no parameters answers over JSON-RPC
;;;   too. *HTMX-REQUEST*'s message has those params and unmapped names.

(defparameter +stream-error-event+ "canvas-error"
  "SSE event name for an error after a stream opened.")

(defvar *htmx-request* nil
  "The HTMX-MESSAGE being handled, bound while a handler runs.")

(defparameter +default-csp+
  "default-src 'self'; script-src 'self'; style-src 'self'; img-src 'self' data:; connect-src 'self'; frame-ancestors 'none'"
  "The canvas brief's Content-Security-Policy (cl-stack docs/capabilities/canvas.md
§ H4h-2), exactly: what :CSP T sends.")

(defparameter +default-token-name+ "canvas-token"
  "Default cookie name and one-time URL field of the token gate.")

(defclass htmx-transport (rpc-protocol:rpc-transport)
  ((codec :initarg :codec :reader htmx-transport-codec)
   (error-target :initarg :error-target :initform +error-fragment-target+
                 :reader htmx-transport-error-target)
   (error-swap :initarg :error-swap :initform +error-fragment-swap+
               :reader htmx-transport-error-swap)
   (csp :initarg :csp :initform nil :reader htmx-transport-csp
        :documentation "NIL or the Content-Security-Policy string (0.3.0, #4).")
   (token :initarg :token :initform nil :reader htmx-transport-token
          :documentation "NIL or the per-run token as an HTTP-PROTOCOL:SECRET (0.3.0, #4).")
   (token-name :initarg :token-name :initform +default-token-name+
               :reader htmx-transport-token-name
               :documentation "Cookie name and one-time URL field of the token gate."))
  (:documentation "htmx server transport: an HTMX-CODEC, error-fragment placement, and
the app's CSP and token gate. See the file header."))

;;; Option validation (0.3.0). Each returns the value to store or signals
;;; TYPE-ERROR (CHECK-TYPE, so STORE-VALUE is offered). File header,
;;; Content-Security-Policy and Token gate. The character classes are ASCII
;;; ranges on purpose: ALPHANUMERICP is true for "é".

(defun %token-char-p (char)
  "True for a character of [A-Za-z0-9_-]."
  (or (char<= #\a char #\z) (char<= #\A char #\Z) (char<= #\0 char #\9)
      (char= char #\_) (char= char #\-)))

(defun %policy-string-p (object)
  "True for a non-empty string holding no control character (code below 32, or 127)."
  (and (stringp object) (plusp (length object))
       (notany #'%file-control-char-p object)))

(defun %token-string-p (object)
  "True for a string, or an HTTP-PROTOCOL:SECRET wrapping one, of 32 to 512
characters of [A-Za-z0-9_-]."
  (let ((value (http-protocol:reveal object)))
    (and (stringp value) (<= 32 (length value) 512)
         (every #'%token-char-p value))))

(defun %token-name-p (object)
  "True for a non-empty string of [A-Za-z0-9_-]."
  (and (stringp object) (plusp (length object))
       (every #'%token-char-p object)))

(defun %url-without-fragment-p (object)
  "True for a string holding no #."
  (and (stringp object) (not (find #\# object))))

(defun %csp-option (csp)
  "CSP (NIL, T or a policy string) → NIL or the policy string; else TYPE-ERROR."
  (check-type csp (or null (eql t) (satisfies %policy-string-p))
              "NIL, T or a non-empty policy string with no control character")
  (if (eq csp t) +default-csp+ csp))

(defun %token-option (token)
  "TOKEN (NIL, a string or an HTTP-PROTOCOL:SECRET) → NIL or a SECRET; else TYPE-ERROR."
  ;; The datum of the TYPE-ERROR is what the caller passed: a SECRET prints redacted.
  (check-type token (or null (satisfies %token-string-p))
              "NIL, or a string or SECRET of 32 to 512 characters of [A-Za-z0-9_-]")
  (http-protocol:make-secret token))   ; NIL stays NIL, a SECRET comes back unchanged

(defun %token-name-option (token-name)
  "TOKEN-NAME → itself when it is a non-empty string of [A-Za-z0-9_-]; else TYPE-ERROR."
  (check-type token-name (satisfies %token-name-p) "a non-empty string of [A-Za-z0-9_-]")
  token-name)

(defun %transport-csp (csp)
  "0.3.0 contract: NIL and T need no validation; anything else goes to %CSP-OPTION."
  (cond ((null csp) nil)
        ((eq csp t) +default-csp+)
        (t (%csp-option csp))))

(defun make-htmx-transport (&key (prefix "/") (max-body-bytes +default-max-body-bytes+)
                              (max-params +default-max-params+)
                              (error-target +error-fragment-target+)
                              (error-swap +error-fragment-swap+)
                              csp token (token-name +default-token-name+))
  "An HTMX-TRANSPORT. See the file header (MAKE-HTMX-TRANSPORT)."
  (make-instance 'htmx-transport
                 :codec (make-htmx-codec :prefix prefix :max-body-bytes max-body-bytes
                                         :max-params max-params)
                 :error-target error-target
                 :error-swap error-swap
                 :csp (%transport-csp csp)
                 :token (and token (%token-option token))
                 :token-name (if (equal token-name +default-token-name+)
                                 token-name
                                 (%token-name-option token-name))))

(defun htmx-token-url (url token &key (token-name +default-token-name+))
  "URL with \"<token-name>=<token>\" appended: the one-time URL of the token gate.
See the file header (Token gate)."
  (check-type url (satisfies %url-without-fragment-p) "a URL string with no #")
  (check-type token (satisfies %token-string-p)
              "a string or SECRET of 32 to 512 characters of [A-Za-z0-9_-]")
  (check-type token-name (satisfies %token-name-p) "a non-empty string of [A-Za-z0-9_-]")
  (concatenate 'string url (if (find #\? url) "&" "?")
               token-name "=" (http-protocol:reveal token)))

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

;;; App wrapping (0.3.0). File header, HTMX-APP, Content-Security-Policy and
;;; Token gate. HTMX-APP composes three layers once, leaving out a layer that
;;; is off: CSP outermost (so the gate's 303 / 403 carry it too), then the
;;; gate, then HTMX-HANDLE-REQUEST. With neither in force the app is 0.2.1's
;;; closure itself.

(defstruct (%gate (:constructor %make-gate (session)) (:copier nil) (:predicate nil))
  ;; One app's token gate state (file header, Token gate: state is per app).
  (session nil :read-only t)            ; this app's session secret, an HTTP-PROTOCOL:SECRET
  (used nil)                            ; T once the bootstrap token was exchanged
  (lock (bt:make-lock "rpc-backend-htmx token gate") :read-only t))

(defun %token= (presented secret)
  "True when the string PRESENTED is SECRET (a string): SECRETS-PROTOCOL:
CONSTANT-TIME-EQUAL on their UTF-8 octets."
  (and (stringp presented)
       (stringp secret)
       (handler-case (secrets-protocol:constant-time-equal (%utf8-octets presented)
                                                           (%utf8-octets secret))
         ;; Translate only: a presented value that does not encode is not the
         ;; secret, so the request is refused (403), not failed (500).
         (stack-encoding:encoding-error () nil))))

(defun %raw-fields (string delimiter)
  "STRING split by quri into ((name . value) …), raw (no percent-decoding; a
field without = has the value NIL); () for NIL or \"\"."
  (if (and (stringp string) (plusp (length string)))
      (quri:url-decode-params string :delimiter delimiter :lenient t :percent-decode nil)
      '()))

(defun %location-path-p (path)
  "True for a path the exchange may redirect to: it starts with / but not with
// or /\\, and holds no space and no control character (file header, Token gate)."
  (and (plusp (length path))
       (char= #\/ (char path 0))
       (not (and (> (length path) 1) (find (char path 1) "/\\")))
       (notany (lambda (char) (or (char= char #\Space) (%file-control-char-p char))) path)))

(defun %clean-location (env token-name fields)
  "The exchange's Location: the path of ENV :REQUEST-URI and the query FIELDS
other than TOKEN-NAME, raw and in order. NIL when the path could leave the
origin, or (defence in depth for the Location header) when the URL would hold a
control character."
  (let* ((uri (getf env :request-uri))
         (path (if (stringp uri) (subseq uri 0 (or (position #\? uri) (length uri))) ""))
         (rest (loop for (name . value) in fields
                     unless (string= name token-name)
                       collect (if value (concatenate 'string name "=" value) name)))
         (location (format nil "~A~@[?~{~A~^&~}~]" path rest)))
    (and (%location-path-p path)
         (notany #'%file-control-char-p location)
         location)))

(defun %session-cookie (token-name gate env)
  "The exchange's Set-Cookie value: the session secret, host-only, for the run."
  (let ((scheme (getf env :url-scheme)))
    (format nil "~A=~A; Path=/; HttpOnly; SameSite=Strict~:[~;; Secure~]"
            token-name (http-protocol:reveal (%gate-session gate))
            (and scheme (typep scheme '(or string symbol)) (string-equal scheme "https")))))

(defun %use-bootstrap (gate)
  "Mark GATE's bootstrap token used, under its lock. → T for the one call that
did, NIL when it was already used."
  (bt:with-lock-held ((%gate-lock gate))
    (if (%gate-used gate)
        nil
        (setf (%gate-used gate) t))))

(defun %valid-cookie-p (token-name gate env)
  "True when some cookie named TOKEN-NAME holds GATE's session secret."
  (let ((session (http-protocol:reveal (%gate-session gate))))
    (loop for (name . value) in (%raw-fields (%env-header env "cookie") #\;)
            thereis (and (string= token-name (string-trim '(#\Space #\Tab) name))
                         (%token= value session)))))

(defun %forbidden (transport)
  "The gate's 403: the error fragment of HTMX-FORBIDDEN, echoing nothing."
  (htmx-error-response transport (make-condition 'htmx-forbidden)))

(defun %token-gate (transport token token-name state env)
  "NIL when ENV may go on to HTMX-HANDLE-REQUEST, else the gate's response (a
303 or a 403). TOKEN the bootstrap SECRET; STATE this app's session secret and
bootstrap use (file header, Token gate)."
  (let* ((fields (%raw-fields (getf env :query-string) #\&))
         (count (count token-name fields :key #'car :test #'string=)))
    (cond ((plusp count)
           ;; 1. The exchange; a valid cookie never rescues a failed one.
           (let ((location (%clean-location env token-name fields)))
             (if (and (= count 1)
                      (%token= (cdr (assoc token-name fields :test #'string=))
                               (http-protocol:reveal token))
                      location
                      ;; Last: only an exchange that passed everything else uses the token.
                      (%use-bootstrap state))
                 (list 303
                       (list :location location
                             :set-cookie (%session-cookie token-name state env)
                             :cache-control "no-store")
                       '())
                 (%forbidden transport))))
          ;; 2. Otherwise the session cookie.
          ((%valid-cookie-p token-name state env) nil)
          (t (%forbidden transport)))))

(defun %with-csp (response csp)
  "RESPONSE (a list or a Clack streaming function) with
(:content-security-policy CSP) as its last header; RESPONSE itself when CSP is NIL."
  ;; Never destructive: a response may be a literal (sse-backend-clack's 404),
  ;; so the header list is copied by APPEND and the body is shared as it is.
  (flet ((add (reply)
           (list* (first reply)
                  (append (second reply) (list :content-security-policy csp))
                  (cddr reply))))
    (cond ((null csp) response)
          ((functionp response)
           ;; Clack streaming: the (status headers) handed to the responder.
           (lambda (responder)
             (funcall response (lambda (reply) (funcall responder (add reply))))))
          ((consp response) (add response))
          (t response))))

(defun %handler-app (transport handler stream-handler)
  "The innermost layer: 0.2.1's app."
  (lambda (env)
    (htmx-handle-request transport handler stream-handler env)))

(declaim (notinline %gate-response))

(defun %gate-layer (app transport token token-name)
  "APP behind the token gate when TOKEN is in force, else APP itself. Each call
makes its own state: a session secret from the CSPRNG (no secrets backend →
SECRETS-PROTOCOL:SECRETS-ERROR here, not at a login) and an unused bootstrap."
  (if (null token)
      app
      (let ((state (%make-gate (http-protocol:make-secret (secrets-protocol:token-urlsafe 32)))))
        (lambda (env)
          (or (%gate-response transport token token-name state env)
              (funcall app env))))))

(defun %csp-layer (app csp)
  "APP with CSP added to every response when a policy is in force, else APP itself."
  (if (null csp)
      app
      (lambda (env)
        (%with-csp (funcall app env) csp))))

(defun htmx-app (transport handler &key stream-handler
                                     (csp nil csp-p) (token nil token-p)
                                     (token-name nil token-name-p))
  "Clack app serving HANDLER / STREAM-HANDLER through TRANSPORT, with its CSP and
token gate (CSP, TOKEN, TOKEN-NAME override the transport's when supplied). See
the file header."
  (check-type transport htmx-transport)
  (check-type handler (or htmx-handlers function null))
  (check-type stream-handler (or function null))
  (let ((policy (if csp-p (%transport-csp csp) (htmx-transport-csp transport)))
        (bootstrap (if token-p
                       (and token (%token-option token))
                       (htmx-transport-token transport)))
        (name (if token-name-p
                  (%token-name-option token-name)
                  (htmx-transport-token-name transport))))
    (%csp-layer (%gate-layer (%handler-app transport handler stream-handler)
                             transport bootstrap name)
                policy)))

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

;;; The gate under the request boundary, in its own NOTINLINE function (declaimed
;;; above %GATE-LAYER): the boundary's value is RETURNED, and the caller's OR
;;; tests a plain value. Written inline, (or (block … (handler-bind …)) …) is
;;; the shape ECL 26.5.5 miscompiles (%RUN-CAPTURING-ERROR below), which would
;;; let a failing gate fall through to the handler.
(defun %gate-response (transport token token-name state env)
  "%TOKEN-GATE's answer; an ERROR inside it → an error response, never NIL, so
the gate fails closed. Nothing escapes the app."
  (%with-error-response (transport)
    (%token-gate transport token token-name state env)))

;;; ---------------------------------------------------------------------------
;;; Request flow
;;; ---------------------------------------------------------------------------

;;; A table entry: 404, then 406, then its key set (%ENTRY-KEY-SET, derived
;;; again after a redefinition) accepts the message's params and unmapped names
;;; (%ACCEPT-PARAMS), all before the thunk is made, so a refused :call-stream
;;; request is a plain 400 and no stream opens. The thunk calls (apply fn
;;; params) / (apply fn stream params), never with :allow-other-keys (#3).
(defun %resolve-callee (handler stream-handler message)
  "→ (values thunk mode). THUNK takes no argument (:call-response, :notify) or
the event stream (:call-stream) and applies the callee's calling convention."
  (let ((name (htmx-message-method message))
        (params (htmx-message-params message))
        (streamp (eq (htmx-message-mode message) :call-stream)))
    (etypecase handler
      (htmx-handlers
       (let ((entry (%find-entry handler name)))
         (unless entry (%method-not-found name))
         (let ((fn (%entry-callee entry))
               (mode (%entry-mode entry)))
           (when (and (eq mode :call-stream) (not streamp))
             (error 'htmx-not-acceptable))
           (%accept-params (%entry-key-set entry) params (htmx-message-unmapped-names message))
           (if (eq mode :call-stream)
               (values (lambda (stream) (apply fn stream params)) mode)
               (values (lambda () (apply fn params)) mode)))))
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

;;; JSONRPC-HANDLER follows the header's Keys order: %JSON-PAIRS does (1) the
;;; shape, (2) the member cap and (3) the sorted, checked members; then (4) the
;;; method; then (5) the names through the codec's own %PARAMS-PLIST
;;; (FIND-SYMBOL, unmapped names kept apart) and the entry's key set.
(defun %json-pairs (params limit)
  "JSON-RPC PARAMS (NIL, an empty vector or an object) → ((name . string) …) in
sorted name order, empty names dropped; more than LIMIT members →
HTMX-TOO-MANY-PARAMS. File header, JSONRPC-HANDLER, Keys (1)–(3)."
  (cond ((null params) '())
        ((and (vectorp params) (not (stringp params)) (zerop (length params))) '())
        ((hash-table-p params)
         (let ((names '()))
           (maphash (lambda (k v) (declare (ignore v)) (push k names)) params)
           (unless (every #'stringp names)
             (error 'rpc-protocol:rpc-invalid-params :message "Param names must be strings"))
           (when (> (hash-table-count params) limit)
             (error 'htmx-too-many-params :limit limit))
           ;; Sorted: hash-table order never reaches the handler.
           (loop for name in (sort names #'string<)
                 unless (zerop (length name))
                   collect (cons name (%json-param-value name (gethash name params))))))
        (t (error 'rpc-protocol:rpc-invalid-params
                  :message "Params must be an object of strings or integers"))))

(defun jsonrpc-handler (transport handlers)
  "JSON-RPC handler over the same HANDLERS table. See the file header."
  (check-type transport htmx-transport)
  (check-type handlers htmx-handlers)
  (let ((limit (htmx-codec-max-params (htmx-transport-codec transport))))
    (lambda (method params)
      (let* ((pairs (%json-pairs params limit))
             (entry (%find-entry handlers method)))
        (when (or (null entry) (eq (%entry-mode entry) :call-stream))
          (%method-not-found method))
        (multiple-value-bind (plist unmapped) (%params-plist pairs)
          (%accept-params (%entry-key-set entry) plist unmapped)
          (let ((*htmx-request* (make-instance 'htmx-message :method method :params plist
                                                             :unmapped-names unmapped
                                                             :mode :call-response
                                                             :http-method :post)))
            (multiple-value-bind (result headers) (apply (%entry-callee entry) plist)
              (if (eq (%entry-mode entry) :notify)
                  ""
                  (format nil "~{~A~}"
                          (third (rpc-protocol:encode-response-using-codec
                                  (htmx-transport-codec transport)
                                  (htmx-result-nodes transport result)
                                  :headers headers)))))))))))
