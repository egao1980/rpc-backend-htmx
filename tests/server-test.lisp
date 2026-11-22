(in-package #:rpc-backend-htmx/tests)

(deftest get-fragment
  (let ((r (h:htmx-request (client) (m "GREET") '(:name "Ann"))))
    (ok (typep r 'h:htmx-reply))
    (ok (= 200 (h:htmx-reply-status r)))
    (ok (equal "text/html; charset=utf-8" (hdr r "Content-Type")))
    (ok (equal "<p>Hello, Ann</p>" (h:htmx-reply-body r)))))

(deftest post-forms-end-to-end
  (let ((c (client)))
    (dolist (encoding '(:urlencoded :multipart))
      (let ((r (h:htmx-request c (m "GREET") '(:name "Bo") :http-method :post :encoding encoding)))
        (ok (= 200 (h:htmx-reply-status r)) (format nil "~S" encoding))
        (ok (equal "<p>Hello, Bo</p>" (h:htmx-reply-body r)) (format nil "~S" encoding))))))

(deftest unknown-method-404
  (let ((c (client)))
    (dolist (method (list (m "NOPE") (m "NOT-LISTED") "COMMON-LISP::CAR"))
      (let ((r (h:htmx-request c method nil)))
        (ok (= 404 (h:htmx-reply-status r)) method)
        (ok (contains "Method not found" (h:htmx-reply-body r)) method)
        (ok (equal "#canvas-error" (hdr r "HX-Retarget")) method)))
    (ok (= 404 (h:htmx-reply-status (h:htmx-request-env c (env :path "/other/A::B")))))))

(deftest method-not-allowed
  (let ((r (h:htmx-request-env (client) (env :method :put))))
    (ok (= 405 (h:htmx-reply-status r)))
    (ok (equal "GET, POST" (hdr r "Allow")))))

(deftest request-metadata-reaches-handler
  (setf *seen* nil)
  (let ((r (h:htmx-request (client) (m "CAPTURE") '(:q "1")
                           :target "list" :trigger "btn" :trigger-name "go"
                           :current-url "http://localhost/page" :boosted t)))
    (ok (= 200 (h:htmx-reply-status r)))
    (ok (equal '((:q "1")
                 (:request t :target "list" :trigger "btn" :trigger-name "go"
                  :current-url "http://localhost/page" :boosted t))
               *seen*)))
  (h:htmx-request (client) (m "CAPTURE") nil :hx-request nil)
  (ok (equal '(nil nil) *seen*) "no HX headers, no metadata"))

(deftest response-metadata-headers
  (let ((r (h:htmx-request (client) (m "WITH-HEADERS") nil)))
    (ok (= 200 (h:htmx-reply-status r)))
    (ok (equal "<p>saved</p>" (h:htmx-reply-body r)))
    (ok (equal "{\"saved\":\"1\"}" (hdr r "HX-Trigger")))
    (ok (equal "#t" (hdr r "hx-retarget")))
    (ok (equal "outerHTML" (hdr r "HX-Reswap")))
    (ok (equal "/next" (hdr r "HX-Redirect")))))

(deftest notify-mode
  (setf *bumps* 0)
  (let ((r (h:htmx-request (client) (m "BUMP") '(:by "3") :http-method :post)))
    (ok (= 204 (h:htmx-reply-status r)))
    (ok (equal "" (h:htmx-reply-body r)))
    (ok (equal "bumped" (hdr r "HX-Trigger")))
    (ok (= 3 *bumps*))))

(deftest stream-method-needs-accept
  (ok (= 406 (h:htmx-reply-status (h:htmx-request (client) (m "TICKER") nil)))))

(deftest function-handler
  (let ((c (client :handler (lambda (method params)
                              (if (equal method "A::B")
                                  (values (elt* "b" nil (getf params :x)) '(("HX-Trigger" . "fn")))
                                  (error 'rpc:rpc-method-not-found))))))
    (let ((r (h:htmx-request c "A::B" '(:x "1"))))
      (ok (equal "<b>1</b>" (h:htmx-reply-body r)))
      (ok (equal "fn" (hdr r "HX-Trigger"))))
    (ok (= 404 (h:htmx-reply-status (h:htmx-request c "A::C" nil))))
    (ok (= 404 (h:htmx-reply-status (h:htmx-request c "A::B" nil :accept "text/event-stream")))
        "no stream handler")))

(deftest fragment-even-without-hx-request
  (ok (equal "<p>Hello, Ann</p>"
             (h:htmx-reply-body (h:htmx-request (client) (m "GREET") '(:name "Ann") :hx-request nil)))
      "the core has no page; rpc-backend-htmx/canvas adds it"))

(deftest serve-through-http-server-protocol
  (let* ((tx (transport))
         (server (rpc:backend-rpc-serve tx (handlers) :host "127.0.0.1" :port 18081
                                                       :backend (make-instance 'fake-server-backend))))
    (ok (typep server 'http-server-protocol:http-server))
    (ok (http-server-protocol:running-p server))
    (ok (= 18081 (http-server-protocol:server-port server)))
    (let ((c (h:make-htmx-client (http-server-protocol:server-app server)
                                 :codec (h:htmx-transport-codec tx))))
      (ok (equal "<p>Hello, Ann</p>" (h:htmx-reply-body (h:htmx-request c (m "GREET") '(:name "Ann")))))))
  (let ((http-server-protocol:*http-server-backend* (make-instance 'fake-server-backend)))
    (let* ((tx (transport))
           (server (rpc:rpc-serve-stream
                    (lambda (mode method params stream)
                      (rpc:rpc-send stream (cons "tick" (format nil "~A ~A ~A" mode method
                                                                (getf params :n)))))
                    :transport tx))
           (c (h:make-htmx-client (http-server-protocol:server-app server)
                                  :codec (h:htmx-transport-codec tx))))
      (ok (equal '(("tick" . "CALL-STREAM A::B 7"))
                 (h:htmx-reply-events
                  (h:htmx-request c "A::B" '(:n "7") :accept "text/event-stream"))))
      (ok (= 404 (h:htmx-reply-status (h:htmx-request c "A::B" nil)))
          "serve-stream has no unary handler"))))
