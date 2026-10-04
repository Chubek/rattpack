if exists('b:current_syntax')
  finish
endif

runtime! syntax/rattscript.vim
syntax keyword rattpkgDeclaration package deps dep registry git http ftp
highlight default link rattpkgDeclaration Keyword
let b:current_syntax = 'rattpkg'
