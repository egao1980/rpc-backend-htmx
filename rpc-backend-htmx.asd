(defsystem "rpc-backend-htmx"
  :version "0.1.0"
  :description "htmx as an rpc-protocol transport + codec: Clack server, SSE streams, test client (H4h-1b)"
  :author "egao1980"
  :license "MIT"
  :depends-on ((:version "rpc-protocol" "0.2.0")
               (:version "http-server-protocol" "0.1.0")
               (:version "http-protocol" "0.4.0")
               (:version "sse-protocol" "0.1.1")
               (:version "sse-backend-clack" "0.1.1")
               (:version "html-protocol" "0.1.1")
               (:version "mime-protocol" "0.2.0")
               (:version "encoding-protocol" "0.2.0")
               "quri")
  :serial t
  :pathname "src"
  :components ((:file "package")
               (:file "conditions")
               (:file "handlers")
               (:file "codec")
               (:file "server")
               (:file "client"))
  :in-order-to ((test-op (test-op "rpc-backend-htmx/tests"))))

(defsystem "rpc-backend-htmx/canvas"
  :version "0.1.0"
  :description "canvas-protocol resolver + page/asset routes for rpc-backend-htmx (H4h-1b)"
  :author "egao1980"
  :license "MIT"
  :depends-on ("rpc-backend-htmx"
               (:version "canvas-protocol" "0.1.0"))
  :pathname "src/canvas"
  :serial t
  :components ((:file "package")
               (:file "canvas")))

(defsystem "rpc-backend-htmx/tests"
  :depends-on ("rpc-backend-htmx"
               "rpc-backend-htmx/canvas"
               (:version "rpc-protocol-json" "0.1.1")
               (:version "json-protocol" "0.2.3")
               (:version "json-backend-jzon" "0.2.3")
               (:version "rpc-backend-http" "0.1.2")
               (:version "html-backend-plump" "0.1.1")
               "rove")
  :pathname "tests"
  :serial t
  :components ((:file "package")
               (:file "support")
               (:file "handlers-test")
               (:file "codec-test")
               (:file "server-test")
               (:file "errors-test")
               (:file "stream-test")
               (:file "escape-test")
               (:file "limit-test")
               (:file "client-test")
               (:file "parity-test")
               (:file "canvas-test"))
  :perform (test-op (o c)
             (unless (symbol-call :rove :run c)
               (error "tests failed for ~A" (component-name c)))))
