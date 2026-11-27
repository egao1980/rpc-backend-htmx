(in-package #:rpc-backend-htmx/tests)

;;; 0.5.0: with sessions in force, an unsafe request a browser sent from
;;; another origin is refused (403, HTMX-CROSS-ORIGIN) before any session is
;;; begun or any body read. The rule is Go's CrossOriginProtection:
;;; Sec-Fetch-Site first, then Origin against Host. Rules: src/session.lisp
;;; (Cross-origin requests).

(defparameter +cross-origin-fragment+
  "<p role=\"alert\">htmx error 403: Cross-origin request</p>")

(defun origin-headers (fetch-site origin host)
  (append (when fetch-site (list (cons "sec-fetch-site" fetch-site)))
          (when origin (list (cons "origin" origin)))
          (when host (list (cons "host" host)))))

(deftest-parametrize cross-origin-rule
    ((http-method fetch-site origin host allowed)
     :ids ("post-no-headers" "same-origin" "none" "same-site" "cross-site" "fetch-site-wins-over-origin"
           "same-origin-wins-over-a-foreign-origin" "unknown-fetch-site" "fetch-site-is-exact"
           "origin-matches-host" "origin-with-port" "origin-host-any-case" "foreign-origin"
           "other-port" "null-origin" "origin-without-host" "origin-without-scheme"
           "get-is-safe" "get-cross-site-is-safe")
     (:post nil nil nil t)
     (:post "same-origin" nil nil t)
     (:post "none" nil nil t)
     (:post "same-site" nil nil nil)
     (:post "cross-site" nil nil nil)
     (:post "cross-site" "http://localhost" "localhost" nil)
     (:post "same-origin" "https://evil.example" "localhost" t)
     (:post "sideways" nil nil nil)
     (:post "Same-Origin" nil nil nil)
     (:post nil "http://localhost" "localhost" t)
     (:post nil "http://localhost:8080" "localhost:8080" t)
     (:post nil "http://LOCALHOST" "localhost" t)
     (:post nil "https://evil.example" "localhost" nil)
     (:post nil "http://localhost:8080" "localhost" nil)
     (:post nil "null" "localhost" nil)
     (:post nil "http://localhost" nil nil)
     (:post nil "localhost" "localhost" nil)
     (:get nil "https://evil.example" "localhost" t)
     (:get "cross-site" nil nil t))
  (with-clock ()
    (let* ((mgr (test-manager))
           (c (session-client (session-transport :sessions mgr)))
           (r (h:htmx-request c (m "REMEMBER") '(:note "x") :http-method http-method
                                                            :headers (origin-headers fetch-site origin host))))
      (if allowed
          (progn
            (ok (= 200 (h:htmx-reply-status r)) "allowed")
            (ok (equal "<p>saved</p>" (h:htmx-reply-body r))))
          (progn
            (ok (= 403 (h:htmx-reply-status r)) "refused")
            (ok (equal +cross-origin-fragment+ (h:htmx-reply-body r)))
            (ok (equal "#canvas-error" (hdr r "HX-Retarget")))
            (ok (null (set-cookies r)) "no session")
            (ok (= 0 (store-count (manager-store mgr))) "no store call"))))))

(deftest cross-origin-condition
  (let ((c (make-condition 'h:htmx-cross-origin)))
    (ok (typep c 'h:htmx-forbidden))
    (ok (= 403 (h:htmx-error-status c)))
    (ok (equal "htmx error 403: Cross-origin request" (princ-to-string c)))))

(deftest cross-origin-refusal-comes-first
  (with-clock ()
    (let* ((mgr (test-manager))
           (store (manager-store mgr))
           (c (session-client (hc:make-canvas-htmx-transport :sessions mgr)))
           (foreign '(("origin" . "https://evil.example") ("host" . "localhost"))))
      (call c "REMEMBER" :note "x")
      (let ((calls (store-count store)))
        (dolist (case (list (list "too large a body, never read (not 413)"
                                  (h:htmx-request-env
                                   c (env :method :post :path (s+ "/canvas/" (m "REMEMBER"))
                                          :headers foreign
                                          :content-type "application/x-www-form-urlencoded"
                                          :body "note=y" :content-length 100000000)))
                            (list "PUT (not 405)"
                                  (h:htmx-request-env c (env :method :put :path (s+ "/canvas/" (m "REMEMBER"))
                                                             :headers foreign)))
                            (list "outside the prefix (not 404)"
                                  (h:htmx-request-env c (env :method :post :path "/elsewhere" :headers foreign)))
                            (list "a stream"
                                  (h:htmx-request c (m "STREAM-RECALL") nil :http-method :post
                                                                            :accept "text/event-stream"
                                                                            :headers foreign))))
          (destructuring-bind (label reply) case
            (ok (= 403 (h:htmx-reply-status reply)) label)
            (ok (equal +cross-origin-fragment+ (h:htmx-reply-body reply)) label)
            (ok (equal +brief-csp+ (csp-of reply)) (s+ label ": with the CSP"))
            (ok (null (set-cookies reply)) (s+ label ": no Set-Cookie"))))
        (ok (= calls (store-count store)) "no session begun for a refused request"))
      (ok (equal "<p>x</p>" (call-body c "RECALL")) "the session is untouched"))))
