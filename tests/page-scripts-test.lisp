(in-package #:rpc-backend-htmx/tests)

;;; 0.4.0 (canvas-protocol#15): the asset route serves an app's registered
;;; assets, and full pages load the app's scripts (MAKE-CANVAS-HTMX-TRANSPORT
;;; :page-scripts). Rules: the src/canvas/canvas.lisp header (Page scripts).

(defun ascii (string)
  (coerce (map 'vector #'char-code string) '(simple-array (unsigned-byte 8) (*))))

(defparameter +big-size+ (* 8 1024 1024))

(defun big-octets ()
  (let ((v (make-array +big-size+ :element-type '(unsigned-byte 8))))
    (dotimes (i +big-size+ v) (setf (aref v i) (logand (* i 13) 255)))))

(defmacro with-app-assets (() &body body)
  "BODY with an app's assets registered: two scripts, an ES module loader and
a large WASM file. The table is restored afterwards."
  `(let ((canvas-protocol::*app-assets* '()))
     (canvas:register-asset "app/main.js" :octets (ascii "document.body.dataset.app=1;"))
     (canvas:register-asset "app/player.js" :octets (ascii "/* player */"))
     (canvas:register-asset "vendor/kit/kit.mjs" :octets (ascii "export const kit=1;")
                                                 :license "Apache-2.0" :version "1.0.0")
     (canvas:register-asset "vendor/kit/kit.wasm" :octets (big-octets))
     ,@body))

(defun script-tag (path &optional (attrs ""))
  (s+ "<script src=\"/canvas-assets/" path "\"" attrs "></script>"))

(defun with-scripts (page &rest paths)
  "PAGE with a script tag for each of PATHS inserted right before </head>."
  (apply #'with-keys-script page (list (apply #'s+ (mapcar #'script-tag paths)))))

(defun scripts-client (&rest transport-keys)
  (canvas-client (apply #'hc:make-canvas-htmx-transport transport-keys)))

(deftest app-asset-route
  (with-app-assets ()
    (let ((c (canvas-client)))
      (let ((r (h:htmx-request-env c (env :path "/canvas-assets/app/main.js"))))
        (ok (= 200 (h:htmx-reply-status r)))
        (ok (equal "text/javascript; charset=utf-8" (hdr r "Content-Type")))
        (ok (equalp (ascii "document.body.dataset.app=1;") (h:htmx-reply-body r)) "exact bytes"))
      (let ((r (h:htmx-request-env c (env :path "/canvas-assets/vendor/kit/kit.mjs"))))
        (ok (= 200 (h:htmx-reply-status r)))
        (ok (equal "text/javascript; charset=utf-8" (hdr r "Content-Type"))))
      (let ((r (h:htmx-request-env c (env :path "/canvas-assets/vendor/kit/kit.wasm"))))
        (ok (= 200 (h:htmx-reply-status r)))
        (ok (equal "application/wasm" (hdr r "Content-Type")))
        (ok (= +big-size+ (length (h:htmx-reply-body r))) "8 MB served whole")
        (ok (equalp (big-octets) (h:htmx-reply-body r)))
        (ok (equal h:+default-csp+ (hdr r "Content-Security-Policy")) "gated like any response"))
      (dolist (path '("/canvas-assets/app/nope.js" "/canvas-assets/app" "/canvas-assets/app/"
                      "/canvas-assets/vendor//kit/kit.mjs" "/canvas-assets/vendor/kit/../../app/main.js"))
        (ok (= 404 (h:htmx-reply-status (h:htmx-request-env c (env :path path)))) path))
      (ok (= 200 (h:htmx-reply-status
                  (h:htmx-request-env (canvas-client (hc:make-canvas-htmx-transport
                                                      :asset-prefix "/static/"))
                                      (env :path "/static/vendor/kit/kit.wasm"))))
          "under another asset prefix")))
  (ok (= 404 (h:htmx-reply-status
              (h:htmx-request-env (canvas-client) (env :path "/canvas-assets/app/main.js"))))
      "an asset no longer registered"))

(deftest app-asset-resolver
  (with-app-assets ()
    (let ((r (hc:make-htmx-resolver (canvas-transport))))
      (ok (equal "/canvas-assets/vendor/kit/kit.wasm" (canvas:resolve-asset-url r "vendor/kit/kit.wasm")))
      (ok (null (canvas:resolve-asset-url r "app/nope.js"))))))

(deftest page-scripts-default-is-0.3.0
  (with-app-assets ()
    (ok (null (hc:canvas-transport-page-scripts (canvas-transport))))
    (ok (equal +people-page-0.1.0+ (plain-page (scripts-client) (m "PEOPLE") '(:sort "a"))))
    (ok (equal +people-page-0.1.0+ (plain-page (scripts-client :page-scripts nil) (m "PEOPLE")
                                               '(:sort "a")))
        ":page-scripts nil is the default")))

(deftest page-scripts-every-page
  (with-app-assets ()
    (let* ((c (scripts-client :page-scripts '((t "app/main.js" ("vendor/kit/kit.mjs" :module t)))))
           (page (plain-page c (m "PEOPLE") '(:sort "a"))))
      (ok (equal (with-keys-script +people-page-0.1.0+
                   (s+ (script-tag "app/main.js") (script-tag "vendor/kit/kit.mjs" " type=\"module\"")))
                 page)
          "the 0.3.0 page plus the scripts, in order, last in <head>")
      (ok (contains (script-tag "app/main.js") (plain-page c (m "BADGE-CANVAS")))))))

(deftest page-scripts-per-handler
  (with-app-assets ()
    (let* ((rules (list (list t "app/main.js")
                        (list (list 'people) "app/player.js" "app/main.js")
                        (list (list (m "LINKER")) "vendor/kit/kit.mjs")))
           (c (scripts-client :page-scripts rules)))
      (ok (equal (with-scripts +people-page-0.1.0+ "app/main.js" "app/player.js")
                 (plain-page c (m "PEOPLE") '(:sort "a")))
          "matching rules in order, a repeated name once")
      (ok (equal (with-scripts (plain-page (canvas-client) (m "BADGE-CANVAS")) "app/main.js")
                 (plain-page c (m "BADGE-CANVAS")))
          "only the T rule")
      (ok (contains (s+ (script-tag "app/main.js") (script-tag "vendor/kit/kit.mjs") "</head>")
                    (plain-page c (m "LINKER"))))
      (ok (equal (list (list t "app/main.js")
                       (list (list (m "PEOPLE")) "app/player.js" "app/main.js")
                       (list (list (m "LINKER")) "vendor/kit/kit.mjs"))
                 (hc:canvas-transport-page-scripts (hc:make-canvas-htmx-transport :page-scripts rules)))
          "symbols become method names"))
    (let ((c (scripts-client :page-scripts '(((badge-canvas) "app/main.js")))))
      (ok (equal +people-page-0.1.0+ (plain-page c (m "PEOPLE") '(:sort "a")))
          "an unselected page is byte-identical to 0.3.0"))))

(deftest page-scripts-with-page-keys
  (with-app-assets ()
    (let ((page (plain-page (scripts-client :page-keys t :page-scripts '((t "app/main.js")))
                            (m "PEOPLE") '(:sort "a"))))
      (ok (contains (s+ "<script src=\"/canvas-assets/htmx-ext-sse.min.js\"></script>"
                        +keys-script+ (script-tag "app/main.js") "</head>")
                    page)
          "after htmx, htmx-ext-sse and canvas-keys"))))

(deftest page-scripts-only-full-pages
  (with-app-assets ()
    (let ((c (scripts-client :page-scripts '((t "app/main.js")))))
      (ok (equal "<p>sort=a page=NIL</p>"
                 (h:htmx-reply-body (h:htmx-request c (m "PEOPLE") '(:sort "a"))))
          "an HX request gets the fragment")
      (ok (equal "<p>sort=a page=NIL</p>"
                 (h:htmx-reply-body (h:htmx-request c (m "PEOPLE") '(:sort "a")
                                                    :hx-request nil :http-method :post))))
      (let ((r (h:htmx-request c (m "NOPE") nil :hx-request nil)))
        (ok (= 404 (h:htmx-reply-status r)))
        (ok (not (contains "<script" (h:htmx-reply-body r))))))))

(deftest page-scripts-csp-clean
  (with-app-assets ()
    (let* ((c (scripts-client :page-keys t
                              :page-scripts '((t "app/main.js" ("vendor/kit/kit.mjs" :module t)))))
           (r (h:htmx-request c (m "PEOPLE") '(:sort "a") :hx-request nil))
           (page (h:htmx-reply-body r)))
      (ok (equal +brief-csp+ (csp-of r)) "the brief policy, unchanged")
      (ok (null (let ((canvas:*canvas-resolver* (hc:make-htmx-resolver (canvas-transport))))
                  (canvas:csp-violations
                   (canvas:page (canvas:el :p nil "sort=a page=NIL") :keys t
                                :scripts '("app/main.js" ("vendor/kit/kit.mjs" :module t))))))
          "the document HTMX-FULL-PAGE builds scans clean")
      (ok (= 5 (count-matches "\"></script>" page)) "each script tag is empty")
      (ok (= 5 (count-matches "<script src=\"/canvas-assets/" page)) "every script same-origin")
      (ok (= 5 (count-matches "</script>" page)) "and none other"))))

(defun count-matches (needle haystack)
  (loop for start = 0 then (+ at (length needle))
        for at = (search needle haystack :start2 start)
        while at count t))

(deftest page-scripts-refusals
  (with-app-assets ()
    (dolist (bad (list :yes t "app/main.js" '("app/main.js") '((t)) '((t . "app/main.js"))
                       '(((people) . nil)) '((:people "app/main.js")) '((("nocolons") "app/main.js"))
                       '((t 42)) '((t ("app/main.js" :async t))) '((t ("app/main.js" :module)))
                       '((t (:module "app/main.js"))) (list* '(t "app/main.js") 'x)))
      (ok (signals (hc:make-canvas-htmx-transport :page-scripts bad) 'type-error)
          (format nil "~S" bad)))
    (let ((c (handler-case (hc:make-canvas-htmx-transport :page-scripts '((t "app/nope.js")))
               (canvas:canvas-asset-not-found (c) c))))
      (ok (typep c 'canvas:canvas-asset-not-found) "an unknown asset at construction")
      (ok (and c (equal "app/nope.js" (canvas:asset-error-name c)))))))
