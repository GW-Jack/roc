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
    first = keep_after_log!(url)
    second = keep_after_fetch!(url)
    main!(Str.concat(first, second))
}

# Returns its own argument; may suspend.
keep_after_fetch! : Str => Str
keep_after_fetch! = |text| {
    _ = Host.fetch!("ping")
    text
}

# The same shape without a suspension site.
keep_after_log! : Str => Str
keep_after_log! = |text| {
    Host.log!("ping")
    text
}
