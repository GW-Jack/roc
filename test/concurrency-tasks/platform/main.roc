platform ""
    requires {
        main! : Str => Str
    }
    exposes [Host]
    packages {}
    provides { "roc_main": main_for_host! }
    hosted {
        "roc_host_fetch": Host.fetch!,
    }
    concurrency: Tasks
    targets: {
        inputs_dir: "targets/",
        arm64mac: { inputs: ["libhost.a", app], output: Shared },
        x64musl: { inputs: ["libhost.a", app], output: Shared },
    }

import Host

main_for_host! : Str => Str
main_for_host! = |url| main!(Host.fetch!(url))
