(in-package #:rpc-backend-htmx/tests)

;;; 0.5.0 (rpc-backend-htmx#19): anonymous visitor sessions. The option, the
;;; flows through HTMX-CLIENT's cookie jar, lazy creation, rotation and
;;; ending, idle expiry on an injected clock, failures, sessions off. Rules:
;;; src/server.lisp (Sessions), src/session.lisp.

(defun session-transport (&rest keys &key (sessions (test-manager)) &allow-other-keys)
  "A core transport at /htmx/ with SESSIONS (default: a fresh TEST-MANAGER)."
  (apply #'transport :sessions sessions (without-key keys :sessions)))

(deftest sessions-option
  (ok (null (h:htmx-transport-sessions (transport))) "off by default")
  (ok (null (h:htmx-transport-sessions (canvas-transport))) "off by default on the canvas transport")
  (let ((m (h:htmx-transport-sessions (transport :sessions t))))
    (ok (typep m 'stack-session:session-manager) "T: a manager")
    (ok (typep (stack-session:session-manager-store m) 'stack-session:cache-session-store))
    (ok (typep (stack-session:cache-session-store-cache (stack-session:session-manager-store m))
               'stack-cache:in-memory-ttl-cache)
        "over an in-memory cache")
    (ok (equal "sid" (stack-session:cookie-policy-name (stack-session:session-manager-cookie-policy m)))
        "session-protocol's defaults")
    (ok (= 86400 (stack-session:session-manager-idle-ttl m))))
  (ok (not (eq (h:htmx-transport-sessions (transport :sessions t))
               (h:htmx-transport-sessions (transport :sessions t))))
      "one manager per transport")
  (let ((mgr (test-manager)))
    (ok (eq mgr (h:htmx-transport-sessions (transport :sessions mgr))) "a manager as given")
    (ok (eq mgr (h:htmx-transport-sessions (hc:make-canvas-htmx-transport :sessions mgr))) "canvas too"))
  (ok (typep (h:htmx-transport-sessions (hc:make-canvas-htmx-transport :sessions t))
             'stack-session:session-manager))
  (dolist (bad (list :yes 42 "t" '(:idle-ttl 60) (stack-session:make-cookie-policy)))
    (ok (signals (transport :sessions bad) 'type-error) (format nil "core ~S" bad))
    (ok (signals (hc:make-canvas-htmx-transport :sessions bad) 'type-error) (format nil "canvas ~S" bad))
    (ok (signals (h:htmx-app (transport) (session-handlers) :sessions bad) 'type-error)
        (format nil "app ~S" bad))))

(deftest session-flow-keeps-values
  (with-clock ()
    (let* ((c (session-client (session-transport)))
           (first-reply (call c "VISIT-COUNT"))
           (sid (sid-of first-reply)))
      (ok (equal "<p>1</p>" (h:htmx-reply-body first-reply)))
      (ok (stack-session:valid-session-id-p sid) "a 43-character id")
      (ok (equal (session-cookie-header sid) (set-cookie-named first-reply "sid"))
          "session-protocol's cookie: Max-Age, Path=/, SameSite=Lax, HttpOnly, no Secure on http")
      (ok (equal sid (h:htmx-client-cookie c "sid")) "the jar keeps it")
      (ok (equal "<p>2</p>" (call-body c "VISIT-COUNT")))
      (ok (equal "<p>3</p>" (call-body c "VISIT-COUNT")))
      (ok (equal sid (h:htmx-client-cookie c "sid")) "the same session")
      (ok (equal "<p>loaded</p>" (call-body c "SESSION-KIND")))
      (ok (equal "<p>4</p>" (h:htmx-reply-body (h:htmx-request c (m "VISIT-COUNT") nil :http-method :post)))
          "a POST loads it too"))))

(deftest two-clients-two-sessions
  (with-clock ()
    (let* ((tx (session-transport))
           (a (session-client tx))
           (b (session-client tx)))
      (call a "REMEMBER" :note "a")
      (call b "REMEMBER" :note "b")
      (ok (equal "<p>a</p>" (call-body a "RECALL")))
      (ok (equal "<p>b</p>" (call-body b "RECALL")))
      (ok (string/= (h:htmx-client-cookie a "sid") (h:htmx-client-cookie b "sid"))))))

(deftest storing-nothing-sets-no-cookie
  (with-clock ()
    (let* ((mgr (test-manager))
           (c (session-client (session-transport :sessions mgr)))
           (r (call c "RECALL")))
      (ok (equal "<p>-</p>" (h:htmx-reply-body r)))
      (ok (null (set-cookies r)) "no Set-Cookie")
      (ok (null (h:htmx-client-cookies c)))
      (ok (equal "<p>new</p>" (call-body c "SESSION-KIND")) "a new session each time")
      (ok (= 0 (store-count (manager-store mgr))) "no store call: no cookie to look up, nothing to save"))))

(deftest forged-cookie-gets-a-fresh-session
  (with-clock ()
    (let* ((mgr (test-manager))
           (c (session-client (session-transport :sessions mgr)))
           (forged (make-string 43 :initial-element #\A)))
      (dolist (value (list forged "short" "../../etc" ""))
        (let ((r (h:htmx-request c (m "SESSION-KIND") nil :headers (list (cons "cookie" (s+ "sid=" value))))))
          (ok (= 200 (h:htmx-reply-status r)) value)
          (ok (equal "<p>new</p>" (h:htmx-reply-body r)) value)
          (ok (null (set-cookies r)) value)))
      (ok (= 1 (store-count (manager-store mgr) :load)) "only the well-formed id is looked up"))))

(deftest session-regenerate
  (with-clock ()
    (let* ((mgr (test-manager))
           (c (session-client (session-transport :sessions mgr))))
      (call c "REMEMBER" :note "x")
      (let* ((old (h:htmx-client-cookie c "sid"))
             (r (call c "ROTATE"))
             (new (sid-of r)))
        (ok (equal "<p>rotated</p>" (h:htmx-reply-body r)))
        (ok (and (first *returned*) (eq (first *returned*) (second *returned*)))
            "HTMX-SESSION-REGENERATE returns the session, never the id")
        (ok (stack-session:session-rotated-p (first *returned*)))
        (ok (and new (string/= old new)) "a new id in the Set-Cookie")
        (ok (equal (session-cookie-header new) (set-cookie-named r "sid")))
        (ok (equal "<p>x</p>" (call-body c "RECALL")) "the values kept under the new id")
        (ok (equal "<p>-</p>"
                   (h:htmx-reply-body (h:htmx-request c (m "RECALL") nil
                                                      :headers (list (cons "cookie" (s+ "sid=" old))))))
            "the old id is gone")))))

(deftest session-end
  (with-clock ()
    (let ((c (session-client (session-transport))))
      (call c "REMEMBER" :note "x")
      (let ((r (call c "LOGOUT")))
        (ok (equal "<p>bye</p>" (h:htmx-reply-body r)))
        (ok (and (first *returned*) (eq (first *returned*) (second *returned*)))
            "HTMX-SESSION-END returns the session")
        (ok (stack-session:session-ended-p (first *returned*)))
        (ok (equal (session-cookie-header "" :max-age 0) (set-cookie-named r "sid"))
            "the expiry cookie")
        (ok (null (h:htmx-client-cookie c "sid")) "the browser drops it"))
      (ok (equal "<p>-</p>" (call-body c "RECALL")) "the values are gone"))))

(deftest idle-expiry-on-the-managers-clock
  (with-clock ()
    (let* ((mgr (test-manager :idle-ttl 100))
           (c (session-client (session-transport :sessions mgr))))
      (call c "REMEMBER" :note "x")
      (incf *now* 10)
      (ok (equal "<p>x</p>" (call-body c "RECALL")) "within the idle TTL")
      (incf *now* 200)
      (ok (h:htmx-client-cookie c "sid") "the browser still sends its cookie (real clock)")
      (ok (equal "<p>-</p>" (call-body c "RECALL")) "idle past the TTL: a fresh session")
      (ok (equal "<p>new</p>" (call-body c "SESSION-KIND"))))))

(deftest server-error-commits-nothing
  (with-clock ()
    (let* ((mgr (test-manager))
           (store (manager-store mgr))
           (c (session-client (session-transport :sessions mgr))))
      (let ((r (call c "NOTE-THEN-BOOM" :note "y")))
        (ok (= 500 (h:htmx-reply-status r)))
        (ok (null (set-cookies r)) "a new session written then failed: no cookie")
        (ok (= 0 (store-count store :save)) "nothing stored"))
      (call c "REMEMBER" :note "x")
      (let ((saves (store-count store :save))
            (r (call c "NOTE-THEN-BOOM" :note "y")))
        (ok (= 500 (h:htmx-reply-status r)))
        (ok (null (set-cookies r)))
        (ok (= saves (store-count store :save)) "the loaded session is not saved"))
      (ok (equal "<p>x</p>" (call-body c "RECALL")) "the stored session as it was"))))

(deftest client-error-commits
  (with-clock ()
    (let* ((c (session-client (session-transport)))
           (r (call c "NOTE-THEN-INVALID" :note "y")))
      (ok (= 422 (h:htmx-reply-status r)))
      (ok (sid-of r) "a 4xx commits")
      (ok (equal "<p>y</p>" (call-body c "RECALL"))))))

(deftest store-failure-is-an-error-response
  (with-clock ()
    (let* ((mgr (test-manager))
           (store (manager-store mgr))
           (c (session-client (session-transport :sessions mgr))))
      (call c "REMEMBER" :note "x")
      (setf (store-fail store) '(:load))
      (multiple-value-bind (r escaped) (escapes (lambda () (call c "RECALL")))
        (ok (null escaped) "nothing escapes the app")
        (ok (= 500 (h:htmx-reply-status r)))
        (ok (equal "<p role=\"alert\">session store load failed: down</p>" (h:htmx-reply-body r)))
        (ok (equal "#canvas-error" (hdr r "HX-Retarget")))
        (ok (null (set-cookies r))))
      (setf (store-fail store) '(:save))
      (multiple-value-bind (r escaped) (escapes (lambda () (call c "REMEMBER" :note "z")))
        (ok (null escaped))
        (ok (= 500 (h:htmx-reply-status r)) "the commit's save failed")
        (ok (equal "<p role=\"alert\">session store save failed: down</p>" (h:htmx-reply-body r)))
        (ok (null (set-cookies r))))
      (setf (store-fail store) '())
      (ok (equal "<p>x</p>" (call-body c "RECALL")) "the stored session as it was"))))

(deftest sessions-off-is-0.4.0
  (let* ((c (session-client (transport)))
         (r (call c "SESSION-KIND")))
    (ok (equal "<p>none</p>" (h:htmx-reply-body r)) "HTMX-SESSION is NIL")
    (ok (equal "<p>-</p>" (call-body c "RECALL")) "HTMX-SESSION-VALUE answers the default")
    (let ((w (call c "REMEMBER" :note "x")))
      (ok (= 500 (h:htmx-reply-status w)))
      (ok (equal "<p role=\"alert\">htmx error 500: No session (the app has no :sessions)</p>"
                 (h:htmx-reply-body w))))
    (ok (null (h:htmx-client-cookies c)) "no cookie ever")
    (ok (= 200 (h:htmx-reply-status
                (h:htmx-request c (m "SESSION-KIND") nil :http-method :post
                                                         :headers '(("sec-fetch-site" . "cross-site")))))
        "no cross-origin check")
    (ok (equal "<p>none</p>"
               (h:htmx-reply-body (h:htmx-request c (m "SESSION-KIND") nil
                                                  :headers '(("cookie" . "sid=AAAA"))))))
    (ok (equal '(("content-type" . "text/html; charset=utf-8")) (h:htmx-reply-headers r))
        "0.4.0's headers exactly"))
  (ok (equal "<p>none</p>"
             (call-body (session-client (session-transport) :sessions nil) "SESSION-KIND"))
      "HTMX-APP :sessions nil turns a transport's sessions off"))

(deftest handler-access-outside-a-request
  (let ((h:*htmx-request* nil))
    (ok (null (h:htmx-session)))
    (ok (equal '(7 nil) (multiple-value-list (h:htmx-session-value "k" 7))))
    (ok (signals (setf (h:htmx-session-value "k") 1) 'h:htmx-error))
    (ok (signals (h:htmx-session-regenerate) 'h:htmx-error))
    (ok (signals (h:htmx-session-end) 'h:htmx-error))
    (ok (signals (h:htmx-session-value :k) 'type-error) "keys are strings")
    (ok (equal "No session (the app has no :sessions)"
               (handler-case (h:htmx-session-end)
                 (h:htmx-error (e) (rpc:rpc-error-message e)))))))

(deftest handler-access-is-session-protocol
  (with-clock ()
    (let* ((seen nil)
           (read-back nil)
           (tx (session-transport))
           (c (h:make-htmx-client
               (h:htmx-app tx (h:make-htmx-handlers
                               (list "X::PEEK" (lambda (&key)
                                                 (setf seen (h:htmx-session))
                                                 (setf (stack-session:session-value (h:htmx-session) "k")
                                                       '(1 "two"))
                                                 (setf read-back (multiple-value-list
                                                                  (h:htmx-session-value "k")))
                                                 "ok"))))
               :codec (h:htmx-transport-codec tx) :cookies t)))
      (ok (= 200 (h:htmx-reply-status (h:htmx-request c "X::PEEK" nil))))
      (ok (typep seen 'stack-session:session) "a session-protocol SESSION")
      (ok (stack-session:session-new-p seen))
      (ok (stack-session:session-committed-p seen) "committed once the response is made")
      (ok (equal '((1 "two") t) read-back) "HTMX-SESSION-VALUE reads what session-protocol wrote")
      (ok (h:htmx-client-cookie c "sid") "and the commit set the cookie"))))

(deftest one-manager-per-transport
  (with-clock ()
    (let* ((tx (session-transport))
           (a (session-client tx))
           (b (session-client tx)))
      (call a "REMEMBER" :note "shared")
      (let ((sid (h:htmx-client-cookie a "sid")))
        (ok (equal "<p>shared</p>"
                   (h:htmx-reply-body (h:htmx-request b (m "RECALL") nil
                                                      :headers (list (cons "cookie" (s+ "sid=" sid))))))
            "two apps over one transport share its manager and store")
        (let ((own (session-client tx :sessions t)))
          (ok (equal "<p>-</p>"
                     (h:htmx-reply-body (h:htmx-request own (m "RECALL") nil
                                                        :headers (list (cons "cookie" (s+ "sid=" sid))))))
              "HTMX-APP :sessions t: the app's own manager"))))))

(deftest sessions-need-their-backends
  (let ((tx (transport :sessions t)))
    (let ((secrets-protocol:*secrets-backend* nil))
      (ok (signals (h:htmx-app tx (session-handlers)) 'secrets-protocol:secrets-error)
          "no CSPRNG: no app"))
    (let ((stack-json:*json-backend* nil))
      (ok (signals (h:htmx-app tx (session-handlers)) 'stack-json:json-error)
          "no JSON backend: no app"))
    (let ((secrets-protocol:*secrets-backend* nil)
          (stack-json:*json-backend* nil))
      (ok (typep (h:htmx-app (transport) (session-handlers)) 'function)
          "sessions off need neither"))))

(deftest session-cookie-secure-over-https
  (with-clock ()
    (let* ((c (session-client (session-transport)))
           (r (h:htmx-request-env c (list* :url-scheme "https"
                                           (env :path (s+ +prefix+ (m "REMEMBER")) :query "note=x")))))
      (ok (= 200 (h:htmx-reply-status r)))
      (ok (equal (session-cookie-header (sid-of r) :secure t) (set-cookie-named r "sid"))))))

(deftest canvas-session-flow
  (with-clock ()
    (let* ((mgr (test-manager :refresh-interval 0))
           (store (manager-store mgr))
           (tx (hc:make-canvas-htmx-transport :sessions mgr))
           (c (session-client tx)))
      (call c "REMEMBER" :note "x")
      (let ((page (h:htmx-request c (m "RECALL") nil :hx-request nil)))
        (ok (= 200 (h:htmx-reply-status page)))
        (ok (contains "<p>x</p>" (h:htmx-reply-body page)) "a full page reads the session")
        (ok (equal '("content-type" "set-cookie" "content-security-policy") (header-names page))
            "the refresh's Set-Cookie, then the CSP, last"))
      (let ((loads (store-count store :load))
            (saves (store-count store :save)))
        (dolist (path (list "/canvas-assets/htmx.min.js" "/canvas-assets/nope.js" "/elsewhere"))
          (let ((r (h:htmx-request-env c (env :path path))))
            (ok (null (set-cookies r)) (s+ path ": no Set-Cookie"))
            (ok (equal +brief-csp+ (csp-of r)) (s+ path ": the CSP"))))
        (ok (= loads (store-count store :load)) "assets and paths outside the prefix: no store read")
        (ok (= saves (store-count store :save)))))))
