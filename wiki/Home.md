# Stats for Windower 4

Stats tracks active FFXI enemies separately and saves completed fights in a local SQLite database. See the [README](../README.md) for installation, settings, and command details.

To move the overlay, drag it with the left mouse button. The position saves when you release the button and is restored when the addon next loads. Use `//stats position reset` if it moves off screen.

Use `//stats active` to list enemies and `//stats focus <enemy ID>` to choose which fight appears on the overlay. Other enemies continue to be tracked. The overlay keeps a separate session damage total for the current character. `//stats export [character]` writes a character named CSV, and automatic per-character logging is on by default. Useful commands also include `//stats`, `//stats report`, `//stats reset`, `//stats review`, `//stats review all`, `//stats overlay on`, and `//stats help`.
