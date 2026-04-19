# ripbot

Disc ingestion + classification + automated ripping pipeline.

## Current Features
- Probe disc via MakeMKV
- Classify titles (episode vs junk)
- Confidence scoring
- Conditional auto-rip

## Usage
./bin/ripAssistant.sh --help

## Structure
- bin/      -> executable scripts
- state/    -> runtime state (ignored)
- logs/     -> logs (ignored)
- tmp/      -> scratch (ignored)
