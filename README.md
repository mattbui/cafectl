# cafectl

Small menu bar and command line util for caffinate your Mac.

- Prevent display, system, or disk sleep independently.
- Automation for each mode based on power source and battery level.

## Usage

Start the service:

```sh
cafectl start
```

Commands:

```sh
cafectl toggle display
cafectl toggle system
cafectl toggle disk
cafectl status
cafectl off-all
cafectl stop
```

Run `cafectl --help` for all commands.

Or use the menu bar item to set power policies and automatic activation for each mode.

## Build

Build from source with Swift 6 on macOS 13 or later:

```sh
swift build -c release
```

## Acknowledgements

- The menu bar icon rendering code is adopted from [Vorssaint](https://github.com/vorssaint/vorssaint-utils)
