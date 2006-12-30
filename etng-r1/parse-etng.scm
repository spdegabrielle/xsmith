(define parse-etng
  (let* ((nonquote (lambda (ch) (not (eqv? ch #\"))))
	 (non-string-quote (lambda (ch) (not (eqv? ch #\'))))

	 (stream-ns-uri "http://eighty-twenty.org/etng/r1/ns/stream")
	 (stream-cons-name (make-qname stream-ns-uri 'cons))
	 (stream-cons-ref (make-node 'core-ref 'name stream-cons-name))
	 (stream-nil-name (make-qname stream-ns-uri 'nil))
	 (stream-nil-ref (make-node 'core-ref 'name stream-nil-name))

	 (expand-stream (lambda (prefix suffix)
			  (fold-right (lambda (p acc)
					(make-node 'core-send
						   'receiver stream-cons-ref
						   'message (make-node 'core-tuple
								       'elements (list p acc))))
				      (or suffix stream-nil-ref)
				      prefix)))

	 (parser
	  (packrat-parse
	   `(

	     (toplevel (ws semis (m <- command semis)+ #f ,(packrat-lambda (m) m)))
	     (toplevel1 (ws semis m <- command #\; ,(packrat-lambda (m) m)))

	     (command (/ (def <- namespace-declaration
			      ,(packrat-lambda (def)
				 (make-node 'command-define-namespace
					    'prefix (car def)
					    'uri (cdr def))))
			 (DEFINE p <- tuple-pattern EQ e <- expr
			  ,(packrat-lambda (p e)
			     (make-node 'command-define-values
					'pattern p
					'value e)))
			 (DEFINE n <- qname (args <- pattern)* EQ e <- expr
			  ,(packrat-lambda (n args e)
			     (make-node 'command-define-object
					'name n
					'args args
					'body e)))
			 (e <- expr
			    ,(packrat-lambda (e)
			       (make-node 'command-exp
					  'value e)))))

	     (namespace-declaration (NAMESPACE prefix <- id EQ uri <- string
				     ,(packrat-lambda (prefix uri)
					(cons prefix uri))))

	     (expr (/ sequence
		      tuple-value))

	     (tuple-value (es <- comma-separated-exprs
			      ,(packrat-lambda (es)
				 (if (and (pair? es)
					  (null? (cdr es)))
				     (car es)
				     (make-node 'core-tuple 'elements es)))))

	     (comma-separated-exprs (/ (e <- send (#\, ws es <- send)*
					  ,(packrat-lambda (e es) (cons e es)))
				       ,(packrat-lambda () '())))

	     (send ((e <- simple-expr)+ ,(packrat-lambda (e)
					   (fold (lambda (operand operator)
						   (make-node 'core-send
							      'receiver operator
							      'message operand))
						 (car e)
						 (cdr e)))))

	     (simple-expr (/ object
			     function
			     message
			     stream
			     (OPARENnows o <- operator CPAREN ,(packrat-lambda (o)
								 (make-node 'core-ref 'name o)))
			     (SELF ,(packrat-lambda () (make-node 'core-self)))
			     (q <- qname ,(packrat-lambda (q) (make-node 'core-ref 'name q)))
			     (l <- literal ,(packrat-lambda (l) (make-node 'core-lit 'value l)))
			     (OPAREN e <- expr CPAREN ,(packrat-lambda (e) e))))

	     (literal (/ (#\. ws q <- qname ,(packrat-lambda (q) q))
			 (o <- operator ,(packrat-lambda (o) o))
			 (w <- word ,(packrat-lambda (w) w))))

	     (object (OBRACK (m <- member)* CBRACK
			     ,(packrat-lambda (m) (make-node 'core-object 'methods m))))

	     (function (#\{ ws (m <- member)* #\} ws
			,(packrat-lambda (m) (make-node 'core-function 'methods m))))

	     (message (OANGLE (es <- message-component)* CANGLE
		       ,(packrat-lambda (es) (make-node 'core-message 'parts es))))

	     (message-component ((! #\>) simple-expr))

	     (stream (OBRACK p <- comma-separated-exprs s <- stream-suffix
			     ,(packrat-lambda (p s) (expand-stream p s))))

	     (stream-suffix (/ (CBRACK ,(packrat-lambda () #f))
			       (PIPE CBRACK ,(packrat-lambda () #f))
			       (PIPE e <- simple-expr CBRACK ,(packrat-lambda (e) e))))

	     (member (/ constant-member
			method-member))

	     (constant-member (ps <- patterns EQ e <- expr semis
				  ,(packrat-lambda (ps e) (make-node 'core-constant
								     'patterns ps 'body e))))
	     (method-member (ps <- patterns ARROW e <- expr semis
				,(packrat-lambda (ps e) (make-node 'core-method
								   'patterns ps 'body e))))

	     (sequence (/ (def <- namespace-declaration semis e <- expr
			       ,(packrat-lambda (def)
				  (make-node 'core-namespace
					     'prefix (car def)
					     'uri (cdr def)
					     'value e)))
			  (LET p <- tuple-pattern EQ e <- expr semis b <- expr
			   ,(packrat-lambda (p e b)
			      (make-node 'core-let
					 'pattern p
					 'value e
					 'body b)))
			  (LAZY p <- tuple-pattern EQ e <- expr semis b <- expr
				,(packrat-lambda (p e b)
				   (make-node 'core-lazy
					      'pattern p
					      'value e
					      'body b)))
			  (REC q <- qname m <- simple-expr b <- simple-expr
			       ,(packrat-lambda (q m b)
				  (make-node 'core-lazy
					     'pattern (make-node 'pat-binding 'name q)
					     'value b
					     'body (make-node 'core-send
							      'receiver (make-node 'core-ref
										   'name q)
							      'message m))))
			  (DO head <- expr semis tail <- expr
			   ,(packrat-lambda (head tail)
			      (make-node 'core-do
					 'head head
					 'tail tail)))))

	     (patterns (/ ((ps <- pattern)* (! #\,) ,(packrat-lambda (ps) ps))
			  (p <- tuple-pattern ,(packrat-lambda (p) (list p)))))

	     (pattern (/ (OPARENnows o <- operator CPAREN ,(packrat-lambda (o)
							     (make-node 'pat-binding 'name o)))
			 message-pattern
			 (#\_ ws ,(packrat-lambda () (make-node 'pat-discard)))
			 (l <- literal ,(packrat-lambda (l) (make-node 'pat-lit 'value l)))
			 (q <- qname ,(packrat-lambda (q) (make-node 'pat-binding 'name q)))
			 (OPAREN p <- tuple-pattern CPAREN ,(packrat-lambda (p) p))))

	     (tuple-pattern (ps <- comma-separated-patterns
				,(packrat-lambda (ps)
				   (if (and (pair? ps)
					    (null? (cdr ps)))
				       (car ps)
				       (make-node 'pat-tuple 'elements ps)))))

	     (message-pattern (OANGLE (ps <- message-pattern-component)* CANGLE
				      ,(packrat-lambda (ps) (make-node 'pat-message 'parts ps))))

	     (message-pattern-component ((! #\>) pattern))

	     (comma-separated-patterns (/ (p <- pattern (#\, ws ps <- pattern)*
					     ,(packrat-lambda (p ps) (cons p ps)))
					  ,(packrat-lambda () '())))

	     ;;---------------------------------------------------------------------------

	     (semis (SEMI *))

	     (qname (/ (prefix <- id #\: localname <- id
			       ,(packrat-lambda (prefix localname)
				  (make-qname prefix localname)))
		       (uri <- string #\: localname <- id
			    ,(packrat-lambda (uri localname)
			       (make-qname uri localname)))
		       (#\: localname <- id
			,(packrat-lambda (localname)
			   (make-qname (string->symbol "") localname)))
		       (localname <- id
				  ,(packrat-lambda (localname)
				     (make-qname #f localname)))))

	     (id ((! #\_) (a <- id-alpha) (r <- (/ id-alpha digit))* ws
		  ,(packrat-lambda (a r) (string->symbol (list->string (cons a r))))))

	     (string (#\' (cs <- (/: ,non-string-quote "string character"))* #\' ws
		      ,(packrat-lambda (cs) (list->string cs))))

	     (operator ((! reserved-operator)
			a <- op-punct (r <- (/ op-punct digit alpha))* ws
			,(packrat-lambda (a r) (string->symbol (list->string (cons a r))))))

	     (word (/ positive-word
		      (#\- ws w <- positive-word ,(packrat-lambda (w) (- w)))))
	     (positive-word ((d <- digit)+ ws
			     ,(packrat-lambda (d) (string->number (list->string d)))))

	     (id-alpha (/ alpha #\_ #\$))
	     (op-punct (/: ":!#%&*+/<=>?@\\^|-~"))

	     (ws (/ ((/: ,char-whitespace? "whitespace")+ ws)
		    (#\" (/: ,nonquote "comment character")* #\" ws)
		    ()))
	     (digit (/: ,char-numeric? "digit"))
	     (alpha (/: ,char-alphabetic? "letter"))

	     (reserved-operator (/ ARROW
				   COLONEQ
				   EQ
				   PIPE))

	     (ARROW ("->" (! op-punct) ws))
	     (COLONEQ (":=" (! op-punct) ws))
	     (EQ (#\= (! op-punct) ws))

	     (SEMI (#\; ws))
	     (OPAREN (OPARENnows ws))
	     (OPARENnows #\()
	     (CPAREN (#\) ws))
	     (OBRACK (#\[ ws))
	     (CBRACK (#\] ws))
	     (OANGLE (#\< ws))
	     (CANGLE (#\> ws))
	     (PIPE (#\| ws))

	     (DEFINE ("define"ws))
	     (NAMESPACE ("namespace"ws))
	     (SELF ("self"ws))
	     (LET ("let"ws))
	     (LAZY ("lazy"ws))
	     (REC ("rec"ws))
	     (DO ("do"ws))

	     ))))
    (lambda (results k-ok k-fail)
      (try-packrat-parse-pattern
       (parser 'toplevel1) '() results
       (lambda (bindings result) (k-ok (parse-result-semantic-value result)
				       (parse-result-next result)))
       (lambda (err) (k-fail (list (parse-position->string (parse-error-position err))
				   (parse-error-expected err)
				   (parse-error-messages err))))))))

;;; Local Variables:
;;; eval: (put 'packrat-lambda 'scheme-indent-function 1)
;;; End:
