app [main!] { pf: platform "./platform/main.roc" }

import pf.Host

# The platform fetches once before calling `main!`, and `main!` fetches
# again, so the task pauses inside a procedure the platform calls.
main! : Str => Str
main! = |text| Host.fetch!(text)
