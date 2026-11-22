(in-package #:rpc-backend-htmx/tests)

;;; Fixtures: canvas-style handler functions in this package, a handler table,
;;; a transport mounted at /htmx/, an in-process client, raw Clack envs, and a
;;; fake http-server backend (BACKEND-RPC-SERVE without sockets).

(defparameter +prefix+ "/htmx/")

(defun s+ (&rest strings)
  (apply #'concatenate 'string strings))

(defun m (name)
  "Method name of a handler in this package."
  (s+ "RPC-BACKEND-HTMX/TESTS::" name))

(defun contains (needle haystack)
  (and (stringp haystack) (search needle haystack) t))

(defun crlf (&rest lines)
  (format nil "~{~A~C~C~}" (loop for l in lines append (list l #\Return #\Linefeed))))

(defun text (string)
  (make-instance 'html:html-text :data string))

(defun elt* (tag attrs &rest children)
  "Raw html-protocol element; string children become text nodes."
  (html:make-html-element tag :attributes attrs
                              :children (mapcar (lambda (c) (if (stringp c) (text c) c))
                                                children)))

(defun plist-without-aok (plist)
  (loop for (k v) on plist by #'cddr
        unless (eq k :allow-other-keys) collect k and collect v))

;;; Handlers

(defvar *seen* nil "Last (params metadata) CAPTURE saw.")
(defvar *bumps* 0)

(defun greet (&key (name "world"))
  (elt* "p" nil (s+ "Hello, " name)))

(defun echo-attr (&key (title ""))
  (elt* "span" (list (cons "title" title)) title))

(defun capture (&rest params &key &allow-other-keys)
  (setf *seen* (list (plist-without-aok params)
                     (h:htmx-message-metadata h:*htmx-request*)))
  "ok")

(defun with-headers (&key)
  (values (elt* "p" nil "saved")
          '(("HX-Trigger" . "{\"saved\":\"1\"}")
            ("HX-Retarget" . "#t")
            ("HX-Reswap" . "outerHTML")
            ("HX-Redirect" . "/next"))))

(defun bump (&key (by "1"))
  (incf *bumps* (parse-integer by))
  (values nil '(("HX-Trigger" . "bumped"))))

(defun boom (&key)
  (error "boom <b>&</b>"))

(defun bad-params (&key)
  (error 'rpc:rpc-invalid-params :message "need <id>"))

(defun bad-header (&key)
  (values "x" (list (cons "HX-Trigger" (format nil "a~C~CSet-Cookie: x=1" #\Return #\Linefeed)))))

(defun not-hx-header (&key)
  (values "x" '(("Set-Cookie" . "x=1"))))

(defun ticker (stream &key (n "2"))
  (loop for i from 1 to (parse-integer n)
        do (rpc:rpc-send stream (cons "row" (elt* "li" nil (princ-to-string i))))))

(defun ticker-hostile (stream &key (text ""))
  (rpc:rpc-send stream (cons "row" (elt* "p" nil text)))
  (rpc:rpc-send stream (cons "row" (elt* "p" nil "after"))))

(defun ticker-fail (stream &key)
  (rpc:rpc-send stream (cons "row" (elt* "p" nil "one")))
  (error "stream <boom>"))

(defun ticker-keepalive (stream &key)
  (rpc:rpc-send stream (cons "row" "a"))
  (h:htmx-stream-keepalive stream)
  (rpc:rpc-send stream (cons "row" "b")))

(defun not-listed (&key)
  "fbound but never in the table")

(defun handlers ()
  (h:make-htmx-handlers
   'greet 'echo-attr 'capture 'with-headers
   '(bump :mode :notify)
   'boom 'bad-params 'bad-header 'not-hx-header
   '(ticker :mode :call-stream)
   '(ticker-hostile :mode :call-stream)
   '(ticker-fail :mode :call-stream)
   '(ticker-keepalive :mode :call-stream)
   (list "X::LAMBDA" (lambda (&key) "lam"))))

(defun transport (&rest keys)
  (apply #'h:make-htmx-transport :prefix +prefix+ keys))

(defun client (&key (transport (transport)) (handler (handlers)) stream-handler)
  (h:make-htmx-client (h:htmx-app transport handler :stream-handler stream-handler)
                      :codec (h:htmx-transport-codec transport)))

(defun codec (&rest keys)
  (apply #'h:make-htmx-codec :prefix +prefix+ keys))

;;; Raw Clack envs

(defun headers-table (alist)
  (let ((h (make-hash-table :test 'equal)))
    (loop for (k . v) in alist do (setf (gethash (string-downcase k) h) v))
    h))

(defun octets (string)
  (stack-encoding:encode-to-octets string :encoding :utf-8))

(defun env (&key (method :get) (path (s+ +prefix+ (m "GREET"))) query headers body
              content-type (content-length :auto))
  "A Clack env as a server would build it. BODY a string (UTF-8) or octets."
  (let* ((bytes (cond ((null body) nil)
                      ((stringp body) (octets body))
                      (t (coerce body '(simple-array (unsigned-byte 8) (*))))))
         (len (if (eq content-length :auto) (and bytes (length bytes)) content-length))
         (hs (append headers
                     (when content-type (list (cons "content-type" content-type)))
                     (when len (list (cons "content-length" (princ-to-string len)))))))
    (append (list :request-method method :script-name "" :path-info path
                  :query-string query
                  :request-uri (if query (s+ path "?" query) path)
                  :server-name "localhost" :server-port 80 :server-protocol :http/1.1
                  :url-scheme "http" :remote-addr "127.0.0.1"
                  :headers (headers-table hs))
            (when content-type (list :content-type content-type))
            (when len (list :content-length len))
            (when bytes (list :raw-body (http-protocol:make-octet-input-stream bytes))))))

(defun decode (env &optional (codec (codec)))
  (rpc:decode-message-using-codec codec env))

(defun hdr (reply name)
  (h:htmx-reply-header reply name))

;;; Fake http-server backend: records the app, never binds a socket.

(defclass fake-server-backend (http-server-protocol:http-server-backend) ())
(defclass fake-server (http-server-protocol:http-server) ())

(defmethod http-server-protocol:backend-make-server
    ((backend fake-server-backend) &key host port app ssl-cert ssl-key backlog)
  (declare (ignore ssl-cert ssl-key backlog))
  (make-instance 'fake-server :host host :port port :app app))

(defmethod http-server-protocol:start ((server fake-server) &key background)
  (declare (ignore background))
  (http-server-protocol:mark-running server t)
  server)
