(in-package #:rpc-backend-htmx/tests)

;;; 0.5.0: HTMX-CLIENT's cookie jar (:cookies t; Set-Cookie in, Cookie out, per
;;; client) and :remote-addr. Rules: src/client.lisp (Cookie jar and client
;;; address).

(defun cookie-app (&rest replies)
  "A Clack app answering request i with the Set-Cookie values (nth i REPLIES)
(the last list repeats); its body is \"<cookie header>|<remote-addr>\"."
  (let ((queue replies))
    (lambda (env)
      (let ((values (if (rest queue) (pop queue) (first queue))))
        (list 200
              (loop for v in values collect :set-cookie collect v)
              (list (format nil "~A|~A"
                            (or (gethash "cookie" (getf env :headers)) "")
                            (getf env :remote-addr))))))))

(defun jar-client (app &rest keys)
  (apply #'h:make-htmx-client app :cookies t keys))

(defun hit-body (c &optional (env (env)))
  (h:htmx-reply-body (h:htmx-request-env c env)))

(defun https-env (&rest keys)
  (list* :url-scheme "https" (apply #'env keys)))

(deftest client-options
  (let ((c (h:make-htmx-client (cookie-app nil))))
    (ok (null (h:htmx-client-remote-addr c)) "no address by default")
    (ok (null (h:htmx-client-cookies c)) "no jar by default")
    (ok (null (h:htmx-client-cookie c "a"))))
  (ok (equal "203.0.113.9" (h:htmx-client-remote-addr
                            (h:make-htmx-client (cookie-app nil) :remote-addr "203.0.113.9"))))
  (dolist (bad (list :yes "t" 1))
    (ok (signals (h:make-htmx-client (cookie-app nil) :cookies bad) 'type-error)
        (format nil ":cookies ~S" bad)))
  (dolist (bad (list "" 42 :local '("1.2.3.4")))
    (ok (signals (h:make-htmx-client (cookie-app nil) :remote-addr bad) 'type-error)
        (format nil ":remote-addr ~S" bad))))

(deftest no-jar-is-0.4.0
  (let ((c (h:make-htmx-client (cookie-app '("a=1; Path=/")))))
    (ok (equal "|127.0.0.1" (hit-body c)))
    (ok (equal "|127.0.0.1" (hit-body c)) "a Set-Cookie is not kept")
    (ok (null (h:htmx-client-cookies c))))
  (let* ((c (gated-client))
         (r (visit c (h:htmx-token-url +gated-url+ +token+))))
    (ok (= 303 (h:htmx-reply-status r)))
    (ok (forbidden-p (visit c +gated-url+)) "without a jar the gate's cookie is the caller's to send")))

(deftest jar-keeps-and-sends-cookies
  (let ((c (jar-client (cookie-app '("a=1; Path=/" "b=2; Path=/; HttpOnly") '()))))
    (ok (equal "|127.0.0.1" (hit-body c)) "nothing to send on the first request")
    (ok (equal '(("a" . "1") ("b" . "2")) (h:htmx-client-cookies c)) "both kept, in order")
    (ok (equal "1" (h:htmx-client-cookie c "a")))
    (ok (null (h:htmx-client-cookie c "A")) "names are case-sensitive")
    (ok (equal "a=1; b=2|127.0.0.1" (hit-body c)) "sent back as one Cookie header")
    (ok (equal "a=1; b=2|127.0.0.1" (hit-body c)) "and kept")))

(deftest jar-replaces-and-expires
  (let ((c (jar-client (cookie-app '("a=1; Path=/") '("a=2; Path=/") '("a=; Max-Age=0; Path=/") '()))))
    (hit-body c)
    (ok (equal "a=1|127.0.0.1" (hit-body c)) "a=1 sent; a=2 set")
    (ok (equal '(("a" . "2")) (h:htmx-client-cookies c)) "the same name and path replaces")
    (ok (equal "a=2|127.0.0.1" (hit-body c)) "a=2 sent; Max-Age=0 set")
    (ok (null (h:htmx-client-cookies c)) "Max-Age=0 removes it at once")
    (ok (equal "|127.0.0.1" (hit-body c)) "and nothing is sent")))

(deftest jar-explicit-cookie-header-wins
  (let ((c (jar-client (cookie-app '("a=1; Path=/") '()))))
    (hit-body c)
    (ok (equal "x=9|127.0.0.1" (hit-body c (env :headers '(("cookie" . "x=9")))))
        "a hand-made env's Cookie header replaces the jar's")
    (ok (equal "x=9|127.0.0.1"
               (h:htmx-reply-body (h:htmx-request c "A::B" nil :headers '(("cookie" . "x=9")))))
        "so does HTMX-REQUEST :headers")
    (ok (equal "a=1|127.0.0.1" (hit-body c)) "the jar is unchanged")))

(deftest jar-secure-cookies-only-over-https
  (let ((c (jar-client (cookie-app '("s=1; Path=/; Secure") '()))))
    (ok (equal "|127.0.0.1" (hit-body c (https-env))))
    (ok (equal '(("s" . "1")) (h:htmx-client-cookies c)))
    (ok (equal "|127.0.0.1" (hit-body c)) "not over http")
    (ok (equal "s=1|127.0.0.1" (hit-body c (https-env))) "over https")))

(deftest jar-is-per-client
  (let* ((app (cookie-app '("who=a; Path=/") '("who=b; Path=/") '()))
         (a (jar-client app))
         (b (jar-client app)))
    (hit-body a)
    (hit-body b)
    (ok (equal "who=a|127.0.0.1" (hit-body a)))
    (ok (equal "who=b|127.0.0.1" (hit-body b)))))

(deftest jar-leaves-the-callers-env-alone
  (let* ((c (jar-client (cookie-app '("a=1; Path=/") '()) :remote-addr "203.0.113.9"))
         (e (env)))
    (hit-body c)
    (let ((copy (copy-list e))
          (table (getf e :headers)))
      (ok (equal "a=1|203.0.113.9" (hit-body c e)))
      (ok (equal copy e) "the plist")
      (ok (null (gethash "cookie" table)) "the :headers table")
      (ok (equal "127.0.0.1" (getf e :remote-addr))))))

(deftest client-remote-addr
  (let ((c (h:make-htmx-client (cookie-app '()) :remote-addr "203.0.113.9")))
    (ok (equal "|203.0.113.9" (hit-body c)) "a hand-made env")
    (ok (equal "|203.0.113.9" (h:htmx-reply-body (h:htmx-request c "A::B" nil))) "HTMX-REQUEST")
    (ok (equal "|203.0.113.9" (h:htmx-reply-body (h:htmx-request-url c "/A::B?x=1")))
        "HTMX-REQUEST-URL")))

(deftest jar-walks-the-gate
  (setf *gated-calls* 0)
  (let* ((tx (gated-transport))
         (c (h:make-htmx-client (h:htmx-app tx (gated-handlers))
                                :codec (h:htmx-transport-codec tx) :cookies t))
         (r (visit c (h:htmx-token-url +gated-url+ +token+))))
    (ok (= 303 (h:htmx-reply-status r)))
    (ok (equal (set-cookie-value r) (h:htmx-client-cookie c "canvas-token")) "the jar holds the secret")
    (let ((page (visit c (hdr r "Location"))))
      (ok (= 200 (h:htmx-reply-status page)) "the redirect followed with the jar's cookie")
      (ok (= 1 *gated-calls*)))
    (ok (= 200 (h:htmx-reply-status (h:htmx-request c (m "GATED-CANVAS") '(:q "2")))) "a fragment")
    (ok (equal '(("row" . "x"))
               (h:htmx-reply-events (h:htmx-request c (m "GATED-TICKER") nil :accept "text/event-stream")))
        "a stream")))
