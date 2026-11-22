(in-package #:rpc-backend-htmx/tests)

(defun sse-request (method params)
  (h:htmx-request (client) method params :accept "text/event-stream"))

(deftest sse-events-end-to-end
  (let ((r (sse-request (m "TICKER") '(:n "3"))))
    (ok (= 200 (h:htmx-reply-status r)))
    (ok (contains "text/event-stream" (hdr r "Content-Type")))
    (ok (equal '(("row" . "<li>1</li>") ("row" . "<li>2</li>") ("row" . "<li>3</li>"))
               (h:htmx-reply-events r)))
    (ok (equal (s+ (format nil "event: row~%data: <li>1</li>~%~%event: row~%data: <li>2</li>~%~%")
                    (format nil "event: row~%data: <li>3</li>~%~%"))
               (h:htmx-reply-body r))
        "the shape the htmx SSE extension reads")))

(deftest sse-wire-format
  (let* ((out (make-string-output-stream))
         (s (h:make-htmx-event-stream out :method (m "TICKER"))))
    (ok (typep s 'rpc:rpc-stream))
    (ok (eq :call-stream (rpc:rpc-stream-mode s)))
    (rpc:rpc-send s (cons "row" (elt* "li" nil "1")))
    (ok (equal (format nil "event: row~%data: <li>1</li>~%~%") (get-output-stream-string out)))
    (rpc:rpc-send s (cons "multi" (elt* "p" nil (format nil "a~%b"))))
    (ok (equal (format nil "event: multi~%data: <p>a~%data: b</p>~%~%")
               (get-output-stream-string out)))
    (rpc:rpc-send s (sse:make-sse-event :type "x.y:z-1" :data "d"))
    (ok (equal (format nil "event: x.y:z-1~%data: d~%~%") (get-output-stream-string out))
        "an sse-event (canvas fragment-event) passes through")))

(deftest sse-refusals
  (let ((s (h:make-htmx-event-stream (make-string-output-stream))))
    (ok (signals (rpc:rpc-send s (cons (format nil "a~%event: b") "x")) 'h:htmx-error))
    (ok (signals (rpc:rpc-send s (cons "a b" "x")) 'h:htmx-error))
    (ok (signals (rpc:rpc-send s (cons "" "x")) 'h:htmx-error))
    (ok (signals (rpc:rpc-send s (sse:make-sse-event :type (format nil "a~Cb" #\Return) :data "x"))
                 'h:htmx-error))
    (rpc:rpc-close s)
    (ok (signals (rpc:rpc-send s (cons "row" "x")) 'rpc:rpc-error) "closed")))

(deftest sse-error-after-open
  (let ((r (sse-request (m "TICKER-FAIL") nil)))
    (ok (= 200 (h:htmx-reply-status r)))
    (ok (equal '(("row" . "<p>one</p>")
                 ("canvas-error" . "<p role=\"alert\">stream &lt;boom&gt;</p>"))
               (h:htmx-reply-events r)))))

(deftest sse-keepalive
  (let* ((r (sse-request (m "TICKER-KEEPALIVE") nil))
         (lines (uiop:split-string (h:htmx-reply-body r) :separator '(#\Newline))))
    (ok (equal '(("row" . "a") ("row" . "b")) (h:htmx-reply-events r)))
    (ok (find-if (lambda (l) (and (plusp (length l)) (char= #\: (char l 0)))) lines)
        "a comment line from sse-protocol")))

(deftest rpc-call-stream-through-client
  (let* ((s (rpc:rpc-call-stream (m "TICKER") '(:n "2") :transport (client)))
         (got (loop for ev = (rpc:rpc-recv s) until (eq ev :eof) collect ev)))
    (ok (equal '(("row" . "<li>1</li>") ("row" . "<li>2</li>")) got))
    (rpc:rpc-close s)))
