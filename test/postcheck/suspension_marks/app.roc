app [main!] { pf: platform "./platform/main.roc" }

main! = |text| Str.concat(text, "!")
