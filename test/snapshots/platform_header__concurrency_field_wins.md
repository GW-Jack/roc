# META
~~~ini
description=Platform Header - right after provides, `concurrency :` is the header field, not an annotation
type=file
~~~
# SOURCE
~~~roc
platform "test-platform"
	requires {}
	exposes []
	packages {}
	provides {}

concurrency : U64
concurrency = 4
~~~
# EXPECTED
NIL
# PROBLEMS
NIL
# TOKENS
~~~zig
KwPlatform,StringStart,StringPart,StringEnd,
KwRequires,OpenCurly,CloseCurly,
KwExposes,OpenSquare,CloseSquare,
KwPackages,OpenCurly,CloseCurly,
KwProvides,OpenCurly,CloseCurly,
LowerIdent,OpColon,UpperIdent,
LowerIdent,OpAssign,Int,
EndOfFile,
~~~
# PARSE
~~~clojure
(file
	(platform (name "test-platform") (concurrency "U64")
		(requires)
		(exposes)
		(packages)
		(provides))
	(statements
		(s-decl
			(p-ident (raw "concurrency"))
			(e-int (raw "4")))))
~~~
# FORMATTED
~~~roc
platform "test-platform"
	requires {}
	exposes []
	packages {}
	provides {}

	concurrency: U64
concurrency = 4
~~~
# CANONICALIZE
~~~clojure
(can-ir
	(d-let
		(p-assign (ident "concurrency"))
		(e-num (value "4"))))
~~~
# TYPES
~~~clojure
(inferred-types
	(defs
		(patt (type "Dec")))
	(expressions
		(expr (type "Dec"))))
~~~
