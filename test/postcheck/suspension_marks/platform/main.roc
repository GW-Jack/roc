platform ""
    requires {} { main! : Str => Str }
    exposes []
    packages {}
    provides { "roc_main": main_for_host! }
    hosted {
        "roc_host_fetch": Host.fetch!,
        "roc_host_log": Host.log!,
    }
    concurrency: Tasks
    targets: {}

import Host

main_for_host! : Str => Str
main_for_host! = |url| {
    note!(url)
    main!(fetch_both!(url))
}

fetch_both! : Str => Str
fetch_both! = |url| Str.concat(Host.fetch!(url), Host.fetch!(url))

note! : Str => {}
note! = |text| Host.log!(text)
