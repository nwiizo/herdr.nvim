local root = vim.fn.fnamemodify(vim.fn.getcwd(), ":p")
vim.opt.runtimepath:prepend(root)
vim.opt.swapfile = false
vim.opt.shadafile = "NONE"
-- Unit tests must not move the real caller's Herdr pane. Integration tests opt in
-- with their own isolated configuration; the cross-Space unit test sets this.
vim.env.HERDR_ENV = nil
