# META
~~~ini
description=suspending on an annotation that has a definition is reported
type=file:Http.roc
~~~
# SOURCE
~~~roc
Http := [].{
	suspending get! : Str => Str
	get! = |url| url
}

suspending fetch! : Str => Str
fetch! = |url| url
~~~
# EXPECTED
SUSPENDING NEEDS A HOSTED FUNCTION - suspending_not_hosted.md:2:2:2:30
SUSPENDING NEEDS A HOSTED FUNCTION - suspending_not_hosted.md:6:1:6:31
# PROBLEMS
~~~clojure
(reports
	(report
		(severity runtime_error)
		(title "Suspending Needs A Hosted Function")
		(region (start 2 2) (end 2 30))
		(headline
			(reflow "Only a hosted function can be ")
			(annotated code "suspending")
			(reflow ". This declaration has a definition, so it runs Roc code and can't pause its task by itself."))
		(document
			(source-region (file "suspending_not_hosted.md") (start 2 2) (end 2 30) (annotation error) (line-text "\tsuspending get! : Str => Str"))
			(line-break)
			(reflow "Remove ")
			(annotated code "suspending")
			(reflow ". Code that calls a suspending hosted function can already pause.")))
	(report
		(severity runtime_error)
		(title "Suspending Needs A Hosted Function")
		(region (start 6 1) (end 6 31))
		(headline
			(reflow "Only a hosted function can be ")
			(annotated code "suspending")
			(reflow ". This declaration has a definition, so it runs Roc code and can't pause its task by itself."))
		(document
			(source-region (file "suspending_not_hosted.md") (start 6 1) (end 6 31) (annotation error) (line-text "suspending fetch! : Str => Str"))
			(line-break)
			(reflow "Remove ")
			(annotated code "suspending")
			(reflow ". Code that calls a suspending hosted function can already pause."))))
~~~
# TOKENS
~~~zig
UpperIdent,OpColonEqual,OpenSquare,CloseSquare,Dot,OpenCurly,
LowerIdent,LowerIdent,OpColon,UpperIdent,OpFatArrow,UpperIdent,
LowerIdent,OpAssign,OpBar,LowerIdent,OpBar,LowerIdent,
CloseCurly,
LowerIdent,LowerIdent,OpColon,UpperIdent,OpFatArrow,UpperIdent,
LowerIdent,OpAssign,OpBar,LowerIdent,OpBar,LowerIdent,
EndOfFile,
~~~
# PARSE
~~~clojure
(file
	(type-mod)
	(statements
		(s-type-decl
			(header (name "Http")
				(args))
			(ty-tag-union
				(tags))
			(associated
				(s-type-anno (name "get!") (suspending true)
					(ty-fn
						(ty (name "Str"))
						(ty (name "Str"))))
				(s-decl
					(p-ident (raw "get!"))
					(e-lambda
						(args
							(p-ident (raw "url")))
						(e-ident (raw "url"))))))
		(s-type-anno (name "fetch!") (suspending true)
			(ty-fn
				(ty (name "Str"))
				(ty (name "Str"))))
		(s-decl
			(p-ident (raw "fetch!"))
			(e-lambda
				(args
					(p-ident (raw "url")))
				(e-ident (raw "url"))))))
~~~
# FORMATTED
~~~roc
NO CHANGE
~~~
# CANONICALIZE
~~~clojure
(can-ir
	(d-let
		(p-assign (ident "Http.get!"))
		(e-lambda
			(args
				(p-assign (ident "url")))
			(e-lookup-local
				(p-assign (ident "url"))))
		(annotation
			(ty-fn (effectful true)
				(ty-lookup (name "Str") (builtin))
				(ty-lookup (name "Str") (builtin)))))
	(d-let
		(p-assign (ident "fetch!"))
		(e-lambda
			(args
				(p-assign (ident "url")))
			(e-lookup-local
				(p-assign (ident "url"))))
		(annotation
			(ty-fn (effectful true)
				(ty-lookup (name "Str") (builtin))
				(ty-lookup (name "Str") (builtin)))))
	(s-nominal-decl
		(ty-header (name "Http"))
		(ty-tag-union)))
~~~
# TYPES
~~~clojure
(inferred-types
	(defs
		(patt (type "Str => Str"))
		(patt (type "Str => Str")))
	(type_decls
		(nominal (type "Http")
			(ty-header (name "Http"))))
	(expressions
		(expr (type "Str => Str"))
		(expr (type "Str => Str"))))
~~~
