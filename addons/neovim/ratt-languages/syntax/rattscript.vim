if exists('b:current_syntax')
  finish
endif

syntax case match
syntax keyword rattscriptKeyword let var const fn import as action
syntax keyword rattscriptControl if else for foreach while return break continue
syntax keyword rattscriptBoolean true false
syntax keyword rattscriptConstant nil
syntax keyword rattscriptType any bool int float str path list map set target rule pkg
syntax keyword rattscriptOperator and or not in
syntax keyword rattscriptBuiltin print assert len type range sorted keys
syntax match rattscriptFunction "\<[A-Za-z_][A-Za-z0-9_]*\ze\s*("
syntax match rattscriptNumber "\<\d\+\%(\.\d\+\)\?\%([eE][+-]\?\d\+\)\?\>"
syntax match rattscriptOperator "[-+*/%=!<>]\|&&\|||\|\.\.\|->"
syntax match rattscriptComment "#.*$" contains=rattscriptTodo
syntax match rattscriptComment "//.*$" contains=rattscriptTodo
syntax keyword rattscriptTodo TODO FIXME NOTE XXX contained
syntax match rattscriptEscapeError +\\.+ contained
syntax match rattscriptEscape +\\\%([nrtbf/\\'\"]\|u[0-9A-Fa-f]\{4}\)+ contained
syntax region rattscriptString start=+"+ skip=+\\\\\|\\"+ end=+"+ contains=rattscriptEscape,rattscriptEscapeError,rattscriptTemplate
syntax region rattscriptString start=+'+ skip=+\\\\\|\\'+ end=+'+ contains=rattscriptEscape,rattscriptEscapeError,rattscriptTemplate
syntax region rattscriptTemplate start=+@{+ end=+}+ contains=rattscriptNumber,rattscriptFunction,rattscriptString,rattscriptOperator
syntax match rattscriptTemplateDirective "@\%(if\|else\|end\|foreach\)\>"

highlight default link rattscriptKeyword Keyword
highlight default link rattscriptControl Statement
highlight default link rattscriptBoolean Boolean
highlight default link rattscriptConstant Constant
highlight default link rattscriptType Type
highlight default link rattscriptOperator Operator
highlight default link rattscriptBuiltin Function
highlight default link rattscriptFunction Function
highlight default link rattscriptComment Comment
highlight default link rattscriptTodo Todo
highlight default link rattscriptNumber Number
highlight default link rattscriptString String
highlight default link rattscriptEscape SpecialChar
highlight default link rattscriptEscapeError Error
highlight default link rattscriptTemplate PreProc
highlight default link rattscriptTemplateDirective PreProc

let b:current_syntax = 'rattscript'
