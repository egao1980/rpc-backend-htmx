(in-package #:rpc-backend-htmx/tests)

;;; 0.3.0 (rpc-backend-htmx#4): the Content-Security-Policy header on every
;;; response of the app, SSE streams and assets included. The canvas transport
;;; sends the brief's policy by default; the core transport is opt-in. Rules:
;;; src/server.lisp (HTMX-APP, Content-Security-Policy), src/canvas/canvas.lisp
;;; (Security).

(defparameter +brief-csp+
  "default-src 'self'; script-src 'self'; style-src 'self'; img-src 'self' data:; connect-src 'self'; frame-ancestors 'none'"
  "cl-stack docs/capabilities/canvas.md § H4h-2, verbatim.")

(defun csp-of (reply) (hdr reply "Content-Security-Policy"))

(defun csp-count (reply)
  (count "content-security-policy" (h:htmx-reply-headers reply) :key #'car :test #'string-equal))

(defun last-header (reply) (car (last (h:htmx-reply-headers reply))))

(defun csp-handlers ()
  (h:make-htmx-handlers 'people 'boom 'coerce-canvas 'dashboard '(bump :mode :notify)
                        '(ticker :mode :call-stream) '(ticker-fail :mode :call-stream)))

(defun csp-client (&optional (tx (canvas-transport)) &rest app-keys)
  (h:make-htmx-client (apply #'h:htmx-app tx (csp-handlers) app-keys)
                      :codec (h:htmx-transport-codec tx)))

(defun canvas-path (name) (s+ "/canvas/" (m name)))

(defun csp-replies (c)
  "(label status reply) for every kind of response the canvas app gives."
  (list (list "fragment" 200 (h:htmx-request c (m "PEOPLE") '(:sort "a")))
        (list "full page" 200 (h:htmx-request c (m "PEOPLE") '(:sort "a") :hx-request nil))
        (list "zero-arg page" 200 (h:htmx-request c (m "DASHBOARD") nil :hx-request nil))
        (list "post" 200 (h:htmx-request c (m "PEOPLE") '(:sort "a") :http-method :post))
        (list "notify" 204 (h:htmx-request c (m "BUMP") nil :http-method :post))
        (list "unknown param" 400 (h:htmx-request c (m "PEOPLE") '(:x "1")))
        (list "unknown method" 404 (h:htmx-request c (m "NOPE") nil))
        (list "outside the prefix" 404 (h:htmx-request-env c (env :path "/elsewhere/A::B")))
        (list "method not allowed" 405 (h:htmx-request-env c (env :method :put
                                                                  :path (canvas-path "PEOPLE"))))
        (list "stream without accept" 406 (h:htmx-request c (m "TICKER") nil))
        (list "coercion" 422 (h:htmx-request c (m "COERCE-CANVAS") '(:page "x")))
        (list "handler error" 500 (h:htmx-request c (m "BOOM") nil))
        (list "asset" 200 (h:htmx-request-env c (env :path "/canvas-assets/htmx.min.js")))
        (list "missing asset" 404 (h:htmx-request-env c (env :path "/canvas-assets/nope.js")))
        (list "stream" 200 (h:htmx-request c (m "TICKER") '(:n "2") :accept "text/event-stream"))
        (list "stream error" 200 (h:htmx-request c (m "TICKER-FAIL") nil
                                                 :accept "text/event-stream"))))

(deftest default-csp-is-the-brief-policy
  (ok (equal +brief-csp+ h:+default-csp+)))

(deftest canvas-app-sends-csp-on-every-response
  (dolist (case (csp-replies (csp-client)))
    (destructuring-bind (label status reply) case
      (ok (= status (h:htmx-reply-status reply)) label)
      (ok (equal +brief-csp+ (csp-of reply)) label)
      (ok (equal (cons "content-security-policy" +brief-csp+) (last-header reply))
          (s+ label ": the last header"))
      (ok (= 1 (csp-count reply)) (s+ label ": exactly once")))))

(deftest csp-leaves-bodies-and-events-alone
  (let ((on (csp-replies (csp-client)))
        (off (csp-replies (csp-client (hc:make-canvas-htmx-transport :csp nil)))))
    (loop for (label nil a) in on
          for (nil nil b) in off
          do (ok (equalp (h:htmx-reply-body a) (h:htmx-reply-body b)) (s+ label ": same body"))
             (ok (null (csp-of b)) (s+ label ": :csp nil sends none"))
             (ok (equal (h:htmx-reply-headers b) (butlast (h:htmx-reply-headers a)))
                 (s+ label ": the only header added"))))
  (let ((c (csp-client)))
    (ok (equal +people-page-0.1.0+ (plain-page c (m "PEOPLE") '(:sort "a")))
        "the full page is byte-identical to 0.1.0")
    (ok (equal '(("row" . "<li>1</li>") ("row" . "<li>2</li>"))
               (h:htmx-reply-events (h:htmx-request c (m "TICKER") '(:n "2")
                                                    :accept "text/event-stream")))
        "events unchanged")
    (ok (equalp (canvas:asset-bytes "htmx.min.js")
                (h:htmx-reply-body (h:htmx-request-env c (env :path "/canvas-assets/htmx.min.js"))))
        "asset octets unchanged"))
  (ok (equal '(("content-type" . "text/html; charset=utf-8"))
             (h:htmx-reply-headers (h:htmx-request (csp-client (hc:make-canvas-htmx-transport :csp nil))
                                                   (m "PEOPLE") '(:sort "a"))))
      ":csp nil: 0.2.1's headers exactly"))

(deftest csp-transport-options
  (ok (equal +brief-csp+ (h:htmx-transport-csp (hc:make-canvas-htmx-transport))) "canvas: on by default")
  (ok (equal +brief-csp+ (h:htmx-transport-csp (hc:make-canvas-htmx-transport :csp t))))
  (ok (null (h:htmx-transport-csp (hc:make-canvas-htmx-transport :csp nil))))
  (ok (equal "default-src 'none'"
             (h:htmx-transport-csp (hc:make-canvas-htmx-transport :csp "default-src 'none'"))))
  (ok (null (h:htmx-transport-csp (h:make-htmx-transport))) "core: opt-in")
  (ok (equal +brief-csp+ (h:htmx-transport-csp (h:make-htmx-transport :csp t))))
  (ok (equal "img-src 'self'" (h:htmx-transport-csp (h:make-htmx-transport :csp "img-src 'self'"))))
  (dolist (bad (list 42 "" (format nil "a~%b") (format nil "a~Cb" #\Return)
                     (format nil "a~Cb" #\Tab) (format nil "a~Cb" (code-char 127)) :yes '("x")))
    (ok (signals (h:make-htmx-transport :csp bad) 'type-error) (format nil "core ~S" bad))
    (ok (signals (hc:make-canvas-htmx-transport :csp bad) 'type-error) (format nil "canvas ~S" bad))
    (ok (signals (h:htmx-app (transport) (handlers) :csp bad) 'type-error) (format nil "app ~S" bad))))

(deftest core-transport-csp-is-opt-in
  (ok (null (csp-of (h:htmx-request (client) (m "GREET") '(:name "Ann")))) "no header by default")
  (let ((c (client :transport (transport :csp t))))
    (ok (equal +brief-csp+ (csp-of (h:htmx-request c (m "GREET") '(:name "Ann")))))
    (ok (equal +brief-csp+ (csp-of (h:htmx-request c (m "TICKER") nil :accept "text/event-stream")))
        "core streams too")
    (ok (equal +brief-csp+ (csp-of (h:htmx-request c (m "NOPE") nil))) "core errors too"))
  (ok (equal "default-src 'none'"
             (csp-of (h:htmx-request (client :transport (transport :csp "default-src 'none'"))
                                     (m "GREET") nil)))
      "a policy string is sent as given"))

(deftest htmx-app-csp-overrides-the-transport
  (let ((tx (canvas-transport)))
    (ok (null (csp-of (h:htmx-request (csp-client tx :csp nil) (m "PEOPLE") nil))) ":csp nil")
    (ok (equal "default-src 'none'"
               (csp-of (h:htmx-request (csp-client tx :csp "default-src 'none'") (m "PEOPLE") nil)))
        "a string")
    (ok (equal +brief-csp+ (csp-of (h:htmx-request (csp-client tx) (m "PEOPLE") nil)))
        "not supplied: the transport's"))
  (let* ((tx (transport))
         (c (h:make-htmx-client (h:htmx-app tx (handlers) :csp t) :codec (h:htmx-transport-codec tx))))
    (ok (equal +brief-csp+ (csp-of (h:htmx-request c (m "GREET") nil))) "core transport, app :csp t")))

(deftest csp-over-rpc-serve
  (let* ((tx (canvas-transport))
         (server (rpc:backend-rpc-serve tx (csp-handlers) :host "127.0.0.1" :port 18082
                                                          :backend (make-instance 'fake-server-backend)))
         (c (h:make-htmx-client (http-server-protocol:server-app server)
                                :codec (h:htmx-transport-codec tx))))
    (ok (equal +brief-csp+ (csp-of (h:htmx-request c (m "PEOPLE") nil))))))

(deftest csp-with-the-413
  (let* ((tx (hc:make-canvas-htmx-transport :max-params 1))
         (r (h:htmx-request (csp-client tx) (m "PEOPLE") '(:sort "a" :page "2"))))
    (ok (= 413 (h:htmx-reply-status r)))
    (ok (equal +brief-csp+ (csp-of r)))))
