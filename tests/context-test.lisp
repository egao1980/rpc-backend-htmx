(in-package #:rpc-backend-htmx/tests)

;;; 0.5.0 (rpc-backend-htmx#15): request context for handlers. The client
;;; address (ENV :REMOTE-ADDR, or behind trusted proxies the right-most
;;; untrusted X-Forwarded-For hop) and Last-Event-ID in the metadata. Rules:
;;; src/codec.lisp (Client address, Metadata).

(defun context-client (&key trusted-proxies remote-addr (transport nil transport-p))
  (let ((tx (if transport-p transport (transport :trusted-proxies trusted-proxies))))
    (h:make-htmx-client (h:htmx-app tx (session-handlers))
                        :codec (h:htmx-transport-codec tx)
                        :remote-addr remote-addr)))

(defun address-seen (c &optional xff)
  "The client address WHOAMI saw for one request of C carrying X-Forwarded-For XFF."
  (call-body-with c "WHOAMI" (when xff (list (cons "x-forwarded-for" xff)))))

(defun call-body-with (c name headers)
  (h:htmx-reply-body (h:htmx-request c (m name) nil :headers headers)))

(defun p (text) (s+ "<p>" text "</p>"))

(deftest trusted-proxies-option
  (ok (null (h:htmx-codec-trusted-proxies (codec))) "none by default")
  (ok (null (h:htmx-codec-trusted-proxies (h:htmx-transport-codec (transport)))))
  (ok (null (h:htmx-codec-trusted-proxies (h:htmx-transport-codec (canvas-transport)))))
  (let* ((given (list "10.0.0.0/8" "127.0.0.1" "::1" "fd00::/8"))
         (tx (transport :trusted-proxies given))
         (got (h:htmx-codec-trusted-proxies (h:htmx-transport-codec tx))))
    (ok (equal given got) "the strings as given, in order")
    (ok (not (eq given got)) "a fresh list")
    (setf (first got) "x")
    (ok (equal "10.0.0.0/8" (first (h:htmx-codec-trusted-proxies (h:htmx-transport-codec tx))))
        "the reader's list is the caller's to change"))
  (ok (equal '("192.168.0.0/16")
             (h:htmx-codec-trusted-proxies
              (h:htmx-transport-codec (hc:make-canvas-htmx-transport :trusted-proxies '("192.168.0.0/16")))))
      "the canvas transport passes it on")
  (dolist (bad (list "10.0.0.0/8" '("nope") '("10.0.0.0/33") '("10.0.0.0/x") '("010.0.0.1")
                     '(42) '(:loopback) '("10.0.0.1" . "10.0.0.2") t 7))
    (ok (signals (h:make-htmx-codec :trusted-proxies bad) 'type-error) (format nil "codec ~S" bad))
    (ok (signals (transport :trusted-proxies bad) 'type-error) (format nil "transport ~S" bad))
    (ok (signals (hc:make-canvas-htmx-transport :trusted-proxies bad) 'type-error)
        (format nil "canvas ~S" bad))))

(deftest client-address-is-the-remote-addr
  (ok (equal (p "127.0.0.1") (address-seen (context-client))) "the codec env's address")
  (ok (equal (p "203.0.113.7") (address-seen (context-client :remote-addr "203.0.113.7")))
      "the client's :remote-addr")
  (ok (equal (p "203.0.113.7") (address-seen (context-client :remote-addr "203.0.113.7")
                                             "198.51.100.1"))
      "a spoofed X-Forwarded-For is ignored without :trusted-proxies")
  (ok (equal (p "10.0.0.2") (address-seen (context-client :remote-addr "10.0.0.2")
                                          "198.51.100.1"))
      "even from a private address: no proxy is trusted by default")
  (let ((c (context-client)))
    (ok (equal (p "nil") (h:htmx-reply-body
                          (h:htmx-request-env c (without-key (env :path (s+ +prefix+ (m "WHOAMI")))
                                                             :remote-addr))))
        "no :remote-addr in the env → NIL")))

(deftest-parametrize client-address-behind-trusted-proxies
    ((proxies remote xff expected)
     :ids ("one-proxy" "spoof-left-of-the-client" "two-proxies" "direct-client-xff-ignored"
           "proxy-without-xff" "all-trusted-left-most" "gap-stops-the-walk" "trimmed-empty-dropped"
           "port-is-not-an-address" "ipv6" "single-address-network" "cidr-boundary")
     ('("10.0.0.0/8") "10.0.0.2" "198.51.100.1" "198.51.100.1")
     ('("10.0.0.0/8") "10.0.0.2" "6.6.6.6, 198.51.100.1" "198.51.100.1")
     ('("10.0.0.0/8") "10.0.0.2" "198.51.100.1, 10.0.0.5" "198.51.100.1")
     ('("10.0.0.0/8") "203.0.113.7" "198.51.100.1" "203.0.113.7")
     ('("10.0.0.0/8") "10.0.0.2" nil "10.0.0.2")
     ('("10.0.0.0/8") "10.0.0.2" "10.0.0.9, 10.0.0.5" "10.0.0.9")
     ('("10.0.0.0/8") "10.0.0.2" "198.51.100.1, unknown, 10.0.0.5" "10.0.0.5")
     ('("10.0.0.0/8") "10.0.0.2" (format nil " 198.51.100.1 ,~C, " #\Tab) "198.51.100.1")
     ('("10.0.0.0/8") "10.0.0.2" "198.51.100.1:4711" "10.0.0.2")
     ('("::1" "fd00::/8") "::1" "2001:db8::7, fd00::3" "2001:db8::7")
     ('("127.0.0.1") "127.0.0.1" "198.51.100.1" "198.51.100.1")
     ('("10.0.0.0/30") "10.0.0.2" "10.0.0.4" "10.0.0.4"))
  (ok (equal (p expected) (address-seen (context-client :trusted-proxies proxies :remote-addr remote)
                                        xff))
      (format nil "remote ~A, X-Forwarded-For ~S" remote xff)))

(deftest client-address-in-streams-and-json-rpc
  (let ((c (context-client :trusted-proxies '("10.0.0.0/8") :remote-addr "10.0.0.2")))
    (ok (equal '(("addr" . "198.51.100.1"))
               (stream-events c "STREAM-WHOAMI" :headers '(("x-forwarded-for" . "198.51.100.1"))))
        "a :call-stream handler sees it"))
  (ok (equal "<p>nil</p>" (funcall (h:jsonrpc-handler (transport :trusted-proxies '("10.0.0.0/8"))
                                                      (session-handlers))
                                   (m "WHOAMI") nil))
      "JSON-RPC: no client address")
  (let ((message (decode (env :path (s+ +prefix+ (m "WHOAMI"))
                              :headers '(("x-forwarded-for" . "198.51.100.1"))))))
    (ok (equal "127.0.0.1" (h:htmx-message-client-address message)) "the codec decodes it")))

(deftest last-event-id-reaches-a-stream
  (ok (equal '("last-event-id" . :last-event-id) (car (last h:+request-metadata-headers+)))
      "appended to the metadata headers")
  (let ((c (context-client)))
    (ok (equal '(("id" . "41")) (stream-events c "STREAM-RESUME" :headers '(("last-event-id" . "41"))))
        "a reconnecting EventSource's Last-Event-ID")
    (ok (equal '(("id" . "none")) (stream-events c "STREAM-RESUME")) "none without the header")
    (h:htmx-request c (m "CAPTURE") nil :headers '(("last-event-id" . "a b")))
    (ok (equal '(:request t :last-event-id "a b") (second *seen*)) "the string as sent, last")
    (h:htmx-request c (m "CAPTURE") nil :target "t")
    (ok (equal '(:request t :target "t") (second *seen*)) "absent: the 0.4.0 plist")))
