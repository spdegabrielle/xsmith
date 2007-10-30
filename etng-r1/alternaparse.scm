(define etng-naked-id-terminators (string->list "`.()[]{}:;,'\""))

(define (char-etng-id-alpha? ch)
  (or (char-alphabetic? ch)
      (eqv? ch #\_)))

(define (char-etng-id-punct? ch)
  (not (or (char-alphabetic? ch)
	   (char-whitespace? ch)
	   (char-numeric? ch)
	   (memv ch etng-naked-id-terminators))))

(define EMPTY-SYMBOL (string->symbol ""))
(define SEMI-SYMBOL (string->symbol ";"))
(define COMMA-SYMBOL (string->symbol ","))
(define EQUAL-SYMBOL (string->symbol "="))

(define read-etng
  (let ()
    (define (list-interleave x xs)
      (cond
       ((null? xs) '())
       ((null? (cdr xs)) xs)
       (else (cons (car xs) (cons x (list-interleave x (cdr xs)))))))

    (define read-etng
      (let* ((non-eol (lambda (ch) (not (or (eqv? ch #\return)
					    (eqv? ch #\newline)))))
	     (non-string-quote (lambda (ch) (not (eqv? ch #\"))))
	     (non-id-quote (lambda (ch) (not (eqv? ch #\'))))

	     (reader
	      (packrat-parse
	       `(
		 (entry-point sexp)

		 (sexp (/ (ws #\. s <- sexp
			   ,(packrat-lambda (s) `(paren ,(make-qname EMPTY-SYMBOL 'quote) ,s)))
			  (ws #\` s <- sexp
			   ,(packrat-lambda (s) `(paren ,(make-qname EMPTY-SYMBOL 'unquote) ,s)))
			  (ws #\( ss <- sexps ws #\)
			      ,(packrat-lambda (ss) `(paren ,@ss)))
			  (ws #\[ ss <- sexps ws #\]
			      ,(packrat-lambda (ss) `(brack ,@ss)))
			  (ws #\{ ss <- sexps ws #\}
			      ,(packrat-lambda (ss) `(brace ,@ss)))
			  (l <- leaf
			     ,(packrat-lambda (l) l))))

		 (sexps (/ (s <- sexp ss <- sexps ,(packrat-lambda (s ss) (cons s ss)))
			   ,(packrat-lambda () '())))

		 (leaf (/ qname
			  word
			  string))

		 (qname (/ (lhs <- id #\: rhs <- id ,(packrat-lambda (lhs rhs)
							  (make-qname lhs rhs)))
			   (ws #\: rhs <- id ,(packrat-lambda (rhs)
						(make-qname EMPTY-SYMBOL rhs)))
			   (rhs <- id ,(packrat-lambda (rhs)
					 rhs
					 ;;(make-qname #f rhs)
					 ))))

		 (id (/ (ws i <- id1 ,(packrat-lambda (i)
					(string->symbol
					 (string-concatenate (list-interleave "'" i)))))
			(ws #\; ,(packrat-lambda () SEMI-SYMBOL))
			(ws #\, ,(packrat-lambda () COMMA-SYMBOL))
			(ws (a <- id-alpha) (r <- (/ id-alpha digit))*
			    ,(packrat-lambda (a r) (string->symbol (list->string (cons a r)))))
			(ws (p <- id-punct)+
			    ,(packrat-lambda (p) (string->symbol (list->string p))))))
		 (id1 (/ (i <- id-subunit is <- id1
			    ,(packrat-lambda (i is) (cons i is)))
			 (i <- id-subunit
			    ,(packrat-lambda (i) (list i)))))
		 (id-subunit (#\' (cs <- (/: ,non-id-quote "escaped-identifier-character"))* #\'
			      ,(packrat-lambda (cs) (list->string cs))))

		 (word (/ positive-word
			  (ws #\- w <- positive-word ,(packrat-lambda (w) (- w)))))
		 (positive-word (ws (d <- digit)+
				    ,(packrat-lambda (d) (string->number (list->string d)))))

		 (string (ws s <- string1 ,(packrat-lambda (s)
					     (string-concatenate (list-interleave "\"" s)))))
		 (string1 (/ (s <- string-subunit ss <- string1
				,(packrat-lambda (s ss) (cons s ss)))
			     (s <- string-subunit
				,(packrat-lambda (s) (list s)))))
		 (string-subunit (#\" (cs <- (/: ,non-string-quote "string character"))* #\"
				  ,(packrat-lambda (cs) (list->string cs))))

		 (id-alpha (/: ,char-etng-id-alpha? "identifier-character"))
		 (id-punct (/: ,char-etng-id-punct? "punctuation-character"))
		 (digit (/: ,char-numeric? "digit"))

		 (ws (/ ((/: ,char-whitespace? "whitespace")+ ws)
			(#\- #\- (/: ,non-eol "comment character")* (/ #\return #\newline) ws)
			()))

		 ))))
	(lambda (results k-ok k-fail)
	  (try-packrat-parse-pattern
	   (reader 'entry-point) '() results
	   (lambda (bindings result) (k-ok (parse-result-semantic-value result)
					   (parse-result-next result)))
	   (lambda (err) (k-fail (list (parse-position->string (parse-error-position err))
				       (parse-error-expected err)
				       (parse-error-messages err))))))))

    (lambda (results k-ok k-fail)
      (read-etng results
		 k-ok
		 k-fail))))

(define (etng-sexp-special-match? sexps uri localname)
  (and (pair? sexps)
       (let ((tok (car sexps)))
	 (if uri
	     (and (qname? tok)
		  (eq? uri (qname-uri tok))
		  (eq? localname (qname-localname tok)))
	     (eq? localname tok)))))

(define (etng-sexp->string namespace-env n)
  (let ()
    (define (x n tail)
      (cond
       ((pair? n)
	(case (car n)
	  ((paren)
	   (cond
	    ((etng-sexp-special-match? (cdr n) EMPTY-SYMBOL 'quote)
	     (cons #\. (x (caddr n) tail)))
	    ((etng-sexp-special-match? (cdr n) EMPTY-SYMBOL 'unquote)
	     (cons #\` (x (caddr n) tail)))
	    (else
	     (wrap #\( #\) (cdr n) tail))))
	  ((brack) (wrap #\[ #\] (cdr n) tail))
	  ((brace) (wrap #\{ #\} (cdr n) tail))
	  (else (cons #\? (cons #\? tail)))))
       ((qname? n) (x-qname n tail))
       ((symbol? n) (x-base-id n tail))
       ((string? n) (x-string n tail))
       ((number? n) (append (string->list (number->string n)) tail))))

    (define (wrap o c ns tail)
      (cons o (let loop ((ns ns)
			 (tail (cons c tail)))
		(cond
		 ((null? ns) tail)
		 ((null? (cdr ns)) (x (car ns) tail))
		 (else (x (car ns) (cons #\space (loop (cdr ns) tail))))))))

    (define (x-qname q tail)
      (if (qname-uri q)
	  (x-base-id (lookup-namespace (qname-uri q))
		     (cons #\: (x-base-id (qname-localname q) tail)))
	  (x-base-id (qname-localname q) tail)))

    (define (lookup-namespace u)
      (cond
       ((assoc u namespace-env) => cadr)
       (else u)))

    (define (x-base-id str tail)
      (if (symbol? str)
	  (x-base-id (symbol->string str) tail)
	  (let ((chars (string->list str)))
	    (if (or (every char-etng-id-punct? chars)
		    (every char-etng-id-alpha? chars)
		    (member str '(";" ",")))
		(append chars tail)
		(cons #\' (quote-string #\' chars (cons #\' tail)))))))

    (define (x-string str tail)
      (cons #\" (quote-string #\" (string->list str) (cons #\" tail))))

    (define (quote-string needs-escaping chars tail)
      (cond
       ((null? chars) tail)
       ((eqv? (car chars) needs-escaping)
	(cons needs-escaping
	      (cons needs-escaping
		    (quote-string needs-escaping (cdr chars) tail))))
       (else (cons (car chars) (quote-string needs-escaping (cdr chars) tail)))))

    (list->string (x n '()))))

(define (etng-sexp-parse n)
  (let ()
    (define (x n)
      (cond
       ((pair? n)
	(case (car n)
	  ((paren) (x-seq (cdr n)))
	  ((brack) (x-obj 'core-object (cdr n)))
	  ((brace) (x-obj 'core-function (cdr n)))
	  (else (error "Bad etng-sexp" n))))
       ((qname? n) (make-node 'core-ref 'name n))
       ((symbol? n) (make-node 'core-ref 'name (make-qname #f n)))
       ((string? n) (make-node 'core-lit 'value n))
       ((number? n) (make-node 'core-lit 'value n))))

    (define (split elts sep)
      (let loop ((elts elts)
		 (current '())
		 (acc '()))
	(cond
	 ((null? elts) (reverse (cons (reverse current) acc)))
	 ((eq? (car elts) sep) (loop (cdr elts) '() (cons (reverse current) acc)))
	 (else (loop (cdr elts) (cons (car elts) current) acc)))))

    (define (split-semi xs)
      (filter (lambda (x) (not (null? x)))
	      (split xs SEMI-SYMBOL)))

    (define (x-seq elts)
      (let ((segments (split-semi elts)))
	(if (null? segments)
	    (make-node 'core-tuple 'elements '())
	    (x-expr segments
		    (lambda (node remaining)
		      (if (null? remaining)
			  node
			  (error "Remaining elements in sequence" elts)))))))

    (define (x-obj kind elts)
      (let loop ((segments (split-semi elts))
		 (methodsrev '()))
	(if (null? segments)
	    (make-node kind 'methods (reverse methodsrev))
	    (x-method segments '-> 'core-method
		      (lambda (method remaining)
			(loop remaining (cons method methodsrev)))
		      (lambda ()
			(x-method segments '= 'core-constant
				  (lambda (method remaining)
				    (loop remaining (cons method methodsrev)))
				  (lambda ()
				    (x-expr segments
					    (lambda (body remaining)
					      (if (null? remaining)
						  (loop '()
							(cons (make-node 'core-method
									 'patterns (list
										    (make-node
										     'pat-discard))
									 'body body)
							      methodsrev))
						  (error "Unexpected continuation of body"
							 segments)))))))))))

    (define (x-method segments split-symbol method-kind k-yes k-no)
      (if (special-segment? (car segments))
	  (k-no)
	  (let ((maybe-header (split (car segments) split-symbol)))
	    (cond
	     ((= (length maybe-header) 2)
	      (x-expr (cons (cadr maybe-header) (cdr segments))
		      (lambda (body remaining)
			(k-yes (make-node method-kind
					  'patterns (x-method-patterns (car maybe-header))
					  'body body)
			       remaining))))
	     ((= (length maybe-header) 1)
	      (k-no))
	     (else
	      (error "Too many method-header-separators" segments))))))

    (define (x-method-patterns segment)
      (let ((parts (split segment COMMA-SYMBOL)))
	(if (= (length parts) 1)
	    (map x-pattern-atom segment)
	    (list (x-pattern segment)))))

    (define (special-segment? segment)
      (and (pair? segment)
	   (or (etng-sexp-special-match? segment EMPTY-SYMBOL 'quote)
	       (etng-sexp-special-match? segment EMPTY-SYMBOL 'unquote)
	       (etng-sexp-special-match? segment #f 'do)
	       (etng-sexp-special-match? segment #f 'let))))

    (define (special-pattern-segment? segment)
      (and (pair? segment)
	   (or (etng-sexp-special-match? segment EMPTY-SYMBOL 'quote))))

    (define (special-localname n)
      (if (qname? n)
	  (qname-localname n)
	  n))

    (define (fun pat body)
      (make-node 'core-function
		 'methods (list (make-node 'core-method
					   'patterns (list pat)
					   'body body))))

    (define (x-expr segments k)
      (let ((segment (car segments))
	    (remaining (cdr segments)))
	(cond
	 ((null? segment) (error "Empty segment in sequence" segments))
	 ((special-segment? segment)
	  (case (special-localname (car segment))
	    ((quote) (k (make-node 'core-lit 'value (cadr segment)) remaining))
	    ((unquote) (error "Naked unquote" segments))
	    ((do) (x-expr remaining
			  (lambda (tail remaining1)
			    (k (make-node 'core-send
					  'receiver (fun (make-node 'pat-discard) tail)
					  'message (x-tuple (cdr segment)))
			       remaining1))))
	    ((let) (let ((parts (split (cdr segment) EQUAL-SYMBOL)))
		     (if (not (= (length parts) 2))
			 (error "Invalid let clause" segment)
			 (x-expr remaining
				 (lambda (tail remaining1)
				   (k (make-node 'core-send
						 'receiver (fun (x-pattern (car parts)) tail)
						 'message (x-tuple (cadr parts)))
				      remaining1))))))))
	 (else (k (x-tuple segment) remaining)))))

    (define (x-tuple segment)
      (parse-tuple segment 'core-tuple x-send))

    (define (parse-tuple segment kind k)
      (let ((elements (split segment COMMA-SYMBOL)))
	(if (null? (cdr elements))
	    (k (car elements))
	    (make-node kind 'elements (map k elements)))))

    (define (x-send seq)
      (cond
       ((null? seq) (error "Empty send" seq))
       ((eq? (car seq) '<)
	(let-values (((parts rest) (break (lambda (x) (eq? x '>)) (cdr seq))))
	  (x-send-core (cdr rest) (make-node 'core-message
					     'parts (map x parts)))))
       (else
	(x-send-core (cdr seq) (x (car seq))))))

    (define (x-send-core messages receiver)
      (if (null? messages)
	  receiver
	  (x-send-core (cdr messages)
		       (make-node 'core-send
				  'receiver receiver
				  'message (x (car messages))))))

    (define (x-pattern segment)
      (parse-tuple segment 'pat-tuple x-pattern-element))

    (define (x-pattern-element seq)
      (if (special-pattern-segment? seq)
	  (case (special-localname (car seq))
	    ((quote) (make-node 'pat-lit 'value (cadr seq))))
	  (case (length seq)
	    ((1) (x-pattern-atom (car seq)))
	    ((0) (make-node 'pat-tuple 'elements '()))
	    (else
	     (error "Invalid pattern syntax" seq)))))

    (define (x-pattern-atom n)
      (cond
       ((pair? n)
	(case (car n)
	  ((paren) (x-pattern (cdr n)))
	  (else (error "Invalid pattern atom" n))))
       ((qname? n) (make-node 'pat-binding 'name n))
       ((eq? n '_) (make-node 'pat-discard))
       ((symbol? n) (make-node 'pat-binding 'name (make-qname #f n)))
       ((string? n) (make-node 'pat-lit 'value n))
       ((number? n) (make-node 'pat-lit 'value n))))

    (x n)))

;;; Local Variables:
;;; eval: (put 'packrat-lambda 'scheme-indent-function 1)
;;; End:
