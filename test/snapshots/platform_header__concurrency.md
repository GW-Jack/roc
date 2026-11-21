# META
~~~ini
description=Platform Header - concurrency mode after hosted
type=header
~~~
# SOURCE
~~~roc
platform "test-platform"
	requires {}
	exposes []
	packages {}
	provides { "roc_main": main! }
	hosted { "roc_http_get": Http.get! }
	concurrency: Tasks
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
KwProvides,OpenCurly,StringStart,StringPart,StringEnd,OpColon,LowerIdent,CloseCurly,
KwHosted,OpenCurly,StringStart,StringPart,StringEnd,OpColon,UpperIdent,NoSpaceDotLowerIdent,CloseCurly,
LowerIdent,OpColon,UpperIdent,
EndOfFile,
~~~
# PARSE
~~~clojure
(platform (name "test-platform") (concurrency "Tasks")
	(requires)
	(exposes)
	(packages)
	(provides
		(symbol-map-entry (symbol "roc_main") (func "main!")))
	(hosted
		(symbol-map-entry (symbol "roc_http_get") (mod "Http") (func ".get!"))))
~~~
# FORMATTED
~~~roc
NO CHANGE
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
