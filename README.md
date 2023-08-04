<p align="center">
  <a href="https://github.com/koraykoska/libwebsockets.swift">
    <img src="https://crypto-bot-main.fra1.digitaloceanspaces.com/libwebsockets.swift/logo512.png" width="256" height="256">
  </a>
</p>

<p align="center">
  <a href="https://github.com/koraykoska/libwebsockets.swift/actions/workflows/test.yml">
    <img src="https://github.com/koraykoska/libwebsockets.swift/actions/workflows/test.yml/badge.svg?branch=master" alt="CI Status">
  </a>
  <a href="https://github.com/koraykoska/libwebsockets.swift/releases">
    <img src="https://img.shields.io/github/v/release/koraykoska/libwebsockets.swift" alt="Latest Release">
  </a>
</p>

# :hatching_chick: libwebsockets.swift

libwebsockets.swift is a thin Swift wrapper around [libwebsockets](https://github.com/warmcat/libwebsockets).

This library aims to be the most performant Swift Websocket library, and hence uses [swift-nio](https://github.com/apple/swift-nio)
EventLoops, is thread safe by default, non-blocking and manages memory automatically.

Websocket messages can be received as either Text, Binary or Fragments to be parsed manually.

SSL (wss) support is achieved using OpenSSL bindings.

Compression ([permessage-deflate](https://datatracker.ietf.org/doc/html/rfc7692)) is supported with all config options.

The test suite utilizes the [Autobahn test suite](https://github.com/crossbario/autobahn-testsuite)
and passes all of the (currently) 517 test cases. With the performance tests finishing ~2-3x faster than any
other Swift Websocket library as of this writing.

## Example

The `Examples/` directory has some examples you can use as a base for your project.

## Contributing

PRs are welcome, but please make sure to keep the feature set at a minimum. Our philosophy is to be as thin of a
wrapper as practical to maintain the speed and efficiency of libwebsockets while being as user friendly for
Swift developers as possible.

We want to achieve maximum configurability, to make it possible to use libwebsockets.swift in any use case, but don't
want to encode all use cases into the repository.

## Why?

I love Swift. But I hate the ecosystem. Swift is amazing for high performance apps, but the open source ecosystem
is scarce and the only Websocket libraries out there right now are slow, feature-incomplete and lack high-throughput
battle-testedness.

Building on libwebsockets, which is in use by FAANG and other Fortune 500 for years already, and building the thinnest
practical wrapper on top, this library aims to make the Swift ecosystem a little bit better.

## Platforms

We officially support macOS and Ubuntu (as you can see in the CI). The library was built with Swift 5.8 in mind,
but Swift 5.7 is tested and works as well.
That being said, all little endian Systems that support Swift 5.7+ and the below system dependencies should work fine.
Just make sure to run the test suite before using it in production.

## System Dependencies

An up-to-date list of system dependencies can be found in the `Package.swift`. The most important ones are listed below:

* OpenSSL (Homebrew: openssl, apt: libssl-dev)
* DBus (Homebrew: dbus, apt: libdbus-1-dev)
* Zlib (macOS: XCode command line tools, apt: libz-dev)
* SQlite3 (Homebrew: sqlite3, apt: libsqlite3-dev)

When building a Docker image, make sure to install those system dependencies in both the build container and the
run container.

## Installation

### Swift Package Manager

libwebsockets.swift is compatible with Swift Package Manager (Swift 5.7 and above). Simply add it to the dependencies
in your `Package.swift`.

```Swift
dependencies: [
    .package(url: "https://github.com/koraykoska/libwebsockets.swift.git", from: "0.1.0")
]
```

And then add it to your target dependencies:

```Swift
targets: [
    .target(
        name: "MyProject",
        dependencies: [
            .product(name: "libwebsockets", package: "libwebsockets.swift"),
        ]
    ),
    .testTarget(
        name: "MyProjectTests",
        dependencies: ["MyProject"])
]
```

After the installation you can import `libwebsockets` in your `.swift` files.

```Swift
import libwebsockets
```
