(in-package #:rpc-backend-htmx/tests)

;;; 0.5.0: sessions in :call-stream (SSE) requests. The stream's head commits
;;; the session before any event is written (S0b through MAP-RESPONSE), so a
;;; stream handler reads the session and a write is session-protocol's
;;; SESSION-WRITE-ERROR. Rules: src/session.lisp (step 3, Streams, the S1
;;; mixin's HANDLE :around).

(defparameter +committed-write-fragment+
  "<p role=\"alert\">session cannot change: it is committed</p>")

(deftest stream-reads-the-session
  (with-clock ()
    (let ((c (session-client (session-transport))))
      (call c "REMEMBER" :note "x")
      (ok (equal '(("note" . "x") ("committed" . "t")) (stream-events c "STREAM-RECALL"))
          "the stored value, and the session already committed when the first event is written"))))

(deftest stream-for-a-new-visitor
  (with-clock ()
    (let* ((mgr (test-manager))
           (c (session-client (session-transport :sessions mgr)))
           (r (h:htmx-request c (m "STREAM-RECALL") nil :accept "text/event-stream")))
      (ok (= 200 (h:htmx-reply-status r)))
      (ok (equal '(("note" . "-") ("committed" . "t")) (h:htmx-reply-events r)))
      (ok (null (set-cookies r)) "nothing stored, no Set-Cookie")
      (ok (= 0 (store-count (manager-store mgr)))))))

(deftest stream-head-carries-the-refresh
  (with-clock ()
    (let* ((mgr (test-manager :refresh-interval 0))
           (store (manager-store mgr))
           (c (session-client (hc:make-canvas-htmx-transport :sessions mgr))))
      (call c "REMEMBER" :note "x")
      (let* ((saves (store-count store :save))
             (r (h:htmx-request c (m "STREAM-RECALL") nil :accept "text/event-stream")))
        (ok (contains "text/event-stream" (hdr r "Content-Type")))
        (ok (equal (session-cookie-header (h:htmx-client-cookie c "sid")) (set-cookie-named r "sid"))
            "the refresh write's Set-Cookie is in the stream's head")
        (ok (equal "set-cookie" (car (nth (- (length (h:htmx-reply-headers r)) 2) (h:htmx-reply-headers r))))
            "right before the CSP")
        (ok (equal (cons "content-security-policy" +brief-csp+) (last-header r)) "the CSP, last")
        (ok (= (1+ saves) (store-count store :save)) "one save, at the head")
        (ok (equal '(("note" . "x") ("committed" . "t")) (h:htmx-reply-events r)))))))

(deftest stream-write-is-a-write-error
  (with-clock ()
    (let ((c (session-client (session-transport))))
      (call c "REMEMBER" :note "x")
      (multiple-value-bind (events escaped) (escapes (lambda () (stream-events c "STREAM-WRITE")))
        (ok (null escaped) "nothing escapes")
        (ok (equal (list '("before" . "x") (cons h:+stream-error-event+ +committed-write-fragment+))
                   events)
            "the write → the stream boundary's error event, then the stream closes"))
      (ok (equal "<p>x</p>" (call-body c "RECALL")) "not stored"))))

(deftest stream-write-continue-ignores-it
  (with-clock ()
    (let ((c (session-client (session-transport))))
      (call c "REMEMBER" :note "x")
      (ok (equal '(("before" . "x") ("after" . "y")) (stream-events c "STREAM-WRITE-CONTINUE"))
          "CONTINUE: the write is ignored and the stream goes on")
      (ok (equal "<p>x</p>" (call-body c "RECALL"))))))

(deftest stream-store-failure-at-the-head-continues
  (with-clock ()
    (let* ((mgr (test-manager :refresh-interval 0))
           (store (manager-store mgr))
           (c (session-client (session-transport :sessions mgr))))
      (call c "REMEMBER" :note "x")
      (setf (store-fail store) '(:save))
      (multiple-value-bind (r escaped)
          (escapes (lambda () (h:htmx-request c (m "STREAM-RECALL") nil :accept "text/event-stream")))
        (ok (null escaped) "nothing escapes the app")
        (ok (= 200 (h:htmx-reply-status r)))
        (ok (equal '(("note" . "x") ("committed" . "t")) (h:htmx-reply-events r))
            "the refresh is skipped (CONTINUE), the stream goes on"))
      (setf (store-fail store) '())
      (ok (equal "<p>x</p>" (call-body c "RECALL"))))))
