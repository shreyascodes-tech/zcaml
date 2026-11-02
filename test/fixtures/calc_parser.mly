%token <int> INT
%token PLUS TIMES EOF
%left PLUS
%left TIMES
%start main
%type <int> main
%%
main:
  expr EOF { $1 }
;
expr:
  | INT { $1 }
  | expr PLUS expr { $1 + $3 }
  | expr TIMES expr { $1 * $3 }
;
