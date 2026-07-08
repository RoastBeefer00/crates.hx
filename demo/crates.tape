# crates.hx demo
# Requirements: helix-steel with crates.hx loaded and enable-crates-auto! called
# Run from this directory: vhs crates.tape

Output crates.gif

Set Shell "fish"
Set FontSize 14
Set Width 1000
Set Height 400
Set Theme "Catppuccin Mocha"
Set TypingSpeed 80ms

# Open a Cargo.toml — enable-crates-auto! fires the background fetch immediately
Type "hx Cargo.toml"
Enter
Sleep 2s

# Wait for crates.io fetches to finish (background thread, ~5-8s on a typical connection)
Sleep 8s

# Hints are now visible inline — scroll through to show them all
Type "gg"
Sleep 1s
Type "G"
Sleep 2s

# Clear hints with the provided command
Type ":crates-clear-hints"
Enter
Sleep 1s

# Re-fetch on demand
Type ":crates-show-hints"
Enter
Sleep 8s

Type ":q!"
Enter
