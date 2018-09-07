(in-package :lem-language-client)

(defparameter *root-path* (probe-file "."))
(defparameter *log-stream* *error-output*)

(defparameter |TextDocumentSyncKind.None| 0)
(defparameter |TextDocumentSyncKind.Full| 1)
(defparameter |TextDocumentSyncKind.Incremental| 2)

(defparameter |TextDocumentSaveReason.Manual| 1)
(defparameter |TextDocumentSaveReason.AfterDelay| 2)
(defparameter |TextDocumentSaveReason.FocusOut| 3)

(defvar *workspaces* '())
(defvar *response-methods* '())

(defstruct workspace
  connection
  server-capabilities
  text-document-sync
  root
  language-id
  (file-version-table (make-hash-table)))

(defstruct text-document-sync
  open-close
  change
  will-save
  will-save-wait-until
  save)

(lem:define-minor-mode language-client-mode
    (:name "Language Client")
  (setf (lem:variable-value 'lem.language-mode:completion-function) 'completion)
  ;(uiop:run-program "go-langserver -mode tcp -gocodecompletion &")
  (let ((buffer (lem:current-buffer)))
    (start (lem:buffer-major-mode buffer) buffer)))

(defun get-language-id (language)
  (ecase language
    (lem-js-mode:js-mode "javascript")
    (lem-go-mode:go-mode "go")))

(defmacro define-response-method (name (&rest vars) &body body)
  (alexandria:with-gensyms (params)
    `(pushnew
      (defun ,name (,params)
        (let ,(mapcar (lambda (var)
                        `(,var (gethash ,(string var) ,params)))
                      vars)
          ,@body))
      *response-methods*)))

(defun pathname-to-uri (pathname)
  (let ((filename (namestring pathname)))
    (format nil "file://~A"
            (if (alexandria:starts-with-subseq "~/" filename)
                (merge-pathnames (subseq filename 2) (user-homedir-pathname))
                filename))))

