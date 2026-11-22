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
        x64mac: { inputs: ["libhost.a", app] },
        arm64mac: { inputs: ["libhost.a", app] },
        x64musl: { inputs: ["rcrt1.o", "libhost.a", app, "libc.a"] },
        arm64musl: { inputs: ["rcrt1.o", "libhost.a", app, "libc.a"] },
    }

import Host

main_for_host! : Str => Str
main_for_host! = |url| main!(Host.fetch!(url))
