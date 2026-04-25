if vim.g.loaded_universal_live_share == 1 then
  return
end

vim.g.loaded_universal_live_share = 1

require("universal_live_share").setup()
