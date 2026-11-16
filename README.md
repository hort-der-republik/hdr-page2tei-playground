# Page2TEI Playground
Repo for testing transformation of Transkribus Page XML export to TEI XML

## Current Goal

Creating a workflow that allows for seamless transformation without manual XML editing. 

## Work Flow

Adding tags and attributes in Transkribus (some custom, some TEI) > XSLT > voilá. 

## Status

**Adding and transforming structural markup**, including

- region nesting
- assigning lines to regions
- transforming regions to respective surface, zone, div, and metamark elements
- relocating margin additions from outside the text column into the text flow while preserving coordinates

works so far. Clean-up and testing ongoing.

Next annotation layer: **Genetic markup** via change/hand etc. attributes.

Not yet included: More or less the complete **TEI:header**.




