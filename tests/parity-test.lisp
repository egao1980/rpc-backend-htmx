(in-package #:rpc-backend-htmx/tests)

;;; The same handler table over JSON-RPC (rpc-protocol-json codec, rpc-backend-http app).

(defparameter +json+ rpc-protocol-json:*jsonrpc-codec*)

(defun json-object (&rest kvs)
  (let ((h (make-hash-table :test 'equal)))
    (loop for (k v) on kvs by #'cddr do (setf (gethash k h) v))
    h))

(defun jsonrpc (method params)
  "POST one JSON-RPC request to rpc-backend-http's app over JSONRPC-HANDLER → decoded reply."
  (let* ((app (rpc-backend-http:make-rpc-app (h:jsonrpc-handler (transport) (handlers))
                                             :path "/rpc"))
         (body (rpc:encode-request-using-codec +json+ method params :id 1))
         (res (funcall app (list :request-method :post :path-info "/rpc" :raw-body body
                                 :headers (make-hash-table :test 'equal)))))
    (rpc:decode-message-using-codec +json+ (first (third res)))))

(deftest jsonrpc-parity
  (dolist (name '("Ann" "<i>Zoë</i> & co"))
    (let ((htmx (h:htmx-reply-body (h:htmx-request (client) (m "GREET") (list :name name))))
          (json (gethash "result" (jsonrpc (m "GREET") (json-object "name" name)))))
      (ok (equal htmx json) name)))
  (ok (equal (h:htmx-reply-body (h:htmx-request (client) (m "ECHO-ATTR") '(:title "\"q\"")))
             (gethash "result" (jsonrpc (m "ECHO-ATTR") (json-object "title" "\"q\""))))))

(deftest jsonrpc-handler-direct
  (let ((fn (h:jsonrpc-handler (transport) (handlers))))
    (ok (equal "<p>Hello, world</p>" (funcall fn (m "GREET") nil)))
    (ok (equal "<p>Hello, world</p>" (funcall fn (m "GREET") #())))
    (ok (equal "<p>Hello, 7</p>" (funcall fn (m "GREET") (json-object "name" 7))))
    (setf *bumps* 0)
    (ok (equal "" (funcall fn (m "BUMP") (json-object "by" "4"))))
    (ok (= 4 *bumps*))))

(deftest jsonrpc-errors
  (flet ((code (method params)
           (gethash "code" (gethash "error" (jsonrpc method params)))))
    (ok (= -32601 (code (m "NOPE") nil)))
    (ok (= -32601 (code (m "NOT-LISTED") nil)) "the same allowlist")
    (ok (= -32601 (code (m "TICKER") nil)) "streams are not JSON-RPC unary")
    (ok (= -32602 (code (m "GREET") (json-object "name" (vector 1 2)))))
    (ok (= -32602 (code (m "GREET") (vector "positional"))))
    (ok (= -32602 (code (m "BAD-PARAMS") nil)))))
