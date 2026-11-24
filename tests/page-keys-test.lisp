(in-package #:rpc-backend-htmx/tests)

;;; 0.2.0 (rpc-backend-htmx#6): full pages can load canvas-keys.js
;;; (MAKE-CANVAS-HTMX-TRANSPORT :page-keys). Rules: the src/canvas/canvas.lisp
;;; header (Page keys).

(defparameter +people-page-0.1.0+
  (s+ "<!DOCTYPE html><html lang=\"en\"><head><meta charset=\"utf-8\">"
      "<meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">"
      "<meta name=\"htmx-config\" content=\"{&quot;allowEval&quot;:false,&quot;allowScriptTags&quot;:false,&quot;historyCacheSize&quot;:0,&quot;includeIndicatorStyles&quot;:false,&quot;refreshOnHistoryMiss&quot;:true,&quot;selfRequestsOnly&quot;:true}\">"
      "<title>canvas</title>"
      "<link rel=\"stylesheet\" href=\"/canvas-assets/canvas.css\">"
      "<script src=\"/canvas-assets/htmx.min.js\"></script>"
      "<script src=\"/canvas-assets/htmx-ext-sse.min.js\"></script></head>"
      "<body><p>sort=a page=NIL</p></body></html>")
  "The full page for GET PEOPLE ?sort=a without HX-Request, exactly as
rpc-backend-htmx 0.1.0 serves it (canvas-protocol 0.2.0, default transport).")

(defparameter +keys-script+ "<script src=\"/canvas-assets/canvas-keys.js\"></script>")

(defun with-keys-script (page &optional (script +keys-script+))
  "PAGE with SCRIPT inserted right before </head>."
  (let ((at (search "</head>" page)))
    (s+ (subseq page 0 at) script (subseq page at))))

(defun keys-client (&rest transport-keys)
  (canvas-client (apply #'hc:make-canvas-htmx-transport transport-keys)))

(defun plain-page (client method &optional params)
  (h:htmx-reply-body (h:htmx-request client method params :hx-request nil)))

(defun key-grid (&key key)
  (canvas:el :div (canvas:hx-post (canvas:canvas-link 'key-grid) :keys '("ArrowUp" "Ctrl+z"))
             (or key "none")))

(deftest page-keys-default-is-0.1.0
  (let ((tx (hc:make-canvas-htmx-transport)))
    (ok (null (hc:canvas-transport-page-keys tx)))
    (ok (equal +people-page-0.1.0+ (plain-page (canvas-client tx) (m "PEOPLE") '(:sort "a")))
        "byte-identical to 0.1.0")
    (ok (equal +people-page-0.1.0+ (plain-page (keys-client :page-keys nil) (m "PEOPLE")
                                               '(:sort "a")))
        ":page-keys nil is the default")))

(deftest page-keys-t
  (let* ((tx (hc:make-canvas-htmx-transport :page-keys t))
         (page (plain-page (canvas-client tx) (m "PEOPLE") '(:sort "a"))))
    (ok (eq t (hc:canvas-transport-page-keys tx)))
    (ok (equal (with-keys-script +people-page-0.1.0+) page)
        "the 0.1.0 page plus one script, the last element of <head>")
    (ok (contains (s+ "<script src=\"/canvas-assets/htmx.min.js\"></script>"
                      "<script src=\"/canvas-assets/htmx-ext-sse.min.js\"></script>"
                      +keys-script+ "</head>")
                  page)
        "after htmx and htmx-ext-sse")))

(deftest page-keys-asset-prefix
  (let* ((c (keys-client :asset-prefix "/static/" :page-keys t))
         (page (plain-page c (m "PEOPLE")))
         (asset (h:htmx-request-env c (env :path "/static/canvas-keys.js"))))
    (ok (contains "<script src=\"/static/canvas-keys.js\"></script></head>" page))
    (ok (not (contains "/canvas-assets/" page)))
    (ok (= 200 (h:htmx-reply-status asset)) "the asset route serves the script it names")
    (ok (equal (canvas:asset-content-type "canvas-keys.js") (hdr asset "Content-Type")))
    (ok (equalp (canvas:asset-bytes "canvas-keys.js") (h:htmx-reply-body asset)))))

(deftest page-keys-only-full-pages
  (let ((c (keys-client :page-keys t)))
    (ok (equal "<p>sort=a page=NIL</p>"
               (h:htmx-reply-body (h:htmx-request c (m "PEOPLE") '(:sort "a"))))
        "an HX request still gets the fragment")
    (ok (equal "<p>sort=a page=NIL</p>"
               (h:htmx-reply-body (h:htmx-request c (m "PEOPLE") '(:sort "a")
                                                  :hx-request nil :http-method :post)))
        "a plain POST too")
    (let ((r (h:htmx-request c (m "NOPE") nil :hx-request nil)))
      (ok (= 404 (h:htmx-reply-status r)))
      (ok (not (contains "<script" (h:htmx-reply-body r))) "an error response carries no script"))))

(deftest page-keys-per-handler
  (dolist (selection (list (list 'people) (list (m "PEOPLE")) (list 'linker (m "PEOPLE"))))
    (let ((c (keys-client :page-keys selection)))
      (ok (equal (with-keys-script +people-page-0.1.0+) (plain-page c (m "PEOPLE") '(:sort "a")))
          (format nil "~S: a listed method loads the script" selection))
      (ok (equal (plain-page (canvas-client) (m "BADGE-CANVAS"))
                 (plain-page c (m "BADGE-CANVAS")))
          (format nil "~S: another method's page stays as in 0.1.0" selection))))
  (ok (equal (list (m "PEOPLE") (m "LINKER"))
             (hc:canvas-transport-page-keys
              (hc:make-canvas-htmx-transport :page-keys (list 'people (m "LINKER")))))
      "symbols become method names, in the given order"))

(deftest page-keys-refusals
  (dolist (bad (list :yes "RPC-BACKEND-HTMX/TESTS::PEOPLE" 'people 42
                     (list :people) (list "nocolons") (list "::x") (list 3)
                     (list* 'people 'linker)))
    (ok (signals (hc:make-canvas-htmx-transport :page-keys bad) 'type-error)
        (format nil "~S" bad))))

(deftest page-keys-bound-canvas
  ;; A key-bound canvas: its page loads the script that fires canvas:key; the
  ;; request it then sends carries the chord as the param "key".
  (let* ((tx (hc:make-canvas-htmx-transport :page-keys '(key-grid)))
         (c (h:make-htmx-client (h:htmx-app tx (h:make-htmx-handlers 'key-grid))
                                :codec (h:htmx-transport-codec tx)))
         (page (plain-page c (m "KEY-GRID"))))
    (ok (contains "data-canvas-keys=\"ArrowUp Ctrl+z\"" page))
    (ok (contains "hx-trigger=\"canvas:key\"" page))
    (ok (contains (s+ +keys-script+ "</head>") page))
    (ok (equal (s+ "<div hx-post=\"/canvas/RPC-BACKEND-HTMX%2FTESTS::KEY-GRID\""
                   " hx-trigger=\"canvas:key\" data-canvas-keys=\"ArrowUp Ctrl+z\">ArrowUp</div>")
               (h:htmx-reply-body (h:htmx-request c (m "KEY-GRID") '(:key "ArrowUp")
                                                  :http-method :post :trigger "grid")))
        "the bound request reaches the handler")))
