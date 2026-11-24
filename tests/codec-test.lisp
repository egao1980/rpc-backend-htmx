(in-package #:rpc-backend-htmx/tests)

(deftest decode-get-query
  (let ((msg (decode (env :query "name=Ann+Lee&x=%C3%A9&=dropped"))))
    (ok (typep msg 'h:htmx-message))
    (ok (equal (m "GREET") (h:htmx-message-method msg)))
    (ok (equal '(:name "Ann Lee" :x "é") (h:htmx-message-params msg)))
    (ok (eq :get (h:htmx-message-http-method msg)))
    (ok (eq :call-response (h:htmx-message-mode msg)))
    (ok (null (h:htmx-message-metadata msg)))))

(deftest decode-post-urlencoded
  (let ((msg (decode (env :method :post :query "a=1"
                          :content-type "application/x-www-form-urlencoded; charset=UTF-8"
                          :body "b=two+words&a=3"))))
    (ok (eq :post (h:htmx-message-http-method msg)))
    (ok (equal '(:a "3" :b "two words") (h:htmx-message-params msg))
        "query first, body replaces in place")))

(deftest decode-post-multipart
  ;; 0.1 also had a part with filename="n.txt" here, read as text ("a filename
  ;; is ignored"). 0.2.0 makes such a part a file: multipart-test.lisp.
  (let* ((body (crlf "--XyZ"
                     "Content-Disposition: form-data; name=\"name\""
                     ""
                     "Zoë"
                     "--XyZ"
                     "Content-Disposition: form-data; name=\"note\""
                     "Content-Type: text/plain"
                     ""
                     "line"
                     "--XyZ--"))
         (msg (decode (env :method :post :body body
                           :content-type "multipart/form-data; boundary=XyZ"))))
    (ok (equal '(:name "Zoë" :note "line") (h:htmx-message-params msg)))))

(deftest codec-round-trips
  (let ((codec (codec)))
    (dolist (case '((:get :urlencoded) (:post :urlencoded) (:post :multipart)))
      (destructuring-bind (http-method encoding) case
        (let* ((env (rpc:encode-request-using-codec
                     codec (m "GREET") '(:name "Zoë & <co>" :page 2 :skip nil)
                     :http-method http-method :encoding encoding))
               (msg (decode env codec)))
          (ok (eq http-method (getf env :request-method)) (format nil "~S" case))
          (ok (equal (m "GREET") (h:htmx-message-method msg)) (format nil "~S" case))
          (ok (equal '(:name "Zoë & <co>" :page "2") (h:htmx-message-params msg))
              (format nil "~S" case)))))
    (ok (equal (m "GREET")
               (h:htmx-message-method
                (decode (rpc:encode-request-using-codec codec 'greet nil) codec)))
        "a symbol names its method")
    (let ((env (rpc:encode-notification-using-codec codec (m "BUMP") '(:by "2"))))
      (ok (eq :post (getf env :request-method)))
      (ok (equal '(:by "2") (h:htmx-message-params (decode env codec)))))))

(deftest decode-metadata
  (let ((msg (decode (env :headers '(("HX-Boosted" . "true")
                                     ("HX-Current-URL" . "http://localhost/page")
                                     ("HX-Trigger-Name" . "go")
                                     ("HX-Trigger" . "btn")
                                     ("HX-Target" . "list")
                                     ("HX-Request" . "true")
                                     ("X-Other" . "ignored"))))))
    (ok (equal '(:request t :target "list" :trigger "btn" :trigger-name "go"
                 :current-url "http://localhost/page" :boosted t)
               (h:htmx-message-metadata msg))))
  (let ((env (rpc:encode-request-using-codec
              (codec) (m "GREET") nil
              :metadata '(:request t :target "list" :current-url "http://localhost/"))))
    (ok (equal '(:request t :target "list" :current-url "http://localhost/")
               (h:htmx-message-metadata (decode env))))))

(deftest decode-mode-from-accept
  (ok (eq :call-stream
          (h:htmx-message-mode
           (decode (env :headers '(("Accept" . "text/event-stream")))))))
  (ok (eq :call-response
          (h:htmx-message-mode (decode (env :headers '(("Accept" . "text/html"))))))))

(deftest decode-refusals
  (ok (signals (decode (env :path "/elsewhere/A::B")) 'rpc:rpc-method-not-found))
  (ok (signals (decode (env :path (s+ +prefix+ "nocolons"))) 'rpc:rpc-method-not-found))
  (ok (signals (decode (env :path (s+ +prefix+ "::x"))) 'rpc:rpc-method-not-found))
  (ok (signals (decode (env :path (s+ +prefix+ "x::"))) 'rpc:rpc-method-not-found))
  (ok (signals (decode (env :method :put)) 'h:htmx-method-not-allowed))
  (ok (signals (decode (env :method :post :content-type "application/json" :body "{}"))
               'h:htmx-unsupported-media-type))
  (ok (signals (decode (env :query "a=%ZZ")) 'h:htmx-bad-request))
  (ok (null (h:htmx-message-params (decode (env :method :post))))
      "an empty POST needs no content type"))

(deftest encode-response
  (let ((res (rpc:encode-response-using-codec
              (codec) (list (elt* "p" nil "a") "b<")
              :headers '(("HX-Retarget" . "#x") ("HX-Trigger" . "t")))))
    (ok (= 200 (first res)))
    (ok (equal '(:content-type "text/html; charset=utf-8" :hx-retarget "#x" :hx-trigger "t")
               (second res)))
    (ok (equal "<p>a</p>b&lt;" (apply #'s+ (third res)))))
  (ok (equal "" (apply #'s+ (third (rpc:encode-response-using-codec (codec) nil)))))
  (ok (= 201 (first (rpc:encode-response-using-codec (codec) "x" :status 201))))
  (ok (signals (rpc:encode-response-using-codec
                (codec) "x" :headers (list (cons "HX-Trigger" (format nil "a~%b"))))
               'h:htmx-error))
  (ok (signals (rpc:encode-response-using-codec (codec) "x" :headers '(("Set-Cookie" . "a=1")))
               'h:htmx-error)))

(deftest encode-error-response
  (let ((res (rpc:encode-error-response-using-codec (codec) -32601 "nope <x>")))
    (ok (= 404 (first res)))
    (ok (equal '(:content-type "text/html; charset=utf-8"
                 :hx-retarget "#canvas-error" :hx-reswap "innerHTML")
               (second res)))
    (ok (equal "<p role=\"alert\">nope &lt;x&gt;</p>" (apply #'s+ (third res)))))
  (ok (= 422 (first (rpc:encode-error-response-using-codec (codec) -32602 "m"))))
  (ok (= 400 (first (rpc:encode-error-response-using-codec (codec) -32700 "m"))))
  (ok (= 500 (first (rpc:encode-error-response-using-codec (codec) -32603 "m"))))
  (ok (= 413 (first (rpc:encode-error-response-using-codec (codec) 413 "m"))))
  (ok (equal '(:content-type "text/html; charset=utf-8" :hx-retarget "#err" :hx-reswap "outerHTML")
             (second (rpc:encode-error-response-using-codec
                      (codec) 500 "m" :target "#err" :swap "outerHTML")))))
