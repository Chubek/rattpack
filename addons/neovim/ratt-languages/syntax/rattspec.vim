if exists('b:current_syntax')
  finish
endif

runtime! syntax/rattscript.vim
syntax keyword rattspecDeclaration project module target rule monorepo member vendored ignore
highlight default link rattspecDeclaration Keyword
let b:current_syntax = 'rattspec'
