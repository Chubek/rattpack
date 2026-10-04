if exists('b:did_indent')
  finish
endif
let b:did_indent = 1
setlocal autoindent nolisp nosmartindent
setlocal indentexpr=ratt#Indent()
setlocal indentkeys=0{,0},0),0],!^F,o,O
let b:undo_indent = 'setlocal autoindent< lisp< smartindent< indentexpr< indentkeys<'
