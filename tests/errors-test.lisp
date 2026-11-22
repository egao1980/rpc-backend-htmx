(in-package #:rpc-backend-htmx/tests)

(deftest error-maps-to-500-fragment
  (let ((r (h:htmx-request (client) (m "BOOM") nil)))
    (ok (= 500 (h:htmx-reply-status r)))
    (ok (equal "text/html; charset=utf-8" (hdr r "Content-Type")))
    (ok (equal "#canvas-error" (hdr r "HX-Retarget")))
    (ok (equal "innerHTML" (hdr r "HX-Reswap")))
    (ok (equal "<p role=\"alert\">boom &lt;b&gt;&amp;&lt;/b&gt;</p>" (h:htmx-reply-body r)))))

(deftest invalid-params-maps-to-422
  (let ((r (h:htmx-request (client) (m "BAD-PARAMS") nil)))
    (ok (= 422 (h:htmx-reply-status r)))
    (ok (contains "need &lt;id&gt;" (h:htmx-reply-body r)))
    (ok (not (contains "<id>" (h:htmx-reply-body r))))))

(deftest error-target-from-transport
  (let ((r (h:htmx-request (client :transport (transport :error-target "#err" :error-swap "outerHTML"))
                           (m "BOOM") nil)))
    (ok (equal "#err" (hdr r "HX-Retarget")))
    (ok (equal "outerHTML" (hdr r "HX-Reswap")))))

(deftest bad-response-headers-are-500
  (dolist (name '("BAD-HEADER" "NOT-HX-HEADER"))
    (let ((r (h:htmx-request (client) (m name) nil)))
      (ok (= 500 (h:htmx-reply-status r)) name)
      (ok (null (hdr r "Set-Cookie")) name)
      (ok (null (hdr r "HX-Trigger")) name))))

(deftest condition-status
  (let ((tx (transport)))
    (ok (= 404 (h:htmx-condition-status tx (make-condition 'rpc:rpc-method-not-found))))
    (ok (= 422 (h:htmx-condition-status tx (make-condition 'rpc:rpc-invalid-params))))
    (ok (= 413 (h:htmx-condition-status tx (make-condition 'h:htmx-body-too-large :limit 1))))
    (ok (= 415 (h:htmx-condition-status tx (make-condition 'h:htmx-unsupported-media-type))))
    (ok (= 400 (h:htmx-condition-status tx (make-condition 'h:htmx-bad-request))))
    (ok (= 500 (h:htmx-condition-status tx (make-condition 'simple-error :format-control "x"))))
    (let ((res (h:htmx-error-response tx (make-condition 'h:htmx-bad-request))))
      (ok (= 400 (first res)))
      (ok (equal "#canvas-error" (getf (second res) :hx-retarget))))))
