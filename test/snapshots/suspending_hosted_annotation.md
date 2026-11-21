# META
~~~ini
description=suspending marks a hosted function annotation in a type mod's associated block
type=file:Http.roc
~~~
# SOURCE
~~~roc
Http := [].{
	suspending get_utf8! : Str => Str
	suspending   # waits on the network
		post! : Str, Str => Str
	line! : Str => {}
}
~~~
# EXPECTED
DECLARATION HAS NO VALUE - suspending_hosted_annotation.md:2:2:2:35
DECLARATION HAS NO VALUE - suspending_hosted_annotation.md:3:2:4:26
DECLARATION HAS NO VALUE - suspending_hosted_annotation.md:5:2:5:19
# PROBLEMS
~~~clojure
(reports
	(report
		(severity warning)
		(title "Declaration Has No Value")
		(region (start 2 2) (end 2 35))
		(headline
			(reflow "This declaration has a type annotation but no implementation."))
		(document
			(source-region (file "suspending_hosted_annotation.md") (start 2 2) (end 2 35) (annotation error) (line-text "\tsuspending get_utf8! : Str => Str"))
			(line-break)
			(line-break)
			(reflow "Add a value body here, or put hosted functions in a platform type mod so they are published through the host boundary.")))
	(report
		(severity warning)
		(title "Declaration Has No Value")
		(region (start 3 2) (end 4 26))
		(headline
			(reflow "This declaration has a type annotation but no implementation."))
		(document
			(source-region (file "suspending_hosted_annotation.md") (start 3 2) (end 4 26) (annotation error) (line-text "\tsuspending   # waits on the network\n\t\tpost! : Str, Str => Str"))
			(line-break)
			(line-break)
			(reflow "Add a value body here, or put hosted functions in a platform type mod so they are published through the host boundary.")))
	(report
		(severity warning)
		(title "Declaration Has No Value")
		(region (start 5 2) (end 5 19))
		(headline
			(reflow "This declaration has a type annotation but no implementation."))
		(document
			(source-region (file "suspending_hosted_annotation.md") (start 5 2) (end 5 19) (annotation error) (line-text "\tline! : Str => {}"))
			(line-break)
			(line-break)
			(reflow "Add a value body here, or put hosted functions in a platform type mod so they are published through the host boundary."))))
~~~
# TOKENS
~~~zig
UpperIdent,OpColonEqual,OpenSquare,CloseSquare,Dot,OpenCurly,
LowerIdent,LowerIdent,OpColon,UpperIdent,OpFatArrow,UpperIdent,
LowerIdent,
LowerIdent,OpColon,UpperIdent,Comma,UpperIdent,OpFatArrow,UpperIdent,
LowerIdent,OpColon,UpperIdent,OpFatArrow,OpenCurly,CloseCurly,
CloseCurly,
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
				(s-type-anno (name "get_utf8!") (suspending true)
					(ty-fn
						(ty (name "Str"))
						(ty (name "Str"))))
				(s-type-anno (name "post!") (suspending true)
					(ty-fn
						(ty (name "Str"))
						(ty (name "Str"))
						(ty (name "Str"))))
				(s-type-anno (name "line!")
					(ty-fn
						(ty (name "Str"))
						(ty-record)))))))
~~~
# FORMATTED
~~~roc
Http := [].{
	suspending get_utf8! : Str => Str
	suspending # waits on the network
		post! : Str, Str => Str
	line! : Str => {}
}
~~~
# CANONICALIZE
~~~clojure
(can-ir
	(d-let
		(p-assign (ident "Http.get_utf8!"))
		(e-anno-only)
		(annotation
			(ty-fn (effectful true)
				(ty-lookup (name "Str") (builtin))
				(ty-lookup (name "Str") (builtin)))))
	(d-let
		(p-assign (ident "Http.post!"))
		(e-anno-only)
		(annotation
			(ty-fn (effectful true)
				(ty-lookup (name "Str") (builtin))
				(ty-lookup (name "Str") (builtin))
				(ty-lookup (name "Str") (builtin)))))
	(d-let
		(p-assign (ident "Http.line!"))
		(e-anno-only)
		(annotation
			(ty-fn (effectful true)
				(ty-lookup (name "Str") (builtin))
				(ty-record))))
	(s-nominal-decl
		(ty-header (name "Http"))
		(ty-tag-union)))
~~~
# TYPES
~~~clojure
(inferred-types
	(defs
		(patt (type "Str => Str"))
		(patt (type "Str, Str => Str"))
		(patt (type "Str => {}")))
	(type_decls
		(nominal (type "Http")
			(ty-header (name "Http"))))
	(expressions
		(expr (type "Str => Str"))
		(expr (type "Str, Str => Str"))
		(expr (type "Str => {}"))))
~~~
