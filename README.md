# universal-live-share.nvim

Neovim plugin that mirrors the behavior of the `universal-live-share` VS Code extension in this workspace.

It:

- connects to `ws://127.0.0.1:42069`
- listens for remote change commands and applies them to the current buffer
- watches local edits and sends compact `{ index, add }` / `{ index, del }` commands
- batches outgoing edits with debounce (`100ms`) and max wait (`200ms`)
- auto-reconnects on websocket disconnect

## Install

Use any plugin manager, for example with `lazy.nvim`:

```lua
{
  dir = "~/dev/hackupc/nvim-plugin",
}
```

No explicit setup call is needed; it loads on startup via `plugin/universal_live_share.lua`.

## Notes for Neovim 0.12

The implementation uses the current `nvim_buf_attach(..., { on_bytes = ... })` callback argument order from Neovim `0.12.x` docs.
