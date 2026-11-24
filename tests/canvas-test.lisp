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

;;; Streaming through the canvas transport: the response function runs after
;;; HTMX-HANDLE-REQUEST (and its :around) returned, yet the handler still
;;; builds links through CANVAS:*CANVAS-RESOLVER*.

(defun canvas-link-ticker (stream &key)
  (rpc:rpc-send stream (cons "row" (canvas:el :a (canvas:hx-get (canvas:canvas-link 'people :sort "-name"))
                                              "sort")))
  (rpc:rpc-send stream (cons "row" (canvas:el :span nil (canvas:canvas-url 'people :page 2))))
  (rpc:rpc-send stream (cons "row" (canvas:el :span nil (if (canvas:canvas-url 'not-listed)
                                                            "listed" "inert")))))

(deftest canvas-stream-builds-links
  (let* ((tx (canvas-transport))
         (c (h:make-htmx-client
             (h:htmx-app tx (h:make-htmx-handlers 'people '(canvas-link-ticker :mode :call-stream)))
             :codec (h:htmx-transport-codec tx)))
         (r nil) (escaped nil))
    (ok (progn (block run
                 (handler-bind ((error (lambda (e) (setf escaped e) (return-from run))))
                   (setf r (h:htmx-request c (m "CANVAS-LINK-TICKER") nil
                                           :accept "text/event-stream"))))
               (null escaped))
        "no error escapes")
    (ok (= 200 (h:htmx-reply-status r)))
    (ok (equal `(("row" . ,(s+ "<a hx-get=\"" +people-url+ "?sort=-name\">sort</a>"))
                 ("row" . ,(s+ "<span>" +people-url+ "?page=2</span>"))
                 ("row" . "<span>inert</span>"))
               (h:htmx-reply-events r))
        "the request's resolver (with its allowlist) is bound while the stream runs")
    (ok (notany (lambda (ev) (equal h:+stream-error-event+ (car ev))) (h:htmx-reply-events r))
        "no *canvas-resolver* is NIL error event")))

;;; Sortable tables end to end (canvas-protocol#13). Every link a table emits
;;; must be one its canvas takes: under the 0.3.0 key sets (#2) a param the
;;; canvas does not take is a 400. An unpaged table canvas takes &key sort
;;; alone, so its header links carry no page (canvas-protocol >= 0.2.2); a
;;; paged one takes &key sort page.

(defparameter *table-rows*
  (list (list :name "Bo" :age 30) (list :name "Al" :age 25) (list :name "Cy" :age 41)))

(defun sortable-columns ()
  (list (canvas:column "Name" :name :name "name" :sortable t)
        (canvas:column "Age" :age :name "age" :sortable t)))

(defun sort-only-table (&key sort)
  (canvas:table *table-rows* (sortable-columns) :id "t"
                :link (canvas:canvas-link 'sort-only-table) :sort sort))

(defun paged-table (&key sort page)
  (canvas:table *table-rows* (sortable-columns) :id "t"
                :link (canvas:canvas-link 'paged-table) :sort sort :page page :page-size 2))

(defun table-client ()
  (let ((tx (canvas-transport)))
    (h:make-htmx-client (h:htmx-app tx (h:make-htmx-handlers 'sort-only-table 'paged-table))
                        :codec (h:htmx-transport-codec tx))))

(defun button-links (reply)
  "The hx-get of every button in REPLY's fragment that has one, in document order."
  (let ((html:*html-backend* (html-backend-plump:make-plump-backend)))
    (loop for button in (html:select (h:htmx-reply-fragment reply) "button")
          for url = (html:element-attr button "hx-get")
          when url collect url)))

(deftest table-header-click-on-sort-only-canvas
  (let* ((c (table-client))
         (first (h:htmx-request c (m "SORT-ONLY-TABLE") nil))
         (links (button-links first)))
    (ok (= 200 (h:htmx-reply-status first)))
    (ok (= 2 (length links)) "one link per sortable header, no pager")
    (dolist (url links)
      (ok (not (search "page=" url)) (s+ "no page param: " url))
      (let ((r (h:htmx-request-url c url)))
        (ok (= 200 (h:htmx-reply-status r)) (s+ "header click is 200: " url))
        (ok (contains "aria-sort=\"ascending\"" (h:htmx-reply-body r)) "the clicked sort applies")))))

(deftest table-header-and-pager-clicks-on-paged-canvas
  (let* ((c (table-client))
         (links (button-links (h:htmx-request c (m "PAGED-TABLE") '(:sort "age")))))
    (ok (= 3 (length links)) "two headers and Next (Previous is disabled)")
    (ok (every (lambda (url) (search "page=" url)) links) "paged links carry page")
    (dolist (url links)
      (ok (= 200 (h:htmx-reply-status (h:htmx-request-url c url))) (s+ "click is 200: " url)))))
