# META
~~~ini
description=Platform Header - concurrency field without a mode
type=header
~~~
# SOURCE
~~~roc
platform "test-platform"
	requires {}
	exposes []
	packages {}
	provides {}
	concurrency: tasks
~~~
# EXPECTED
EXPECTED CONCURRENCY MODE - platform_header__concurrency_missing_mode.md:6:15:6:20
# PROBLEMS
~~~clojure
(reports
	(report
		(severity runtime_error)
		(title "Expected Concurrency Mode")
		(region (start 6 15) (end 6 20))
		(headline
			(reflow "I was parsing a `concurrency` field in a platform header, and I expected a mode name."))
		(document
			(reflow "A concurrency mode is an uppercase name such as ")
			(annotated code "Tasks")
			(reflow ".")
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
			(annotated code "tasks")
			(text " here.")
			(line-break)
			(reflow "Names that start with lowercase letters are value names or record field names, depending on the surrounding syntax.")
			(line-break)
			(line-break)
			(source-region (file "platform_header__concurrency_missing_mode.md") (start 6 15) (end 6 20) (annotation error) (line-text "\tconcurrency: tasks")))))
~~~
# TOKENS
~~~zig
KwPlatform,StringStart,StringPart,StringEnd,
KwRequires,OpenCurly,CloseCurly,
KwExposes,OpenSquare,CloseSquare,
KwPackages,OpenCurly,CloseCurly,
KwProvides,OpenCurly,CloseCurly,
LowerIdent,OpColon,LowerIdent,
EndOfFile,
~~~
# PARSE
~~~clojure
(malformed-header (tag "expected_concurrency_mode"))
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
