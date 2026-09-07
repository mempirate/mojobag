# Mojobag

An implementation of a BPE tokenizer in Mojo. 
Train your own tokenizer to produce a bag of tokens.

> [!IMPORTANT]
> Only tested on Linux x86. Does not work on Apple Silicon yet due to a pcre2 dependency issue.

## Getting Started
- Clone this repository
- [Install pixi](https://pixi.prefix.dev/latest/installation/)
- Run `pixi shell`. This will set up your environment with all required dependencies.

## Training

I've included a compressed `wikitext-103-raw-v1` in [`data/`](./data/). To build training,
test and validation datasets, run `pixi unzip-wikitext`.
