# Pack.nvim

Pack is a fork of [paq-nvim](https://github.com/savq/paq-nvim) and tries to be
dead simple and levereging the neovim's builtin APIs to reduce it's size.

## Features

- **Simple**: Easy to use and configure
- **Fast**: Installs and updates packages concurrently using Neovim's event-loop
- **Small**: Around 450 LOC
- **UpToDate**: Relies as much as possible to neovim nightly APIs
- **Upstreamable**: Tries to always match the neovim core lua code style

## Requirements

- git
- [Neovim Nightly](https://github.com/neovim/neovim)

## Installation

Clone this repository.

For Unix-like systems:

```sh
git clone --depth=1 https://github.com/saccarosium/pack.nvim.git \
    "${XDG_DATA_HOME:-$HOME/.local/share}"/nvim/site/pack/packs/start/pack.nvim
```

For Windows (cmd.exe):

```
git clone https://github.com/saccarosium/pack.nvim.git %LOCALAPPDATA%\nvim-data\site\pack\packs\start\pack.nvim
```

For Windows (powershell):

```
git clone https://github.com/saccarosium/pack.nvim.git $env:LOCALAPPDATA\nvim-data\site\pack\packs\start\pack.nvim
```

## Usage

In your init.lua, `require` the `"pack"` module with a list of packages, like:

```lua
-- pack will autoupdate by itself
require("pack").register({
    "neovim/nvim-lspconfig",
    { 'nvim-treesitter/nvim-treesitter', build = ':TSUpdate' }, -- Use braces when passing options
})
```

Then, source your configuration (executing `:source $MYVIMRC`) and run `:PackInstall`.

## Commands

- `PackInstall`: Install all packages listed in your configuration.
- `PackUpdate`: Update all packages already on your system (it won't implicitly install them).
- `PackClean`: Remove all packages (in Pack's directory) that aren't listed on your configuration.
- `PackSync`: Execute the three commands listed above.

## Options

| Option | Type     |                                                           |
|--------|----------|-----------------------------------------------------------|
| as     | string   | Name to use for the package locally                       |
| branch | string   | Branch of the repository                                  |
| build  | function | Lua function to run after install/update                  |
| build  | string   | Shell command to run after install/update                 |
| build  | string   | Prefixed with a ':' will run a vim command                |
| pin    | boolean  | Pinned packages are not updated                           |
| url    | string   | URL of the remote repository, useful for non-GitHub repos |

## Credits

Thanks to Sergio A. Vargas (@savq) for creating [paq-nvim](https://github.com/savq/paq-nvim).
