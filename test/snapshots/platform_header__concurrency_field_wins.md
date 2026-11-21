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
UNKNOWN CONCURRENCY MODE - platform_header__concurrency_field_wins.md:7:15:7:18
# PROBLEMS
~~~clojure
(reports
	(report
		(severity runtime_error)
		(title "Unknown Concurrency Mode")
		(region (start 7 15) (end 7 18))
		(headline
			(reflow "This platform's ")
			(annotated code "concurrency")
			(reflow " field names ")
			(annotated code "U64")
			(reflow ", which is not a concurrency mode."))
		(document
			(reflow "The modes are ")
			(annotated code "None")
			(reflow ", ")
			(annotated code "Tasks")
			(reflow " and ")
			(annotated code "ParallelTasks")
			(reflow ".")
			(line-break)
			(source-region (file "platform_header__concurrency_field_wins.md") (start 7 15) (end 7 18) (annotation error) (line-text "concurrency : U64")))))
~~~
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
