" Maintainer:  David Ulrich
" Last Change: 2015-03-18

set background=dark
hi clear
if exists("syntax_on")
	syntax reset
endif

let g:colors_name = "dulrich"

hi Normal       ctermfg=grey ctermbg=black cterm=none term=none
hi ErrorMsg     ctermfg=white ctermbg=lightblue
hi Visual       ctermfg=lightblue ctermbg=fg cterm=reverse
hi VisualNOS    ctermfg=lightblue ctermbg=fg cterm=reverse,underline
hi Todo         ctermfg=red	ctermbg=darkblue
hi Search       ctermfg=white ctermbg=darkblue cterm=underline term=underline
hi IncSearch    ctermfg=darkblue ctermbg=gray

hi SpecialKey		guifg=cyan			ctermfg=darkcyan
hi Directory		guifg=cyan			ctermfg=cyan
hi Title			guifg=magenta gui=none ctermfg=magenta cterm=bold
hi WarningMsg		guifg=red			ctermfg=red
hi WildMenu			guifg=yellow guibg=black ctermfg=yellow ctermbg=black cterm=none term=none
hi ModeMsg			guifg=#22cce2		ctermfg=lightblue
hi MoreMsg			ctermfg=darkgreen	ctermfg=darkgreen
hi Question			guifg=green gui=none ctermfg=green cterm=none
hi NonText			guifg=#0030ff		ctermfg=darkblue

hi StatusLine	guifg=blue guibg=darkgray gui=none		ctermfg=blue ctermbg=gray term=none cterm=none
hi StatusLineNC	guifg=black guibg=darkgray gui=none		ctermfg=black ctermbg=gray term=none cterm=none
hi VertSplit        ctermfg=grey ctermbg=gray term=none cterm=none

hi Folded	guifg=#808080 guibg=#000040			ctermfg=darkgrey ctermbg=black cterm=bold term=bold
hi FoldColumn	guifg=#808080 guibg=#000040			ctermfg=darkgrey ctermbg=black cterm=bold term=bold
hi LineNr	guifg=#90f020			ctermfg=green cterm=none

hi DiffAdd	guibg=darkblue	ctermbg=darkblue term=none cterm=none
hi DiffChange	guibg=darkmagenta ctermbg=magenta cterm=none
hi DiffDelete	ctermfg=blue ctermbg=cyan gui=bold guifg=Blue guibg=DarkCyan
hi DiffText	cterm=bold ctermbg=red gui=bold guibg=Red

hi Cursor	guifg=black guibg=yellow ctermfg=black ctermbg=yellow
hi lCursor	guifg=black guibg=white ctermfg=black ctermbg=white


hi Comment    ctermfg=darkblue
hi Constant   ctermfg=magenta cterm=none
hi Function   ctermfg=white
hi Special    ctermfg=brown cterm=none gui=none
hi Identifier ctermfg=cyan cterm=none
hi Statement  ctermfg=yellow cterm=none
hi String     ctermfg=darkred cterm=none
hi PreProc    ctermfg=magenta cterm=none
hi type       ctermfg=green cterm=none
hi Underlined cterm=underline term=underline
hi Ignore     ctermfg=bg

" suggested by tigmoid, 2008 Jul 18
hi Pmenu guifg=#c0c0c0 guibg=#404080
hi PmenuSel guifg=#c0c0c0 guibg=#2050d0
hi PmenuSbar guifg=blue guibg=darkgray
hi PmenuThumb guifg=#c0c0c0
