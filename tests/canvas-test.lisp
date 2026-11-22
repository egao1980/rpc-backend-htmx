(in-package #:rpc-backend-htmx/tests)

;;; rpc-backend-htmx/canvas: canvas-protocol's resolver GF, pages, assets, RENDER.

(defun people (&key sort page)
  (canvas:el :p nil (format nil "sort=~A page=~A" sort page)))

(defun linker (&key)
  (canvas:el :a (canvas:hx-get (canvas:canvas-link 'people :sort "-name")) "sort"))

(defun badge-canvas (&key)
  (canvas:badge "ok" :status :ok))

(defun coerce-canvas (&key page)
  (canvas:el :p nil (princ-to-string (canvas:coerce-param page :integer :field "page"))))

(defun canvas-handlers ()
  (h:make-htmx-handlers 'people 'linker 'badge-canvas 'coerce-canvas))

(defun canvas-transport ()
  (hc:make-canvas-htmx-transport))

(defun canvas-client (&optional (tx (canvas-transport)))
  (h:make-htmx-client (h:htmx-app tx (canvas-handlers)) :codec (h:htmx-transport-codec tx)))

(defparameter +people-url+ "/canvas/RPC-BACKEND-HTMX%2FTESTS::PEOPLE")

(deftest canvas-transport-defaults
  (let ((tx (canvas-transport)))
    (ok (typep tx 'h:htmx-transport))
    (ok (equal "/canvas/" (h:htmx-transport-prefix tx)))
    (ok (equal "/canvas-assets/" (hc:canvas-transport-asset-prefix tx)))))

(deftest resolver-builds-urls
  (let* ((tx (canvas-transport))
         (r (hc:make-htmx-resolver tx (canvas-handlers))))
    (ok (typep r 'canvas:canvas-resolver))
    (let ((canvas:*canvas-resolver* r))
      (ok (equal (s+ +people-url+ "?sort=-name&page=2")
                 (canvas:canvas-url 'people :sort "-name" :page 2)))
      (ok (equal +people-url+ (canvas:canvas-url 'people)))
      (ok (null (canvas:canvas-url 'not-listed)) "not in the allowlist → no URL")
      (ok (null (canvas:hx-get (canvas:canvas-link 'not-listed))) "renders inert"))
    (ok (equal "/canvas-assets/htmx.min.js" (canvas:resolve-asset-url r "htmx.min.js")))
    (ok (null (canvas:resolve-asset-url r "nope.js")))
    (let ((open (hc:make-htmx-resolver tx)))
      (ok (equal (s+ "/canvas/RPC-BACKEND-HTMX%2FTESTS::NOT-LISTED")
                 (canvas:resolve-canvas-url open 'not-listed nil))
          "no table, no check"))))

(deftest resolver-round-trip
  (let* ((tx (canvas-transport))
         (url (let ((canvas:*canvas-resolver* (hc:make-htmx-resolver tx (canvas-handlers))))
                (canvas:canvas-url 'people :sort "-name & <x>" :page 2)))
         (r (h:htmx-request-url (canvas-client tx) url)))
    (ok (= 200 (h:htmx-reply-status r)))
    (ok (equal "<p>sort=-name &amp; &lt;x&gt; page=2</p>" (h:htmx-reply-body r))
        "the URL the resolver built routes to the same method and params")))

(deftest resolver-bound-during-requests
  (ok (equal (s+ "<a hx-get=\"" +people-url+ "?sort=-name\">sort</a>")
             (h:htmx-reply-body (h:htmx-request (canvas-client) (m "LINKER") nil)))))

(deftest page-vs-fragment
  (let* ((c (canvas-client))
         (page (h:htmx-reply-body (h:htmx-request c (m "PEOPLE") '(:sort "a") :hx-request nil)))
         (fragment (h:htmx-reply-body (h:htmx-request c (m "PEOPLE") '(:sort "a")))))
    (ok (equal "<p>sort=a page=NIL</p>" fragment))
    (ok (string-equal "<!doctype html>" (subseq page 0 (min 15 (length page)))))
    (ok (contains fragment page))
    (ok (contains "src=\"/canvas-assets/htmx.min.js\"" page))
    (ok (equal fragment (h:htmx-reply-body (h:htmx-request c (m "PEOPLE") '(:sort "a")
                                                           :hx-request nil :http-method :post)))
        "only a plain GET gets a page")))

(deftest asset-route
  (let* ((c (canvas-client))
         (r (h:htmx-request-env c (env :path "/canvas-assets/htmx.min.js"))))
    (ok (= 200 (h:htmx-reply-status r)))
    (ok (equal (canvas:asset-content-type "htmx.min.js") (hdr r "Content-Type")))
    (ok (equalp (canvas:asset-bytes "htmx.min.js") (h:htmx-reply-body r)))
    (ok (= 404 (h:htmx-reply-status (h:htmx-request-env c (env :path "/canvas-assets/nope.js")))))))

(deftest canvas-render-results
  (ok (equal (let ((canvas:*canvas-resolver* (canvas:make-freeze-resolver)))
               (canvas:to-html (canvas:badge "ok" :status :ok)))
             (h:htmx-reply-body (h:htmx-request (canvas-client) (m "BADGE-CANVAS") nil)))))

(deftest canvas-coercion-error-is-422
  (let ((r (h:htmx-request (canvas-client) (m "COERCE-CANVAS") '(:page "abc"))))
    (ok (= 422 (h:htmx-reply-status r)))
    (ok (equal "#canvas-error" (hdr r "HX-Retarget"))))
  (ok (equal "<p>3</p>" (h:htmx-reply-body (h:htmx-request (canvas-client) (m "COERCE-CANVAS")
                                                         '(:page "3"))))))
