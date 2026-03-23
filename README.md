# dial
A very work in progress Odin native game engine/framework.

## Usage
Clone the repo:
`git clone --recursive https://github.com/jfosburgh/dial.git`
Copy the `src` folder into your project, or into Odin's shared collection and import into your project

## Dependencies
This project uses my fork of Leonardo Temperanza's [no_gfx_api](https://github.com/LeonardoTemperanza/no_gfx_api/tree/main) repo, which is a graphics API over Vulkan inspired by Sebastian Aaltonen's [No Graphics Api](https://www.sebastianaaltonen.com/blog/no-graphics-api) blog post.
My only modification so far is to add `cmd_draw_indexed` to enable drawing with shaders that have self-contained vertex/index data.
