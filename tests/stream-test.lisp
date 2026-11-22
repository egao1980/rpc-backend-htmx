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

;;; A :call-stream response is a Clack streaming function the server calls
;;; after HTMX-HANDLE-REQUEST returned: request context and the condition
;;; boundary must still hold inside it.

(defun sse-request/escaped (method params &rest keys)
  "(values reply escaped-condition): any error that leaves the app or the client."
  (let ((reply nil) (escaped nil))
    (block run
      (handler-bind ((error (lambda (c) (setf escaped c) (return-from run))))
        (setf reply (apply #'h:htmx-request (client) method params
                           :accept "text/event-stream" keys))))
    (values reply escaped)))

(defun error-fragment (message)
  "Body string HTMX-ERROR-RESPONSE gives for a SIMPLE-ERROR reporting MESSAGE."
  (format nil "~{~A~}"
          (third (h:htmx-error-response
                  (transport)
                  (make-condition 'simple-error :format-control "~A"
                                                :format-arguments (list message))))))

(defun error-events (events)
  (count h:+stream-error-event+ events :key #'car :test #'equal))

(deftest stream-request-context
  (let (r escaped)
    (ok (progn (multiple-value-setq (r escaped)
                 (sse-request/escaped (m "TICKER-CONTEXT") '(:n "7") :target "rows"))
               (null escaped))
        "no error escapes")
    (ok (equal `(("target" . "rows") ("method" . ,(m "TICKER-CONTEXT")) ("param" . "7"))
               (h:htmx-reply-events r))
        "*htmx-request* is the request's message while the stream runs")
    (ok (zerop (error-events (h:htmx-reply-events r))))))

(deftest stream-error-mid-stream
  (let (r escaped)
    (ok (progn (multiple-value-setq (r escaped) (sse-request/escaped (m "TICKER-FAIL") nil))
               (null escaped))
        "no error escapes the app or the client")
    (ok (= 200 (h:htmx-reply-status r)))
    (let ((events (h:htmx-reply-events r)))
      (ok (= 2 (length events)) "first event, one error event, then the stream closed")
      (ok (equal '("row" . "<p>one</p>") (first events)))
      (ok (= 1 (error-events events)))
      (ok (equal (cons h:+stream-error-event+ (error-fragment "stream <boom>")) (second events))
          "the error event carries HTMX-ERROR-RESPONSE's fragment")
      (ok (equal "<p role=\"alert\">stream &lt;boom&gt;</p>" (cdr (second events)))))))

(deftest stream-error-before-first-event
  (let (r escaped)
    (ok (progn (multiple-value-setq (r escaped) (sse-request/escaped (m "TICKER-FAIL-FIRST") nil))
               (null escaped))
        "no error escapes the app or the client")
    (ok (= 200 (h:htmx-reply-status r)))
    (ok (contains "text/event-stream" (hdr r "Content-Type")))
    (ok (equal (list (cons h:+stream-error-event+ (error-fragment "early <boom>")))
               (h:htmx-reply-events r))
        "exactly one error event, then the stream closed")
    (ok (equal "<p role=\"alert\">early &lt;boom&gt;</p>" (cdr (first (h:htmx-reply-events r)))))))

(deftest stream-errors-through-rpc-call-stream
  (flet ((drain (method)
           (let ((got nil) (escaped nil))
             (block run
               (handler-bind ((error (lambda (c) (setf escaped c) (return-from run))))
                 (let ((s (rpc:rpc-call-stream method nil :transport (client))))
                   (setf got (loop for ev = (rpc:rpc-recv s) collect ev until (eq ev :eof)))
                   (rpc:rpc-close s))))
             (values got escaped))))
    (let (got escaped)
      (ok (progn (multiple-value-setq (got escaped) (drain (m "TICKER-FAIL"))) (null escaped)))
      (ok (equal (list '("row" . "<p>one</p>")
                       (cons h:+stream-error-event+ (error-fragment "stream <boom>"))
                       :eof)
                 got)))
    (let (got escaped)
      (ok (progn (multiple-value-setq (got escaped) (drain (m "TICKER-FAIL-FIRST"))) (null escaped)))
      (ok (equal (list (cons h:+stream-error-event+ (error-fragment "early <boom>")) :eof)
                 got)))))
