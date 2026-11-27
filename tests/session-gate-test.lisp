(in-package #:rpc-backend-htmx/tests)

;;; 0.5.0: sessions next to the token gate (#4) and the CSP header. The gate
;;; still runs first (an unauthenticated request never begins a session or
;;; reaches the store), the gate's cookie and the session cookie coexist under
;;; distinct names, and the CSP header is on every response, the last one,
;;; after a session's Set-Cookie. Rules: src/server.lisp (HTMX-APP, Order;
;;; Sessions), src/session.lisp.

(defun canvas-url-of (name) (s+ "/canvas/RPC-BACKEND-HTMX%2FTESTS::" name))

(defun gated-session-client (manager &rest transport-keys)
  "A jar client of a gated canvas app over (SESSION-HANDLERS) with MANAGER's sessions."
  (session-client (apply #'gated-transport :sessions manager transport-keys)))

(defun jar-login (c &optional (name "RECALL"))
  "The gate's exchange through C's jar → the 303 reply."
  (visit c (h:htmx-token-url (canvas-url-of name) +token+)))

(deftest gate-runs-before-sessions
  (with-clock ()
    (let* ((mgr (test-manager :refresh-interval 0))
           (store (manager-store mgr))
           (c (gated-session-client mgr))
           (login (jar-login c)))
      (ok (= 303 (h:htmx-reply-status login)))
      (ok (equal '("canvas-token") (mapcar (lambda (v) (subseq v 0 (position #\= v))) (set-cookies login)))
          "the exchange sets the gate's cookie only")
      (ok (= 0 (store-count store)) "the exchange begins no session")
      (call c "REMEMBER" :note "x")
      (let ((sid (h:htmx-client-cookie c "sid"))
            (calls (store-count store)))
        (ok (stringp sid) "past the gate, a session")
        (let ((stranger (session-client (gated-transport :sessions mgr))))
          (dolist (case (list (list "fragment" (h:htmx-request stranger (m "RECALL") nil
                                                               :headers (list (cons "cookie" (s+ "sid=" sid)))))
                              (list "post" (h:htmx-request stranger (m "REMEMBER") '(:note "y")
                                                           :http-method :post
                                                           :headers (list (cons "cookie" (s+ "sid=" sid)))))
                              (list "stream" (h:htmx-request stranger (m "STREAM-RECALL") nil
                                                             :accept "text/event-stream"
                                                             :headers (list (cons "cookie" (s+ "sid=" sid)))))
                              (list "cross-site post"
                                    (h:htmx-request stranger (m "REMEMBER") '(:note "y")
                                                    :http-method :post
                                                    :headers (list (cons "cookie" (s+ "sid=" sid))
                                                                   (cons "sec-fetch-site" "cross-site"))))))
            (destructuring-bind (label reply) case
              (ok (forbidden-p reply) (s+ label ": the gate's 403, not the cross-origin one"))
              (ok (null (set-cookies reply)) (s+ label ": no Set-Cookie"))
              (ok (equal +brief-csp+ (csp-of reply)) (s+ label ": with the CSP")))))
        (ok (= calls (store-count store)) "no store call for a request the gate refused")
        (ok (equal "<p>x</p>" (call-body c "RECALL")) "and the session is as it was")))))

(deftest gate-and-session-cookies-coexist
  (with-clock ()
    (let* ((c (gated-session-client (test-manager)))
           (login (jar-login c))
           (page (visit c (hdr login "Location"))))
      (ok (= 200 (h:htmx-reply-status page)) "the redirect followed: the gate's cookie from the jar")
      (ok (equal "<p>-</p>" (h:htmx-reply-body (call c "RECALL"))))
      (let ((r (call c "REMEMBER" :note "x")))
        (ok (sid-of r))
        (ok (equal (session-cookie-header (sid-of r)) (set-cookie-named r "sid")) "SameSite=Lax, Max-Age")
        (ok (search "SameSite=Strict" (set-cookie-named login "canvas-token")) "the gate's: Strict"))
      (ok (equal '("canvas-token" "sid") (mapcar #'car (h:htmx-client-cookies c))) "both in the jar")
      (ok (equal "<p>x</p>" (call-body c "RECALL")) "each request carries both")
      (ok (forbidden-p (h:htmx-request c (m "RECALL") nil
                                       :headers (list (cons "cookie" (s+ "sid=" (h:htmx-client-cookie c "sid"))))))
          "the session cookie alone does not pass the gate")
      (ok (equal "<p>-</p>"
                 (h:htmx-reply-body
                  (h:htmx-request c (m "RECALL") nil
                                  :headers (list (cons "cookie" (s+ "canvas-token="
                                                                    (h:htmx-client-cookie c "canvas-token")))))))
          "the gate's cookie alone carries no session"))))

(deftest session-cookie-name-must-differ-from-the-gate
  (let ((clash (stack-session:make-session-manager
                :cookie-policy (stack-session:make-cookie-policy :name "canvas-token"))))
    (ok (signals (h:htmx-app (gated-transport :sessions clash) (session-handlers)) 'h:htmx-error))
    (ok (equal "Session cookie name canvas-token is the token gate's cookie name"
               (handler-case (h:htmx-app (gated-transport :sessions clash) (session-handlers))
                 (h:htmx-error (e) (rpc:rpc-error-message e)))))
    (ok (signals (h:htmx-app (canvas-transport) (session-handlers) :sessions clash :token +token+)
                 'h:htmx-error)
        "the app's own token and sessions")
    (ok (typep (h:htmx-app (gated-transport :sessions clash :token-name "run-7") (session-handlers))
               'function)
        "another gate name")
    (ok (typep (h:htmx-app (canvas-transport) (session-handlers) :sessions clash) 'function)
        "no gate: any cookie name")))

(deftest csp-on-every-response-with-sessions
  (dolist (case (csp-replies (csp-client (hc:make-canvas-htmx-transport :sessions t))))
    (destructuring-bind (label status reply) case
      (ok (= status (h:htmx-reply-status reply)) label)
      (ok (equal (cons "content-security-policy" +brief-csp+) (last-header reply))
          (s+ label ": the CSP, last"))
      (ok (= 1 (csp-count reply)) (s+ label ": exactly once"))
      (ok (null (set-cookies reply)) (s+ label ": nothing stored, no Set-Cookie"))))
  (with-clock ()
    (let* ((c (session-client (hc:make-canvas-htmx-transport :sessions (test-manager))))
           (r (call c "REMEMBER" :note "x")))
      (ok (equal '("content-type" "set-cookie" "content-security-policy") (header-names r))
          "a response that sets the session cookie: the Set-Cookie, then the CSP")
      (let ((refused (h:htmx-request c (m "REMEMBER") '(:note "y") :http-method :post
                                                                  :headers '(("sec-fetch-site" . "cross-site")))))
        (ok (= 403 (h:htmx-reply-status refused)))
        (ok (equal (cons "content-security-policy" +brief-csp+) (last-header refused))
            "the cross-origin 403 too"))
      (let ((logout (call c "LOGOUT")))
        (ok (equal '("content-type" "set-cookie" "content-security-policy") (header-names logout))
            "the expiry cookie too")))))
