if exists("b:current_syntax")
  finish
endif

syn match Column1 /^\s*\S\+/ nextgroup=Column2 skipwhite
syn match Column2 / \S\+/ nextgroup=Column3 skipwhite
syn match Column3 / /
syn match Input /@|#|&\S+/
syn keyword MyKey Running

let b:current_syntax = "kubelist"
hi def link     Input Function
hi def link     MyKey Function
hi def link     Column1 Identifier
hi def link     Column2 String
hi def link     Column3 Normal
