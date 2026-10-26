-- Native Neovim 0.11+ integration. No plugin manager or language-client dependency.
if vim.g.loaded_chainwall then return end
vim.g.loaded_chainwall = true
vim.filetype.add({ extension = { ls = 'lambdascript' } })
if vim.fn.has('nvim-0.11') == 0 then
  vim.notify('Chainwall LSP requires Neovim 0.11 or newer', vim.log.levels.WARN)
  return
end
vim.lsp.config('chainwall', {
  cmd = vim.g.chainwall_lsp_cmd or { 'chainwall-lsp', '--stdio' },
  filetypes = { 'lambdascript' },
  root_markers = { 'chainwall-lsp.json', '.git' },
})
vim.lsp.enable('chainwall')
