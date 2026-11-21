# META
~~~ini
description=ParallelTasks is reported as not yet implemented
type=file
~~~
# SOURCE
~~~roc
platform "test-platform"
	requires {}
	exposes []
	packages {}
	provides {}
	concurrency: ParallelTasks

helper = 1
~~~
# EXPECTED
NOT IMPLEMENTED - platform_concurrency_parallel_tasks.md:6:15:6:28
# PROBLEMS
~~~clojure
(reports
	(report
		(severity fatal)
		(title "Not Implemented")
		(region (start 6 15) (end 6 28))
		(headline
			(reflow "This feature is not yet implemented: ")
			(annotation-start emphasis)
			(text "the ParallelTasks concurrency mode")
			(annotation-end)
			(reflow "."))
		(document
			(source-region (file "platform_concurrency_parallel_tasks.md") (start 6 15) (end 6 28) (annotation error) (line-text "\tconcurrency: ParallelTasks"))
			(line-break)
			(reflow "This error doesn't have a proper diagnostic report yet. Let us know if you want to help improve Roc's error messages!")
			(line-break))))
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
	(platform (name "test-platform") (concurrency "ParallelTasks")
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
