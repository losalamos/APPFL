-- Lexer for stg like lang.

module Lexer
( Tag(..)
, Token
, prelex
, lexer
, strip
, lexString 
) where

import Parsing

prelex :: [Char] -> [Pos Char]
prelex = pl (0,0)
    where
        pl (r,c) [] = []
        pl (r,c) (x:xs) 
            | x == '\t' = (x,(r,c)) : pl (r, tab c) xs
            | x == '\n' = (x,(r,c)) : pl (r+1, 0) xs
            | otherwise = (x,(r,c)) : pl (r, c+1) xs
        tab c = ((c `div` 8)+1)*8               

-- 4.3 Lexical analysis

data Tag = Ident | Integer | Floating | Symbol | Junk | Keyword |
           Construct | Obj | Prim deriving (Eq,Show)

type Token = (Tag,[Char])

tok :: Parser (Pos Char) [Char] -> Tag -> Parser (Pos Char) (Pos Token)
(p `tok` t) inp = [(((t,xs),(r,c)),out) | (xs,out) <- p inp]
                  where (x,(r,c)) = head inp

lexit :: [(Parser (Pos Char) [Char],Tag)] -> Parser (Pos Char) [Pos Token]
lexit = many . (foldr op failure)
        where (p,t) `op` xs = (p `tok` t) `alt` xs      

lexer :: Parser (Pos Char) [Pos Token]
lexer = lexit [(some (any' literal " \t\n"), Junk),
                (comment, Junk),
                ( any' string ["plus#", "sub#", "mult#", "div#", "eq#", "neq#", "lt#", "gt#","lte#", "gte#", "intToBool#"], Prim), -- want intToBool before in...
                (string "let", Keyword),
                (string "in", Keyword),
                (string "case", Keyword),
                (string "of", Keyword),
                (string "FUN", Obj),
                (string "PAP", Obj),
                (string "CON", Obj),
                (string "THUNK", Obj),
                (string "BLACKHOLE", Obj),
                (string "ERROR", Obj),
                ( any' string ["(",")","=","{","}",";"], Symbol),
                ( any' string ["->"], Symbol),
                (conname, Construct),
                (varname, Ident),
                (floating, Floating), -- want floating before integer
                (number, Integer)]

-- 4.4 Scanning

strip :: [Pos Token] -> [Pos Token]
strip = filter ((/=Junk).fst.fst)

-- full lexer
lexString :: [Char] -> [Parsing.Pos Token]
lexString = strip.fst.head.lexer.prelex