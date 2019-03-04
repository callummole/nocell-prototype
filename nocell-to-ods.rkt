#!/usr/bin/env racket
#lang racket
(require "private/nocell/main.rkt")
(require "private/raw/to-raw.rkt")
(require "private/raw/to-zip.rkt")

(let* ([arguments (vector->list (current-command-line-arguments))])
    (unless (equal? 2 (length arguments)) (begin (printf "nocell-to-ods <nocell-source> <ods-target>~n~nWill translate a nocell source file into an ods spreadshet~ne.g., nocell-to-ods examples/dcf.nocell dcf.ods~n") (exit -1)))
    (let* ([source (path->complete-path (string->path (first arguments)) (current-directory) )]
       [ods (path->complete-path (string->path (last arguments)) (current-directory) )]
       [nocell (file->value source)]
       [stack (nocell->stack nocell)]
       [grid (stack->grid stack)]
       [raw (workbook->raw (list (grid->raw-worksheet "sheet 1" grid)))]
      )
      (printf "Translating ~a into ~a~n" source ods)
      (raw->zip raw ods)
      (printf "Finished~n")
      )
)