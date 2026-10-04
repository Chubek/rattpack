augroup filetypedetect_rattspec
  autocmd!
  " Canonical .m specs take precedence over the editor's generic MATLAB rule.
  autocmd BufRead,BufNewFile Rattspec,Rattspec.m,Rattspec.in,Rattspec.m.in,*.rattspec,*.rattspec.in setlocal filetype=rattspec
augroup END