(defun {} (&rest plist)
  (alexandria:plist-hash-table plist :test 'equal))

(defun -> (table &rest keys)
  (loop :for k* :on keys
        :for k := (first k*)
        :do (if (rest k*)
                (progn
                  (setf table (gethash k table))
                  (unless (hash-table-p table)
                    (return nil)))
                (setf table (gethash k table)))
        :finally (return table)))

(defun merge-table (parent child)
  (maphash (lambda (key value)
             (setf (gethash key child) value))
           parent)
  child)

(defun find-workspace (root-path)
  (find root-path *workspaces*
        :test #'equal
        :key #'workspace-root))

(defun buffer-language-id (buffer)
  (lem:mode-name (lem:buffer-major-mode buffer)))

(defun buffer-workspace (buffer)
  (lem:buffer-value buffer 'workspace))

(defun (setf buffer-workspace) (workspace buffer)
  (setf (lem:buffer-value buffer 'workspace) workspace))

(defun buffer-file-version (buffer)
  (gethash buffer (workspace-file-version-table (buffer-workspace buffer)) 0))

(defun (setf buffer-file-version) (value buffer)
  (setf (gethash buffer (workspace-file-version-table (buffer-workspace buffer))) value))

(defun buffer-text (buffer)
  (lem:points-to-string (lem:buffer-start-point buffer)
                        (lem:buffer-end-point buffer)))

(defun buffer-uri (buffer)
  (pathname-to-uri (lem:buffer-filename buffer)))

(defun lsp-position (point)
  ({} "line" (1- (lem:line-number-at-point point))
      "character" (lem:point-charpos point)))

(defun lsp-range (start end)
  (when (lem:point< end start)
    (rotatef start end))
  ({} "start" (lsp-position start)
      "end" (lsp-position end)))

(defun lsp-location (start end)
  (let ((buffer (lem:point-buffer start)))
    ({} "uri" (buffer-uri buffer)
        "range" (lsp-range start end))))

(defun move-to-lsp-position (point position)
  (let-hash (|line| |character|) position
    (lem:move-to-line point (1+ |line|))
    (lem:line-offset point 0 |character|)
    point))

(defun decode-lsp-text-edit (buffer text-edit)
  (let-hash (|range| |newText|) text-edit
    (let-hash (|start| |end|) |range|
      (lem:with-point ((start-point (lem:buffer-point buffer))
                       (end-point (lem:buffer-point buffer)))
        (move-to-lsp-position start-point |start|)
        (move-to-lsp-position (lem:move-point end-point start-point) |end|)
        (values start-point end-point |newText|)))))

(defun text-document-identifier (buffer)
  ({} "uri" (buffer-uri buffer)))

(defun text-document-item (buffer)
  ({} "uri" (buffer-uri buffer)
      "languageId" (workspace-language-id (buffer-workspace buffer))
      "version" (buffer-file-version buffer)
      "text" (buffer-text buffer)))

(defun versioned-text-document-identifier (buffer)
  (let ((text-document-identifier (text-document-identifier buffer))
        (version (buffer-file-version buffer)))
    (merge-table text-document-identifier
                 ({} "version" version))))

(defun text-document-position-params (point)
  ({} "textDocument" (text-document-identifier (lem:point-buffer point))
      "position" (lsp-position point)))

(defun workspace-client-capabilities ()
  ({} "applyEdit" 'yason:false
      "workspaceEdit" ({} "documentChanges" 'yason:false)
      "didChangeConfiguration" ({} "dynamicRegistration" 'yason:false)
      "didChangeWatchedFiles" ({} "dynamicRegistration" 'yason:false)
      "symbol" ({} "dynamicRegistration" 'yason:false
                   "symbolKind" ({} "valueSet" #()))
      "executeCommand" ({} "dynamicRegistration" 'yason:false)
      "workspaceFolders" 'yason:false
      "configuration" 'yason:false))

(defun text-document-client-capabilities ()
  ({} "synchronization" ({} "dynamicRegistration" 'yason:false
                            "willSave" 'yason:false
                            "willSaveWaitUntil" 'yason:false
                            "didSave" 'yason:false)
      "completion" ({} "dynamicRegistration" 'yason:false
                       "completionItem" ({} "snippetSupport" 'yason:false
                                            "commitCharacterSupport" 'yason:false
                                            "documentationFormat" #()
                                            "deprecatedSupport" 'yason:false
                                            "preselectSupport" 'yason:false)
                       "completionItemKind" ({} "valueSet" #())
                       "contextSupport" 'yason:false)
      "hover" ({} "dynamicRegistration" 'yason:false
                  "contentFormat" #())
      "signatureHelp" ({} "dynamicRegistration" 'yason:false
                          "signatureInformation" ({} "documentationFormat" #()))
      "references" ({} "dynamicRegistration" 'yason:false)
      "documentHighlight" ({} "dynamicRegistration" 'yason:false)
      "documentSymbol" ({} "dynamicRegistration" 'yason:false
                           "symbolKind" ({} "valueSet" #()))
      "formatting" ({} "dynamicRegistration" 'yason:false)
      "rangeFormatting" ({} "dynamicRegistration" 'yason:false)
      "onTypeFormatting" ({} "dynamicRegistration" 'yason:false)
      "definition" ({} "dynamicRegistration" 'yason:false)
      "typeDefinition" ({} "dynamicRegistration" 'yason:false)
      "implementation" ({} "dynamicRegistration" 'yason:false)
      "codeAction" ({} "dynamicRegistration" 'yason:false
                       "codeActionLiteralSupport" ({}
                                                   "codeActionKind" ({}
                                                                     "valueset" #())))
      "codeLens" ({} "dynamicRegistration" 'yason:false)
      "documentLink" ({} "dynamicRegistration" 'yason:false)
      "colorProvider" ({} "dynamicRegistration" 'yason:false)
      "rename" ({} "dynamicRegistration" 'yason:false)
      "publishDiagnostics" ({} "relatedInformation" 'yason:false)))

(defun client-capabilities ()
  ({} "workspace" (workspace-client-capabilities)
      "textDocument" (text-document-client-capabilities)
      #|"experimental"|#))

(defun convert-text-document-sync (sync)
  (etypecase sync
    (number
     (make-text-document-sync :change sync))
    (hash-table
     (make-text-document-sync :open-close (gethash "openClose" sync)
                              :change (gethash "change" sync)
                              :will-save (gethash "willSave" sync)
                              :will-save-wait-until (gethash "willSaveWaitUntil" sync)
                              :save (gethash "save" sync)))))

(defun initialize (workspace)
  (let* ((root (workspace-root workspace))
         (response (jsonrpc-call (workspace-connection workspace)
                                 "initialize"
                                 ({}
                                  "processId" (getpid)
                                  #|"rootPath" root|#
                                  "rootUri" (pathname-to-uri root)
                                  #|"initializationOptions"|#
                                  "capabilities" (client-capabilities)
                                  #|"trace" "off"|#
                                  #|"workspaceFolders" nil|#)))
         (server-capabilities (gethash "capabilities" response)))
    (setf (workspace-server-capabilities workspace)
          server-capabilities)
    (alexandria:when-let (sync (gethash "textDocumentSync" server-capabilities))
      (setf (workspace-text-document-sync workspace)
            (convert-text-document-sync sync)))))

(defun initialized (workspace)
  (jsonrpc-notify (workspace-connection workspace) "initialized" ({})))

(defun shutdown (workspace)
  (jsonrpc-call (workspace-connection workspace) "shutdown" ({})))

(defun exit (workspace)
  (jsonrpc-notify (workspace-connection workspace) "exit" ({})))

(define-response-method |window/showMessage| (|type| |message|)
  (declare (ignore |type|))
  (lem:message "~A" |message|))

(define-response-method |window/showMessageRequest| (|type| |message|)
  (declare (ignore |type|))
  (lem:message "~A" |message|))

(define-response-method |window/logMessage| (|type| |message|)
  (format *log-stream* "~A: ~A" |type| |message|))

(defun text-document-did-open (buffer)
  (jsonrpc-notify (workspace-connection (buffer-workspace buffer))
                  "textDocument/didOpen"
                  ({} "textDocument" (text-document-item buffer))))

(defun text-document-did-change (buffer changes)
  (jsonrpc-notify (workspace-connection (buffer-workspace buffer))
                  "textDocument/didChange"
                  ({} "textDocument" (versioned-text-document-identifier buffer)
                      "contentChanges" changes)))

(defun text-document-content-change-event (point string-or-number)
  (let ((start-position (lsp-position point)))
    (etypecase string-or-number
      (string
       ({} "range" ({} "start" start-position
                       "end" start-position)
           "rangeLength" 0
           "text" string-or-number))
      (number
       (lem:with-point ((end point))
         (lem:character-offset end string-or-number)
         (let ((end-position (lsp-position end)))
           ({} "range" ({} "start" start-position
                           "end" end-position)
               "rangeLength" (lem:count-characters end point)
               "text" "")))))))

(defun text-document-will-save (buffer &optional (reason |TextDocumentSaveReason.Manual|))
  (jsonrpc-notify (workspace-connection (buffer-workspace buffer))
                  "textDocument/willSave"
                  ({} "textDocument"
                      "reason" reason)))

(defun text-document-will-save-wait-until (buffer &optional (reason |TextDocumentSaveReason.Manual|))
  (let ((workspace (buffer-workspace buffer)))
    (jsonrpc-notify (workspace-connection workspace)
                    "textDocument/willSaveWaitUntil"
                    ({} "textDocument"
                        "reason" reason))))

(defun text-document-did-save (buffer)
  (jsonrpc-notify (workspace-connection (buffer-workspace buffer))
                  "textDocument/didSave"
                  ({} "textDocument" (text-document-identifier buffer)
                      #|"text" (buffer-text buffer)|#)))

(defun text-document-did-close (buffer)
  (let* ((workspace (buffer-workspace buffer))
         (file-version-table (workspace-file-version-table workspace)))
    (remhash buffer file-version-table)
    (jsonrpc-notify (workspace-connection workspace)
                    "textDocument/didClose"
                    ({} "textDocument" (text-document-identifier buffer)))
    (when (zerop (hash-table-count file-version-table))
      (shutdown workspace))))

(defun hover-contents-to-string (contents)
  (typecase contents
    (string contents)
    (list
     (with-output-to-string (out)
       (dolist (c contents)
         (write-string (hover-contents-to-string c) out)
         (terpri out))))
    (hash-table
     (gethash "value" contents ""))
    (otherwise
     "")))

(defun completion-params (point &optional (trigger-kind 1))
  (setq trigger-kind 1)
  (merge-table (text-document-position-params point)
               ({} "triggerKind" trigger-kind
                   #|"triggerCharacter"|#)))

(defun completion-items (buffer items)
  (delete
   nil
   (map 'list
        (lambda (item)
          (let-hash (|label|
                     |kind| |detail| |documentation| |deprecated| |preselect|
                     |sortText| |filterText| |insertText| |insertTextFormat|
                     |textEdit| |additionalTextEdits| |commitCharacters|
                     |command| |data|)
              item
            (declare (ignorable |label|
                                |kind| |detail| |documentation| |deprecated| |preselect|
                                |sortText| |filterText| |insertText| |insertTextFormat|
                                |textEdit| |additionalTextEdits| |commitCharacters|
                                |command| |data|))
            (cond
              (|textEdit|
               (multiple-value-bind (start end newText)
                   (decode-lsp-text-edit buffer |textEdit|)
                 (lem.completion-mode:make-completion-item
                  :label newText :detail |detail| :start start :end end)))
              (|label|
               (lem.completion-mode:make-completion-item :label |label|)))))
        items)))

(defun completion (point)
  (let* ((workspace (buffer-workspace (lem:point-buffer point)))
         (result (jsonrpc-call (workspace-connection workspace)
                               "textDocument/completion"
                               (completion-params point)))
         (buffer (lem:point-buffer point)))
    (etypecase result
      (null)
      (vector
       (completion-items buffer result))
      (hash-table
       (completion-items buffer (gethash "items" result))))))

(defun hover (point)
  (let ((workspace (buffer-workspace (lem:point-buffer point))))
    (handler-case
        (let ((hover (jsonrpc-call (workspace-connection workspace)
                                   "textDocument/hover"
                                   (text-document-position-params point))))
          (let ((contents (gethash "contents" hover)))
            (hover-contents-to-string contents)))
      (jsonrpc:jsonrpc-error (e)
        (jsonrpc:jsonrpc-error-message e)))))

(defun on-change (point arg)
  (let* ((buffer (lem:point-buffer point))
         (workspace (buffer-workspace buffer)))
    (incf (buffer-file-version buffer))
    (text-document-did-change buffer
                              (alexandria:switch
                                  ((text-document-sync-change
                                    (workspace-text-document-sync workspace))
                                   :test #'eql)
                                (|TextDocumentSyncKind.None|)
                                (|TextDocumentSyncKind.Full|
                                 (list ({} "text" (buffer-text buffer))))
                                (|TextDocumentSyncKind.Incremental|
                                 (list (text-document-content-change-event
                                        point
                                        (if (characterp arg)
                                            (string arg)
                                            arg))))))))

(defun initialize-hooks (buffer)
  (lem:add-hook (lem:variable-value 'lem:before-change-functions :buffer buffer) 'on-change)
  ;(lem:add-hook (lem:variable-value 'lem:before-save-hook :buffer buffer) 'text-document-will-save)
  (lem:add-hook (lem:variable-value 'lem:after-save-hook :buffer buffer) 'text-document-did-save)
  (lem:add-hook (lem:variable-value 'lem:kill-buffer-hook :buffer buffer) 'text-document-did-close))

(defun start (language buffer)
  (let* ((root-path *root-path*)
         (workspace (find-workspace root-path)))
    (cond
      (workspace
       (setf (buffer-workspace buffer) workspace))
      (t
       (let* ((connection (jsonrpc:make-client))
              (workspace (make-workspace :connection connection
                                         :root root-path
                                         :language-id (get-language-id language))))
         (push workspace *workspaces*)
         (setf (buffer-workspace buffer) workspace)
         (dolist (response-method *response-methods*)
           (jsonrpc:expose connection (string response-method) response-method))
         (jsonrpc:client-connect (workspace-connection workspace)
                                 :mode :tcp
                                 :port 2089)
         (initialize workspace)
         (initialized workspace)
         workspace))))
  (text-document-did-open buffer)
  (initialize-hooks buffer)
  (values))

(lem:define-command lsp-hover () ()
  (alexandria:when-let ((message (hover (lem:current-point))))
    (lem:display-popup-message (wrap-text message 80))))
