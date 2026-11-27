(in-package #:rpc-backend-htmx/tests)

;;; 0.5.0 (S1): visitor sessions (rpc-backend-htmx#19) and request context
;;; (#15). Shared fixtures for the S1 test files: a test clock, a session store
;;; that counts (and on demand fails) its calls, managers over it, handlers
;;; that use the session through the request, clients with a cookie jar.
;;; Rules: src/session.lisp, src/server.lisp (Sessions), src/codec.lisp
;;; (Client address, Metadata), src/client.lisp (Cookie jar).
;;; crypto-backend-ironclad (session ids) and json-backend-jzon (the stored
;;; record) are test dependencies: they install the backends sessions need.

;;; Time

(defparameter +t0+ 1800000000 "Unix seconds: the start of each test's clock.")

(defvar *now* +t0+ "The test clock's reading, Unix seconds.")

(defun test-clock () *now*)

(defmacro with-clock (() &body body)
  "BODY with the test clock at +T0+."
  `(let ((*now* +t0+)) ,@body))

;;; A session store that counts its calls and fails on demand. It keeps the
;;; records in a cache-session-store over an in-memory cache on the test clock.

(defclass counting-store (stack-session:session-store)
  ((inner :initarg :inner :reader inner-store)
   (calls :initform '() :accessor store-calls
          :documentation "The operations called, newest first (:load :save :delete).")
   (fail :initform '() :accessor store-fail
         :documentation "Operations that signal SESSION-STORE-ERROR instead.")))

(defun make-counting-store ()
  (make-instance 'counting-store
                 :inner (stack-session:make-cache-session-store
                         (stack-cache:make-in-memory-ttl-cache :clock #'test-clock))))

(defun store-count (store &optional operation)
  "How many calls STORE got (of OPERATION, or of any)."
  (if operation
      (count operation (store-calls store))
      (length (store-calls store))))

(defun %store-call (store operation thunk)
  (push operation (store-calls store))
  (when (member operation (store-fail store))
    (error 'stack-session:session-store-error :store store :operation operation
                                              :message "down"))
  (funcall thunk))

(defmethod stack-session:session-store-load ((store counting-store) id)
  (%store-call store :load (lambda () (stack-session:session-store-load (inner-store store) id))))

(defmethod stack-session:session-store-save ((store counting-store) session ttl)
  (%store-call store :save
               (lambda () (stack-session:session-store-save (inner-store store) session ttl))))

(defmethod stack-session:session-store-delete ((store counting-store) id)
  (%store-call store :delete
               (lambda () (stack-session:session-store-delete (inner-store store) id))))

(defun test-manager (&rest keys &key (store (make-counting-store)) &allow-other-keys)
  "A session manager over STORE on the test clock; KEYS go to MAKE-SESSION-MANAGER."
  (let ((keys (loop for (k v) on keys by #'cddr unless (eq k :store) collect k and collect v)))
    (apply #'stack-session:make-session-manager :store store :clock #'test-clock keys)))

(defun manager-store (manager)
  (stack-session:session-manager-store manager))

;;; Handlers that use the session through the request

(defun visit-count (&key)
  (elt* "p" nil (princ-to-string (incf (h:htmx-session-value "n" 0)))))

(defun remember (&key note)
  (setf (h:htmx-session-value "note") note)
  (elt* "p" nil "saved"))

(defun recall (&key)
  (elt* "p" nil (h:htmx-session-value "note" "-")))

(defun session-kind (&key)
  "none, new or loaded"
  (let ((s (h:htmx-session)))
    (elt* "p" nil (cond ((null s) "none")
                        ((stack-session:session-new-p s) "new")
                        (t "loaded")))))

(defvar *returned* nil "What the last ROTATE or LOGOUT got back, with the request's session.")

(defun rotate (&key)
  (setf *returned* (list (h:htmx-session-regenerate) (h:htmx-session)))
  (elt* "p" nil "rotated"))

(defun logout (&key)
  (setf *returned* (list (h:htmx-session-end) (h:htmx-session)))
  (elt* "p" nil "bye"))

(defun note-then-boom (&key note)
  (setf (h:htmx-session-value "note") note)
  (error "boom after a write"))

(defun note-then-invalid (&key note)
  (setf (h:htmx-session-value "note") note)
  (error 'rpc:rpc-invalid-params :message "bad input"))

(defun whoami (&key)
  (elt* "p" nil (or (h:htmx-message-client-address h:*htmx-request*) "nil")))

(defun stream-recall (stream &key)
  (rpc:rpc-send stream (cons "note" (h:htmx-session-value "note" "-")))
  (rpc:rpc-send stream (cons "committed" (if (and (h:htmx-session)
                                                  (stack-session:session-committed-p (h:htmx-session)))
                                             "t" "nil"))))

(defun stream-write (stream &key)
  (rpc:rpc-send stream (cons "before" "x"))
  (setf (h:htmx-session-value "note") "late")
  (rpc:rpc-send stream (cons "after" "y")))

(defun stream-write-continue (stream &key)
  (rpc:rpc-send stream (cons "before" "x"))
  (handler-bind ((stack-session:session-write-error #'continue))
    (setf (h:htmx-session-value "note") "late"))
  (rpc:rpc-send stream (cons "after" "y")))

(defun stream-whoami (stream &key)
  (rpc:rpc-send stream (cons "addr" (or (h:htmx-message-client-address h:*htmx-request*) "nil"))))

(defun stream-resume (stream &key)
  (rpc:rpc-send stream (cons "id" (or (getf (h:htmx-message-metadata h:*htmx-request*) :last-event-id)
                                      "none"))))

(defun session-handlers ()
  (h:make-htmx-handlers
   'visit-count 'remember 'recall 'session-kind 'rotate 'logout
   'note-then-boom 'note-then-invalid 'whoami 'capture
   '(stream-recall :mode :call-stream)
   '(stream-write :mode :call-stream)
   '(stream-write-continue :mode :call-stream)
   '(stream-whoami :mode :call-stream)
   '(stream-resume :mode :call-stream)))

(defun session-client (tx &rest app-keys &key (cookies t) remote-addr &allow-other-keys)
  "A client with a cookie jar (COOKIES) for (HTMX-APP TX (SESSION-HANDLERS) . APP-KEYS)."
  (let ((app-keys (loop for (k v) on app-keys by #'cddr
                        unless (member k '(:cookies :remote-addr)) collect k and collect v)))
    (h:make-htmx-client (apply #'h:htmx-app tx (session-handlers) app-keys)
                        :codec (h:htmx-transport-codec tx)
                        :cookies cookies :remote-addr remote-addr)))

(defun call (c name &rest params)
  "An hx-get of the handler NAME (a string: its symbol name) with PARAMS → the reply."
  (h:htmx-request c (m name) params))

(defun call-body (c name &rest params)
  "The body of (CALL c name . params)."
  (h:htmx-reply-body (apply #'call c name params)))

(defun stream-events (c name &rest keys)
  (h:htmx-reply-events (apply #'h:htmx-request c (m name) nil :accept "text/event-stream" keys)))

;;; Set-Cookie headers

(defun set-cookies (reply)
  "Every Set-Cookie value of REPLY, in order."
  (loop for (name . value) in (h:htmx-reply-headers reply)
        when (string-equal name "set-cookie") collect value))

(defun set-cookie-named (reply name)
  "The first Set-Cookie of REPLY for the cookie NAME, or NIL."
  (find-if (lambda (v) (eql 0 (search (s+ name "=") v))) (set-cookies reply)))

(defun cookie-value-in (set-cookie)
  "The value part of one Set-Cookie header value."
  (let ((start (1+ (position #\= set-cookie))))
    (subseq set-cookie start (position #\; set-cookie :start start))))

(defun sid-of (reply)
  "The value REPLY's Set-Cookie gives the cookie \"sid\", or NIL."
  (let ((header (set-cookie-named reply "sid")))
    (and header (cookie-value-in header))))

(defun header-names (reply)
  (mapcar #'car (h:htmx-reply-headers reply)))

(defun session-cookie-header (id &key (max-age 86400) secure)
  "Exactly what session-protocol's default policy writes (cl-cookie 0.2.0)."
  (format nil "sid=~A; Max-age=~D; Path=/; SameSite=Lax~:[~;; Secure~]; HttpOnly" id max-age secure))

(defun without-key (plist key)
  (loop for (k v) on plist by #'cddr unless (eq k key) collect k and collect v))

(defun escapes (thunk)
  "(values result escaped-condition): an ERROR leaving THUNK is caught and returned."
  (let ((result nil) (escaped nil))
    (block run
      (handler-bind ((error (lambda (c) (setf escaped c) (return-from run))))
        (setf result (funcall thunk))))
    (values result escaped)))
