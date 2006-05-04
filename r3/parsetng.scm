(define (port-results filename p)
  (base-generator->results
   (let ((ateof #f)
	 (pos (top-parse-position filename)))
     (lambda ()
       (if ateof
	   (values pos #f)
	   (let ((x (read-char p)))
	     (if (eof-object? x)
		 (begin
		   (set! ateof #t)
		   (values pos #f))
		 (let ((old-pos pos))
		   (set! pos (update-parse-position pos x))
		   (values old-pos (cons x x))))))))))

(define (string-results filename s)
  (base-generator->results
   (let ((idx 0)
	 (len (string-length s))
	 (pos (top-parse-position filename)))
     (lambda ()
       (if (= idx len)
	   (values pos #f)
	   (let ((x (string-ref s idx))
		 (old-pos pos))
	     (set! pos (update-parse-position pos x))
	     (set! idx (+ idx 1))
	     (values old-pos (cons x x))))))))

(define (parse-result->value error-text result)
  (if (parse-result-successful? result)
      (parse-result-semantic-value result)
      (error error-text
	     (let ((e (parse-result-error result)))
	       (list error-text
		     (parse-position->string (parse-error-position e))
		     (parse-error-expected e)
		     (parse-error-messages e))))))

(define (packrat-token str)
  (lambda (starting-results)
    (let loop ((pos 0) (results starting-results))
      (if (= pos (string-length str))
	  (make-result str results)
	  (if (and results (char=? (parse-results-token-value results) (string-ref str pos)))
	      (loop (+ pos 1) (parse-results-next results))
	      (make-expected-result (parse-results-position starting-results) str))))))

(define (parse-results-take results n)
  (let loop ((acc '())
	     (results results)
	     (n n))
    (if (zero? n)
	(values (list->string (reverse acc))
		results)
	(loop (cons (parse-results-token-value results) acc)
	      (parse-results-next results)
	      (- n 1)))))

(define (parse-results->pregexp-stream results)
  (pregexp-make-stream (lambda (r)
			 (if r
			     (cons (parse-results-token-value r)
				   (parse-results-next r))
			     (cons #f #f)))
		       results))

(define (packrat-regex name . string-fragments)
  (let* ((exp (string-concatenate string-fragments))
	 (re (pregexp exp)))
    (lambda (results)
      (let* ((stream (parse-results->pregexp-stream results))
	     (match (pregexp-match-head re stream)))
	(if match
	    (let-values (((str next) (parse-results-take results (cdar match))))
	      (make-result str next))
	    (make-expected-result (parse-results-position results) name))))))

(define (packrat-cache key parser)
  (lambda (results)
    (results->result results key
		     (lambda ()
		       (parser results)))))

(define-syntax define-packrat-cached
  (syntax-rules ()
    ((_ (fnname results) body ...)
     (define fnname
       (packrat-cache 'fnname
		      (letrec ((fnname (lambda (results) body ...)))
			fnname))))
    ((_ fnname exp)
     (define fnname
       (packrat-cache 'fnname exp)))))

(define (make-node name . args)
  (cons name args))

(define (node-push node arg)
  (cons (car node) (cons arg (cdr node))))

(define-values (parse-ThiNG parse-ThiNG-toplevel)
  (let* ((p "[-+=_|/?.<>*&^%$@!`~]")
	 (midsym (string-append "([a-zA-Z0-9]|"p")")))
    (packrat-parser (begin
		      (define-packrat-cached (white results)
			(if (and-let* ((ch (parse-results-token-value results)))
			      (char-whitespace? ch))
			    (white (parse-results-next results))
			    (comment results)))
		      (define-packrat-cached (comment results)
			(if (eq? (parse-results-token-value results) #\")
			    (skip-comment-body (parse-results-next results))
			    (make-result 'whitespace results)))
		      (define (skip-comment-body results)
			(if (eq? (parse-results-token-value results) #\")
			    (white (parse-results-next results))
			    (skip-comment-body (parse-results-next results))))
		      (define (string-body results)
			(string-body* results '()))
		      (define (string-body* results acc)
			(let ((ch (parse-results-token-value results))
			      (next (parse-results-next results)))
			  (if (eq? ch #\')
			      (string-body-quote next acc)
			      (string-body* next (cons ch acc)))))
		      (define (string-body-quote results acc)
			(if (eq? (parse-results-token-value results) #\')
			    (string-body* (parse-results-next results) (cons #\' acc))
			    (make-result (list->string (reverse acc)) results)))
		      (define-packrat-cached atom-raw (packrat-regex 'atom "[a-zA-Z]"midsym"*"))
		      (define-packrat-cached infixop-raw (packrat-regex 'infixop p midsym"*"))
		      (define-packrat-cached integer (packrat-regex 'integer "[0-9]+"))
		      (define (make-binary op left right)
			(make-node 'adj (make-node 'adj op left) right))
		      (values tuple1 toplevel))
		    (toplevel ((d <- tuple1 white '#\; '#\;) d)
			      ((white '#f) (make-node 'quote (make-node 'atom 'quit))))
		    (datum ((s <- tuple0) s))
		    (tuple0 ((s <- tuple1) s)
			    (() (make-node 'unit)))
		    (tuple1 ((s <- tuple1*) (if (= (length s) 2) (cadr s) s)))
		    (tuple1* ((d <- fun white '#\, s <- tuple1*) (node-push s d))
			     ((d <- fun) (make-node 'tuple d)))
		    (fun ((f <- fun*) f)
			 ((v <- funcall f <- fun*) (make-node 'adj v (make-node 'quote f)))
			 ((v <- funcall) v))
		    (fun* ((e <- entry white d <- fun*) (node-push d e))
			  ((e <- entry) (make-node 'fun e)))
		    (entry ((k <- simple colon v <- funcall) (list k v)))
		    (semi ((white '#\; (! '#\;)) 'semi))
		    (colon ((white '#\:) 'colon))
		    (funcall ((a <- adj f <- funcall*) (f a)))
		    (funcall* ((o <- infixop b <- adj f <- funcall*)
			          (lambda (a) (f (make-binary o a b))))
			      (() (lambda (a) a)))
		    (infixop ((white r <- infixop-raw) (make-node 'atom (string->symbol r))))
		    (adj ((left <- adj-leaf f <- adj-tail) (f left)))
		    (adj-tail ((white right <- adj-leaf f <- adj-tail)
			          (lambda (left) (f (make-node 'adj left right))))
			      (() (lambda (left) left)))
		    (adj-leaf ((v <- simple (! colon)) v))
		    (simple ((white d1 <- simple1) d1))
		    (simple1 (('#\( o <- infixop white '#\)) o)
			     (('#\( d <- datum white '#\)) (make-node 'eval d))
			     (('#\[ d <- datum white '#\]) (make-node 'quote d))
			     (('#\{ d <- datum white '#\}) (make-node 'meta-quote d))
			     ((l <- literal) (make-node 'lit l))
			     (('#\# a <- atom) a)
			     ((a <- atom) (make-node 'eval a))
			     (('#\_) (make-node 'discard)))
		    (atom ((a <- atom-raw) (make-node 'atom (string->symbol a)))
			  (('#\' s <- string-body) (make-node 'atom (string->symbol s))))
		    (literal ((i <- integer) (string->number i))
			     (('#\- i <- integer) (- (string->number i)))))))

(define read-ThiNG
  (lambda ()
    (parse-result->value "While parsing ThiNG"
			 (parse-ThiNG-toplevel (port-results "stdin" (current-input-port))))))

(define string->ThiNG
  (lambda (s)
    (parse-result->value "While parsing ThiNG"
			 (parse-ThiNG (string-results "<string>" s)))))
