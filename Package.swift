// swift-tools-version: 5.7
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

//#if !(arch(x86_64) || arch(arm64))
//fatalError("arch not supported")
//#endif
//
//#if !(os(Linux) || os(macOS))
//fatalError("os not supported")
//#endif

let package = Package(
    name: "libwebsockets",
    products: [
        // Products define the executables and libraries a package produces, making them visible to other packages.
        .library(
            name: "libwebsockets",
            targets: ["libwebsockets"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.57.0"),
        .package(url: "https://github.com/apple/swift-atomics.git", from: "1.1.0"),
    ],
    targets: [
        // Targets are the basic building blocks of a package, defining a module or a test suite.
        // Targets can depend on other targets in this package and products from dependencies.
        .target(
            name: "libwebsockets",
            dependencies: [
                "Clibwebsockets",
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOConcurrencyHelpers", package: "swift-nio"),
                .product(name: "Atomics", package: "swift-atomics"),
            ]
        ),
        .target(
            name: "Clibwebsockets",
            dependencies: ["COpenSSL", "CDBus", "CZlib", "Csqlite3"],
            exclude: [
                "include/",
                "src/tls/tls-jit-trust.c",
                "src/tls/mbedtls",
                "src/system/metrics",
                "src/system/ntpclient",
                "src/system/dhcpclient",
                "src/system/async-dns",
                "src/system/fault-injection",
                "src/secure-streams",
                "src/roles/netlink",
                "src/roles/raw-proxy",
                "src/roles/http/server/access-log.c",
                "src/roles/http/compression/brotli",
                "src/roles/http/compression/deflate",
                "src/roles/http/compression/stream.c",
                "src/roles/http/server/ranges.c",
                "src/roles/http/minilex.c",
                "src/roles/h2/minihuf.c",
                "src/roles/cgi",
                "src/roles/dbus",
                "src/roles/mqtt",
                "src/plat/windows",
                "src/plat/freertos",
                "src/plat/optee",
                "src/plat/unix/unix-spawn.c",
                "src/plat/unix/android",
                "src/misc/threadpool",
                "src/misc/peer-limits.c",
                "src/misc/fsmount.c",
                "src/misc/getifaddrs.c",
                "src/misc/daemonize.c",
                "src/jose",
                "src/event-libs/uloop",
                "src/event-libs/sdevent",
                "src/event-libs/libevent",
                "src/event-libs/libev",
                "src/event-libs/libuv",
                "src/event-libs/glib",
                "src/drivers",
                "src/core-net/socks5-client.c",
                "src/core-net/route.c",
                "src/core-net/sequencer.c",
                "src/abstract",

                "src/CMakeLists.txt",
                "src/README.md",
                "src/abstract/CMakeLists.txt",
                "src/abstract/README.md",
                "src/core/CMakeLists.txt",
                "src/core-net/CMakeLists.txt",
                "src/core-net/README.md",
                "src/cose/CMakeLists.txt",
                "src/drivers/CMakeLists.txt",
                "src/drivers/README.md",
                "src/drivers/button/README.md",
                "src/drivers/display/README.md",
                "src/drivers/led/README.md",
                "src/event-libs/CMakeLists.txt",
                "src/event-libs/README.md",
                "src/event-libs/glib/CMakeLists.txt",
                "src/event-libs/libev/CMakeLists.txt",
                "src/event-libs/libevent/CMakeLists.txt",
                "src/event-libs/libuv/CMakeLists.txt",
                "src/event-libs/poll/CMakeLists.txt",
                "src/event-libs/sdevent/CMakeLists.txt",
                "src/event-libs/uloop/CMakeLists.txt",
                "src/jose/CMakeLists.txt",
                "src/jose/README.md",
                "src/misc/CMakeLists.txt",
                "src/misc/fts/README.md",
                "src/misc/lwsac/README.md",
                "src/misc/threadpool/README.md",
                "src/plat/freertos/CMakeLists.txt",
                "src/plat/optee/CMakeLists.txt",
                "src/plat/unix/CMakeLists.txt",
                "src/plat/windows/CMakeLists.txt",
                "src/roles/CMakeLists.txt",
                "src/roles/README.md",
                "src/roles/cgi/CMakeLists.txt",
                "src/roles/dbus/CMakeLists.txt",
                "src/roles/dbus/README.md",
                "src/roles/h1/CMakeLists.txt",
                "src/roles/h2/CMakeLists.txt",
                "src/roles/http/CMakeLists.txt",
                "src/roles/http/compression/README.md",
                "src/roles/listen/CMakeLists.txt",
                "src/roles/mqtt/CMakeLists.txt",
                "src/roles/raw-file/CMakeLists.txt",
                "src/roles/raw-proxy/CMakeLists.txt",
                "src/roles/raw-skt/CMakeLists.txt",
                "src/roles/ws/CMakeLists.txt",
                "src/secure-streams/CMakeLists.txt",
                "src/secure-streams/README.md",
                "src/secure-streams/cpp/README.md",
                "src/secure-streams/protocols/README.md",
                "src/system/CMakeLists.txt",
                "src/system/README.md",
                "src/system/metrics/CMakeLists.txt",
                "src/system/smd/CMakeLists.txt",
                "src/system/smd/README.md",
                "src/tls/CMakeLists.txt",
                "src/tls/mbedtls/CMakeLists.txt",
            ],
            sources: ["src/"],
            publicHeadersPath: "include/",
            cSettings: [
                .headerSearchPath("include"),
                .headerSearchPath("src"),
                .headerSearchPath("src/abstract"),
                .headerSearchPath("src/core"),
                .headerSearchPath("src/core-net"),
                .headerSearchPath("src/cose"),
                .headerSearchPath("src/drivers"),
                .headerSearchPath("src/event-libs"),
                .headerSearchPath("src/jose"),
                .headerSearchPath("src/misc"),
                .headerSearchPath("src/plat"),
                .headerSearchPath("src/plat/freertos"),
                .headerSearchPath("src/plat/optee"),
                .headerSearchPath("src/plat/unix"),
                .headerSearchPath("src/plat/windows"),
                .headerSearchPath("src/roles"),
                .headerSearchPath("src/roles/cgi"),
                .headerSearchPath("src/roles/dbus"),
                .headerSearchPath("src/roles/h1"),
                .headerSearchPath("src/roles/h2"),
                .headerSearchPath("src/roles/http"),
                .headerSearchPath("src/roles/listen"),
                .headerSearchPath("src/roles/mqtt"),
                .headerSearchPath("src/roles/netlink"),
                .headerSearchPath("src/roles/pipe"),
                .headerSearchPath("src/roles/raw-file"),
                .headerSearchPath("src/roles/raw-proxy"),
                .headerSearchPath("src/roles/raw-skt"),
                .headerSearchPath("src/roles/ws"),
                .headerSearchPath("src/secure-streams"),
                .headerSearchPath("src/system"),
                .headerSearchPath("src/system/smd"),
                .headerSearchPath("src/system/metrics"),
                .headerSearchPath("src/tls"),
                .headerSearchPath("src/tls/openssl"),
            ]
        ),
        .systemLibrary(name: "COpenSSL",
            pkgConfig: "openssl",
            providers: [
                .brew(["openssl"]),
                .apt(["libssl-dev"])
            ]
        ),
        .systemLibrary(name: "CDBus",
            pkgConfig: "dbus-1",
            providers: [
                .brew(["dbus"]),
                .apt(["libdbus-1-dev"])
            ]
        ),
        .systemLibrary(name: "CZlib",
            pkgConfig: "zlib",
            providers: [
                .brew(["zlib", "zlib-devel"]),
                .apt(["libz-dev"])
            ]
        ),
        .systemLibrary(name: "Csqlite3",
            pkgConfig: "sqlite3",
            providers: [
                .brew(["sqlite3"]),
                .apt(["libsqlite3-dev"])
            ]
        ),
        .testTarget(
            name: "libwebsocketsTests",
            dependencies: [
                "libwebsockets",
                .product(name: "NIOPosix", package: "swift-nio"),
            ]),
    ]
)
