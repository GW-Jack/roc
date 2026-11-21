# META
~~~ini
description=suspending is contextual: it stays an ordinary identifier
type=snippet
~~~
# SOURCE
~~~roc
suspending : I64
suspending = 1

marker : I64 -> I64
marker = |x| {
	suspending_count = x + suspending
	suspending_count
}
~~~
# EXPECTED
NIL
# PROBLEMS
NIL
# TOKENS
~~~zig
LowerIdent,OpColon,UpperIdent,
LowerIdent,OpAssign,Int,
LowerIdent,OpColon,UpperIdent,OpArrow,UpperIdent,
LowerIdent,OpAssign,OpBar,LowerIdent,OpBar,OpenCurly,
LowerIdent,OpAssign,LowerIdent,OpPlus,LowerIdent,
LowerIdent,
CloseCurly,
EndOfFile,
~~~
# PARSE
~~~clojure
(file
	(type-mod)
	(statements
		(s-type-anno (name "suspending")
			(ty (name "I64")))
		(s-decl
			(p-ident (raw "suspending"))
			(e-int (raw "1")))
		(s-type-anno (name "marker")
			(ty-fn
				(ty (name "I64"))
				(ty (name "I64"))))
		(s-decl
			(p-ident (raw "marker"))
			(e-lambda
				(args
					(p-ident (raw "x")))
				(e-block
					(statements
						(s-decl
							(p-ident (raw "suspending_count"))
							(e-binop (op "+")
								(e-ident (raw "x"))
								(e-ident (raw "suspending"))))
						(e-ident (raw "suspending_count"))))))))
~~~
# FORMATTED
~~~roc
NO CHANGE
~~~
# CANONICALIZE
~~~clojure
(can-ir
	(d-let
		(p-assign (ident "suspending"))
		(e-num (value "1"))
		(annotation
			(ty-lookup (name "I64") (builtin))))
	(d-let
		(p-assign (ident "marker"))
		(e-lambda
			(args
				(p-assign (ident "x")))
			(e-block
				(s-let
					(p-assign (ident "suspending_count"))
					(e-dispatch-call (method "plus") (constraint-fn-var 238)
						(receiver
							(e-lookup-local
								(p-assign (ident "x"))))
						(args
							(e-lookup-local
								(p-assign (ident "suspending"))))))
				(e-lookup-local
					(p-assign (ident "suspending_count")))))
		(annotation
			(ty-fn (effectful false)
				(ty-lookup (name "I64") (builtin))
				(ty-lookup (name "I64") (builtin))))))
~~~
# TYPES
~~~clojure
(inferred-types
	(defs
		(patt (type "I64"))
		(patt (type "I64 -> I64")))
	(expressions
		(expr (type "I64"))
		(expr (type "I64 -> I64"))))
~~~
