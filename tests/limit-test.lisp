(in-package #:rpc-backend-htmx/tests)

(defun form-env (value &key (content-length :auto))
  (env :method :post :content-type "application/x-www-form-urlencoded"
       :body (s+ "name=" value) :content-length content-length))

(deftest codec-limit-with-content-length
  (let ((codec (codec :max-body-bytes 64)))
    (ok (equal (list :name (make-string 59 :initial-element #\a))
               (h:htmx-message-params (decode (form-env (make-string 59 :initial-element #\a)) codec)))
        "exactly 64 octets is allowed")
    (ok (signals (decode (form-env (make-string 60 :initial-element #\a)) codec)
                 'h:htmx-body-too-large))
    (ok (equal '(64 165)
               (handler-case (decode (form-env (make-string 160 :initial-element #\a)) codec)
                 (h:htmx-body-too-large (c) (list (h:htmx-body-limit c) (h:htmx-body-size c))))))))

(deftest codec-limit-without-content-length
  (let ((codec (codec :max-body-bytes 64)))
    (ok (equal '(64 nil)
               (handler-case (decode (form-env (make-string 4000 :initial-element #\a)
                                               :content-length nil)
                                     codec)
                 (h:htmx-body-too-large (c) (list (h:htmx-body-limit c) (h:htmx-body-size c))))))
    (ok (= 59 (length (getf (h:htmx-message-params
                             (decode (form-env (make-string 59 :initial-element #\a)
                                               :content-length nil)
                                     codec))
                            :name))))))

(deftest declared-length-is-checked-before-reading
  (let ((codec (codec :max-body-bytes 64)))
    (ok (signals (decode (env :method :post :content-type "application/x-www-form-urlencoded"
                              :body "name=a" :content-length 1000000)
                         codec)
                 'h:htmx-body-too-large))))

(deftest app-answers-413
  (let* ((c (client :transport (transport :max-body-bytes 64)))
         (r (h:htmx-request c (m "GREET") (list :name (make-string 200 :initial-element #\a))
                            :http-method :post)))
    (ok (= 413 (h:htmx-reply-status r)))
    (ok (equal "#canvas-error" (hdr r "HX-Retarget")))
    (ok (contains "too large" (h:htmx-reply-body r)))
    (ok (= 200 (h:htmx-reply-status (h:htmx-request c (m "GREET") '(:name "ok") :http-method :post))))))

(deftest default-limit
  (ok (= 1048576 h:+default-max-body-bytes+))
  (ok (= 1048576 (h:htmx-codec-max-body-bytes (h:make-htmx-codec)))))
