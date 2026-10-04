" Shared buffer setup, saved-file linting, completion, and indentation.
function! ratt#Setup() abort
  setlocal expandtab shiftwidth=2 softtabstop=2 tabstop=2
  setlocal commentstring=#\ %s comments=:#,://
  setlocal formatoptions-=t formatoptions+=croql
  setlocal omnifunc=ratt#Complete
  let &l:makeprg = shellescape(get(g:, 'ratt_lint_program', 'rattsc')) . ' --lint %:S'
  let &l:errorformat = '%E%f:%l:%c: %m,%-G%.%#'
  command! -buffer RattLint call ratt#Lint()
  let b:undo_ftplugin = 'setlocal expandtab< shiftwidth< softtabstop< tabstop< commentstring< comments< formatoptions< omnifunc< makeprg< errorformat< | silent! delcommand -buffer RattLint'
endfunction

function! ratt#Lint() abort
  let file = expand('%:p')
  if &modified || empty(file) || !filereadable(file)
    echoerr 'RattLint: save the buffer before linting'
    return
  endif
  let program = get(g:, 'ratt_lint_program', 'rattsc')
  if !executable(program)
    echoerr 'RattLint: cannot find ' . program
    return
  endif
  let output = systemlist(shellescape(program) . ' --lint ' . shellescape(file) . ' 2>&1')
  let status = v:shell_error
  call setloclist(0, [], 'r', {'title': 'Rattscript lint', 'lines': output, 'efm': &l:errorformat})
  if status && empty(getloclist(0))
    echoerr join(output, "\n")
  else
    echo status ? 'RattLint: diagnostics available in :lopen' : 'RattLint: no diagnostics'
  endif
endfunction

function! ratt#Complete(findstart, base) abort
  if a:findstart
    let start = col('.') - 1
    let line = getline('.')
    while start > 0 && line[start - 1] =~# '[A-Za-z0-9_]'
      let start -= 1
    endwhile
    return start
  endif
  let words = split('let var const fn import as action if else for foreach while return break continue and or not in true false nil any bool int float str path list map set target rule pkg print assert len type range sorted keys project module monorepo member vendored ignore package deps dep registry git http ftp')
  for line in getline(1, '$')
    let declaration = matchlist(line, '^\s*\%(let\|var\|const\|fn\)\s\+\([A-Za-z_][A-Za-z0-9_]*\)')
    if !empty(declaration)
      call add(words, declaration[1])
    endif
  endfor
  return filter(uniq(sort(words)), 'stridx(v:val, a:base) == 0')
endfunction

function! s:Code(lnum) abort
  let result = ''
  let quote = ''
  let escaped = 0
  let line = getline(a:lnum)
  let index = 0
  while index < strlen(line)
    let character = line[index]
    if !empty(quote)
      if escaped
        let escaped = 0
      elseif character ==# '\'
        let escaped = 1
      elseif character ==# quote
        let quote = ''
      endif
    elseif character ==# '"' || character ==# "'"
      let quote = character
    elseif character ==# '#' || strpart(line, index, 2) ==# '//'
      break
    else
      let result .= character
    endif
    let index += 1
  endwhile
  return result
endfunction

function! ratt#Indent() abort
  let previous = prevnonblank(v:lnum - 1)
  if !previous
    return 0
  endif
  let code = substitute(s:Code(previous), '^\s*[]})]\+', '', '')
  let opening = strlen(substitute(code, '[^([{]', '', 'g'))
  let closing = strlen(substitute(code, '[^])}]', '', 'g'))
  let amount = indent(previous) + shiftwidth() * (opening - closing)
  if s:Code(v:lnum) =~# '^\s*[]})]'
    let amount -= shiftwidth()
  endif
  return max([0, amount])
endfunction
