{
open Calc_parser
}
let digit = ['0'-'9']
rule token = parse
  | [' ' '\t' '\r' '\n'] { token lexbuf }
  | digit+ as n { INT (int_of_string n) }
  | '+' { PLUS }
  | '*' { TIMES }
  | eof { EOF }
