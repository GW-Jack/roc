# META
~~~ini
description=Platform Header - concurrency field keeps its comments and normalizes spacing
type=header
~~~
# SOURCE
~~~roc
platform "test-platform"
	requires {}
	exposes []
	packages {}
	provides {}
	# the mode
	concurrency   :   # only one
		Tasks
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
LowerIdent,OpColon,
UpperIdent,
EndOfFile,
~~~
# PARSE
~~~clojure
(platform (name "test-platform") (concurrency "Tasks")
	(requires)
	(exposes)
	(packages)
	(provides))
~~~
# FORMATTED
~~~roc
platform "test-platform"
	requires {}
	exposes []
	packages {}
	provides {}
	# the mode
	concurrency: # only one
		Tasks
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
