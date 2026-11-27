(in-package #:rpc-backend-htmx)

;;; Visitor sessions (0.5.0, rpc-backend-htmx#19; cl-stack docs/capabilities/
;;; session.md, slice S1). An anonymous server-side session per browser for
;;; multi-page flows (a wizard, "my recent items", per-visitor limits):
;;; session-protocol's model, store and cookie policy (S0), bound to the app
;;; with S0b's SESSION-HANDLER mixin on middleware-protocol. Nothing here
;;; re-implements session-protocol: the option and the manager are in
;;; server.lisp (Sessions), the message's session in codec.lisp; this file is
;;; the session layer HTMX-APP builds, the cross-origin check and the handler
;;; accessors.
;;;
;;; The session layer: (%SESSION-LAYER app transport manager gate-name) → app
;;;   APP the inner Clack app (HTMX-HANDLE-REQUEST's), MANAGER NIL or the
;;;   STACK-SESSION:SESSION-MANAGER in force, GATE-NAME the token gate's
;;;   cookie name when a token is in force, else NIL. MANAGER NIL → APP itself
;;;   (sessions off: nothing else here runs). Otherwise checks a and b
;;;   (server.lisp, Sessions), builds the middleware handler once and returns
;;;   a Clack app that, per request (the gate already let it through):
;;;   1. Cross-origin check (below). Refused → (HTMX-ERROR-RESPONSE transport
;;;      <an HTMX-CROSS-ORIGIN>): 403, before any session is begun, the store
;;;      is called or the body is read; nothing is called.
;;;   2. ENV :PATH-INFO does not start with the transport's prefix (not a
;;;      method call: the canvas asset route, a path outside the prefix) →
;;;      (funcall app env): no session is begun, the store is not called, no
;;;      Set-Cookie. An asset never costs a store read (Express and Rails put
;;;      static files before the session middleware for the same reason). A
;;;      method prefix of "/" puts the asset route under it: those requests get
;;;      sessions like any other.
;;;   3. Otherwise the middleware handler, the Clack app
;;;        (STACK-MIDDLEWARE-CLACK:CLACK-APP
;;;         (STACK-MIDDLEWARE:MAKE-HANDLER
;;;          (list <S1 mixin> 'stack-middleware-clack:clack-handler)
;;;          :session-manager manager :app app))
;;;      made once per HTMX-APP call. The S1 mixin is internal (its name is the
;;;      implementation's), a subclass of STACK-SESSION-MIDDLEWARE:SESSION-HANDLER,
;;;      and its two methods are below. So S0b's rules hold
;;;      (session-protocol src/middleware.lisp):
;;;      - PREPARE-REQUEST begins the session (STACK-SESSION:BEGIN-SESSION on
;;;        the env: the cookie read, the session loaded or a new one started)
;;;        and APP gets (LIST* :MIDDLEWARE.REQUEST request :SESSION session
;;;        env), so HTMX-HANDLE-REQUEST's message carries the session
;;;        (codec.lisp, HTMX-MESSAGE-SESSION) and every handler call and every
;;;        :call-stream request sees it;
;;;      - FINISH-RESPONSE commits it (STACK-SESSION:FINISH-SESSION) through
;;;        MAP-RESPONSE: a list response before the layer returns it; a
;;;        streamed (:call-stream) response when the stream hands its head to
;;;        the server's responder, BEFORE any event is written. The
;;;        Set-Cookie comes last among the response's headers (the CSP layer
;;;        then appends its header after it).
;;;      - Lazy creation (S0): a request that stores nothing gets no
;;;        Set-Cookie and no store write; an unknown, malformed, forged or
;;;        expired cookie gives a fresh session, never an error.
;;;   4. Conditions. Steps 1 to 3 run inside the app's request boundary
;;;      (%WITH-ERROR-RESPONSE, server.lisp): a condition the session layer
;;;      raises before a response exists (a STACK-SESSION:SESSION-STORE-ERROR
;;;      when the session is loaded or committed, a SESSION-VALUE-ERROR at the
;;;      commit) → (HTMX-ERROR-RESPONSE transport condition): the 500 error
;;;      fragment, with no session Set-Cookie and nothing committed. Nothing
;;;      escapes the app, as in 0.4.0. A handler's own conditions never reach
;;;      this boundary: HTMX-HANDLE-REQUEST already turned them into error
;;;      responses, which the S1 mixin then sees.
;;;   The S1 mixin's methods (on the mixin and STACK-MIDDLEWARE-CLACK:CLACK-REQUEST):
;;;   - FINISH-RESPONSE: a response whose status is 500 or more is returned
;;;     unchanged and the session is NOT committed: no store write, no
;;;     Set-Cookie, the visitor's stored session as it was. Any other status →
;;;     (CALL-NEXT-METHOD), S0b's commit (a 4xx commits: a 422 coercion error,
;;;     a 404). Django's SessionMiddleware skips the save on a 5xx; S0b commits
;;;     nothing when a condition escapes the app, and here a handler's
;;;     condition comes back as a 500, so the status stands for it: a handler
;;;     that fails half-way does not persist half its changes.
;;;   - HANDLE :around: a streamed response (a function) comes back wrapped so
;;;     that, while the server runs it, a STACK-SESSION:SESSION-STORE-ERROR
;;;     from the commit at the stream's head is handled by session-protocol's
;;;     CONTINUE restart: the refresh write (or the delete of an expired
;;;     session) is skipped and the stream goes on. A stream's head can only
;;;     refresh or expire a session, since no handler code runs before it (a
;;;     :call-stream handler runs inside the stream's writer), so CONTINUE loses
;;;     at most a refresh; and the head cannot become an error response the way
;;;     a list response can (step 4). Conditions inside the stream are the
;;;     stream boundary's (%STREAM-BOUNDARY, server.lisp), unchanged. A list
;;;     response is returned as it is.
;;;
;;; Cross-origin requests (0.5.0, locked). The session cookie is SameSite=Lax
;;; (session-protocol's default): a browser does not send it on a cross-site
;;; POST, but a page on another subdomain of the same site (same-site) and a
;;; browser without SameSite still can. So, with sessions in force, the
;;; session layer refuses an unsafe request that a browser sent from another
;;; origin. The rule is Go's net/http CrossOriginProtection (Go 1.25): Fetch
;;; Metadata first, then Origin against Host. In order:
;;;   1. ENV :REQUEST-METHOD :GET, :HEAD or :OPTIONS (safe) → allowed.
;;;   2. A "sec-fetch-site" request header → allowed when it is exactly
;;;      "same-origin" or "none" (a typed URL, a bookmark); any other value
;;;      ("same-site", "cross-site", anything else) → refused.
;;;   3. No Sec-Fetch-Site and no "origin" header → allowed: not a browser, or
;;;      a browser from before Fetch Metadata, which sends neither on a
;;;      same-origin request.
;;;   4. An Origin header and no Sec-Fetch-Site → allowed when its host, the
;;;      text after its first "://" (an Origin is scheme://host[:port], RFC
;;;      6454 §6.2), is STRING-EQUAL to the "host" request header; anything
;;;      else ("null", no "://", no Host header, another host or port) →
;;;      refused. The scheme is not compared (Host carries none): an
;;;      http-to-https request from a browser without Fetch Metadata passes, as
;;;      in Go; HSTS covers it.
;;;   Refused → HTMX-CROSS-ORIGIN's error response: 403, the fragment
;;;   <p role="alert">htmx error 403: Cross-origin request</p>, the transport's
;;;   error target and swap, the CSP header (outside). Header values are never
;;;   echoed. It runs for every request through the session layer (any path),
;;;   before the session is begun, the body is read or anything is called, so
;;;   a cross-site PUT is a 403, not a 405. Not configurable in 0.5.0 (no
;;;   trusted-origin list; a later minor, as Go's AddTrustedOrigin). With
;;;   sessions off it never runs: 0.4.0 behaviour. The token gate needs no such
;;;   check: its cookie is SameSite=Strict.
;;;   The decision is ONE pure function of the four facts,
;;;     (%CROSS-ORIGIN-VERDICT &key method fetch-site origin host) → :ALLOW | :REFUSE
;;;   (METHOD the keyword, the other three the header strings or NIL), isolated
;;;   so it can move to policy-protocol as it stands (rules-and-logic;
;;;   rpc-backend-htmx#21, label logic-migration).
;;;
;;; Handler access (0.5.0, locked). A handler reads and writes the visitor's
;;; session through the request it handles (*HTMX-REQUEST*): thin accessors
;;; over session-protocol, no parallel API.
;;;   (HTMX-SESSION) → the STACK-SESSION:SESSION of the request being handled,
;;;     (HTMX-MESSAGE-SESSION *HTMX-REQUEST*), or NIL: sessions off, a request
;;;     the session layer passed by (step 2), JSONRPC-HANDLER's message, or no
;;;     request at all (*HTMX-REQUEST* NIL). Every session-protocol function
;;;     takes it (STACK-SESSION:REMOVE-SESSION-VALUE, CLEAR-SESSION,
;;;     SESSION-DATA, SESSION-NEW-P …).
;;;   (HTMX-SESSION-VALUE key &optional default) → (values value present-p):
;;;     (STACK-SESSION:SESSION-VALUE session key default); with no session
;;;     (values DEFAULT NIL). KEY a string, else TYPE-ERROR (with no session
;;;     too).
;;;   (SETF (HTMX-SESSION-VALUE key &optional default) value) → VALUE as
;;;     (SETF (STACK-SESSION:SESSION-VALUE session key default) value) returns
;;;     it: VALUE JSON data (session-protocol's value domain, else its
;;;     SESSION-VALUE-ERROR with USE-VALUE and SKIP-VALUE); DEFAULT is ignored,
;;;     so (INCF (HTMX-SESSION-VALUE "n" 0)) works.
;;;   (HTMX-SESSION-REGENERATE) → the session, after
;;;     (STACK-SESSION:REGENERATE-SESSION-ID session): a new id at the commit,
;;;     the values and the creation time kept, the old id deleted from the
;;;     store. Call it when the visitor's privileges change (session
;;;     fixation). It returns the session, not the new id: ids are bearer
;;;     credentials and stay out of handler code (session-protocol, Secrets).
;;;   (HTMX-SESSION-END) → the session, after (STACK-SESSION:END-SESSION
;;;     session): every value removed; the commit deletes the stored session
;;;     and expires the cookie (Max-Age=0).
;;;   The setter, HTMX-SESSION-REGENERATE and HTMX-SESSION-END with no session
;;;   → HTMX-ERROR (status 500) whose message is exactly
;;;     No session (the app has no :sessions)
;;;   so the request answers that 500 fragment.
;;;   Streams. A :call-stream handler runs after the stream's head committed
;;;   the session (step 3), so it reads the session as the request found it,
;;;   and STACK-SESSION:SESSION-COMMITTED-P is already true. Every write (the
;;;   setter, REGENERATE, END) signals session-protocol's SESSION-WRITE-ERROR
;;;   (a CERROR: CONTINUE ignores the write). Unhandled, the stream boundary
;;;   answers it like any condition: one +STREAM-ERROR-EVENT+ event whose data
;;;   is the error fragment of its report,
;;;     <p role="alert">session cannot change: it is committed</p>
;;;   then the stream closes. A handler that wants to go on binds it:
;;;     (handler-bind ((stack-session:session-write-error #'continue)) …)
;;;   Failures. A handler condition answered with a 5xx commits nothing (the
;;;   S1 mixin, above): its session changes are lost.
;;;
;;; Given in the S1 contract: the option, its validation and the reader
;;; (server.lisp), the message slots and readers (codec.lisp), HTMX-CROSS-ORIGIN.
;;; Implemented below: the cross-origin verdict, the session layer with its
;;; build-time checks and the S1 mixin, the handler accessors.

;;; ---------------------------------------------------------------------------
;;; Cross-origin requests
;;; ---------------------------------------------------------------------------

(defun %cross-origin-verdict (&key method fetch-site origin host)
  "→ :ALLOW or :REFUSE for an unsafe-method check of one request (file header,
Cross-origin requests): METHOD the request method keyword, FETCH-SITE, ORIGIN
and HOST the Sec-Fetch-Site, Origin and Host header strings, or NIL."
  ;; One cond, the header's four rules in order; it reads nothing else, so it
  ;; can move to policy-protocol as it stands (rpc-backend-htmx#21).
  (let ((separator (and origin (search "://" origin))))
    (cond ((member method '(:get :head :options)) :allow)            ; 1. safe
          (fetch-site                                                ; 2. Fetch Metadata
           (if (or (string= fetch-site "same-origin") (string= fetch-site "none"))
               :allow
               :refuse))
          ((null origin) :allow)                                     ; 3. neither header
          ((and separator host                                       ; 4. Origin against Host
                (string-equal origin host :start1 (+ separator 3)))
           :allow)
          (t :refuse))))

(defun %cross-origin-refused-p (env)
  "True when %CROSS-ORIGIN-VERDICT refuses the request ENV (its method and its
Sec-Fetch-Site, Origin and Host headers; file header, Cross-origin requests)."
  (eq :refuse (%cross-origin-verdict :method (getf env :request-method)
                                     :fetch-site (%env-header env "sec-fetch-site")
                                     :origin (%env-header env "origin")
                                     :host (%env-header env "host"))))

;;; ---------------------------------------------------------------------------
;;; The S1 mixin: S0b's SESSION-HANDLER with the 5xx rule and the stream head
;;; ---------------------------------------------------------------------------

(defclass %htmx-session-handler (stack-session-middleware:session-handler)
  ()
  (:documentation "The S1 mixin (file header, step 3): S0b's SESSION-HANDLER, whose
FINISH-RESPONSE commits nothing for a 5xx and whose HANDLE :around wraps a
streamed response for the commit at its head. No slots of its own."))

(defun %server-error-response-p (response)
  "True for an immediate Clack RESPONSE whose status is 500 or more."
  (let ((status (and (consp response) (first response))))
    (and (integerp status) (>= status 500))))

(defmethod stack-middleware:finish-response ((handler %htmx-session-handler)
                                             (request stack-middleware-clack:clack-request)
                                             response)
  "A 5xx RESPONSE comes back unchanged and commits nothing; any other status is
S0b's commit (file header, the S1 mixin's methods)."
  (if (%server-error-response-p response)
      response                          ; no CALL-NEXT-METHOD: no FINISH-SESSION, no store call
      (call-next-method)))

(defun %continue-at-stream-head (response session)
  "The Clack streaming RESPONSE wrapped: while the server runs it, a
STACK-SESSION:SESSION-STORE-ERROR from the commit of SESSION at the stream's
head takes session-protocol's CONTINUE (file header, HANDLE :around)."
  (lambda (responder)
    (handler-bind ((stack-session:session-store-error
                     (lambda (condition)
                       ;; The commit sets COMMITTED last, so this is true only
                       ;; while the head's refresh or delete runs. Afterwards
                       ;; the handler declines: CONTINUE covers that one
                       ;; operation, nothing the stream does later.
                       (when (and session (not (stack-session:session-committed-p session)))
                         (continue condition)))))
      (funcall response responder))))

(defmethod stack-middleware:handle :around ((handler %htmx-session-handler)
                                            (request stack-middleware-clack:clack-request))
  "A streamed response (a function) comes back wrapped for the commit at its
head; a list response as it is (file header, the S1 mixin's methods)."
  (let ((response (call-next-method)))
    (if (functionp response)
        (%continue-at-stream-head response (stack-session-middleware:request-session request))
        response)))

;;; ---------------------------------------------------------------------------
;;; The session layer
;;; ---------------------------------------------------------------------------

(defun %check-session-cookie-name (manager gate-name)
  "Check a (server.lisp, Sessions): with a gate, the session cookie's name must
not be GATE-NAME, else HTMX-ERROR (500)."
  (when gate-name
    (let ((name (stack-session:cookie-policy-name
                 (stack-session:session-manager-cookie-policy manager))))
      (when (string= name gate-name)
        (error 'htmx-error
               :message (format nil "Session cookie name ~A is the token gate's cookie name"
                                name))))))

(defun %check-session-backends ()
  "Check b (server.lisp, Sessions): a missing secrets backend (the id) or
json-protocol backend (the record) signals here, at HTMX-APP, never at a
visitor's request. The record is thrown away."
  (stack-session:encode-session-record
   (stack-session:make-session :id (stack-session:generate-session-id)
                               :created-at 0 :last-seen 0))
  (values))

(defun %session-layer (app transport manager gate-name)
  "APP itself when MANAGER is NIL, else the session layer around APP (file header)."
  (if (null manager)
      app
      (progn
        (%check-session-cookie-name manager gate-name)   ; a
        (%check-session-backends)                        ; b
        (let ((prefix (htmx-transport-prefix transport))
              ;; Built once per HTMX-APP call: MAKE-HANDLER caches the class,
              ;; and this one instance serves every request.
              (session-app (stack-middleware-clack:clack-app
                            (stack-middleware:make-handler
                             (list '%htmx-session-handler 'stack-middleware-clack:clack-handler)
                             :session-manager manager :app app))))
          (lambda (env)
            ;; Step 4: steps 1 to 3 inside the app's request boundary; its
            ;; value is returned as it is.
            (%with-error-response (transport)
              (cond ((%cross-origin-refused-p env)                 ; 1. any path, any method
                     (htmx-error-response transport (make-condition 'htmx-cross-origin)))
                    ((not (%prefixp prefix (getf env :path-info))) ; 2. not a method call
                     (funcall app env))
                    (t (funcall session-app env)))))))))           ; 3. the middleware handler

;;; ---------------------------------------------------------------------------
;;; Handler access
;;; ---------------------------------------------------------------------------

(defun htmx-session ()
  "The session of the request being handled, or NIL (file header, Handler access)."
  (let ((message *htmx-request*))
    (and message (htmx-message-session message))))

(defun %session-for-write ()
  "The request's session; HTMX-ERROR (500) when there is none (file header,
Handler access)."
  (or (htmx-session)
      (error 'htmx-error :message "No session (the app has no :sessions)")))

(defun htmx-session-value (key &optional default)
  "(values value present-p) for KEY in the request's session; (values DEFAULT
NIL) with no session (file header, Handler access)."
  (check-type key string)               ; with no session too
  (let ((session (htmx-session)))
    (if session
        (stack-session:session-value session key default)
        (values default nil))))

(defun (setf htmx-session-value) (value key &optional default)
  "Store VALUE under KEY in the request's session; HTMX-ERROR with no session
(file header, Handler access)."
  (declare (ignore default))            ; so (INCF (HTMX-SESSION-VALUE "n" 0)) works
  ;; Session-protocol's value, conditions and restarts, unwrapped.
  (setf (stack-session:session-value (%session-for-write) key) value))

(defun htmx-session-regenerate ()
  "A new id for the request's session at the commit → the session (file
header, Handler access)."
  (let ((session (%session-for-write)))
    ;; Its value, the new id, is dropped: ids stay out of handler code.
    (stack-session:regenerate-session-id session)
    session))

(defun htmx-session-end ()
  "End the request's session → the session (file header, Handler access)."
  (let ((session (%session-for-write)))
    (stack-session:end-session session)
    session))
