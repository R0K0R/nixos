# Language servers, compilers and debuggers -- the interactive development set.
# `user` (users.users.<n>.packages), not `system`: these belong to a person, not
# to the machine.
{ pkgs }:
{
  user = with pkgs; [
    cursor-cli
    git
    gh
    nixd
    nixfmt
    statix
    deadnix
    tree
    python3
    # Python LSP for Emacs `lsp-pyright` when using BasedPyright (`basedpyright-langserver`).
    basedpyright
    clang-tools # clangd LSP + clang-format/clang-tidy
    gcc
    gdb
    tinymist
    typst
  ];

  system = with pkgs; [
    openjdk25_headless
  ];
}
