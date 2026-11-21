# META
~~~ini
description=suspending on an annotation that is not a => function type is reported
type=file:Http.roc
~~~
# SOURCE
~~~roc
Http := [].{
	suspending timeout : U64
	suspending pure : Str -> Str
}

Fetch : Str => Str

suspending fetch! : Fetch
~~~
# EXPECTED
SUSPENDING NEEDS AN EFFECTFUL FUNCTION - suspending_not_effectful.md:2:2:2:26
SUSPENDING NEEDS AN EFFECTFUL FUNCTION - suspending_not_effectful.md:3:2:3:30
SUSPENDING NEEDS AN EFFECTFUL FUNCTION - suspending_not_effectful.md:8:1:8:26
DECLARATION HAS NO VALUE - suspending_not_effectful.md:2:2:2:26
DECLARATION HAS NO VALUE - suspending_not_effectful.md:3:2:3:30
DECLARATION HAS NO VALUE - suspending_not_effectful.md:8:1:8:26
# PROBLEMS
~~~clojure
(reports
	(report
		(severity runtime_error)
		(title "Suspending Needs An Effectful Function")
		(region (start 2 2) (end 2 26))
		(headline
			(reflow "A ")
			(annotated code "suspending")
			(reflow " declaration must be annotated as an effectful function, written with ")
			(annotated code "=>")
			(reflow "."))
		(document
			(source-region (file "suspending_not_effectful.md") (start 2 2) (end 2 26) (annotation error) (line-text "\tsuspending timeout : U64"))))
	(report
		(severity runtime_error)
		(title "Suspending Needs An Effectful Function")
		(region (start 3 2) (end 3 30))
		(headline
			(reflow "A ")
			(annotated code "suspending")
			(reflow " declaration must be annotated as an effectful function, written with ")
			(annotated code "=>")
			(reflow "."))
		(document
			(source-region (file "suspending_not_effectful.md") (start 3 2) (end 3 30) (annotation error) (line-text "\tsuspending pure : Str -> Str"))))
	(report
		(severity runtime_error)
		(title "Suspending Needs An Effectful Function")
		(region (start 8 1) (end 8 26))
		(headline
			(reflow "A ")
			(annotated code "suspending")
			(reflow " declaration must be annotated as an effectful function, written with ")
			(annotated code "=>")
			(reflow "."))
		(document
			(source-region (file "suspending_not_effectful.md") (start 8 1) (end 8 26) (annotation error) (line-text "suspending fetch! : Fetch"))))
	(report
		(severity warning)
		(title "Declaration Has No Value")
		(region (start 2 2) (end 2 26))
		(headline
			(reflow "This declaration has a type annotation but no implementation."))
		(document
			(source-region (file "suspending_not_effectful.md") (start 2 2) (end 2 26) (annotation error) (line-text "\tsuspending timeout : U64"))
			(line-break)
			(line-break)
			(reflow "Add a value body here, or put hosted functions in a platform type mod so they are published through the host boundary.")))
	(report
		(severity warning)
		(title "Declaration Has No Value")
		(region (start 3 2) (end 3 30))
		(headline
			(reflow "This declaration has a type annotation but no implementation."))
		(document
			(source-region (file "suspending_not_effectful.md") (start 3 2) (end 3 30) (annotation error) (line-text "\tsuspending pure : Str -> Str"))
			(line-break)
			(line-break)
			(reflow "Add a value body here, or put hosted functions in a platform type mod so they are published through the host boundary.")))
	(report
		(severity warning)
		(title "Declaration Has No Value")
		(region (start 8 1) (end 8 26))
		(headline
			(reflow "This declaration has a type annotation but no implementation."))
		(document
			(source-region (file "suspending_not_effectful.md") (start 8 1) (end 8 26) (annotation error) (line-text "suspending fetch! : Fetch"))
			(line-break)
			(line-break)
			(reflow "Add a value body here, or put hosted functions in a platform type mod so they are published through the host boundary."))))
~~~
# TOKENS
~~~zig
UpperIdent,OpColonEqual,OpenSquare,CloseSquare,Dot,OpenCurly,
LowerIdent,LowerIdent,OpColon,UpperIdent,
LowerIdent,LowerIdent,OpColon,UpperIdent,OpArrow,UpperIdent,
CloseCurly,
UpperIdent,OpColon,UpperIdent,OpFatArrow,UpperIdent,
LowerIdent,LowerIdent,OpColon,UpperIdent,
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
				(s-type-anno (name "timeout") (suspending true)
					(ty (name "U64")))
				(s-type-anno (name "pure") (suspending true)
					(ty-fn
						(ty (name "Str"))
						(ty (name "Str"))))))
		(s-type-decl
			(header (name "Fetch")
				(args))
			(ty-fn
				(ty (name "Str"))
				(ty (name "Str"))))
		(s-type-anno (name "fetch!") (suspending true)
			(ty (name "Fetch")))))
~~~
# FORMATTED
~~~roc
NO CHANGE
~~~
# CANONICALIZE
~~~clojure
(can-ir
	(d-let
		(p-assign (ident "Http.timeout"))
		(e-anno-only)
		(annotation
			(ty-lookup (name "U64") (builtin))))
	(d-let
		(p-assign (ident "Http.pure"))
		(e-anno-only)
		(annotation
			(ty-fn (effectful false)
				(ty-lookup (name "Str") (builtin))
				(ty-lookup (name "Str") (builtin)))))
	(d-let
		(p-assign (ident "fetch!"))
		(e-anno-only)
		(annotation
			(ty-lookup (name "Fetch") (local))))
	(s-nominal-decl
		(ty-header (name "Http"))
		(ty-tag-union))
	(s-alias-decl
		(ty-header (name "Fetch"))
		(ty-fn (effectful true)
			(ty-lookup (name "Str") (builtin))
			(ty-lookup (name "Str") (builtin)))))
~~~
# TYPES
~~~clojure
(inferred-types
	(defs
		(patt (type "U64"))
		(patt (type "Str -> Str"))
		(patt (type "Fetch")))
	(type_decls
		(nominal (type "Http")
			(ty-header (name "Http")))
		(alias (type "Fetch")
			(ty-header (name "Fetch"))))
	(expressions
		(expr (type "U64"))
		(expr (type "Str -> Str"))
		(expr (type "Fetch"))))
~~~
