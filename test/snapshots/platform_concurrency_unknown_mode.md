# META
~~~ini
description=A platform's concurrency field names a mode that does not exist
type=file
~~~
# SOURCE
~~~roc
platform "test-platform"
	requires {}
	exposes []
	packages {}
	provides {}
	concurrency: Async

helper = 1
~~~
# EXPECTED
UNKNOWN CONCURRENCY MODE - platform_concurrency_unknown_mode.md:6:15:6:20
# PROBLEMS
~~~clojure
(reports
	(report
		(severity runtime_error)
		(title "Unknown Concurrency Mode")
		(region (start 6 15) (end 6 20))
		(headline
			(reflow "This platform's ")
			(annotated code "concurrency")
			(reflow " field names ")
			(annotated code "Async")
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
			(source-region (file "platform_concurrency_unknown_mode.md") (start 6 15) (end 6 20) (annotation error) (line-text "\tconcurrency: Async")))))
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
	(platform (name "test-platform") (concurrency "Async")
		(requires)
		(exposes)
		(packages)
		(provides))
	(statements
		(s-decl
			(p-ident (raw "helper"))
			(e-int (raw "1")))))
~~~
# FORMATTED
~~~roc
NO CHANGE
~~~
# CANONICALIZE
~~~clojure
(can-ir
	(d-let
		(p-assign (ident "helper"))
		(e-num (value "1"))))
~~~
# TYPES
~~~clojure
(inferred-types
	(defs
		(patt (type "Dec")))
	(expressions
		(expr (type "Dec"))))
~~~
