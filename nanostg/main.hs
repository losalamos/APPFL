import Lexer
import Parser

teststring1 = "one = CON(I 1);"
teststring2 = "zero = CON(I 0);\n one = CON(I 1);"

testlex = strip.fst.head.lexer.prelex

testparse = fst.head.program.strip.fst.head.lexer.prelex

testdeclparse = fst.head.declaration.strip.fst.head.lexer.prelex