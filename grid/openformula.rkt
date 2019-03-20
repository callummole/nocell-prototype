#lang racket/base

#|

Parse and generate (a small subset of) OpenFormula format formulae from
cell-values.  OpenFormula is the formula language used within OpenDocument
spreadsheets [1].

[1] "Open Document Format for Office Applications (OpenDocument)
    Version 1.2, part 2: Recalculated Formula (OpenFormula)
    Format", OASIS, September 2011

TODO
- Only a limited set of functions are supported
- Doesn't work with ranges

|#

(require racket/format
         racket/string
         racket/match
         racket/list
         rackunit
         math/array
         "sheet.rkt"
         )

(provide cell-expr->openformula
         openformula->cell-expr)

;; ---------------------------------------------------------------------------------------------------

(define (transpose arr) (array-axis-swap arr 0 1))

;; format-element : atomic-value? -> string
(define (format-element elt)
  (cond
    [(real? elt) (~a elt)]
    [(string? elt) (format "&quot;~a&quot;" elt)]
    [(boolean? elt) (if elt "TRUE" "FALSE")]
    [(nothing? elt) ""]
    [else (raise-argument-error 'format-element
                                "atomic-value?"
                                elt)]))

(define (format-array arr)
  (let ((rows (array->list* (transpose arr))))
    (string-join
     (map (lambda (elts)
            (string-join
             (map (lambda (elt) (format-element elt))
                  elts)
             ";"))
          rows)
     "|"
     #:before-first "{"
     #:after-last   "}"
     )))

