# META
~~~ini
description=Platform Header - concurrency field without a colon
type=header
~~~
# SOURCE
~~~roc
platform "test-platform"
	requires {}
	exposes []
	packages {}
	provides {}
	concurrency Tasks
~~~
# EXPECTED
EXPECTED CONCURRENCY COLON - platform_header__concurrency_missing_colon.md:6:14:6:19
# PROBLEMS
~~~clojure
(reports
	(report
		(severity runtime_error)
		(title "Expected Concurrency Colon")
		(region (start 6 14) (end 6 19))
		(headline
			(reflow "I was parsing a `concurrency` field in a platform header, and I expected `:` after `concurrency`."))
		(document
			(reflow "The concurrency field names the platform's concurrency mode after a colon.")
			(line-break)
			(line-break)
			(text "For example:")
			(line-break)
			(annotation-start code-block)
			(indent 1)
			(text "concurrency: Tasks")
			(annotation-end)
			(line-break)
			(line-break)
			(text "I found ")
			(annotated code "Tasks")
			(text " here.")
			(line-break)
			(reflow "Names that start with uppercase letters are used for tags, type names, and mod names in Roc.")
			(line-break)
			(line-break)
			(source-region (file "platform_header__concurrency_missing_colon.md") (start 6 14) (end 6 19) (annotation error) (line-text "\tconcurrency Tasks")))))
~~~
# TOKENS
~~~zig
KwPlatform,StringStart,StringPart,StringEnd,
KwRequires,OpenCurly,CloseCurly,
KwExposes,OpenSquare,CloseSquare,
KwPackages,OpenCurly,CloseCurly,
KwProvides,OpenCurly,CloseCurly,
LowerIdent,UpperIdent,
EndOfFile,
~~~
# PARSE
~~~clojure
(malformed-header (tag "expected_concurrency_colon"))
~~~
# FORMATTED
~~~roc

~~~
# CANONICALIZE
~~~clojure
(can-ir (empty true))
~~~
# TYPES
~~~clojure
(inferred-types
	(defs)
	(expressions))
~~~
