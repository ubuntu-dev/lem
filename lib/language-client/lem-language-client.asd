(defsystem "lem-language-client"
  :depends-on ("jsonrpc" "quri" "lem-process")
  :serial t
  :components ((:file "package")
               (:file "util")
               (:file "jsonrpc-util")
               (:file "jsonrpc-class")
               (:file "language-client")))
