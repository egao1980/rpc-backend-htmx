(in-package #:rpc-backend-htmx/tests)

;;; 0.3.0 (rpc-backend-htmx#4): the per-run token gate. A one-time URL sets the
;;; token as an HttpOnly, SameSite=Strict cookie; every other request needs
;;; the cookie, else 403 before anything is decoded or called. Rules:
;;; src/server.lisp (Token gate).

(defparameter +token+ "Tk_0123456789abcdefghijklmnopqrstuvwxyz-ABC"
  "43 characters of [A-Za-z0-9_-].")

(defparameter +cookie-attributes+ "; Path=/; HttpOnly; SameSite=Strict")

(defvar *gated-calls* 0)

(defun gated-canvas (&key q)
  (incf *gated-calls*)
  (canvas:el :p nil (or q "-")))

(defun gated-ticker (stream &key)
  (incf *gated-calls*)
  (rpc:rpc-send stream (cons "row" "x")))

(defun gated-handlers ()
  (h:make-htmx-handlers 'gated-canvas '(gated-ticker :mode :call-stream)))

(defparameter +gated-url+ "/canvas/RPC-BACKEND-HTMX%2FTESTS::GATED-CANVAS")

(defun gated-transport (&rest keys)
  (apply #'hc:make-canvas-htmx-transport :token +token+ keys))

(defun gated-client (&optional (tx (gated-transport)) &rest app-keys)
  (h:make-htmx-client (apply #'h:htmx-app tx (gated-handlers) app-keys)
                      :codec (h:htmx-transport-codec tx)))

(defun cookie (value &optional (name "canvas-token"))
  (list (cons "cookie" (s+ name "=" value))))

(defun visit (c url &rest keys)
  "A plain browser GET of URL."
  (apply #'h:htmx-request-url c url :hx-request nil keys))

(defun forbidden-p (reply)
  (and (= 403 (h:htmx-reply-status reply))
       (equal "<p role=\"alert\">htmx error 403: Forbidden</p>" (h:htmx-reply-body reply))
       (equal "#canvas-error" (hdr reply "HX-Retarget"))))

(deftest token-defaults
  (ok (equal "canvas-token" h:+default-token-name+))
  (ok (null (h:htmx-transport-token (canvas-transport))) "no gate by default")
  (ok (equal "canvas-token" (h:htmx-transport-token-name (canvas-transport))))
  (ok (equal (s+ "/canvas/A::B?canvas-token=" +token+) (h:htmx-token-url "/canvas/A::B" +token+)))
  (ok (equal (s+ "/canvas/A::B?x=1&canvas-token=" +token+)
             (h:htmx-token-url "/canvas/A::B?x=1" +token+)))
  (ok (equal (s+ "/canvas/A::B?run-7=" +token+)
             (h:htmx-token-url "/canvas/A::B" +token+ :token-name "run-7")))
  (ok (equal (s+ "/c/A::B?canvas-token=" +token+)
             (h:htmx-token-url "/c/A::B" (http-protocol:make-secret +token+)))
      "a SECRET token"))

(deftest token-option-refusals
  (let ((ok32 (make-string 32 :initial-element #\a))
        (ok512 (make-string 512 :initial-element #\Z)))
    (ok (typep (gated-transport) 'hc:canvas-htmx-transport))
    (ok (typep (hc:make-canvas-htmx-transport :token ok32) 'hc:canvas-htmx-transport) "32 characters")
    (ok (typep (hc:make-canvas-htmx-transport :token ok512) 'hc:canvas-htmx-transport) "512 characters")
    (ok (typep (hc:make-canvas-htmx-transport :token (http-protocol:make-secret +token+))
               'hc:canvas-htmx-transport)
        "a SECRET")
    (dolist (bad (list (make-string 31 :initial-element #\a)
                       (make-string 513 :initial-element #\a)
                       (s+ (make-string 31 :initial-element #\a) " ")
                       (s+ (make-string 31 :initial-element #\a) ";")
                       (s+ (make-string 31 :initial-element #\a) "=")
                       (s+ (make-string 31 :initial-element #\a) "%")
                       (s+ (make-string 31 :initial-element #\a) "é")
                       (http-protocol:make-secret "short")
                       42 :token t))
      (ok (signals (hc:make-canvas-htmx-transport :token bad) 'type-error) "canvas")
      (ok (signals (h:make-htmx-transport :token bad) 'type-error) "core")
      (ok (signals (h:htmx-app (transport) (handlers) :token bad) 'type-error) "app")
      (ok (signals (h:htmx-token-url "/a/B::C" bad) 'type-error) "token url"))
    (dolist (bad (list "" "a;b" "a b" "a=b" "é" 7 nil))
      (ok (signals (gated-transport :token-name bad) 'type-error) (format nil "name ~S" bad))
      (ok (signals (h:htmx-token-url "/a/B::C" +token+ :token-name bad) 'type-error)))
    (ok (signals (h:htmx-token-url "/a/B::C#top" +token+) 'type-error) "a URL with a fragment")
    (ok (signals (h:htmx-token-url 42 +token+) 'type-error))))

(deftest token-is-kept-secret
  (let* ((tx (gated-transport))
         (secret (h:htmx-transport-token tx)))
    (ok (http-protocol:secret-p secret))
    (ok (equal +token+ (http-protocol:reveal secret)))
    (ok (not (contains +token+ (princ-to-string secret))) "prints redacted")
    (ok (not (contains +token+ (prin1-to-string tx))))))

(deftest gate-refuses-without-a-cookie
  (setf *gated-calls* 0)
  (let ((c (gated-client)))
    (dolist (case (list (list "fragment" (h:htmx-request c (m "GATED-CANVAS") '(:q "1")))
                        (list "page" (visit c +gated-url+))
                        (list "post" (h:htmx-request c (m "GATED-CANVAS") '(:q "1") :http-method :post))
                        (list "stream" (h:htmx-request c (m "GATED-TICKER") nil
                                                       :accept "text/event-stream"))
                        (list "asset" (h:htmx-request-env c (env :path "/canvas-assets/htmx.min.js")))
                        (list "unknown method (not 404)" (h:htmx-request c (m "NOPE") nil))
                        (list "outside the prefix" (h:htmx-request-env c (env :path "/elsewhere")))
                        (list "PUT (not 405)" (h:htmx-request-env c (env :method :put :path +gated-url+)))
                        (list "too large a body, never read (not 413)"
                              (h:htmx-request-env c (env :method :post :path +gated-url+
                                                         :content-type "application/x-www-form-urlencoded"
                                                         :body "q=1" :content-length 100000000)))))
      (destructuring-bind (label reply) case
        (ok (forbidden-p reply) label)
        (ok (equal +brief-csp+ (csp-of reply)) (s+ label ": with the CSP"))
        (ok (null (h:htmx-reply-events reply)) (s+ label ": no stream"))))
    (ok (= 0 *gated-calls*) "no handler was called")))

(deftest gate-cookie
  (setf *gated-calls* 0)
  (let ((c (gated-client)))
    (flet ((with-cookie (header)
             (h:htmx-request c (m "GATED-CANVAS") '(:q "1") :headers (list (cons "cookie" header)))))
      (let ((r (with-cookie (s+ "canvas-token=" +token+))))
        (ok (= 200 (h:htmx-reply-status r)))
        (ok (equal "<p>1</p>" (h:htmx-reply-body r)))
        (ok (= 1 *gated-calls*)))
      (ok (= 200 (h:htmx-reply-status (with-cookie (s+ "a=1; canvas-token=" +token+ "; b=2"))))
          "among other cookies")
      (ok (= 200 (h:htmx-reply-status (with-cookie (format nil "a=1;~C canvas-token=~A" #\Tab +token+))))
          "names trimmed of spaces and tabs")
      (ok (= 200 (h:htmx-reply-status (with-cookie (s+ "canvas-token=wrong; canvas-token=" +token+))))
          "some cookie of that name carries the token")
      (dolist (bad (list "" (subseq +token+ 0 42) (s+ +token+ "x") (string-upcase +token+)
                         (s+ (subseq +token+ 0 42) "D") (s+ "\"" +token+ "\"")))
        (ok (forbidden-p (with-cookie (s+ "canvas-token=" bad))) (format nil "value ~S" bad)))
      (ok (forbidden-p (with-cookie (s+ "canvas-tokens=" +token+))) "another name")
      (ok (forbidden-p (with-cookie (s+ "x-canvas-token=" +token+))) "another name"))
    (ok (forbidden-p (h:htmx-request c (m "GATED-CANVAS") nil
                                     :headers (list (cons "x-token" +token+))))
        "only the cookie counts")
    (let ((r (h:htmx-request c (m "GATED-TICKER") nil :accept "text/event-stream"
                                                      :headers (cookie +token+))))
      (ok (= 200 (h:htmx-reply-status r)))
      (ok (equal '(("row" . "x")) (h:htmx-reply-events r)) "a stream with the cookie"))
    (ok (equalp (canvas:asset-bytes "htmx.min.js")
                (h:htmx-reply-body (h:htmx-request-env
                                    c (env :path "/canvas-assets/htmx.min.js"
                                           :headers (cookie +token+)))))
        "an asset with the cookie")))

(deftest one-time-url-login
  (setf *gated-calls* 0)
  (let* ((c (gated-client))
         (url (h:htmx-token-url (s+ +gated-url+ "?q=%C3%A9") +token+))
         (r (visit c url)))
    (ok (equal (s+ +gated-url+ "?q=%C3%A9&canvas-token=" +token+) url))
    (ok (= 303 (h:htmx-reply-status r)))
    (ok (equal (list (cons "location" (s+ +gated-url+ "?q=%C3%A9"))
                     (cons "set-cookie" (s+ "canvas-token=" +token+ +cookie-attributes+))
                     (cons "cache-control" "no-store")
                     (cons "content-security-policy" +brief-csp+))
               (h:htmx-reply-headers r))
        "Location without the token, the cookie, no-store, the CSP; in that order")
    (ok (equal "" (h:htmx-reply-body r)) "no body")
    (ok (= 0 *gated-calls*) "the login calls nothing")
    (let ((page (visit c (hdr r "Location") :headers (cookie +token+))))
      (ok (= 200 (h:htmx-reply-status page)))
      (ok (contains "<p>é</p>" (h:htmx-reply-body page)) "the browser follows it with the cookie"))
    (ok (forbidden-p (visit c url)) "used: a second browser is refused")
    (let ((again (visit c url :headers (cookie +token+))))
      (ok (= 303 (h:htmx-reply-status again)) "used, but this browser has the cookie")
      (ok (equal (s+ +gated-url+ "?q=%C3%A9") (hdr again "Location")))
      (ok (null (hdr again "Set-Cookie")) "no cookie set again")
      (ok (equal "no-store" (hdr again "Cache-Control"))))))

(deftest one-time-url-location
  (flet ((location (query)
           (hdr (visit (gated-client) (s+ +gated-url+ "?" query)) "Location")))
    (ok (equal +gated-url+ (location (s+ "canvas-token=" +token+))) "only the token: no ?")
    (ok (equal (s+ +gated-url+ "?a=1&b=2") (location (s+ "a=1&canvas-token=" +token+ "&b=2")))
        "the other fields, in order")
    (ok (equal (s+ +gated-url+ "?flag&b=%2B") (location (s+ "flag&canvas-token=" +token+ "&b=%2B")))
        "raw, a field without = kept alone")))

(deftest one-time-url-failures
  (let ((c (gated-client)))
    (ok (forbidden-p (visit c (s+ +gated-url+ "?canvas-token=" (string-upcase +token+)))) "wrong token")
    (ok (forbidden-p (visit c (s+ +gated-url+ "?canvas-token=" +token+ "&canvas-token=" +token+)))
        "the field twice")
    (ok (forbidden-p (visit c (s+ +gated-url+ "?canvas-token=")) ) "empty")
    (ok (not (contains +token+ (h:htmx-reply-body (visit c (s+ +gated-url+ "?canvas-token=x")))))
        "nothing echoed")
    (ok (= 303 (h:htmx-reply-status (visit c (h:htmx-token-url +gated-url+ +token+))))
        "failed attempts do not use the URL"))
  (dolist (path (list "//evil.example/x" "/\\evil.example/x"))
    (let ((c (gated-client)))
      (ok (forbidden-p (h:htmx-request-env c (env :path path :query (s+ "canvas-token=" +token+))))
          (format nil "no open redirect: ~A" path))
      (ok (= 303 (h:htmx-reply-status (visit c (h:htmx-token-url +gated-url+ +token+))))
          "and the URL is still unused"))))

(deftest one-time-url-secure-over-https
  (let* ((c (gated-client))
         (r (h:htmx-request-env c (append (list :url-scheme "https")
                                          (env :path +gated-url+
                                               :query (s+ "canvas-token=" +token+))))))
    (ok (= 303 (h:htmx-reply-status r)))
    (ok (equal (s+ "canvas-token=" +token+ +cookie-attributes+ "; Secure") (hdr r "Set-Cookie"))))
  (ok (equal (s+ "canvas-token=" +token+ +cookie-attributes+)
             (hdr (visit (gated-client) (h:htmx-token-url +gated-url+ +token+)) "Set-Cookie"))
      "plain http (loopback): no Secure"))

(deftest one-time-url-per-app
  (let* ((tx (gated-transport))
         (a (gated-client tx))
         (b (gated-client tx))
         (url (h:htmx-token-url +gated-url+ +token+)))
    (ok (= 303 (h:htmx-reply-status (visit a url))))
    (ok (= 303 (h:htmx-reply-status (visit b url))) "another app over the same transport")
    (ok (forbidden-p (visit a url)))
    (ok (forbidden-p (visit b url)))))

(deftest token-name
  (let* ((c (gated-client (gated-transport :token-name "run-7")))
         (r (visit c (h:htmx-token-url +gated-url+ +token+ :token-name "run-7"))))
    (ok (equal "run-7" (h:htmx-transport-token-name (gated-transport :token-name "run-7"))))
    (ok (= 303 (h:htmx-reply-status r)))
    (ok (equal (s+ "run-7=" +token+ +cookie-attributes+) (hdr r "Set-Cookie")))
    (ok (= 200 (h:htmx-reply-status (visit c +gated-url+ :headers (cookie +token+ "run-7")))))
    (ok (forbidden-p (visit c +gated-url+ :headers (cookie +token+))) "the default name is not it")
    (ok (forbidden-p (visit c (h:htmx-token-url +gated-url+ +token+)))
        "nor is the default field")))

(deftest htmx-app-token-overrides-the-transport
  (let* ((open-tx (canvas-transport))
         (gated (gated-client open-tx :token +token+)))
    (ok (forbidden-p (visit gated +gated-url+)) "app :token on an open transport")
    (ok (= 200 (h:htmx-reply-status (visit gated +gated-url+ :headers (cookie +token+))))))
  (ok (= 200 (h:htmx-reply-status (visit (gated-client (gated-transport) :token nil) +gated-url+)))
      "app :token nil opens a gated transport")
  (let ((c (gated-client (gated-transport) :token-name "app-1")))
    (ok (= 200 (h:htmx-reply-status (visit c +gated-url+ :headers (cookie +token+ "app-1")))))
    (ok (forbidden-p (visit c +gated-url+ :headers (cookie +token+))))))

(deftest core-transport-gate
  (let* ((tx (transport :token +token+))
         (c (client :transport tx)))
    (ok (= 403 (h:htmx-reply-status (h:htmx-request c (m "GREET") '(:name "Ann")))))
    (ok (null (csp-of (h:htmx-request c (m "GREET") nil))) "the core sends no CSP by default")
    (ok (equal "<p>Hello, Ann</p>"
               (h:htmx-reply-body (h:htmx-request c (m "GREET") '(:name "Ann")
                                                  :headers (cookie +token+)))))
    (let ((r (h:htmx-request-url c (h:htmx-token-url (s+ +prefix+ "RPC-BACKEND-HTMX%2FTESTS::GREET")
                                                     +token+))))
      (ok (= 303 (h:htmx-reply-status r)))
      (ok (equal (s+ +prefix+ "RPC-BACKEND-HTMX%2FTESTS::GREET") (hdr r "Location"))))))

(deftest gate-over-rpc-serve
  (let* ((tx (gated-transport))
         (server (rpc:backend-rpc-serve tx (gated-handlers) :host "127.0.0.1" :port 18083
                                                            :backend (make-instance 'fake-server-backend)))
         (c (h:make-htmx-client (http-server-protocol:server-app server)
                                :codec (h:htmx-transport-codec tx))))
    (ok (forbidden-p (visit c +gated-url+)))
    (ok (= 200 (h:htmx-reply-status (visit c +gated-url+ :headers (cookie +token+)))))))

(deftest jsonrpc-is-not-gated
  (ok (equal "<p>1</p>" (funcall (h:jsonrpc-handler (gated-transport) (gated-handlers))
                                 (m "GATED-CANVAS") (json-object "q" "1")))))
