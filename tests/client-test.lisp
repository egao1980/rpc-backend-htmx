(in-package #:rpc-backend-htmx/tests)

(deftest client-is-an-rpc-transport
  (let ((c (client)))
    (ok (typep c 'rpc:rpc-transport))
    (ok (equal "<p>Hello, Bo</p>" (rpc:rpc-call (m "GREET") '(:name "Bo") :transport c)))
    (ok (signals (rpc:rpc-call (m "NOPE") nil :transport c) 'rpc:rpc-method-not-found))
    (ok (signals (rpc:rpc-call (m "BAD-PARAMS") nil :transport c) 'rpc:rpc-invalid-params))
    (ok (eql 500 (handler-case (rpc:rpc-call (m "BOOM") nil :transport c)
                   (h:htmx-error (e) (h:htmx-error-status e)))))
    (ok (typep (handler-case (rpc:rpc-call (m "BOOM") nil :transport c)
                 (h:htmx-error (e) (rpc:rpc-error-data e)))
               'h:htmx-reply)
        "the reply rides along as :data")))

(deftest client-notify
  (setf *bumps* 0)
  (ok (eq t (rpc:rpc-notify (m "BUMP") '(:by "2") :transport (client))))
  (ok (= 2 *bumps*)))

(deftest reply-headers-and-fragment
  (let ((r (h:htmx-request (client) (m "GREET") '(:name "Ann"))))
    (ok (equal (hdr r "content-type") (hdr r "CONTENT-TYPE")))
    (ok (null (hdr r "X-Missing")))
    (ok (every (lambda (pair) (equal (car pair) (string-downcase (car pair))))
               (h:htmx-reply-headers r)))
    (let ((html:*html-backend* (html-backend-plump:make-plump-backend)))
      (let ((doc (h:htmx-reply-fragment r)))
        (ok (html:html-document-p doc))
        (ok (equal "Hello, Ann" (html:element-text doc)))))
    (ok (null (h:htmx-reply-events r)) "not an event stream")))

(deftest client-request-url
  (let ((r (h:htmx-request-url (client) (s+ +prefix+ "RPC-BACKEND-HTMX%2FTESTS::GREET?name=A%20B"))))
    (ok (= 200 (h:htmx-reply-status r)))
    (ok (equal "<p>Hello, A B</p>" (h:htmx-reply-body r)))))
