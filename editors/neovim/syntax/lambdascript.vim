if exists('b:current_syntax') | finish | endif
syntax keyword chainwallKeyword let and in if then else
syntax match chainwallBuiltin /\$[A-Za-z_][A-Za-z0-9_]*/
syntax match chainwallReference /@[A-Za-z_][A-Za-z0-9_]*/
syntax match chainwallNumber /\<\d[0-9_a-fA-FxXeE.]*\>/
syntax region chainwallString start=/"/ skip=/\\./ end=/"/
syntax region chainwallString start=/'/ skip=/\\./ end=/'/
syntax match chainwallOperator /[+*\/%=<>!&|?:-]/
highlight default link chainwallKeyword Keyword
highlight default link chainwallBuiltin Function
highlight default link chainwallReference Type
highlight default link chainwallNumber Number
highlight default link chainwallString String
highlight default link chainwallOperator Operator
let b:current_syntax = 'lambdascript'
