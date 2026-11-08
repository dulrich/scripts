" osc52.vim: send unnamed-register yanks to the terminal clipboard via OSC 52.
" For terminals that honor OSC 52 writes (e.g. foot); works over ssh.
"
" CC0: This work has been marked as dedicated to the public domain.
" https://creativecommons.org/publicdomain/zero/1.0/
if exists('g:loaded_osc52') || !exists('*echoraw')
  finish
endif
let g:loaded_osc52 = 1

function! s:Yank(ev) abort
  if get(a:ev, 'operator', '') !=# 'y' || get(a:ev, 'regname', 'x') !=# ''
    return
  endif
  let l:text = join(a:ev.regcontents, "\n") . (a:ev.regtype ==# 'V' ? "\n" : '')
  let l:b64 = substitute(system('base64 -w0', l:text), '\n\+$', '', '')
  if v:shell_error == 0
    call echoraw("\e]52;c;" . l:b64 . "\x07")
  endif
endfunction

augroup osc52
  autocmd!
  autocmd TextYankPost * call s:Yank(v:event)
augroup END