(module+ test
  (check-equal?
   (format-array (array #[#[1 2 3] #[4 5 6]]))
   "{1;4|2;5|3;6}"))

(define (fmt-infix op a1 a2)
  (format "(~a~a~a)" a1 op a2))

(define (fmt-prefix fn-name as)
  (string-join as ";"
               #:before-first (string-append fn-name "(")
               #:after-last ")"))

;; symbol? (List-of cell-expr?) -> string?
(define (format-app builtin fmt-args)
  (match `(,builtin . ,fmt-args)
    [(list op x y) #:when (memq op '(+ - * /))
                   (fmt-infix op x y)]
    [(list 'expt x y) (fmt-infix "POWER" x y)]
    [(list 'modulo x y) (fmt-infix "MOD" x y)]
    [(list 'truncate x) (fmt-infix "TRUNC" x)]
    [(list '+ xs ...) (fmt-prefix "SUM" xs)]
    [(list '* xs ...) (fmt-prefix "PRODUCT" xs)]
    [(list fn xs ...) (fmt-prefix (string-upcase (symbol->string fn)) xs)]
    ))

;; --------------------------------------------------------------------------------
;;
;; convert a numeric (zero-indexed) column reference to and from a
;; column letter (A,...,Z,AA,...,AZ,...,ZZ,AAA,...) 
;;
(define codepoint-A 65)

(define (integer->column-letter n)
  (define (recur rems b)
    (if (< (car rems) b)
        rems
        (let-values ([(q r) (quotient/remainder (car rems) b)])
          (recur (list* (- q 1) r (cdr rems)) b))))
  (list->string
   (map (lambda (d) (integer->char (+ d codepoint-A)))
        (recur (list n) 26))))

(define (column-letter->integer cs)
  (let ((ds (map (lambda (c) (- (char->integer c) codepoint-A))
                 (string->list cs))))
    (- (foldl (lambda (a b) (+ (* 26 b) (+ a 1))) 0 ds) 1)))

(module+ test
  (test-case "Column letter"
    (check-equal? (integer->column-letter 0)   "A")
    (check-equal? (integer->column-letter 1)   "B")
    (check-equal? (integer->column-letter 25)  "Z")
    (check-equal? (integer->column-letter 26)  "AA")
    (check-equal? (integer->column-letter 701) "ZZ")
    (check-equal? (integer->column-letter 702) "AAA")
    (check-equal? (integer->column-letter 728) "ABA")
    (for-each
     (lambda (n)
       (with-check-info
         (('current-element n))
         (check-equal? n
                       (column-letter->integer
                        (integer->column-letter n)))))
     (range 0 10000))))
;;
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;


;; cell-addr? -> string?
(define (format-ref ref)
  (let ((col-$ (if (cell-addr-col-is-rel ref) "$" ""))
        (row-$ (if (cell-addr-row-is-rel ref) "$" ""))
        (col-A (integer->column-letter (cell-addr-col ref)))
        (row-1 (add1 (cell-addr-row ref))))
    (format ".~a~a~a~a" col-$ col-A row-$ row-1)))

;; cell-expr->openformula : cell-expr? -> string?
(define (cell-expr->openformula expr)
  (match expr
    [(cell-value elements)
     (if (simple-cell-value? expr)
         (format-element (array-ref elements #(0 0)))
         (format-array elements))]
    
    [(struct cell-addr _) (string-append "[" (format-ref expr) "]")]
    
    [(cell-range tl br)
     (string-append "[" (format-ref tl) ":" (format-ref br) "]")]
    
    [(cell-name id) (~a id)]
    
    [(cell-app builtin args)
     (let ((fmt-args (map cell-expr->openformula args)))
       (format-app builtin fmt-args))]
    ))


;; --------------------------------------------------------------------------------
;;
;; Openformula parser
;;

(require parsack)

(define (maybe s)
  (<or> s (return null)))

(define (withSpaces s)
  (parser-one
   $spaces
   (~> s)
   $spaces))

(define (char->symbol c) (string->symbol (list->string (list c))))

;; parse infix operator parser by their precedence
(define ($infix-op prec)
  (case prec
    ((0) (oneOf "+-"))
    ((1) (oneOf "/*"))
    ((2) (oneOf "^"))
    (else #f)))

(define (($openformula-expr/prec prec) s)
  (let (($op ($infix-op prec)))
    ((parser-compose
      (left <- (withSpaces (if (not $op)
                               $l-expr
                               ($openformula-expr/prec (+ prec 1)))))
      (<or> (try (parser-compose
                  (op <- (or $op $err)) ; $op is #f after last
                                        ; precedence level - call
                                        ; error parser to skip to the
                                        ; other <or> case
                  (op-sym <- (return (char->symbol op)))
                  (right <- (withSpaces ($openformula-expr/prec prec)))
                  (return (cell-app op-sym (list left right)))))
            (return left)))
     s)))

(define $openformula-expr ($openformula-expr/prec 0))

(define $parenthesized-expr
  (between (string "(") (string ")") $openformula-expr))

(define $function-name
  (parser-compose
   (fn <- $identifier)
   (fn-str <- (return (string-downcase (list->string fn))))
   (return
    (case fn-str
      (("sum")     '+)
      (("power")   'expr)
      (("product") '*)
      (("mod")     'modulo)
      (("trunc")   'truncate)
      (else        (string->symbol fn-str))))))

(define $prefix-app
  (parser-compose
   (fn <- $function-name)
   $spaces
   (args <- (between (char #\() (char #\))
                     (sepBy (parser-one $spaces
                                        (~> $openformula-expr)
                                        $spaces)
                            (char #\;))))
   $spaces
   (return (cell-app fn args))
   ))

(define $cell-name
  (parser-compose
   (id <- $identifier)
   (return (cell-name (list->string id)))))

(define $cell-string
  (between (string "&quot;") (string "&quot;")
           (many1 (<!> (string "&quot;")))))

(define $decimal
  (>>= (parser-seq
        (maybe (oneOf "+-"))
        (<or>
         (parser-seq (char #\.) (many1 $digit))
         (try (parser-seq (many1 $digit) (char #\.)))
         (many1 $digit))
        (many $digit))
       (lambda (t) (return (flatten t)))))

(define $cell-number
  (>>= (parser-seq
        $decimal
        (maybe (parser-seq (oneOf "eE")
                           (maybe (oneOf "+-"))
                           (many1 $digit))))
       (lambda (t) (return (string->number
                            (list->string (flatten t)))))))

(define $cell-bool
  (<or> (>> (string "TRUE") (return #t))
        (>> (string "FALSE") (return #f))))

(define $cell-atomic
  (<or> $cell-number
        $cell-bool))

(define $cell-simple-value
  (>>= $cell-atomic
       (lambda (val)
         (return (cell-value-return val)))))

(module+ test
  (check-equal? (parse-result $cell-atomic "1")   1)
  (check-equal? (parse-result $cell-atomic "1.")  1.0)
  (check-equal? (parse-result $cell-atomic ".0")  0.0)
  (check-equal? (parse-result $cell-atomic "2.4") 2.4)
  (check-equal? (parse-result $cell-atomic "1.1E+021") 1.1e21)

  (check-equal? (parse-result $cell-simple-value "0.0")
                (cell-value (array #[#[0.0]]))))


(define $cell-row
  (sepBy (withSpaces (<or> $cell-atomic (return 'nothing))) (char #\;)))

(define $cell-array
  (>>= (between (char #\{) (char #\})
                (sepBy (withSpaces $cell-row) (char #\|)))
       (lambda (elts)
         (return (cell-value (transpose (list*->array elts atomic-value?)))))))
(module+ test
  (check-equal?
   (parse-result $cell-array "{1;4|2;5|3;6}")
   (cell-value (array #[#[1 2 3] #[4 5 6]]))))

(define $ref-addr
  (parser-compose
   (char #\.)
   (col-rel-str <- (maybe (char #\$)))
   (col-rel?    <- (return (not (null? col-rel-str))))

   (col-letter  <- (many1 $letter))
   (col         <- (return (column-letter->integer
                            (list->string col-letter))))
   
   (row-rel-str <- (maybe (char #\$)))
   (row-rel?    <- (return (not (null? row-rel-str))))

   (row-str     <- (many1 $digit))
   (row         <- (return (sub1 (string->number
                                  (list->string row-str)))))
   (return (cell-addr col row col-rel? row-rel?))))

(define $cell-ref
  (between (char #\[) (char #\]) $ref-addr))
(module+ test
  (check-equal?
   (parse-result $cell-ref "[.D5]")
   (cell-addr 3 4 #f #f)))

(define $cell-range
  (between (char #\[) (char #\])
           (parser-compose
            (tl <- $ref-addr)
            (char #\:)
            (br <- $ref-addr)
            (return (cell-range tl br)))))
(module+ test
  (check-equal?
   (parse-result $cell-range "[.A$2:.$C4]")
   (cell-range (cell-addr 0 1 #f #t) (cell-addr 2 3 #t #f))))

(define $l-expr
  (<or> (try $parenthesized-expr)
        (try $prefix-app)
        (try $cell-simple-value)
        (try $cell-array)
        (try $cell-ref)
        (try $cell-range)
        $cell-name))

(define $openformula
  (parser-one
   ;; ignore any starting "=" or "of:="
   (maybe (string "of:"))
   (maybe (string "="))
   ;; allow for "recalculated" formulae (with second "=")
   (maybe (string "="))
   (~> $openformula-expr)
   $eof))

(define (openformula->cell-expr x)
  (parse-result $openformula x))

;; --------------------------------------------------------------------------------
;;

;; (module+ test
;;   (require "../eval.rkt")
;;   (test-case "openformula->cell-expr tests"
;;     (check-equal?
;;      (openformula->cell-expr "SUM({ 1;2  ; 3;4};[.A1])+ 5 *MOD( 7;   6)")
;;      (cell-app
;;       '+
;;       (list
;;        (cell-app
;;         '+
;;         (list
;;          (cell-value (array #[#[1] #[2] #[3] #[4]]))
;;          (cell-addr 0 0 #f #f)))
;;        (cell-app
;;         '*
;;         (list
;;          (cell-value (array #[#[5]]))
;;          (cell-app
;;           'modulo
;;           (list (cell-value (array #[#[7]]))
;;                 (cell-value (array #[#[6]])))))))))

;;     (check-equal?
;;      (sheet-eval (sheet (array #[#[(openformula->cell-expr
;;                                     ; note the empty value in the array
;;                                     "SUM({0;1|2; |4;5})")]])
;;                         null))
;;      (mutable-array #[#[12]]))))