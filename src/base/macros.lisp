(in-package :lem-base)

(export '(save-excursion
          with-point
          with-buffer-read-only
          without-interrupts))

(defmacro save-excursion (&body body)
  `(invoke-save-excursion (lambda () ,@body)))

(defmacro with-point (bindings &body body)
  (let ((cleanups
         (mapcan (lambda (b)
                   (destructuring-bind (var point &optional (kind :temporary)) b
                     (declare (ignore point))
                     (unless (eq :temporary kind)
                       `((delete-point ,var)))))
                 bindings)))
    `(let ,(mapcar (lambda (b)
                     (destructuring-bind (var point &optional (kind :temporary)) b
                       `(,var (copy-point ,point ,kind))))
                   bindings)
       ,(if cleanups
            `(unwind-protect (progn ,@body)
               ,@cleanups)
            `(progn ,@body)))))

(defmacro with-buffer-read-only (buffer flag &body body)
  (let ((gbuffer (gensym "BUFFER"))
        (gtmp (gensym "GTMP")))
    `(let* ((,gbuffer ,buffer)
            (,gtmp (buffer-read-only-p ,gbuffer)))
       (setf (buffer-read-only-p ,gbuffer) ,flag)
       (unwind-protect (progn ,@body)
         (setf (buffer-read-only-p ,gbuffer) ,gtmp)))))

(defmacro without-interrupts (&body body)
  `(#+ccl ccl:without-interrupts
    #+sbcl sb-sys:without-interrupts
    #-(or ccl sbcl) progn
    ,@body))