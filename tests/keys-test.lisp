(in-package #:rpc-backend-htmx/tests)

;;; 0.3.0 (rpc-backend-htmx#2): request names map to keys with FIND-SYMBOL in
;;; KEYWORD, never INTERN; each handler accepts its key set (lambda list or
;;; :params) and a request naming anything else is 400; MAX-PARAMS caps the
;;; fields of one request (413). Rules: src/handlers.lisp (Key sets, Accepting
;;; a request), src/codec.lisp (Params), src/server.lisp (JSONRPC-HANDLER, Keys).

(defun keyword-count ()
  "Symbols in the KEYWORD package."
  (let ((n 0))
    (do-symbols (s (find-package "KEYWORD") n)
      (declare (ignore s))
      (incf n))))

(defvar *fresh-counter* 0)

(defun fresh-names (n)
  "N distinct lowercase names (\"zq…\"), each checked to name no keyword.
Nothing is interned: FORMAT, STRING-UPCASE and FIND-SYMBOL never do."
  (let ((state (make-random-state t))
        (seen (make-hash-table :test 'equal))
        (names '()))
    (loop while (< (hash-table-count seen) n)
          do (let ((name (format nil "zq~(~36R~)~D" (random (expt 36 10) state)
                                 (incf *fresh-counter*))))
               (unless (or (gethash name seen)
                           (nth-value 1 (find-symbol (string-upcase name) "KEYWORD")))
                 (setf (gethash name seen) t)
                 (push name names))))
    (nreverse names)))

(defun query-of (names)
  "name=1&… for NAMES, as a query string or urlencoded body."
  (format nil "~{~A=1~^&~}" names))

(defun interned-any-p (names)
  (some (lambda (name) (nth-value 1 (find-symbol (string-upcase name) "KEYWORD"))) names))

(defun code-of (reply) (h:htmx-reply-status reply))
(defun body-of (reply) (h:htmx-reply-body reply))

(defun path-of (name) (s+ +prefix+ (m name)))

;;; Handlers with every lambda-list shape a key set is derived from.

(defvar *calls* 0)

(defun keyed-canvas (&key a ((:bee b) "-") ((zed z) "z"))
  (incf *calls*)
  (elt* "p" nil (format nil "~A ~A ~A" a b z)))

(defun rest-canvas (&rest args)
  (setf *seen* (list args nil))
  "rest")

(defun rest-key-canvas (&rest args &key a)
  (declare (ignore a))
  (format nil "~{~(~A~)=~A~^ ~}" args))

(defgeneric gf-canvas (&key a))

(defmethod gf-canvas (&key a)
  (elt* "p" nil (or a "none")))

(defun positional-canvas (x) x)

(defun optional-canvas (&optional x) x)

(defun stream-extra (stream x)
  (declare (ignore stream x)))

(defun declared-fn ()
  (lambda (&rest args) (format nil "~{~(~A~)=~A~^ ~}" args)))

(defun keys-handlers ()
  (h:make-htmx-handlers 'greet 'capture 'keyed-canvas 'rest-canvas 'rest-key-canvas 'gf-canvas
                        '(bump :mode :notify) '(ticker :mode :call-stream)
                        (list "X::DECLARED" (declared-fn) :params '(:q :r))
                        (list "X::DUPLICATES" (declared-fn) :params '(:q :q :r :q))
                        (list "X::ANY" (declared-fn) :params t)
                        (list "X::NONE" (declared-fn) :params '())))

(defun param-client (&key (transport (transport)) (handler (keys-handlers)))
  (h:make-htmx-client (h:htmx-app transport handler) :codec (h:htmx-transport-codec transport)))

;;; Key sets

(deftest key-sets-from-lambda-lists
  (let ((table (keys-handlers)))
    (flet ((keys (name) (multiple-value-list (h:htmx-handler-keys table name))))
      (ok (equal '((:name) t) (keys (m "GREET"))) "&key")
      (ok (equal '(t t) (keys (m "CAPTURE"))) "&rest &key &allow-other-keys → any key")
      (ok (equal '((:a :bee) t) (keys (m "KEYED-CANVAS")))
          "VAR and ((:KEY VAR)); ((ZED Z)) names no keyword, so no key")
      (ok (equal '(t t) (keys (m "REST-CANVAS"))) "&rest without &key → any key")
      (ok (equal '((:a) t) (keys (m "REST-KEY-CANVAS"))) "&rest with &key → the keys")
      (ok (equal '((:a) t) (keys (m "GF-CANVAS"))) "a generic function: its lambda list")
      (ok (equal '((:by) t) (keys (m "BUMP"))) ":notify")
      (ok (equal '((:n) t) (keys (m "TICKER"))) ":call-stream: the stream is not a key")
      (ok (equal '((:q :r) t) (keys "X::DECLARED")) ":params, as given")
      (ok (equal '((:q :r) t) (keys "X::DUPLICATES")) ":params, each key once, first place")
      (ok (equal '(t t) (keys "X::ANY")) ":params t")
      (ok (equal '(nil t) (keys "X::NONE")) ":params ()")
      (ok (equal '(nil nil) (keys (m "NOPE"))) "not in the table"))
    (let ((once (h:htmx-handler-keys table (m "KEYED-CANVAS"))))
      (setf (first once) :clobbered)
      (ok (equal '(:a :bee) (h:htmx-handler-keys table (m "KEYED-CANVAS"))) "a fresh list"))))

(deftest key-sets-refuse-uncallable-handlers
  (dolist (entry (list 'positional-canvas
                       'optional-canvas
                       '(stream-extra :mode :call-stream)
                       '(greet :mode :call-stream)
                       '(ticker :mode :call-response)
                       (list "X::POS" #'positional-canvas)))
    (ok (signals (h:make-htmx-handlers entry) 'h:htmx-error) (format nil "~S" entry)))
  (ok (equal (s+ "Handler " (m "POSITIONAL-CANVAS")
                 " cannot take request params: (RPC-BACKEND-HTMX/TESTS::X)")
             (handler-case (h:make-htmx-handlers 'positional-canvas)
               (h:htmx-error (c) (rpc:rpc-error-message c))))
      "the exact message")
  (ok (eql 500 (handler-case (h:make-htmx-handlers 'optional-canvas)
                 (h:htmx-error (c) (h:htmx-error-status c)))))
  (ok (typep (h:make-htmx-handlers '(positional-canvas :params (:x))) 'h:htmx-handlers)
      "with :params the lambda list is never read"))

(deftest params-option-refusals
  (dolist (params (list "name" :name '(name) '("name") '(:name . :x) 42))
    (ok (signals (h:make-htmx-handlers (list 'greet :params params)) 'h:htmx-error)
        (format nil "~S" params)))
  (ok (eql 500 (handler-case (h:make-htmx-handlers '(greet :params "x"))
                 (h:htmx-error (c) (h:htmx-error-status c)))))
  (ok (signals (h:make-htmx-handlers '(greet :bogus 1)) 'h:htmx-error)
      "options stay :mode and :params")
  (ok (eq :notify (nth-value 1 (h:find-htmx-handler
                                (h:make-htmx-handlers '(bump :params (:by) :mode :notify))
                                (m "BUMP"))))
      ":mode and :params in any order"))

;;; Accepting requests

(deftest legitimate-keys-still-bind
  (let ((c (param-client)))
    (ok (equal "<p>1 2 z</p>" (body-of (h:htmx-request c (m "KEYED-CANVAS") '(:a "1" :bee "2")))))
    (ok (equal "<p>1 2 z</p>"
               (body-of (h:htmx-request-env c (env :path (path-of "KEYED-CANVAS")
                                                   :query "A=1&Bee=2"))))
        "names upcase to their keys")
    (ok (equal "<p>3 - z</p>" (body-of (h:htmx-request c (m "KEYED-CANVAS") '(:a "3")
                                                       :http-method :post))))
    (ok (equal "<p>4 - z</p>" (body-of (h:htmx-request c (m "KEYED-CANVAS") '(:a "4")
                                                       :http-method :post :encoding :multipart))))
    (ok (equal "<p>Hello, Ann</p>" (body-of (h:htmx-request c (m "GREET") '(:name "Ann")))))
    (ok (equal "<p>x</p>" (body-of (h:htmx-request c (m "GF-CANVAS") '(:a "x")))))
    (ok (equal "a=1" (body-of (h:htmx-request c (m "REST-KEY-CANVAS") '(:a "1")))))
    (ok (equal "q=1 r=2" (body-of (h:htmx-request c "X::DECLARED" '(:q "1" :r "2")))) ":params")
    (ok (equal "sort=a" (body-of (h:htmx-request c "X::ANY" '(:sort "a")))) ":params t")
    (ok (equal "<p>NIL - z</p>" (body-of (h:htmx-request c (m "KEYED-CANVAS") nil))) "no params")))

(deftest any-key-handlers-drop-unmapped-names
  (let ((c (param-client))
        (name (first (fresh-names 1))))
    (setf *seen* nil)
    (ok (= 200 (code-of (h:htmx-request-env c (env :path (path-of "REST-CANVAS")
                                                   :query (s+ "name=Ann&" name "=1&page=2"))))))
    (ok (equal '(:name "Ann" :page "2") (first *seen*))
        "&rest alone: every mapped key, in order; the unmapped name dropped")
    (setf *seen* nil)
    (ok (= 200 (code-of (h:htmx-request-env c (env :path (path-of "CAPTURE")
                                                   :query (s+ name "=1&q=2"))))))
    (ok (equal '(:q "2") (first *seen*)) "&allow-other-keys")))

(deftest unknown-params-are-400
  (setf *calls* 0)
  (let ((c (param-client))
        (name (first (fresh-names 1))))
    (flet ((check (label reply param)
             (ok (= 400 (code-of reply)) label)
             (ok (equal (s+ "<p role=\"alert\">htmx error 400: Unknown param " param "</p>")
                        (body-of reply))
                 label)
             (ok (equal "#canvas-error" (hdr reply "HX-Retarget")) label))
           (q (query) (h:htmx-request-env c (env :path (path-of "KEYED-CANVAS") :query query))))
      (check "a keyword the handler does not take"
             (h:htmx-request c (m "KEYED-CANVAS") '(:a "1" :sort "x")) "sort")
      (check "a name that is no keyword" (q (s+ "a=1&" name "=2")) name)
      (check "downcased" (q (s+ (string-upcase name) "=2")) name)
      (check "the first refused key, in params order"
             (h:htmx-request c (m "KEYED-CANVAS") '(:page "1" :a "2" :sort "3")) "page")
      (check "keys before unmapped names" (q (s+ name "=1&SORT=2")) "sort")
      (check "a non-keyword key cannot be named" (q "zed=3") "zed")
      (check "POST urlencoded"
             (h:htmx-request c (m "KEYED-CANVAS") '(:sort "x") :http-method :post) "sort")
      (check "POST multipart"
             (h:htmx-request c (m "KEYED-CANVAS") '(:sort "x") :http-method :post
                                                                :encoding :multipart)
             "sort")
      (check ":params" (h:htmx-request c "X::DECLARED" '(:a "1")) "a")
      (check ":params ()" (h:htmx-request c "X::NONE" '(:q "1")) "q")
      (check "a generic function" (h:htmx-request c (m "GF-CANVAS") '(:b "1")) "b"))
    (ok (= 0 *calls*) "nothing was called")))

(deftest unknown-params-refused-before-any-call
  (setf *bumps* 0)
  (let ((c (param-client)))
    (ok (= 400 (code-of (h:htmx-request c (m "BUMP") '(:by "2" :sort "x") :http-method :post)))
        ":notify")
    (ok (= 0 *bumps*) "the :notify handler was not called")
    (let ((r (h:htmx-request c (m "TICKER") '(:n "2" :sort "x") :accept "text/event-stream")))
      (ok (= 400 (code-of r)) ":call-stream: before the stream opens")
      (ok (equal "text/html; charset=utf-8" (hdr r "Content-Type")))
      (ok (null (h:htmx-reply-events r))))))

;;; Never interned (the DoS of #2)

(deftest request-names-never-interned
  (let ((c (param-client :transport (transport :max-params 20000))))
    ;; Warm every path once, so nothing else in the image interns lazily below.
    (let ((warm (fresh-names 3)))
      (dolist (method '("CAPTURE" "GREET"))
        (h:htmx-request-env c (env :path (path-of method) :query (query-of warm)))
        (h:htmx-request-env c (env :method :post :path (path-of method)
                                   :content-type "application/x-www-form-urlencoded"
                                   :body (query-of warm)))))
    (let* ((names (fresh-names 10000))
           (before (keyword-count))
           (get (h:htmx-request-env c (env :path (path-of "CAPTURE") :query (query-of names))))
           (post (h:htmx-request-env c (env :method :post :path (path-of "CAPTURE")
                                            :content-type "application/x-www-form-urlencoded"
                                            :body (query-of names))))
           (strict (h:htmx-request-env c (env :path (path-of "GREET") :query (query-of names))))
           (after (keyword-count)))
      (ok (= before after) "10,000 random names: the KEYWORD package keeps its size")
      (ok (not (interned-any-p names)) "none of them is a keyword")
      (ok (= 200 (code-of get)) "an any-key handler drops them (GET)")
      (ok (= 200 (code-of post)) "an any-key handler drops them (POST)")
      (ok (= 400 (code-of strict)) "a handler with a key list refuses them"))))

(deftest multipart-names-never-interned
  (let* ((c (param-client :transport (transport :max-params 20000)))
         (names (fresh-names 2000))
         (body (format nil "~{~A~C~C~}"
                       (loop for line in (append
                                          (loop for name in names
                                                for i from 0
                                                append (list "--B"
                                                             (if (evenp i)
                                                                 (format nil "Content-Disposition: form-data; name=\"~A\"" name)
                                                                 (format nil "Content-Disposition: form-data; name=\"~A\"; filename=\"f.txt\"" name))
                                                             "" "v"))
                                          (list "--B--"))
                             append (list line #\Return #\Linefeed))))
         (before (keyword-count))
         (r (h:htmx-request-env c (env :method :post :path (path-of "CAPTURE") :body body
                                       :content-type "multipart/form-data; boundary=B"))))
    (ok (= 200 (code-of r)))
    (ok (= before (keyword-count)) "text and file parts: KEYWORD keeps its size")
    (ok (not (interned-any-p names)))))

(deftest default-cap-refuses-10000-names
  (let* ((c (param-client))
         (names (fresh-names 10000))
         (before (keyword-count))
         (r (h:htmx-request-env c (env :path (path-of "CAPTURE") :query (query-of names)))))
    (ok (= 413 (code-of r)) "over the default MAX-PARAMS")
    (ok (= before (keyword-count)))))

(deftest jsonrpc-names-never-interned
  (let* ((fn (h:jsonrpc-handler (transport :max-params 20000) (keys-handlers)))
         (object (lambda (names)
                   (let ((table (make-hash-table :test 'equal)))
                     (dolist (name names table) (setf (gethash name table) "1"))))))
    (funcall fn (m "CAPTURE") (funcall object (fresh-names 3)))
    (handler-case (funcall fn (m "GREET") (funcall object (fresh-names 3)))
      (error () nil))
    (let* ((names (fresh-names 10000))
           (params (funcall object names))
           (before (keyword-count)))
      (ok (equal "ok" (funcall fn (m "CAPTURE") params)) "an any-key handler drops them")
      (ok (signals (funcall fn (m "GREET") params) 'h:htmx-unknown-param)
          "a handler with a key list refuses them")
      (ok (= before (keyword-count)) "JSON-RPC: the KEYWORD package keeps its size")
      (ok (not (interned-any-p names))))))

;;; The codec

(deftest decode-unmapped-names
  (destructuring-bind (n1 n2) (fresh-names 2)
    (let* ((before (keyword-count))
           (msg (decode (env :query (s+ "name=Ann&" n1 "=1&" (string-upcase n1) "=2&" n2
                                        "&page=3")))))
      (ok (equal '(:name "Ann" :page "3") (h:htmx-message-params msg)))
      (ok (equal (list n1 n2) (h:htmx-message-unmapped-names msg))
          "each upcased name once, its first spelling, in wire order")
      (ok (= before (keyword-count))))
    (let ((msg (decode (env :method :post
                            :content-type "multipart/form-data; boundary=B"
                            :body (crlf "--B"
                                        (format nil "Content-Disposition: form-data; name=\"~A\"" n1)
                                        "" "text"
                                        "--B"
                                        (format nil "Content-Disposition: form-data; name=\"~A\"; filename=\"f.txt\"" n2)
                                        "Content-Type: text/plain" "" "file"
                                        "--B"
                                        "Content-Disposition: form-data; name=\"name\""
                                        "" "Ann"
                                        "--B--")))))
      (ok (equal '(:name "Ann") (h:htmx-message-params msg)))
      (ok (equal (list n1 n2) (h:htmx-message-unmapped-names msg)) "text and file parts"))
    (ok (null (h:htmx-message-unmapped-names (decode (env :query "name=Ann")))))))

(deftest max-params-cap
  (ok (= 1000 h:+default-max-params+))
  (ok (= 1000 (h:htmx-codec-max-params (h:make-htmx-codec))))
  (ok (= 3 (h:htmx-codec-max-params (codec :max-params 3))))
  (ok (= 3 (h:htmx-codec-max-params (h:htmx-transport-codec (transport :max-params 3)))))
  (ok (= 3 (h:htmx-codec-max-params
            (h:htmx-transport-codec (hc:make-canvas-htmx-transport :max-params 3)))))
  (dolist (bad (list -1 "3" 1.5 nil))
    (ok (signals (h:make-htmx-codec :max-params bad) 'type-error) (format nil "~S" bad)))
  (let ((codec (codec :max-params 3))
        (name (first (fresh-names 1))))
    (flet ((params (env) (h:htmx-message-params (decode env codec)))
           (limit-of (env) (handler-case (progn (decode env codec) nil)
                             (h:htmx-too-many-params (c) (h:htmx-params-limit c)))))
      (ok (equal '(:a "1" :b "2" :c "3") (params (env :query "a=1&b=2&c=3"))) "exactly the cap")
      (ok (eql 3 (limit-of (env :query "a=1&b=2&c=3&d=4"))) "one more")
      (ok (eql 3 (limit-of (env :query "a=1&a=2&a=3&a=4"))) "duplicates count")
      (ok (eql 3 (limit-of (env :query (s+ "a=1&b=2&c=3&" name "=4")))) "unmapped names count")
      (ok (eql 3 (limit-of (env :method :post :query "a=1&b=2"
                                :content-type "application/x-www-form-urlencoded"
                                :body "c=3&d=4")))
          "query and body together")
      (ok (equal '(:a "1" :b "2" :c "3") (params (env :query "=x&a=1&b=2&c=3&=y")))
          "empty names do not count")
      (ok (equal '(:a "1" :b "2" :c "3")
                 (params (env :method :post :content-type "multipart/form-data; boundary=B"
                              :body (crlf "--B" "Content-Disposition: form-data; name=\"a\"" "" "1"
                                          "--B" "Content-Disposition: form-data; name=\"b\"" "" "2"
                                          "--B" "Content-Disposition: form-data; name=\"f\"; filename=\"\""
                                          "Content-Type: application/octet-stream" "" ""
                                          "--B" "Content-Disposition: form-data; name=\"c\"" "" "3"
                                          "--B--"))))
          "an empty file input does not count")
      (ok (eql 3 (limit-of (env :method :post :content-type "multipart/form-data; boundary=B"
                                :body (crlf "--B" "Content-Disposition: form-data; name=\"a\"" "" "1"
                                            "--B" "Content-Disposition: form-data; name=\"b\"" "" "2"
                                            "--B" "Content-Disposition: form-data; name=\"f\"; filename=\"x.txt\""
                                            "Content-Type: text/plain" "" "x"
                                            "--B" "Content-Disposition: form-data; name=\"f\"; filename=\"y.txt\""
                                            "Content-Type: text/plain" "" "y"
                                            "--B--"))))
          "file parts count, one each"))
    (ok (signals (decode (env :query "a=1") (codec :max-params 0)) 'h:htmx-too-many-params))
    (ok (null (h:htmx-message-params (decode (env) (codec :max-params 0)))) "no fields, no limit hit")))

(deftest app-answers-413-for-too-many-params
  (let* ((c (param-client :transport (transport :max-params 2)))
         (r (h:htmx-request c (m "CAPTURE") '(:a "1" :b "2" :c "3"))))
    (ok (= 413 (code-of r)))
    (ok (equal "#canvas-error" (hdr r "HX-Retarget")))
    (ok (equal "<p role=\"alert\">htmx error 413: Too many request params</p>" (body-of r)))
    (ok (= 200 (code-of (h:htmx-request c (m "CAPTURE") '(:a "1" :b "2")))))))

;;; Live images: a symbol entry follows its definition

(deftest key-set-follows-redefinition
  (handler-bind ((warning #'muffle-warning))
    (eval '(defun redef-canvas (&key a) (elt* "p" nil (format nil "~A" a)))))
  (let* ((table (h:make-htmx-handlers 'redef-canvas))
         (c (param-client :handler table)))
    (ok (equal '(:a) (h:htmx-handler-keys table (m "REDEF-CANVAS"))))
    (ok (= 400 (code-of (h:htmx-request c (m "REDEF-CANVAS") '(:b "2")))))
    (handler-bind ((warning #'muffle-warning))
      (eval '(defun redef-canvas (&key a b) (elt* "p" nil (format nil "~A ~A" a b)))))
    (ok (equal '(:a :b) (h:htmx-handler-keys table (m "REDEF-CANVAS"))) "derived again")
    (ok (equal "<p>NIL 2</p>" (body-of (h:htmx-request c (m "REDEF-CANVAS") '(:b "2"))))
        "the new key binds on the next request")
    (handler-bind ((warning #'muffle-warning))
      (eval '(defun redef-canvas (x) x)))
    (ok (= 500 (code-of (h:htmx-request c (m "REDEF-CANVAS") nil)))
        "a definition the server cannot call: 500")
    (ok (signals (h:htmx-handler-keys table (m "REDEF-CANVAS")) 'h:htmx-error))
    (handler-bind ((warning #'muffle-warning))
      (eval '(defun redef-canvas () (elt* "p" nil "zero"))))
    (ok (equal "<p>zero</p>" (body-of (h:htmx-request c (m "REDEF-CANVAS") nil))))))

(deftest key-set-for-a-symbol-defined-later
  (fmakunbound 'late-canvas)
  (let* ((table (h:make-htmx-handlers 'late-canvas))
         (c (param-client :handler table)))
    (ok (typep table 'h:htmx-handlers) "an unbound symbol is not refused at build time")
    (ok (= 500 (code-of (h:htmx-request c (m "LATE-CANVAS") nil))) "unbound at request time: 500")
    (handler-bind ((warning #'muffle-warning))
      (eval '(defun late-canvas (&key q) (elt* "p" nil (format nil "~A" q)))))
    (ok (equal '(:q) (h:htmx-handler-keys table (m "LATE-CANVAS"))))
    (ok (equal "<p>1</p>" (body-of (h:htmx-request c (m "LATE-CANVAS") '(:q "1")))))))

;;; JSON-RPC

(deftest jsonrpc-keys
  (let ((fn (h:jsonrpc-handler (transport) (keys-handlers)))
        (name (first (fresh-names 1))))
    (flet ((refused (method params)
             (handler-case (progn (funcall fn method params) nil)
               (h:htmx-unknown-param (c)
                 (list (h:htmx-unknown-param-name c) (rpc:rpc-error-message c)
                       (rpc:rpc-error-code c))))))
      (ok (equal "<p>1 2 z</p>" (funcall fn (m "KEYED-CANVAS") (json-object "a" "1" "bee" "2"))))
      (ok (equal "q=1" (funcall fn "X::DECLARED" (json-object "q" "1"))))
      (ok (equal '("sort" "Unknown param sort" -32602)
                 (refused (m "KEYED-CANVAS") (json-object "sort" "x"))))
      (ok (equal (list name (s+ "Unknown param " name) -32602)
                 (refused (m "KEYED-CANVAS") (json-object name "x"))))
      (setf *seen* nil)
      (ok (equal "rest" (funcall fn (m "REST-CANVAS") (json-object "name" "a" name "b"))))
      (ok (equal '(:name "a") (first *seen*)) "any-key handler: unmapped dropped"))
    (ok (= -32602 (gethash "code" (gethash "error" (jsonrpc (m "GREET") (json-object "sort" "x")))))
        "over the wire: invalid params")))

(deftest jsonrpc-max-params
  (let ((fn (h:jsonrpc-handler (transport :max-params 2) (keys-handlers))))
    (ok (equal "ok" (funcall fn (m "CAPTURE") (json-object "a" "1" "b" "2"))))
    (ok (eql 2 (handler-case (funcall fn (m "CAPTURE") (json-object "a" "1" "b" "2" "c" "3"))
                 (h:htmx-too-many-params (c) (h:htmx-params-limit c)))))))
