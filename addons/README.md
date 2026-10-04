# Editor add-ons

Rattpack ships syntax highlighting, file detection, indentation, and language
services for Rattscript, build specs, and package manifests. Build the shared
runtime and language server from the repository root:

```sh
dub build -c rattsc --compiler=ldc2
dub build -c ratt-language-server --compiler=ldc2
```

Put `build/` on `PATH` for editor use, or install with
`./install.sh --build --compiler=ldc2`. The installer places the server beside
the other applications and copies these add-ons to `share/rattpack/addons/`.
Keep the executables and their matching shared runtime together.

## Recognized files

| Language ID / filetype | Canonical files | Additional extensions |
| --- | --- | --- |
| `rattscript` | `*.ratt`, `*.ratt.in` | `*.rattscript`, `*.rattscript.in` |
| `rattspec` | `Rattspec`, `Rattspec.m`, `Rattspec.in`, `Rattspec.m.in` | `*.rattspec`, `*.rattspec.in` |
| `rattpkg` | `Rattpkg`, `Rattpkg.in` | `*.rattpkg`, `*.rattpkg.in` |

`Rattpkg.lock` is TOML and retains the editor's TOML filetype. General `.m` and
`.in` files are not reassigned to Rattscript.

## Vim

Copy the runtime into Vim's native package directory. These commands use a POSIX
shell and run from the checkout:

```sh
mkdir -p ~/.vim/pack/rattpack/start
cp -R addons/vim/ratt-languages ~/.vim/pack/rattpack/start/
```

Enable the usual runtime features in `vimrc`:

```vim
filetype plugin indent on
syntax on
```

Buffers use two-space indentation, `#` comments, both quoted string forms,
numeric exponents, build/package declarations, and template highlighting.
`Ctrl-X Ctrl-O` completes keywords and local declaration names. `:RattLint`
checks the saved file with `rattsc --lint`; `:lopen` displays its location list.
`:make` uses the same linter and populates the quickfix list. Set a custom
interpreter path before opening buffers if needed:

```vim
let g:ratt_lint_program = '/path/to/rattsc'
```

Vim language-server clients can use the server for live unsaved-buffer analysis.
For [vim-lsp](https://github.com/prabirshrestha/vim-lsp), add:

```vim
augroup ratt_language_server
  autocmd!
  autocmd User lsp_setup call lsp#register_server({
        \ 'name': 'ratt-language-server',
        \ 'cmd': {server_info -> ['ratt-language-server', '--stdio']},
        \ 'allowlist': ['rattscript', 'rattspec', 'rattpkg'],
        \ })
augroup END
```

The ftplugins use buffer-local settings and supply undo hooks, so switching to
another filetype restores its normal options.

## Neovim

Install the standalone Neovim package:

```sh
mkdir -p ~/.local/share/nvim/site/pack/rattpack/start
cp -R addons/neovim/ratt-languages ~/.local/share/nvim/site/pack/rattpack/start/
```

It includes the Vim runtime features and starts the native LSP client on
Neovim **0.8+** when `ratt-language-server` is executable. It needs no
`nvim-lspconfig` dependency. Files in one project reuse a server rooted at the
nearest `Rattspec`, `Rattpkg`, template root, or `.git` marker. Standalone files
use their directory as the root.

To customize the command and buffer mappings in `init.lua`:

```lua
require('ratt').setup({
  cmd = { '/path/to/ratt-language-server', '--stdio' },
  on_attach = function(_, buffer)
    vim.keymap.set('n', 'gd', vim.lsp.buf.definition, { buffer = buffer })
    vim.keymap.set('n', 'K', vim.lsp.buf.hover, { buffer = buffer })
  end,
})
```

LSP completion is available through `Ctrl-X Ctrl-O`. Diagnostics use Neovim's
standard diagnostic UI. Disable automatic LSP startup with
`vim.g.ratt_lsp_enabled = 0` before package loading, or with
`require('ratt').setup({ enabled = false })`. The syntax and saved-file tooling
remain available. `vim.g.ratt_lsp_command` can supply an argv list before load.
The package does not install key mappings automatically.

## Sublime Text

Copy the contents of `addons/sublime/` into a `Rattpack` directory under the
Packages folder shown by **Preferences → Browse Packages**. Use Sublime Text 4.
The three syntaxes share the full Rattscript grammar and add spec/package
keywords; syntax-specific settings choose two-space indentation. Comment
commands use the bundled `Rattpack.tmPreferences`.

Install the **LSP** package through Package Control for live language services.
The bundled `plugin.py` registers the three clients and loads their
`LSP-Rattscript.sublime-settings`, `LSP-Rattspec.sublime-settings`, and
`LSP-Rattpkg.sublime-settings` defaults. Syntax support also works without LSP.
Use LSP's client settings to override the command with an absolute server path:

```json
{"command": ["/path/to/ratt-language-server", "--stdio"]}
```

The settings contain normal per-client LSP fields, so no manual copy into the
global `clients` map is needed. Enable or disable individual clients through LSP.

## Language server

Run `ratt-language-server --stdio` from an LSP client. It implements byte-counted
`Content-Length` framing over stdin/stdout; logs use stderr or LSP log messages.
`--help` and `--version` are ordinary command-line queries.

| Service | Behavior |
| --- | --- |
| Synchronization | Open/close, full replacement, and incremental UTF-16 edits |
| Diagnostics | Parser errors, statically inferable annotation mismatches, and source-import errors; refresh on edits/save/watch notifications |
| Completion | Keywords, visible declarations, standard-module import names, and members of imported/aliased modules |
| Hover | Local annotations/function signatures and shipped standard-library signatures |
| Definition | Lexically resolved declarations, local module imports, and statically declared imported members |
| Document symbols | Functions, variables, parameters, and imported bindings |

Imported source is read relative to the importing file. Open documents in the
same session take precedence over disk, so unsaved helper edits update dependent
diagnostics and definitions. Import cycles and missing modules use `E_IMPORT`.
Embedded module signatures are read from their compiled source without executing
it. An unfinished expression retains imports and complete preceding statements
for completion.

The server uses the real parser and annotation linter. It never executes script
top-level statements, actions, package resolution, or template expressions.
Template directives are masked and substitutions are treated as unknown values
for static body checks, preserving original diagnostic offsets. Configuration-
dependent template output and dynamic build/package validation are checked by
the corresponding CLI. Diagnostics report the first failing check in each open
document's import tree, as `rattsc --lint` does for source files.

Generic client descriptors are in `lsp/*.json`. They document language IDs,
extensions, exact filenames, command argv, and root markers; adapt those fields
to your client's configuration schema.

## Verification

From the checkout, build `rattsc` and `ratt-language-server` with the same
compiler, then run:

```sh
dub test
./build/rattsc --test tests/script
python3 tests/addons/run.py
```

The add-on suite exercises protocol lifecycle/framing, UTF-16 incremental edits,
unsaved imports, static diagnostics, completion, hover, definitions, templates,
and live Neovim attachment. Available Vim/Neovim executables also verify file
detection, syntax groups, indentation, and lint location lists. Missing editors
are reported as skipped.
