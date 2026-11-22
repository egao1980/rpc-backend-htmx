(defsystem "rpc-backend-htmx"
  :version "0.0.0"
  :description "htmx as an rpc-protocol transport + codec: Clack server, SSE streams, test client (H4h-1b)"
  :author "egao1980"
  :license "MIT"
  :depends-on ()
  :serial t
  :pathname "src"
  :components ((:file "package"))
  :in-order-to ((test-op (test-op "rpc-backend-htmx/tests"))))

(defsystem "rpc-backend-htmx/tests"
  :depends-on ("rpc-backend-htmx" "rove")
  :pathname "tests"
  :serial t
  :components ((:file "package"))
  :perform (test-op (o c)
             (unless (symbol-call :rove :run c)
               (error "tests failed for ~A" (component-name c)))))
