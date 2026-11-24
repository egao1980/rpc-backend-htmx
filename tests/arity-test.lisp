(in-package #:rpc-backend-htmx/tests)

;;; 0.3.0 (rpc-backend-htmx#3): a canvas with no parameters. 0.2.1 called every
;;; handler as (apply fn :allow-other-keys t params), which (defun dashboard ()
;;; …) cannot take: 500 "invalid number of arguments: 2". Now its key set is
;;; empty, it is called with no arguments, and params sent to it are a clear
;;; 400. Rules: src/handlers.lisp (Key sets, Calling convention).

(defvar *pings* 0)

(defun dashboard ()
  (elt* "p" nil "dashboard"))

(defun ping-canvas ()
  (incf *pings*)
  (values nil '(("HX-Trigger" . "pinged"))))

(defun zero-ticker (stream)
  (rpc:rpc-send stream (cons "row" (elt* "li" nil "z"))))

(defun arity-handlers ()
  (h:make-htmx-handlers 'dashboard '(ping-canvas :mode :notify) '(zero-ticker :mode :call-stream)))

(defun arity-client (&optional (tx (transport)))
  (h:make-htmx-client (h:htmx-app tx (arity-handlers)) :codec (h:htmx-transport-codec tx)))

(deftest zero-arg-canvas-answers
  (let ((c (arity-client)))
    (ok (equal '(nil t) (multiple-value-list (h:htmx-handler-keys (arity-handlers) (m "DASHBOARD"))))
        "no keys")
    (let ((r (h:htmx-request c (m "DASHBOARD") nil)))
      (ok (= 200 (code-of r)) "hx-get")
      (ok (equal "<p>dashboard</p>" (body-of r))))
    (ok (equal "<p>dashboard</p>" (body-of (h:htmx-request c (m "DASHBOARD") nil :http-method :post)))
        "hx-post, empty form")
    (ok (equal "<p>dashboard</p>" (body-of (h:htmx-request c (m "DASHBOARD") nil
                                                           :http-method :post :encoding :multipart)))
        "hx-post, empty multipart form")
    (ok (equal "<p>dashboard</p>" (body-of (h:htmx-request c (m "DASHBOARD") nil :hx-request nil)))
        "a plain GET")
    (ok (equal "<p>dashboard</p>" (rpc:rpc-call (m "DASHBOARD") nil :transport c))
        "through the client as an rpc transport")))

(deftest zero-arg-canvas-page
  (let* ((tx (canvas-transport))
         (c (h:make-htmx-client (h:htmx-app tx (arity-handlers)) :codec (h:htmx-transport-codec tx)))
         (r (h:htmx-request c (m "DASHBOARD") nil :hx-request nil)))
    (ok (= 200 (code-of r)))
    (ok (string-equal "<!doctype html>" (subseq (body-of r) 0 (min 15 (length (body-of r))))))
    (ok (contains "<body><p>dashboard</p></body>" (body-of r)) "the canvas full page")))

(deftest zero-arg-canvas-with-params-is-400
  (let ((c (arity-client))
        (name (first (fresh-names 1))))
    (dolist (case (list (list "x" "GET" (h:htmx-request c (m "DASHBOARD") '(:x "1")))
                        (list "x" "POST" (h:htmx-request c (m "DASHBOARD") '(:x "1")
                                                         :http-method :post))
                        (list name "unmapped"
                              (h:htmx-request-env c (env :path (path-of "DASHBOARD")
                                                         :query (s+ name "=1"))))))
      (destructuring-bind (param label r) case
        (ok (= 400 (code-of r)) label)
        (ok (equal (s+ "<p role=\"alert\">htmx error 400: Unknown param " param "</p>") (body-of r))
            label)
        (ok (not (contains "invalid number of arguments" (body-of r))) label)))))

(deftest zero-arg-notify-and-stream
  (setf *pings* 0)
  (let ((c (arity-client)))
    (let ((r (h:htmx-request c (m "PING-CANVAS") nil :http-method :post)))
      (ok (= 204 (code-of r)))
      (ok (equal "pinged" (hdr r "HX-Trigger")))
      (ok (= 1 *pings*)))
    (ok (= 400 (code-of (h:htmx-request c (m "PING-CANVAS") '(:x "1") :http-method :post))))
    (ok (= 1 *pings*) "a refused :notify is not called")
    (let ((r (h:htmx-request c (m "ZERO-TICKER") nil :accept "text/event-stream")))
      (ok (= 200 (code-of r)))
      (ok (equal '(("row" . "<li>z</li>")) (h:htmx-reply-events r)) "(stream) alone"))
    (ok (= 400 (code-of (h:htmx-request c (m "ZERO-TICKER") '(:x "1") :accept "text/event-stream"))))))

(deftest zero-arg-over-jsonrpc
  (let ((fn (h:jsonrpc-handler (transport) (arity-handlers))))
    (ok (equal "<p>dashboard</p>" (funcall fn (m "DASHBOARD") nil)))
    (ok (equal "<p>dashboard</p>" (funcall fn (m "DASHBOARD") #())))
    (ok (equal "<p>dashboard</p>" (funcall fn (m "DASHBOARD") (json-object))))
    (ok (signals (funcall fn (m "DASHBOARD") (json-object "x" "1")) 'h:htmx-unknown-param))
    (setf *pings* 0)
    (ok (equal "" (funcall fn (m "PING-CANVAS") nil)))
    (ok (= 1 *pings*))))
