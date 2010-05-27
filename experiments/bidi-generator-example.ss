#lang scheme
(require "bidi-generator.ss")

(define (print-all)
  (display "FIRST")
  (newline)
  (do ()
    (#f)
    (display (yield))
    (newline)))

(let ((pa (generator () (print-all))))
  (pa)
  (pa 1)
  (pa 2)
  (pa 3))

(define (yield-four)
  (generator ()
             (yield 1)
             (yield 2)
             (yield 3)
             (yield 4)
             'final-value))

(let ((x (yield-four)))
  (display (x))
  (display (x 'a))
  (display (x 'b))
  (display (x 'c))
  (display (x 'd)))