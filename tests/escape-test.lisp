(in-package #:rpc-backend-htmx/tests)

(deftest hostile-param-in-text
  (let ((body (h:htmx-reply-body
               (h:htmx-request (client) (m "GREET") '(:name "<script>alert(1)</script>")))))
    (ok (equal "<p>Hello, &lt;script&gt;alert(1)&lt;/script&gt;</p>" body))
    (ok (not (contains "<script" body)))))

(deftest hostile-param-in-attribute
  (ok (equal "<span title=\"&quot; onmouseover=&quot;x() &lt;\">\" onmouseover=\"x() &lt;</span>"
             (h:htmx-reply-body
              (h:htmx-request (client) (m "ECHO-ATTR") '(:title "\" onmouseover=\"x() <")
                              :http-method :post)))))

(deftest hostile-method-name
  (let ((r (h:htmx-request-env (client) (env :path (s+ +prefix+ "<img src=x>::y")))))
    (ok (= 404 (h:htmx-reply-status r)))
    (ok (contains "&lt;img src=x&gt;::y" (h:htmx-reply-body r)))
    (ok (not (contains "<img" (h:htmx-reply-body r))))))

(deftest hostile-param-in-stream
  (let* ((text (format nil "x~Cevent: pwn~C~Cdata: <b>" #\Return #\Return #\Linefeed))
         (events (h:htmx-reply-events
                  (h:htmx-request (client) (m "TICKER-HOSTILE") (list :text text)
                                  :accept "text/event-stream"))))
    (ok (= 2 (length events)))
    (ok (every (lambda (e) (equal "row" (car e))) events) "no injected event type")
    (ok (equal (format nil "<p>x~%event: pwn~%data: &lt;b&gt;</p>") (cdr (first events))))
    (ok (equal "<p>after</p>" (cdr (second events))))))

(deftest hostile-error-report
  (let ((r (h:htmx-request (client) (m "BOOM") nil)))
    (ok (not (contains "<b>" (h:htmx-reply-body r))))
    (ok (not (contains "BACKTRACE" (string-upcase (h:htmx-reply-body r)))))))
